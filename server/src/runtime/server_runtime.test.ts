import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { resolve } from 'node:path';
import test from 'node:test';

import { io as createClient, Socket } from 'socket.io-client';

import { loadServerConfig } from '../config';
import { RoomManager } from '../game/room_manager';
import { deserializeFinishedMatchRecord } from '../persistence/finished_match_record';
import {
    InMemoryMatchOutboxRepository,
    type MatchOutboxRepository,
} from '../persistence/match_outbox';
import { PROTOCOL_VERSION } from '../types/protocol';
import { createServerRuntime } from './server_runtime';

test('phase 3 outbox migration is explicitly transactional', () => {
    const migration = readFileSync(
        resolve(
            __dirname,
            '../../prisma/migrations/20260824_phase3_match_outbox/migration.sql',
        ),
        'utf8',
    ).trim();

    assert.match(migration, /^BEGIN;\s/i);
    assert.match(migration, /SET LOCAL lock_timeout = '5s';/i);
    assert.match(migration, /\sCOMMIT;$/i);
});

test('listen failure performs one full shutdown and keeps start rejected', async (t) => {
    const occupied = createServer();
    await new Promise<void>((resolve) => occupied.listen(0, '0.0.0.0', resolve));
    t.after(() => new Promise<void>((resolve) => occupied.close(() => resolve())));
    const port = (occupied.address() as AddressInfo).port;
    let databaseCloseCalls = 0;
    class TrackingRoomManager extends RoomManager {
        public disposeCalls = 0;

        public override dispose(): void {
            this.disposeCalls += 1;
            super.dispose();
        }
    }
    const roomManager = new TrackingRoomManager();
    const runtime = createServerRuntime(
        { ...loadServerConfig({ NODE_ENV: 'test' }), port },
        {
            database: {
                checkReadiness: async () => undefined,
                close: async () => {
                    databaseCloseCalls += 1;
                },
                saveMatchResult: async () => ({ id: 'unused-match' }),
            },
            outboxRepository: new InMemoryMatchOutboxRepository(),
            roomManager,
        },
    );

    const first = runtime.start();
    await assert.rejects(
        first,
        (error: unknown) => isNodeError(error) && error.code === 'EADDRINUSE',
    );
    await assert.rejects(
        runtime.start(),
        (error: unknown) => isNodeError(error) && error.code === 'EADDRINUSE',
    );
    await runtime.shutdown();

    assert.equal(runtime.isShuttingDown(), true);
    assert.equal(databaseCloseCalls, 1);
    assert.equal(roomManager.disposeCalls, 1);
});

test('listen failure reports a fixed event when cleanup also fails', async (t) => {
    const occupied = createServer();
    await new Promise<void>((resolve) => occupied.listen(0, '0.0.0.0', resolve));
    t.after(() => new Promise<void>((resolve) => occupied.close(() => resolve())));
    const originalConsoleError = console.error;
    const logged: unknown[][] = [];
    console.error = (...values: unknown[]) => logged.push(values);
    t.after(() => {
        console.error = originalConsoleError;
    });
    const runtime = createServerRuntime(
        {
            ...loadServerConfig({ NODE_ENV: 'test' }),
            port: (occupied.address() as AddressInfo).port,
        },
        {
            database: {
                checkReadiness: async () => undefined,
                close: async () => {
                    throw new Error('private cleanup failure');
                },
                saveMatchResult: async () => ({ id: 'unused-match' }),
            },
            outboxRepository: new InMemoryMatchOutboxRepository(),
        },
    );

    await assert.rejects(
        runtime.start(),
        (error: unknown) => isNodeError(error) && error.code === 'EADDRINUSE',
    );

    assert.deepEqual(logged, [['Server startup cleanup failed']]);
    assert.equal(JSON.stringify(logged).includes('private'), false);
});

test('server runtime starts ready and shuts every owned resource once', async () => {
    let readinessCalls = 0;
    let closeCalls = 0;
    const database = {
        checkReadiness: async () => {
            readinessCalls += 1;
        },
        close: async () => {
            closeCalls += 1;
        },
        saveMatchResult: async () => ({ id: 'unused-match' }),
    };
    const runtime = createServerRuntime(
        { ...loadServerConfig({ NODE_ENV: 'test' }), port: 0 },
        {
            database,
            outboxRepository: new InMemoryMatchOutboxRepository(),
        },
    );

    const address = await runtime.start();
    const ready = await fetch(
        `http://127.0.0.1:${address.port}/health/ready`,
    );
    assert.equal(ready.status, 200);

    const firstShutdown = runtime.shutdown();
    const secondShutdown = runtime.shutdown();
    await Promise.all([firstShutdown, secondShutdown]);

    assert.equal(readinessCalls, 1);
    assert.equal(closeCalls, 1);
    assert.equal(runtime.isShuttingDown(), true);
});

test('server runtime preserves the database adapter method receiver', async () => {
    class StatefulDatabase {
        public ready = true;

        public async checkReadiness(): Promise<void> {
            if (!this.ready) throw new Error('not ready');
        }

        public async close(): Promise<void> {
            this.ready = false;
        }

        public async saveMatchResult(): Promise<unknown> {
            return { id: 'unused-match' };
        }
    }
    const database = new StatefulDatabase();
    const runtime = createServerRuntime(
        { ...loadServerConfig({ NODE_ENV: 'test' }), port: 0 },
        {
            database,
            outboxRepository: new InMemoryMatchOutboxRepository(),
        },
    );

    const address = await runtime.start();
    const ready = await fetch(
        `http://127.0.0.1:${address.port}/health/ready`,
    );
    await runtime.shutdown();

    assert.equal(ready.status, 200);
    assert.equal(database.ready, false);
});

test('server startup recovers a durable outbox task before later polling', async () => {
    const outboxRepository = new InMemoryMatchOutboxRepository();
    const record = deserializeFinishedMatchRecord(JSON.stringify({
        schemaVersion: 1,
        matchId: 'match-runtime-recovery',
        protocolVersion: 1,
        players: [
            { identityId: 'device-first', color: 'black' },
            { identityId: 'device-second', color: 'white' },
        ],
        winner: 'black',
        startingPlayer: 'black',
        endReason: 'piece_count',
        revision: 1,
        moves: [],
        startedAtEpochMs: 1_000,
        finishedAtEpochMs: 2_000,
    }));
    await outboxRepository.enqueue(record, 2_000);
    const materialized: string[] = [];
    const database = {
        checkReadiness: async () => undefined,
        close: async () => undefined,
        saveMatchResult: async (candidate: typeof record) => {
            materialized.push(candidate.matchId);
            return { id: 'stored-match' };
        },
    };
    const runtime = createServerRuntime(
        { ...loadServerConfig({ NODE_ENV: 'test' }), port: 0 },
        { database, outboxRepository },
    );

    await runtime.start();
    for (let attempt = 0; materialized.length === 0 && attempt < 50; attempt += 1) {
        await new Promise<void>((resolve) => setImmediate(resolve));
    }
    await runtime.shutdown();

    assert.deepEqual(materialized, ['match-runtime-recovery']);
});

test('shutdown total deadline also bounds database close', async () => {
    const database = {
        checkReadiness: async () => undefined,
        close: () => new Promise<void>(() => undefined),
        saveMatchResult: async () => ({ id: 'unused-match' }),
    };
    const runtime = createServerRuntime(
        {
            ...loadServerConfig({ NODE_ENV: 'test' }),
            port: 0,
            shutdownTimeoutMs: 100,
        },
        {
            database,
            outboxRepository: new InMemoryMatchOutboxRepository(),
        },
    );
    await runtime.start();

    const result = await Promise.race([
        runtime.shutdown().then(
            () => ({ status: 'resolved' as const }),
            (error: unknown) => ({
                status: 'rejected' as const,
                message: error instanceof Error ? error.message : '',
            }),
        ),
        new Promise<{ status: 'pending' }>((resolve) => {
            setTimeout(() => resolve({ status: 'pending' }), 300);
        }),
    ]);

    assert.deepEqual(result, {
        status: 'rejected',
        message: 'server_shutdown_timeout',
    });
});

test('first shutdown phase timeout still starts database close once', async () => {
    const outboxRepository = new InMemoryMatchOutboxRepository();
    const record = deserializeFinishedMatchRecord(JSON.stringify({
        schemaVersion: 1,
        matchId: 'match-runtime-timeout',
        protocolVersion: 1,
        players: [
            { identityId: 'device-timeout-a', color: 'black' },
            { identityId: 'device-timeout-b', color: 'white' },
        ],
        winner: 'black',
        startingPlayer: 'black',
        endReason: 'piece_count',
        revision: 1,
        moves: [],
        startedAtEpochMs: 1_000,
        finishedAtEpochMs: 2_000,
    }));
    await outboxRepository.enqueue(record, 2_000);
    let releaseMaterialization: (() => void) | undefined;
    let closeCalls = 0;
    const database = {
        checkReadiness: async () => undefined,
        close: async () => {
            closeCalls += 1;
        },
        saveMatchResult: () => new Promise<void>((resolve) => {
            releaseMaterialization = resolve;
        }),
    };
    const runtime = createServerRuntime(
        {
            ...loadServerConfig({ NODE_ENV: 'test' }),
            port: 0,
            shutdownTimeoutMs: 100,
        },
        { database, outboxRepository },
    );
    await runtime.start();
    while (!releaseMaterialization) {
        await new Promise<void>((resolve) => setImmediate(resolve));
    }

    const result = await runtime.shutdown().then(
        () => ({ status: 'resolved' as const, message: '' }),
        (error: unknown) => ({
            status: 'rejected' as const,
            message: error instanceof Error ? error.message : '',
        }),
    );
    await new Promise<void>((resolve) => setImmediate(resolve));
    releaseMaterialization!();

    assert.deepEqual(result, {
        status: 'rejected',
        message: 'server_shutdown_timeout',
    });
    assert.equal(closeCalls, 1);
});

test('gateway flush failure waits for outbox work before closing database', async () => {
    const pendingRecord = deserializeFinishedMatchRecord(JSON.stringify({
        schemaVersion: 1,
        matchId: 'match-runtime-pending',
        protocolVersion: 1,
        players: [
            { identityId: 'device-pending-a', color: 'black' },
            { identityId: 'device-pending-b', color: 'white' },
        ],
        winner: 'black',
        startingPlayer: 'black',
        endReason: 'piece_count',
        revision: 1,
        moves: [],
        startedAtEpochMs: 1_000,
        finishedAtEpochMs: 2_000,
    }));
    let claimed = false;
    const outboxRepository: MatchOutboxRepository = {
        enqueue: async () => {
            throw new Error('private enqueue failure');
        },
        claim: async () => {
            if (claimed) return [];
            claimed = true;
            return [{
                taskId: 'pending-task',
                leaseToken: 'pending-lease',
                attemptNumber: 1,
                record: pendingRecord,
            }];
        },
        acknowledge: async () => undefined,
        reschedule: async () => undefined,
    };
    let releaseMaterialization: (() => void) | undefined;
    let materializationFinished = false;
    let databaseCloseCalls = 0;
    let closeSawFinishedMaterialization = false;
    const database = {
        checkReadiness: async () => undefined,
        close: async () => {
            databaseCloseCalls += 1;
            closeSawFinishedMaterialization = materializationFinished;
        },
        saveMatchResult: async () => {
            await new Promise<void>((resolve) => {
                releaseMaterialization = resolve;
            });
            materializationFinished = true;
            return { id: 'stored-pending-match' };
        },
    };
    const roomManager = new RoomManager();
    const runtime = createServerRuntime(
        { ...loadServerConfig({ NODE_ENV: 'test' }), port: 0 },
        { database, outboxRepository, roomManager },
    );
    const address = await runtime.start();
    while (!releaseMaterialization) {
        await new Promise<void>((resolve) => setImmediate(resolve));
    }
    const serverUrl = `http://127.0.0.1:${address.port}`;
    const first = socketClient(serverUrl);
    const second = socketClient(serverUrl);
    const clients = [first, second];
    const firstConnected = onceEvent(first, 'connect');
    const secondConnected = onceEvent(second, 'connect');
    first.connect();
    second.connect();
    await Promise.all([firstConnected, secondConnected]);
    const firstMatched = onceEvent(first, 'match_found');
    const secondMatched = onceEvent(second, 'match_found');
    first.emit('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'runtime-player-first',
    });
    second.emit('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'runtime-player-second',
    });
    await Promise.all([firstMatched, secondMatched]);
    const room = roomManager.getRoomBySocketId(first.id!);
    assert.ok(room);
    room.gameState = {
        ...room.gameState,
        status: 'finished',
        winner: 'black',
        endReason: 'disconnect',
        revision: room.gameState.revision + 1,
    };
    roomManager.emit('game_finished', {
        roomId: room.id,
        state: room.gameState,
    });
    await new Promise<void>((resolve) => setImmediate(resolve));

    const shutdownResult = runtime.shutdown().then(
        () => ({ status: 'resolved' as const, message: '' }),
        (error: unknown) => ({
            status: 'rejected' as const,
            message: error instanceof Error ? error.message : '',
        }),
    );
    await new Promise<void>((resolve) => setImmediate(resolve));
    const closeCallsBeforeRelease = databaseCloseCalls;
    releaseMaterialization!();
    const result = await shutdownResult;
    for (const client of clients) client.disconnect();

    assert.equal(closeCallsBeforeRelease, 0);
    assert.equal(databaseCloseCalls, 1);
    assert.equal(closeSawFinishedMaterialization, true);
    assert.deepEqual(result, {
        status: 'rejected',
        message: 'server_shutdown_failed',
    });
});

const onceEvent = (
    socket: Socket,
    event: string,
    timeoutMs = 3_000,
): Promise<unknown> => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timed out: ${event}`)), timeoutMs);
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

const isNodeError = (
    error: unknown,
): error is Error & { code: string } => error instanceof Error
    && 'code' in error
    && typeof error.code === 'string';
