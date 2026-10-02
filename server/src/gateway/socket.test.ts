import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';

import { createSocketGateway } from './socket';
import type { MatchmakingResult } from '../game/room_manager';
import type { FinishedMatchRecord } from '../persistence/finished_match_record';
import { InMemoryMatchOutboxRepository } from '../persistence/match_outbox';
import { MatchOutboxWorker } from '../persistence/match_outbox_worker';
import type { GameState, Player, Room } from '../types/game';
import type {
    AuthoritativeSnapshot,
    MoveDecision,
    MoveIntent,
} from '../types/protocol';
import { PROTOCOL_VERSION } from '../types/protocol';

type EmittedEvent = {
    event: string;
    payload: unknown;
};

class FakeSocket {
    public readonly emitted: EmittedEvent[] = [];
    public readonly joinedRooms: string[] = [];
    private readonly listeners = new Map<string, (payload?: unknown) => void>();

    public constructor(public readonly id: string) {}

    public emit(event: string, payload: unknown): void {
        this.emitted.push({ event, payload });
    }

    public on(event: string, listener: (payload?: unknown) => void): void {
        this.listeners.set(event, listener);
    }

    public join(roomId: string): void {
        this.joinedRooms.push(roomId);
    }

    public trigger(event: string, payload?: unknown): void {
        this.listeners.get(event)?.(payload);
    }
}

class FakeIo {
    public readonly roomEvents: Array<EmittedEvent & { target: string }> = [];
    public readonly sockets = {
        sockets: new Map<string, FakeSocket>(),
    };
    private connectionListener?: (socket: FakeSocket) => void;

    public on(event: string, listener: (socket: FakeSocket) => void): void {
        assert.equal(event, 'connection');
        this.connectionListener = listener;
    }

    public to(target: string): { emit: (event: string, payload: unknown) => void } {
        return {
            emit: (event, payload) => {
                this.roomEvents.push({ target, event, payload });
            },
        };
    }

    public connect(socket: FakeSocket): void {
        this.sockets.sockets.set(socket.id, socket);
        this.connectionListener?.(socket);
    }
}

class FakeRoomManager extends EventEmitter {
    public readonly calls: string[] = [];
    public resumeResult?: AuthoritativeSnapshot;
    public snapshotResult?: AuthoritativeSnapshot;
    public queuedRoom: Room | null = null;
    public roomBySocket?: Room;
    public moveDecision: MoveDecision = {
        type: 'rejected',
        protocolVersion: PROTOCOL_VERSION,
        commandId: 'command-1',
        reason: 'room_not_found',
        currentRevision: 0,
    };
    public handledIntent?: MoveIntent;
    public handleMoveCalls = 0;
    public disconnectDeadlineEpochMs = 30_000;
    public removeFromQueueResult = true;

    public resumePlayer(
        playerId: string,
        socketId: string,
        matchId: string,
    ): AuthoritativeSnapshot | undefined {
        this.calls.push(`resume:${playerId}:${socketId}:${matchId}`);
        return this.resumeResult;
    }

    public createSnapshotForSocket(
        socketId: string,
        matchId: string,
    ): AuthoritativeSnapshot | undefined {
        this.calls.push(`snapshot:${socketId}:${matchId}`);
        return this.snapshotResult;
    }

    public queuePlayer(player: Player): MatchmakingResult {
        this.calls.push(`queue:${player.id}:${player.socketId}`);
        return this.queuedRoom == null
            ? { status: 'queued' }
            : { status: 'matched', room: this.queuedRoom };
    }

    public removePlayerFromQueue(playerId: string, socketId: string): boolean {
        this.calls.push(`cancel:${playerId}:${socketId}`);
        return this.removeFromQueueResult;
    }

    public handleMove(socketId: string, intent: MoveIntent): MoveDecision {
        this.calls.push(`move:${socketId}`);
        this.handleMoveCalls += 1;
        this.handledIntent = intent;
        return this.moveDecision;
    }

    public getRoomBySocketId(): Room | undefined {
        return this.roomBySocket;
    }

    public removePlayer(socketId: string): Room | undefined {
        this.calls.push(`disconnect:${socketId}`);
        return this.roomBySocket;
    }

    public getDisconnectDeadline(socketId: string): number | undefined {
        this.calls.push(`disconnect-deadline:${socketId}`);
        return this.disconnectDeadlineEpochMs;
    }
}

const createState = (status: GameState['status'] = 'playing'): GameState => ({
    board: Array.from({ length: 4 }, () => Array(4).fill(null)),
    currentTurn: 'black',
    status,
    moveHistory: [],
    noCapturePly: 0,
    revision: status === 'playing' ? 0 : 1,
    ...(status === 'finished'
        ? { winner: 'black' as const, endReason: 'disconnect' as const }
        : {}),
});

const createRoom = (firstSocketId = 'socket-a'): Room => ({
    id: 'match-1',
    players: [
        { id: 'player-aaaa', socketId: firstSocketId, name: 'A' },
        { id: 'player-bbbb', socketId: 'socket-b', name: 'B' },
    ],
    spectators: [],
    gameState: createState(),
    colorBySocketId: {
        [firstSocketId]: 'black',
        'socket-b': 'white',
    },
    startingPlayer: 'black',
    turnDeadlineEpochMs: 60_000,
    createdAt: 0,
});

const setup = () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    const persisted: FinishedMatchRecord[] = [];
    createSocketGateway(
        io,
        manager,
        async (record) => {
            persisted.push(record);
            return 'enqueued' as const;
        },
        () => undefined,
        () => 70_000,
    );
    return { io, manager, persisted };
};

test('resume_match restores a retained room without entering matchmaking', () => {
    const { io, manager } = setup();
    const socket = new FakeSocket('socket-new');
    const room = createRoom('socket-new');
    manager.roomBySocket = room;
    manager.resumeResult = {
        protocolVersion: PROTOCOL_VERSION,
        matchId: room.id,
        color: 'black',
        state: room.gameState,
        turnDeadlineEpochMs: room.turnDeadlineEpochMs,
        opponentConnected: true,
    };

    io.connect(socket);
    socket.trigger('resume_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
        matchId: room.id,
    });

    assert.deepEqual(manager.calls, [
        'resume:player-aaaa:socket-new:match-1',
    ]);
    assert.deepEqual(socket.joinedRooms, ['match-1']);
    assert.equal(
        socket.emitted.some((event) => event.event === 'authoritative_snapshot'),
        true,
    );
    assert.equal(
        io.roomEvents.some(
            (event) => event.target === 'socket-b'
                && event.event === 'opponent_reconnected',
        ),
        true,
    );
});

test('request_snapshot returns only the current socket authoritative view', () => {
    const { io, manager } = setup();
    const socket = new FakeSocket('socket-a');
    const room = createRoom();
    manager.snapshotResult = {
        protocolVersion: PROTOCOL_VERSION,
        matchId: room.id,
        color: 'black',
        state: room.gameState,
        turnDeadlineEpochMs: room.turnDeadlineEpochMs,
        opponentConnected: true,
    };
    io.connect(socket);

    socket.trigger('request_snapshot', {
        protocolVersion: PROTOCOL_VERSION,
        matchId: room.id,
    });

    assert.deepEqual(manager.calls, ['snapshot:socket-a:match-1']);
    assert.equal(
        socket.emitted.some(
            (event) => event.event === 'authoritative_snapshot',
        ),
        true,
    );

    manager.snapshotResult = undefined;
    socket.trigger('request_snapshot', {
        protocolVersion: PROTOCOL_VERSION,
        matchId: room.id,
    });
    assert.deepEqual(socket.emitted.at(-1), {
        event: 'snapshot_rejected',
        payload: {
            protocolVersion: PROTOCOL_VERSION,
            matchId: room.id,
            reason: 'not_room_player',
        },
    });
});

test('match lifecycle responses always carry the protocol version', () => {
    const { io } = setup();
    const socket = new FakeSocket('socket-a');
    io.connect(socket);

    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'short',
    });
    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });
    socket.trigger('cancel_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });

    for (const eventName of [
        'match_rejected',
        'match_queued',
        'match_cancelled',
    ]) {
        const event = socket.emitted.find(
            (candidate) => candidate.event === eventName,
        );
        assert.equal(
            (event?.payload as { protocolVersion?: number }).protocolVersion,
            PROTOCOL_VERSION,
            `${eventName} must carry protocolVersion`,
        );
    }
});

test('match requests reject an unsupported protocol version', () => {
    const { io } = setup();
    const socket = new FakeSocket('socket-a');
    io.connect(socket);

    socket.trigger('request_match', {
        protocolVersion: 999,
        playerId: 'player-aaaa',
    });

    const rejection = socket.emitted.find(
        (event) => event.event === 'match_rejected',
    );
    assert.equal(
        (rejection?.payload as { reason?: string }).reason,
        'invalid_protocol',
    );
});

test('cancel_match rejects when that identity is not queued on the socket', () => {
    const { io, manager } = setup();
    const socket = new FakeSocket('socket-a');
    manager.removeFromQueueResult = false;
    io.connect(socket);

    socket.trigger('cancel_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-bbbb',
    });

    assert.equal(
        socket.emitted.some((event) => event.event === 'match_cancelled'),
        false,
    );
    assert.deepEqual(
        socket.emitted.find(
            (event) => event.event === 'match_rejected',
        )?.payload,
        {
            protocolVersion: PROTOCOL_VERSION,
            reason: 'not_queued',
        },
    );
});

test('hostile match payload getters cannot escape socket handlers', () => {
    const { io } = setup();
    const socket = new FakeSocket('socket-a');
    io.connect(socket);
    const hostilePayload = new Proxy({}, {
        get: () => {
            throw new Error('hostile getter');
        },
    });

    assert.doesNotThrow(() => socket.trigger('request_match', hostilePayload));
    assert.doesNotThrow(() => socket.trigger('cancel_match', hostilePayload));
    assert.deepEqual(
        socket.emitted
            .filter((event) => event.event === 'match_rejected')
            .map((event) => (event.payload as { reason: string }).reason),
        ['invalid_payload', 'invalid_payload'],
    );
});

test('match_found never exposes either anonymous reconnect identity', () => {
    const { io, manager } = setup();
    const firstSocket = new FakeSocket('socket-a');
    const secondSocket = new FakeSocket('socket-b');
    const room = createRoom();
    manager.queuedRoom = room;
    io.sockets.sockets.set(secondSocket.id, secondSocket);
    io.connect(firstSocket);

    firstSocket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });

    for (const playerSocket of [firstSocket, secondSocket]) {
        const found = playerSocket.emitted.find(
            (event) => event.event === 'match_found',
        );
        const serialized = JSON.stringify(found?.payload);
        assert.equal(serialized.includes('player-aaaa'), false);
        assert.equal(serialized.includes('player-bbbb'), false);
        assert.equal(serialized.includes('opponentId'), false);
        assert.equal(serialized.includes('ownId'), false);
    }
});

test('submit_move rejects invalid payloads and forwards only trusted fields', () => {
    const { io, manager } = setup();
    const socket = new FakeSocket('socket-a');
    io.connect(socket);

    socket.trigger('submit_move', {
        matchId: 'match-1',
        commandId: 'command-1',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });
    socket.trigger('submit_move', {
        protocolVersion: 999,
        matchId: 'match-1',
        commandId: 'command-1',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });
    socket.trigger('submit_move', {
        protocolVersion: PROTOCOL_VERSION,
        matchId: 'match-1',
        commandId: 'command-1',
        expectedRevision: 'zero',
        from: null,
        to: { x: 0, y: 1 },
    });
    socket.trigger('submit_move', {
        protocolVersion: PROTOCOL_VERSION,
        matchId: 'm'.repeat(129),
        commandId: 'command-1',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });
    socket.trigger('submit_move', {
        protocolVersion: PROTOCOL_VERSION,
        matchId: 'match-1',
        commandId: 'contains spaces',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });

    assert.equal(manager.handleMoveCalls, 0);
    assert.deepEqual(
        socket.emitted
            .filter((event) => event.event === 'move_rejected')
            .map((event) => (event.payload as { reason: string }).reason),
        [
            'invalid_protocol',
            'invalid_protocol',
            'invalid_payload',
            'invalid_payload',
            'invalid_payload',
        ],
    );

    socket.trigger('submit_move', {
        protocolVersion: PROTOCOL_VERSION,
        matchId: 'match-1',
        commandId: 'command-1',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
        color: 'white',
        capturedPieces: [{ x: 1, y: 1 }],
        winner: 'white',
    });

    assert.equal(manager.handleMoveCalls, 1);
    assert.deepEqual(manager.handledIntent, {
        protocolVersion: PROTOCOL_VERSION,
        matchId: 'match-1',
        commandId: 'command-1',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });

    const hostilePayload = new Proxy({}, {
        get: () => {
            throw new Error('hostile getter');
        },
    });
    assert.doesNotThrow(() => socket.trigger('submit_move', hostilePayload));

    manager.handleMove = () => {
        throw new Error('unexpected manager failure');
    };
    assert.doesNotThrow(() => socket.trigger('submit_move', {
        protocolVersion: PROTOCOL_VERSION,
        matchId: 'match-1',
        commandId: 'command-2',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    }));
});

test('timeout or disconnect completion broadcasts and persists exactly once', () => {
    const { io, manager, persisted } = setup();
    const socket = new FakeSocket('socket-a');
    const room = createRoom();
    manager.queuedRoom = room;
    manager.roomBySocket = room;
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));
    io.connect(socket);
    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });
    socket.trigger('disconnect');

    assert.deepEqual(
        io.roomEvents.find(
            (event) => event.event === 'opponent_disconnected',
        )?.payload,
        {
            protocolVersion: PROTOCOL_VERSION,
            matchId: room.id,
            reconnectDeadlineEpochMs: 30_000,
        },
    );

    room.gameState = createState('finished');
    const finished = { roomId: room.id, state: room.gameState };
    manager.emit('game_finished', finished);
    manager.emit('game_finished', finished);

    assert.equal(
        io.roomEvents.filter((event) => event.event === 'game_over').length,
        1,
    );
    assert.equal(persisted.length, 1);
    assert.equal(persisted[0].matchId, room.id);
    assert.equal(persisted[0].startedAtEpochMs, room.createdAt);
    assert.equal(persisted[0].finishedAtEpochMs, 70_000);
    assert.deepEqual(persisted[0].players, [
        { identityId: 'player-aaaa', color: 'black' },
        { identityId: 'player-bbbb', color: 'white' },
    ]);
    assert.equal(Object.isFrozen(persisted[0]), true);
});

test('persistence keeps retrying without rebroadcasting game over', async () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    const retries: Array<{ callback: () => void; delayMs: number }> = [];
    let attempts = 0;
    let now = 70_000;
    const attemptedRecords: FinishedMatchRecord[] = [];
    createSocketGateway(
        io,
        manager,
        async (record) => {
            attempts += 1;
            attemptedRecords.push(record);
            if (attempts < 4) throw new Error('database unavailable');
            return 'enqueued' as const;
        },
        (callback, delayMs) => {
            retries.push({ callback, delayMs });
        },
        () => now,
        () => undefined,
        () => 0.5,
    );
    const socket = new FakeSocket('socket-a');
    const room = createRoom();
    manager.queuedRoom = room;
    manager.roomBySocket = room;
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));
    io.connect(socket);
    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });
    room.gameState = createState('finished');

    manager.emit('game_finished', { roomId: room.id, state: room.gameState });
    manager.emit('game_finished', { roomId: room.id, state: room.gameState });
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(attempts, 1);
    assert.equal(retries[0].delayMs, 1_000);

    now = 80_000;
    retries.shift()!.callback();
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(attempts, 2);
    assert.equal(retries[0].delayMs, 2_000);

    now = 90_000;
    retries.shift()!.callback();
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(attempts, 3);
    assert.equal(retries[0].delayMs, 4_000);

    now = 100_000;
    retries.shift()!.callback();
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(attempts, 4);
    assert.equal(
        io.roomEvents.filter((event) => event.event === 'game_over').length,
        1,
    );
    assert.equal(
        attemptedRecords.every((record) => record === attemptedRecords[0]),
        true,
    );
    assert.equal(attemptedRecords[0].finishedAtEpochMs, 70_000);
});

test('persistence retry jitter disperses equal first failures', async () => {
    const firstDelayFor = async (randomValue: number): Promise<number> => {
        const io = new FakeIo();
        const manager = new FakeRoomManager();
        const delays: number[] = [];
        createSocketGateway(
            io,
            manager,
            async () => {
                throw new Error('database unavailable');
            },
            (_callback, delayMs) => delays.push(delayMs),
            () => 70_000,
            () => undefined,
            () => randomValue,
        );
        const socket = new FakeSocket('socket-a');
        const room = createRoom();
        manager.queuedRoom = room;
        manager.roomBySocket = room;
        io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));
        io.connect(socket);
        socket.trigger('request_match', {
            protocolVersion: PROTOCOL_VERSION,
            playerId: 'player-aaaa',
        });
        room.gameState = createState('finished');
        manager.emit('game_finished', { roomId: room.id, state: room.gameState });
        await new Promise<void>((resolve) => setImmediate(resolve));
        return delays[0];
    };

    assert.equal(await firstDelayFor(0), 500);
    assert.equal(await firstDelayFor(1), 1_500);
});

test('durable enqueue attempts use a global concurrency bound', async () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    const started: string[] = [];
    const finish = new Map<string, () => void>();
    const lifecycle = createSocketGateway(
        io,
        manager,
        (record) => new Promise<'enqueued'>((resolve) => {
            started.push(record.matchId);
            finish.set(record.matchId, () => resolve('enqueued'));
        }),
    );
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));

    for (let index = 0; index < 3; index += 1) {
        const socket = new FakeSocket(`socket-${index}`);
        const room = createRoom(socket.id);
        room.id = `match-${index}`;
        manager.queuedRoom = room;
        manager.roomBySocket = room;
        io.connect(socket);
        socket.trigger('request_match', {
            protocolVersion: PROTOCOL_VERSION,
            playerId: `player-${index}aaa`,
        });
        room.gameState = createState('finished');
        manager.emit('game_finished', { roomId: room.id, state: room.gameState });
    }

    assert.deepEqual(started, ['match-0', 'match-1']);
    finish.get('match-0')!();
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.deepEqual(started, ['match-0', 'match-1', 'match-2']);

    finish.get('match-1')!();
    finish.get('match-2')!();
    await lifecycle.shutdown();
});

test('shutdown final flush keeps the same global concurrency bound', async () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    const completions: Array<() => void> = [];
    let active = 0;
    let maximumActive = 0;
    let attempts = 0;
    const lifecycle = createSocketGateway(
        io,
        manager,
        () => new Promise<'enqueued'>((resolve) => {
            attempts += 1;
            active += 1;
            maximumActive = Math.max(maximumActive, active);
            completions.push(() => {
                active -= 1;
                resolve('enqueued');
            });
        }),
    );
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));

    for (let index = 0; index < 4; index += 1) {
        const socket = new FakeSocket(`shutdown-socket-${index}`);
        const room = createRoom(socket.id);
        room.id = `shutdown-match-${index}`;
        manager.queuedRoom = room;
        manager.roomBySocket = room;
        io.connect(socket);
        socket.trigger('request_match', {
            protocolVersion: PROTOCOL_VERSION,
            playerId: `shutdown-player-${index}`,
        });
        room.gameState = createState('finished');
        manager.emit('game_finished', { roomId: room.id, state: room.gameState });
    }

    assert.equal(active, 2);
    const shutdown = lifecycle.shutdown();
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(maximumActive, 2);

    let completed = 0;
    while (completed < 4) {
        while (completed < completions.length) {
            completions[completed++]();
        }
        await new Promise<void>((resolve) => setImmediate(resolve));
    }
    await shutdown;
    assert.equal(attempts, 4);
    assert.equal(active, 0);
});

test('an invalid resolved enqueue result is retried', async () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    const scheduled: Array<{ callback: () => void; delayMs: number }> = [];
    createSocketGateway(
        io,
        manager,
        async () => false as never,
        (callback, delayMs) => {
            const handle = { callback, delayMs };
            scheduled.push(handle);
            return handle;
        },
        () => 70_000,
        () => undefined,
        () => 0.5,
    );
    const socket = new FakeSocket('socket-a');
    const room = createRoom();
    manager.queuedRoom = room;
    manager.roomBySocket = room;
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));
    io.connect(socket);
    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });
    room.gameState = createState('finished');

    manager.emit('game_finished', { roomId: room.id, state: room.gameState });
    await new Promise<void>((resolve) => setImmediate(resolve));

    assert.equal(scheduled.length, 1);
    assert.equal(scheduled[0].delayMs, 1_000);
});

test('gateway shutdown reports a failed final scheduled-record flush', async () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    const scheduled: Array<{ callback: () => void; delayMs: number }> = [];
    const cancelled: unknown[] = [];
    let attempts = 0;
    const lifecycle = createSocketGateway(
        io,
        manager,
        async () => {
            attempts += 1;
            throw new Error('database unavailable');
        },
        (callback, delayMs) => {
            const handle = { callback, delayMs };
            scheduled.push(handle);
            return handle;
        },
        () => 0,
        (handle) => cancelled.push(handle),
    );
    const socket = new FakeSocket('socket-a');
    const room = createRoom();
    manager.queuedRoom = room;
    manager.roomBySocket = room;
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));
    io.connect(socket);
    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });
    room.gameState = createState('finished');
    manager.emit('game_finished', { roomId: room.id, state: room.gameState });
    await Promise.resolve();

    await assert.rejects(
        lifecycle.shutdown(),
        (error: unknown) => error instanceof Error
            && error.message === 'match_persistence_final_flush_failed'
            && !error.message.includes(room.id)
            && !error.message.includes('player-aaaa'),
    );
    assert.equal(attempts, 2);
    scheduled[0].callback();
    await Promise.resolve();

    assert.equal(attempts, 2);
    assert.deepEqual(cancelled, [scheduled[0]]);
});

test('successful shutdown flush is recovered by a new outbox worker', async () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    const outbox = new InMemoryMatchOutboxRepository();
    const scheduled: Array<{ callback: () => void; delayMs: number }> = [];
    let enqueueAttempts = 0;
    const lifecycle = createSocketGateway(
        io,
        manager,
        async (record) => {
            enqueueAttempts += 1;
            if (enqueueAttempts === 1) throw new Error('database unavailable');
            return outbox.enqueue(record, 0);
        },
        (callback, delayMs) => {
            const handle = { callback, delayMs };
            scheduled.push(handle);
            return handle;
        },
        () => 0,
        () => undefined,
    );
    const socket = new FakeSocket('socket-a');
    const room = createRoom();
    room.gameState = createState('finished');
    manager.queuedRoom = room;
    manager.roomBySocket = room;
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));
    io.connect(socket);
    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });
    manager.emit('game_finished', { roomId: room.id, state: room.gameState });
    await Promise.resolve();

    await lifecycle.shutdown();
    assert.equal(enqueueAttempts, 2);

    const recovered: string[] = [];
    const worker = new MatchOutboxWorker({
        repository: outbox,
        materialize: async (record) => {
            recovered.push(record.matchId);
        },
        now: () => 0,
        random: () => 0.5,
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    await worker.start();
    for (let attempt = 0; recovered.length === 0 && attempt < 50; attempt += 1) {
        await new Promise<void>((resolve) => setImmediate(resolve));
    }
    await worker.shutdown();

    assert.deepEqual(recovered, [room.id]);
});

test('gateway shutdown is idempotent and waits for the current persistence attempt', async () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    let finishPersistence: (() => void) | undefined;
    const lifecycle = createSocketGateway(
        io,
        manager,
        () => new Promise<'enqueued'>((resolve) => {
            finishPersistence = () => resolve('enqueued');
        }),
    );
    const socket = new FakeSocket('socket-a');
    const room = createRoom();
    manager.queuedRoom = room;
    manager.roomBySocket = room;
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));
    io.connect(socket);
    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });
    room.gameState = createState('finished');
    manager.emit('game_finished', { roomId: room.id, state: room.gameState });
    let shutdownFinished = false;

    const firstShutdown = lifecycle.shutdown().then(() => {
        shutdownFinished = true;
    });
    const secondShutdown = lifecycle.shutdown();
    await Promise.resolve();
    assert.equal(shutdownFinished, false);

    finishPersistence!();
    await Promise.all([firstShutdown, secondShutdown]);
    assert.equal(shutdownFinished, true);
});

test('completion de-duplication covers every retained finished room', () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    createSocketGateway(io, manager, () => 'enqueued');
    const state = createState('finished');

    for (let index = 0; index < 1_025; index += 1) {
        manager.emit('game_finished', { roomId: `match-${index}`, state });
    }
    manager.emit('game_finished', { roomId: 'match-0', state });

    assert.equal(
        io.roomEvents.filter((event) => event.event === 'game_over').length,
        1_025,
    );
});

test('a terminal committed move uses the same de-duplicated completion path', () => {
    const { io, manager, persisted } = setup();
    const socket = new FakeSocket('socket-a');
    const room = createRoom();
    room.gameState = createState('finished');
    manager.roomBySocket = room;
    manager.moveDecision = {
        type: 'committed',
        protocolVersion: PROTOCOL_VERSION,
        commandId: 'command-1',
        state: room.gameState,
        capturedPieces: [],
        turnDeadlineEpochMs: room.turnDeadlineEpochMs,
    };
    manager.queuedRoom = room;
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));
    io.connect(socket);
    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });

    const intent = {
        protocolVersion: PROTOCOL_VERSION,
        matchId: room.id,
        commandId: 'command-1',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    };
    socket.trigger('submit_move', intent);
    manager.emit('game_finished', { roomId: room.id, state: room.gameState });

    assert.equal(
        io.roomEvents.filter((event) => event.event === 'game_over').length,
        1,
    );
    assert.equal(persisted.length, 1);
    assert.equal(persisted[0].matchId, room.id);
    assert.equal(persisted[0].finishedAtEpochMs, 70_000);
});

test('a repeated terminal command cannot retain and re-persist a finished room', () => {
    const io = new FakeIo();
    const manager = new FakeRoomManager();
    const persisted: FinishedMatchRecord[] = [];
    let now = 70_000;
    createSocketGateway(
        io,
        manager,
        (record) => {
            persisted.push(record);
            return 'enqueued';
        },
        () => undefined,
        () => now,
    );
    const socket = new FakeSocket('socket-a');
    const room = createRoom();
    room.gameState = createState('finished');
    manager.roomBySocket = room;
    manager.moveDecision = {
        type: 'committed',
        protocolVersion: PROTOCOL_VERSION,
        commandId: 'command-1',
        state: room.gameState,
        capturedPieces: [],
        turnDeadlineEpochMs: room.turnDeadlineEpochMs,
    };
    manager.queuedRoom = room;
    io.sockets.sockets.set('socket-b', new FakeSocket('socket-b'));
    io.connect(socket);
    socket.trigger('request_match', {
        protocolVersion: PROTOCOL_VERSION,
        playerId: 'player-aaaa',
    });
    const intent = {
        protocolVersion: PROTOCOL_VERSION,
        matchId: room.id,
        commandId: 'command-1',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    };

    socket.trigger('submit_move', intent);
    socket.trigger('submit_move', intent);
    now += 5 * 60_000 + 1;
    manager.emit('game_finished', { roomId: room.id, state: room.gameState });

    assert.equal(persisted.length, 1);
    assert.equal(
        io.roomEvents.filter((event) => event.event === 'game_over').length,
        2,
    );
});
