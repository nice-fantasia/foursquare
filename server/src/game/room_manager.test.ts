import assert from 'node:assert/strict';
import test from 'node:test';

import { RoomManager } from './room_manager';
import { Player } from '../types/game';

const black: Player = { id: 'device-a', socketId: 'socket-a', name: 'A' };
const white: Player = { id: 'device-b', socketId: 'socket-b', name: 'B' };

test('matchmaking rejects duplicate socket and identity bindings', () => {
    const manager = new RoomManager({
        now: () => 500_000,
        random: () => 0,
        id: () => 'match-binding',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });

    assert.deepEqual(manager.queuePlayer(black), { status: 'queued' });
    assert.deepEqual(
        manager.queuePlayer({
            id: 'different-device',
            socketId: black.socketId,
            name: 'Impostor',
        }),
        { status: 'rejected', reason: 'socket_in_use' },
    );
    assert.deepEqual(
        manager.queuePlayer({
            id: black.id,
            socketId: 'different-socket',
            name: 'Impostor',
        }),
        { status: 'rejected', reason: 'identity_in_use' },
    );

    const matched = manager.queuePlayer(white);
    assert.equal(matched.status, 'matched');
    if (matched.status !== 'matched') return;
    assert.notEqual(
        matched.room.players[0].socketId,
        matched.room.players[1].socketId,
    );

    assert.deepEqual(
        manager.queuePlayer({
            id: 'third-device',
            socketId: black.socketId,
            name: 'Already playing',
        }),
        { status: 'rejected', reason: 'socket_in_use' },
    );
});

test('only the queued socket can cancel its anonymous identity', () => {
    const manager = new RoomManager({
        now: () => 750_000,
        random: () => 0,
        id: () => 'match-cancel-binding',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });

    assert.deepEqual(manager.queuePlayer(black), { status: 'queued' });
    assert.equal(
        manager.removePlayerFromQueue(black.id, 'attacker-socket'),
        false,
    );
    assert.equal(manager.queuePlayer(white).status, 'matched');
});

test('commits one authoritative move with a revision and 60-second deadline', () => {
    let now = 1_000_000;
    const manager = new RoomManager({
        now: () => now,
        random: () => 0,
        id: () => 'match-1',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);

    assert.equal(room.gameState.currentTurn, 'black');
    assert.equal(room.turnDeadlineEpochMs, now + 60_000);

    const committed = manager.handleMove(black.socketId, {
        protocolVersion: 1,
        matchId: room.id,
        commandId: 'command-1',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });

    assert.equal(committed.type, 'committed');
    assert.equal(committed.state.revision, 1);
    assert.equal(committed.state.currentTurn, 'white');
    assert.equal(committed.turnDeadlineEpochMs, now + 60_000);
});

test('retries are idempotent and stale revisions are rejected', () => {
    const manager = new RoomManager({
        now: () => 2_000_000,
        random: () => 0,
        id: () => 'match-2',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);
    const intent = {
        protocolVersion: 1 as const,
        matchId: room.id,
        commandId: 'command-1',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    };

    const first = manager.handleMove(black.socketId, intent);
    const retry = manager.handleMove(black.socketId, intent);
    assert.deepEqual(retry, first);
    assert.equal(room.gameState.revision, 1);

    const stale = manager.handleMove(white.socketId, {
        ...intent,
        commandId: 'command-2',
    });
    assert.equal(stale.type, 'rejected');
    assert.equal(stale.reason, 'stale_revision');

    const reused = manager.handleMove(black.socketId, {
        ...intent,
        to: { x: 1, y: 0 },
    });
    assert.equal(reused.type, 'rejected');
    assert.equal(reused.reason, 'command_conflict');
});

test('a rejected command id cannot later be reused for a different move', () => {
    const manager = new RoomManager({
        now: () => 2_500_000,
        random: () => 0,
        id: () => 'match-rejected-command',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);

    const rejected = manager.handleMove(black.socketId, {
        protocolVersion: 1,
        matchId: room.id,
        commandId: 'bad-command',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 1, y: 0 },
    });
    assert.equal(rejected.type, 'rejected');
    assert.equal(rejected.reason, 'target_occupied');

    const reused = manager.handleMove(black.socketId, {
        protocolVersion: 1,
        matchId: room.id,
        commandId: 'bad-command',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });
    assert.equal(reused.type, 'rejected');
    assert.equal(reused.reason, 'command_conflict');
    assert.equal(room.gameState.revision, 0);
});

test('rejected command caching is bounded and then rate limits the room', () => {
    const manager = new RoomManager({
        now: () => 2_750_000,
        random: () => 0,
        id: () => 'match-rejection-limit',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);

    for (let index = 0; index < 256; index += 1) {
        const rejected = manager.handleMove(black.socketId, {
            protocolVersion: 1,
            matchId: room.id,
            commandId: `rejected-${index}`,
            expectedRevision: 0,
            from: { x: 0, y: 0 },
            to: { x: 1, y: 0 },
        });
        assert.equal(rejected.type, 'rejected');
        assert.equal(rejected.reason, 'target_occupied');
    }

    const limited = manager.handleMove(black.socketId, {
        protocolVersion: 1,
        matchId: room.id,
        commandId: 'over-limit',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });
    assert.equal(limited.type, 'rejected');
    assert.equal(limited.reason, 'rate_limited');
    assert.equal(room.gameState.revision, 0);
});

test('finished rooms and command caches are released after retention', () => {
    let now = 2_900_000;
    const scheduled: Array<{ callback: () => void; delayMs: number }> = [];
    const manager = new RoomManager({
        now: () => now,
        random: () => 0,
        id: () => 'match-cleanup',
        schedule: (callback, delayMs) => {
            const task = { callback, delayMs };
            scheduled.push(task);
            return task;
        },
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);
    now = room.turnDeadlineEpochMs;
    manager.handleMove(black.socketId, {
        protocolVersion: 1,
        matchId: room.id,
        commandId: 'late-cleanup-command',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });

    const cleanup = scheduled.at(-1)!;
    assert.equal(cleanup.delayMs, 5 * 60_000);
    now += cleanup.delayMs;
    cleanup.callback();

    assert.equal(manager.getRoomBySocketId(black.socketId), undefined);
    assert.deepEqual(manager.queuePlayer(black), { status: 'queued' });
});

test('an expired turn is finalized before a late move can execute', () => {
    let now = 3_000_000;
    const manager = new RoomManager({
        now: () => now,
        random: () => 0,
        id: () => 'match-3',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);
    now = room.turnDeadlineEpochMs;

    const rejected = manager.handleMove(black.socketId, {
        protocolVersion: 1,
        matchId: room.id,
        commandId: 'late-command',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });

    assert.equal(rejected.type, 'rejected');
    assert.equal(rejected.reason, 'game_finished');
    assert.equal(room.gameState.status, 'finished');
    assert.equal(room.gameState.winner, 'white');
    assert.equal(room.gameState.endReason, 'timeout');
    assert.equal(room.gameState.revision, 1);
    assert.equal(room.gameState.board[0][0], 'black');
});

test('reconnects the same anonymous player with a full unchanged snapshot', () => {
    let now = 4_000_000;
    const manager = new RoomManager({
        now: () => now,
        random: () => 0,
        id: () => 'match-4',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);
    const originalBoard = room.gameState.board.map((row) => [...row]);
    const originalDeadline = room.turnDeadlineEpochMs;

    assert.equal(manager.removePlayer(black.socketId), room);
    assert.equal(manager.getRoomBySocketId(white.socketId), room);
    now += 10_000;

    const snapshot = manager.resumePlayer(
        black.id,
        'socket-a-reconnected',
        room.id,
    );

    assert.deepEqual(snapshot, {
        protocolVersion: 1,
        matchId: room.id,
        color: 'black',
        state: {
            board: originalBoard,
            currentTurn: 'black',
            status: 'playing',
            moveHistory: [],
            noCapturePly: 0,
            revision: 0,
        },
        turnDeadlineEpochMs: originalDeadline,
        opponentConnected: true,
    });
    assert.equal(manager.getRoomBySocketId(black.socketId), undefined);
    assert.equal(manager.getRoomBySocketId('socket-a-reconnected'), room);
    assert.equal(room.players[0].socketId, 'socket-a-reconnected');
});

test('reconnect snapshot reports an opponent still in disconnect grace', () => {
    let now = 4_500_000;
    const manager = new RoomManager({
        now: () => now,
        random: () => 0,
        id: () => 'match-presence',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);

    manager.removePlayer(black.socketId);
    now += 1_000;
    manager.removePlayer(white.socketId);
    now += 1_000;

    const snapshot = manager.resumePlayer(
        black.id,
        'socket-a-returned',
        room.id,
    );

    assert.equal(snapshot?.opponentConnected, false);
    assert.equal(
        snapshot?.opponentReconnectDeadlineEpochMs,
        4_531_000,
    );
    assert.equal(snapshot?.matchId, room.id);
});

test('disconnect grace expires after 30 seconds and the disconnected player loses', () => {
    let now = 5_000_000;
    const scheduled: Array<{
        callback: () => void;
        delayMs: number;
        cancelled: boolean;
    }> = [];
    const manager = new RoomManager({
        now: () => now,
        random: () => 0,
        id: () => 'match-5',
        schedule: (callback, delayMs) => {
            const task = { callback, delayMs, cancelled: false };
            scheduled.push(task);
            return task;
        },
        cancelSchedule: (handle) => {
            (handle as { cancelled: boolean }).cancelled = true;
        },
    });
    const room = manager.createRoom(black, white);
    const turnDeadline = room.turnDeadlineEpochMs;

    manager.removePlayer(black.socketId);
    const disconnectTask = scheduled.at(-1)!;

    assert.equal(disconnectTask.delayMs, 30_000);
    assert.equal(room.turnDeadlineEpochMs, turnDeadline);
    assert.equal(room.gameState.status, 'playing');

    now += 30_000;
    disconnectTask.callback();

    assert.equal(room.gameState.status, 'finished');
    assert.equal(room.gameState.winner, 'white');
    assert.equal(room.gameState.endReason, 'disconnect');
    assert.equal(room.gameState.revision, 1);
    const terminalSnapshot = manager.resumePlayer(
        black.id,
        'socket-a-too-late',
        room.id,
    );
    assert.equal(terminalSnapshot?.state.status, 'finished');
    assert.equal(terminalSnapshot?.state.winner, 'white');
    assert.equal(terminalSnapshot?.state.endReason, 'disconnect');
});

test('the absolute turn deadline keeps running while a player is disconnected', () => {
    let now = 6_000_000;
    const manager = new RoomManager({
        now: () => now,
        random: () => 0,
        id: () => 'match-6',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);
    now += 50_000;
    manager.removePlayer(black.socketId);

    now += 10_000;
    const snapshot = manager.resumePlayer(
        black.id,
        'socket-a-after-turn-deadline',
        room.id,
    );

    assert.equal(snapshot?.state.status, 'finished');
    assert.equal(snapshot?.state.endReason, 'timeout');
    assert.equal(room.gameState.status, 'finished');
    assert.equal(room.gameState.winner, 'white');
    assert.equal(room.gameState.endReason, 'timeout');
    assert.equal(room.gameState.revision, 1);
});

test('creates a full snapshot only for the socket bound to the match', () => {
    const manager = new RoomManager({
        random: () => 0,
        id: () => 'match-snapshot',
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);

    const snapshot = manager.createSnapshotForSocket(black.socketId, room.id);

    assert.equal(snapshot?.matchId, room.id);
    assert.equal(snapshot?.color, 'black');
    assert.equal(snapshot?.state.revision, 0);
    assert.equal(
        manager.createSnapshotForSocket(white.socketId, 'different-match'),
        undefined,
    );
    assert.equal(
        manager.createSnapshotForSocket('unknown-socket', room.id),
        undefined,
    );
});

test('a stale disconnect timer cannot erase a newer room reconnect record', () => {
    let now = 7_000_000;
    let roomSequence = 0;
    const scheduled: Array<{
        callback: () => void;
        delayMs: number;
        cancelled: boolean;
    }> = [];
    const manager = new RoomManager({
        now: () => now,
        random: () => 0,
        id: () => `match-stale-timer-${++roomSequence}`,
        schedule: (callback, delayMs) => {
            const task = { callback, delayMs, cancelled: false };
            scheduled.push(task);
            return task;
        },
        cancelSchedule: (handle) => {
            (handle as { cancelled: boolean }).cancelled = true;
        },
    });
    const firstRoom = manager.createRoom(black, white);
    manager.removePlayer(black.socketId);
    const staleDisconnectTask = scheduled.at(-1)!;

    now = firstRoom.turnDeadlineEpochMs;
    manager.handleMove(white.socketId, {
        protocolVersion: 1,
        matchId: firstRoom.id,
        commandId: 'finish-first-room',
        expectedRevision: 0,
        from: { x: 0, y: 3 },
        to: { x: 0, y: 2 },
    });
    assert.equal(firstRoom.gameState.status, 'finished');
    assert.equal(staleDisconnectTask.cancelled, true);

    const returnedBlack: Player = {
        ...black,
        socketId: 'socket-a-new-room',
    };
    const returnedWhite: Player = {
        ...white,
        socketId: 'socket-b-new-room',
    };
    const secondRoom = manager.createRoom(returnedBlack, returnedWhite);
    manager.removePlayer(returnedBlack.socketId);

    now += 1;
    staleDisconnectTask.callback();
    const resumed = manager.resumePlayer(
        returnedBlack.id,
        'socket-a-new-room-resumed',
        secondRoom.id,
    );

    assert.equal(resumed?.matchId, secondRoom.id);
    assert.equal(resumed?.state.status, 'playing');
});

test('disconnecting after game over does not start a reconnect timer', () => {
    let now = 8_000_000;
    const scheduled: Array<{ callback: () => void; delayMs: number }> = [];
    const manager = new RoomManager({
        now: () => now,
        random: () => 0,
        id: () => 'match-finished-disconnect',
        schedule: (callback, delayMs) => {
            const task = { callback, delayMs };
            scheduled.push(task);
            return task;
        },
        cancelSchedule: () => undefined,
    });
    const room = manager.createRoom(black, white);
    now = room.turnDeadlineEpochMs;
    manager.handleMove(black.socketId, {
        protocolVersion: 1,
        matchId: room.id,
        commandId: 'finish-before-disconnect',
        expectedRevision: 0,
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
    });
    const scheduledBeforeDisconnect = scheduled.length;

    assert.equal(manager.removePlayer(black.socketId), undefined);
    assert.equal(scheduled.length, scheduledBeforeDisconnect);
});

test('disposing a room manager cancels timers and releases retained state', () => {
    const scheduled: Array<{ callback: () => void; delayMs: number }> = [];
    const cancelled: unknown[] = [];
    const manager = new RoomManager({
        random: () => 0,
        id: () => 'match-disposed',
        schedule: (callback, delayMs) => {
            const handle = { callback, delayMs };
            scheduled.push(handle);
            return handle;
        },
        cancelSchedule: (handle) => cancelled.push(handle),
    });
    const first: Player = {
        id: 'dispose-first',
        socketId: 'dispose-socket-first',
        name: 'First',
    };
    const second: Player = {
        id: 'dispose-second',
        socketId: 'dispose-socket-second',
        name: 'Second',
    };
    manager.queuePlayer(first);
    manager.queuePlayer(second);
    manager.removePlayer(first.socketId);

    manager.dispose();
    manager.dispose();

    assert.equal(scheduled.length, 2);
    assert.equal(cancelled.length, 2);
    assert.equal(manager.getRoomBySocketId(second.socketId), undefined);
    assert.equal(
        manager.removePlayerFromQueue(first.id, first.socketId),
        false,
    );
});
