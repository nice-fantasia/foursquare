import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import test from 'node:test';

import { io as createClient, Socket } from 'socket.io-client';

import { loadServerConfig } from '../config';
import { createSecureSocketServer } from './socket_security';

test('Socket origin policy allows native clients and rejects unknown browser origins', async (t) => {
    const httpServer = createServer();
    const ioServer = createSecureSocketServer(
        httpServer,
        loadServerConfig({
            NODE_ENV: 'test',
            CORS_ORIGINS: 'https://game.example.com',
        }),
    );
    await new Promise<void>((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
    const address = httpServer.address() as AddressInfo;
    const serverUrl = `http://127.0.0.1:${address.port}`;
    const clients: Socket[] = [];
    t.after(async () => {
        for (const client of clients) client.disconnect();
        await new Promise<void>((resolve) => ioServer.close(() => resolve()));
    });

    const nativeClient = createClient(serverUrl, {
        autoConnect: false,
        forceNew: true,
        reconnection: false,
        transports: ['websocket'],
    });
    clients.push(nativeClient);
    const connected = onceEvent(nativeClient, 'connect');
    nativeClient.connect();
    await connected;

    const blockedClient = createClient(serverUrl, {
        autoConnect: false,
        extraHeaders: { Origin: 'https://attacker.example' },
        forceNew: true,
        reconnection: false,
        transports: ['websocket'],
    });
    clients.push(blockedClient);
    const rejected = onceEvent(blockedClient, 'connect_error');
    blockedClient.connect();
    await rejected;

    assert.equal(nativeClient.connected, true);
    assert.equal(blockedClient.connected, false);
});

test('Socket handshakes above the per-peer quota fail with a fixed error', async (t) => {
    const httpServer = createServer();
    const ioServer = createSecureSocketServer(
        httpServer,
        loadServerConfig({
            NODE_ENV: 'test',
            SOCKET_CONNECTION_RATE_LIMIT_WINDOW_MS: '1000',
            SOCKET_CONNECTION_RATE_LIMIT_MAX: '1',
        }),
    );
    let engineConnections = 0;
    ioServer.engine.on('connection', () => {
        engineConnections += 1;
    });
    await new Promise<void>((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
    const address = httpServer.address() as AddressInfo;
    const serverUrl = `http://127.0.0.1:${address.port}`;
    const clients: Socket[] = [];
    t.after(async () => {
        for (const client of clients) client.disconnect();
        await new Promise<void>((resolve) => ioServer.close(() => resolve()));
    });

    const first = socketClient(serverUrl);
    clients.push(first);
    const firstConnected = onceEvent(first, 'connect');
    first.connect();
    await firstConnected;

    const second = socketClient(serverUrl);
    clients.push(second);
    const rejected = onceEvent(second, 'connect_error');
    second.connect();
    const error = await rejected;

    assert.ok(error instanceof Error);
    assert.equal(error.message, 'websocket error');
    assert.equal(second.connected, false);
    assert.equal(engineConnections, 1);
});

test('trusted proxy mode rejects a missing forwarding chain before Engine.IO connects', async (t) => {
    const httpServer = createServer();
    const ioServer = createSecureSocketServer(
        httpServer,
        loadServerConfig({
            NODE_ENV: 'test',
            TRUSTED_PROXY_HOPS: '1',
        }),
    );
    let engineConnections = 0;
    ioServer.engine.on('connection', () => {
        engineConnections += 1;
    });
    await new Promise<void>((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
    const address = httpServer.address() as AddressInfo;
    const client = socketClient(`http://127.0.0.1:${address.port}`);
    t.after(async () => {
        client.disconnect();
        await new Promise<void>((resolve) => ioServer.close(() => resolve()));
    });
    const rejected = onceEvent(client, 'connect_error');

    client.connect();
    await rejected;

    assert.equal(client.connected, false);
    assert.equal(engineConnections, 0);
});

test('Socket events above the per-connection quota are dropped before disconnect', async (t) => {
    const httpServer = createServer();
    const ioServer = createSecureSocketServer(
        httpServer,
        loadServerConfig({
            NODE_ENV: 'test',
            SOCKET_EVENT_RATE_LIMIT_WINDOW_MS: '1000',
            SOCKET_EVENT_RATE_LIMIT_MAX: '1',
        }),
    );
    let acceptedEvents = 0;
    ioServer.on('connection', (socket) => {
        socket.on('action', () => {
            acceptedEvents += 1;
            socket.emit('accepted');
        });
    });
    await new Promise<void>((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
    const address = httpServer.address() as AddressInfo;
    const client = socketClient(`http://127.0.0.1:${address.port}`);
    t.after(async () => {
        client.disconnect();
        await new Promise<void>((resolve) => ioServer.close(() => resolve()));
    });
    const connected = onceEvent(client, 'connect');
    client.connect();
    await connected;

    const accepted = onceEvent(client, 'accepted');
    client.emit('action');
    await accepted;
    const disconnected = onceEvent(client, 'disconnect');
    client.emit('action');
    await disconnected;

    assert.equal(acceptedEvents, 1);
    assert.equal(client.connected, false);
});

test('Socket payloads above the configured byte limit close before dispatch', async (t) => {
    const httpServer = createServer();
    const ioServer = createSecureSocketServer(
        httpServer,
        loadServerConfig({
            NODE_ENV: 'test',
            SOCKET_MAX_PAYLOAD_BYTES: '1024',
        }),
    );
    let dispatched = false;
    ioServer.on('connection', (socket) => {
        socket.on('oversized', () => {
            dispatched = true;
        });
    });
    await new Promise<void>((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
    const address = httpServer.address() as AddressInfo;
    const client = socketClient(`http://127.0.0.1:${address.port}`);
    t.after(async () => {
        client.disconnect();
        await new Promise<void>((resolve) => ioServer.close(() => resolve()));
    });
    const connected = onceEvent(client, 'connect');
    client.connect();
    await connected;

    const disconnected = onceEvent(client, 'disconnect');
    client.emit('oversized', 'x'.repeat(2_000));
    await disconnected;

    assert.equal(dispatched, false);
});

const onceEvent = (
    socket: Socket,
    event: string,
    timeoutMs = 3_000,
): Promise<unknown> => new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
        reject(new Error(`Timed out waiting for ${event}`));
    }, timeoutMs);
    socket.once(event, (payload: unknown) => {
        clearTimeout(timer);
        resolve(payload);
    });
});

const socketClient = (serverUrl: string): Socket => createClient(serverUrl, {
    autoConnect: false,
    forceNew: true,
    reconnection: false,
    transports: ['websocket'],
});
