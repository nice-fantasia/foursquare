import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import test from 'node:test';

import { Server } from 'socket.io';
import { io as createClient, Socket } from 'socket.io-client';

import { RoomManager } from '../game/room_manager';
import { createSocketGateway } from './socket';

type WirePayload = Record<string, any>;

test('two real Socket.IO clients match, move, disconnect and resume', async (t) => {
    const httpServer = createServer();
    const ioServer = new Server(httpServer, {
        cors: { origin: '*' },
    });
    const manager = new RoomManager({
        random: () => 0,
        id: () => 'match-real-transport',
        schedule: (callback, delayMs) => {
            const timer = setTimeout(callback, delayMs);
            timer.unref();
            return timer;
        },
        cancelSchedule: (handle) => clearTimeout(handle as NodeJS.Timeout),
    });
    createSocketGateway(
        ioServer as unknown as Parameters<typeof createSocketGateway>[0],
        manager,
        async () => 'enqueued' as const,
    );
    await new Promise<void>((resolve) => httpServer.listen(0, resolve));
    const address = httpServer.address() as AddressInfo;
    const serverUrl = `http://127.0.0.1:${address.port}`;
    const clients: Socket[] = [];

    t.after(async () => {
        for (const client of clients) client.disconnect();
        await new Promise<void>((resolve) => ioServer.close(() => resolve()));
    });

    const first = await connectClient(serverUrl);
    const second = await connectClient(serverUrl);
    clients.push(first, second);

    const queued = onceEvent(first, 'match_queued');
    first.emit('request_match', {
        protocolVersion: 1,
        playerId: 'device-real-first',
    });
    assert.equal((await queued).status, 'searching');

    const firstMatched = onceEvent(first, 'match_found');
    const secondMatched = onceEvent(second, 'match_found');
    second.emit('request_match', {
        protocolVersion: 1,
        playerId: 'device-real-second',
    });
    const [firstSnapshot, secondSnapshot] = await Promise.all([
        firstMatched,
        secondMatched,
    ]);

    assert.equal(firstSnapshot.matchId, 'match-real-transport');
    assert.equal(secondSnapshot.matchId, firstSnapshot.matchId);
    assert.notEqual(firstSnapshot.color, secondSnapshot.color);
    assert.equal(firstSnapshot.state.revision, 0);
    assert.equal(JSON.stringify(firstSnapshot).includes('device-real'), false);

    const currentColor = firstSnapshot.state.currentTurn as string;
    const mover = firstSnapshot.color === currentColor ? first : second;
    const fromY = currentColor === 'black' ? 0 : 3;
    const toY = currentColor === 'black' ? 1 : 2;
    const firstCommit = onceEvent(first, 'move_committed');
    const secondCommit = onceEvent(second, 'move_committed');
    mover.emit('submit_move', {
        protocolVersion: 1,
        matchId: firstSnapshot.matchId,
        commandId: 'command-real-1',
        expectedRevision: 0,
        from: { x: 0, y: fromY },
        to: { x: 0, y: toY },
    });
    const [commitForFirst, commitForSecond] = await Promise.all([
        firstCommit,
        secondCommit,
    ]);

    assert.equal(commitForFirst.state.revision, 1);
    assert.deepEqual(commitForSecond.state, commitForFirst.state);
    assert.equal(commitForFirst.state.board[fromY][0], null);
    assert.equal(commitForFirst.state.board[toY][0], currentColor);

    const opponentDisconnected = onceEvent(second, 'opponent_disconnected');
    first.disconnect();
    const disconnected = await opponentDisconnected;
    assert.equal(disconnected.matchId, firstSnapshot.matchId);
    assert.equal(typeof disconnected.reconnectDeadlineEpochMs, 'number');

    const returned = await connectClient(serverUrl);
    clients.push(returned);
    const resumedSnapshot = onceEvent(returned, 'authoritative_snapshot');
    const opponentReconnected = onceEvent(second, 'opponent_reconnected');
    returned.emit('resume_match', {
        protocolVersion: 1,
        playerId: 'device-real-first',
        matchId: firstSnapshot.matchId,
    });
    const [resumed, reconnected] = await Promise.all([
        resumedSnapshot,
        opponentReconnected,
    ]);

    assert.equal(resumed.matchId, firstSnapshot.matchId);
    assert.equal(resumed.color, firstSnapshot.color);
    assert.equal(resumed.state.revision, 1);
    assert.deepEqual(resumed.state.board, commitForFirst.state.board);
    assert.equal(reconnected.matchId, firstSnapshot.matchId);

    const refreshedSnapshot = onceEvent(returned, 'authoritative_snapshot');
    returned.emit('request_snapshot', {
        protocolVersion: 1,
        matchId: firstSnapshot.matchId,
    });
    const refreshed = await refreshedSnapshot;
    assert.equal(refreshed.state.revision, 1);
    assert.deepEqual(refreshed.state.board, commitForFirst.state.board);
});

const connectClient = (serverUrl: string): Promise<Socket> =>
    new Promise((resolve, reject) => {
        const socket = createClient(serverUrl, {
            autoConnect: false,
            forceNew: true,
            reconnection: false,
            transports: ['websocket'],
        });
        const timer = setTimeout(() => {
            socket.disconnect();
            reject(new Error('Socket.IO client connection timed out'));
        }, 3_000);
        socket.once('connect', () => {
            clearTimeout(timer);
            resolve(socket);
        });
        socket.once('connect_error', (error) => {
            clearTimeout(timer);
            socket.disconnect();
            reject(error);
        });
        socket.connect();
    });

const onceEvent = (
    socket: Socket,
    event: string,
    timeoutMs = 3_000,
): Promise<WirePayload> =>
    new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            reject(new Error(`Timed out waiting for ${event}`));
        }, timeoutMs);
        socket.once(event, (payload: WirePayload) => {
            clearTimeout(timer);
            resolve(payload);
        });
    });
