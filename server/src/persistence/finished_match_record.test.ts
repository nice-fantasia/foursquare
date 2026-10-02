import assert from 'node:assert/strict';
import test from 'node:test';

import type { GameState, Room } from '../types/game';
import {
    createFinishedMatchRecord,
    deserializeFinishedMatchRecord,
    finishedMatchContentHash,
    serializeFinishedMatchRecord,
} from './finished_match_record';

test('terminal room becomes one deeply immutable finished-match record', () => {
    const state: GameState = {
        board: [
            ['black', null, null, 'white'],
            [null, 'black', 'white', null],
            [null, null, null, null],
            ['white', null, null, 'black'],
        ],
        currentTurn: 'white',
        status: 'finished',
        winner: 'black',
        endReason: 'piece_count',
        moveHistory: [{
            matchId: 'match-finished-1',
            from: { x: 0, y: 0 },
            to: { x: 0, y: 1 },
            player: 'black',
            capturedPieces: [{ x: 1, y: 1 }, { x: 0, y: 2 }],
        }],
        noCapturePly: 0,
        revision: 9,
    };
    const room: Room = {
        id: 'match-finished-1',
        players: [
            { id: 'device-first', socketId: 'socket-a', name: 'Anonymous' },
            { id: 'device-second', socketId: 'socket-b', name: 'Anonymous' },
        ],
        spectators: [],
        gameState: state,
        colorBySocketId: { 'socket-a': 'black', 'socket-b': 'white' },
        startingPlayer: 'white',
        turnDeadlineEpochMs: 50_000,
        createdAt: 10_000,
    };

    const record = createFinishedMatchRecord(room, state, 70_000);

    assert.deepEqual(record, {
        schemaVersion: 1,
        matchId: 'match-finished-1',
        protocolVersion: 1,
        players: [
            { identityId: 'device-first', color: 'black' },
            { identityId: 'device-second', color: 'white' },
        ],
        winner: 'black',
        startingPlayer: 'white',
        endReason: 'piece_count',
        revision: 9,
        moves: [{
            matchId: 'match-finished-1',
            from: { x: 0, y: 0 },
            to: { x: 0, y: 1 },
            player: 'black',
            capturedPieces: [{ x: 1, y: 1 }, { x: 0, y: 2 }],
        }],
        startedAtEpochMs: 10_000,
        finishedAtEpochMs: 70_000,
    });
    assert.equal(Object.isFrozen(record), true);
    assert.equal(Object.isFrozen(record.players), true);
    assert.equal(Object.isFrozen(record.moves[0].capturedPieces), true);

    state.moveHistory[0].from.x = 3;
    state.moveHistory[0].capturedPieces.length = 0;
    room.players[0].id = 'mutated-device';

    assert.equal(record.players[0].identityId, 'device-first');
    assert.deepEqual(record.moves[0].from, { x: 0, y: 0 });
    assert.equal(record.moves[0].capturedPieces.length, 2);
});

test('finished-match records reject non-terminal state', () => {
    const state: GameState = {
        board: Array.from({ length: 4 }, () => Array(4).fill(null)),
        currentTurn: 'black',
        status: 'playing',
        moveHistory: [],
        noCapturePly: 0,
        revision: 0,
    };
    const room: Room = {
        id: 'match-playing',
        players: [
            { id: 'device-first', socketId: 'socket-a', name: 'Anonymous' },
            { id: 'device-second', socketId: 'socket-b', name: 'Anonymous' },
        ],
        spectators: [],
        gameState: state,
        colorBySocketId: { 'socket-a': 'black', 'socket-b': 'white' },
        startingPlayer: 'black',
        turnDeadlineEpochMs: 60_000,
        createdAt: 0,
    };

    assert.throws(
        () => createFinishedMatchRecord(room, state, 1_000),
        /finished_match_state_invalid/,
    );
});

test('finished-match serialization and content hash are deterministic', () => {
    const room = finishedRoom();
    const first = createFinishedMatchRecord(room, room.gameState, 70_000);
    const second = createFinishedMatchRecord(room, room.gameState, 70_000);
    const laterRevision = Object.freeze({ ...second, revision: 10 });

    assert.equal(
        serializeFinishedMatchRecord(first),
        serializeFinishedMatchRecord(second),
    );
    assert.equal(
        finishedMatchContentHash(first),
        finishedMatchContentHash(second),
    );
    assert.notEqual(
        finishedMatchContentHash(first),
        finishedMatchContentHash(laterRevision),
    );
    const restored = deserializeFinishedMatchRecord(
        serializeFinishedMatchRecord(first),
    );
    assert.deepEqual(restored, first);
    assert.equal(Object.isFrozen(restored.moves), true);
    assert.throws(
        () => deserializeFinishedMatchRecord('{"schemaVersion":1}'),
        /finished_match_payload_invalid/,
    );
});

test('finished-match records reject incomplete colors, time, and foreign moves', () => {
    const room = finishedRoom();
    delete room.colorBySocketId['socket-b'];
    assert.throws(
        () => createFinishedMatchRecord(room, room.gameState, 70_000),
        /finished_match_payload_invalid/,
    );

    room.colorBySocketId['socket-b'] = 'white';
    assert.throws(
        () => createFinishedMatchRecord(room, room.gameState, 9_999),
        /finished_match_payload_invalid/,
    );

    room.gameState.moveHistory.push({
        matchId: 'another-match',
        from: { x: 0, y: 0 },
        to: { x: 0, y: 1 },
        player: 'black',
        capturedPieces: [],
    });
    assert.throws(
        () => createFinishedMatchRecord(room, room.gameState, 70_000),
        /finished_match_payload_invalid/,
    );
});

const finishedRoom = (): Room => {
    const state: GameState = {
        board: Array.from({ length: 4 }, () => Array(4).fill(null)),
        currentTurn: 'white',
        status: 'finished',
        winner: 'black',
        endReason: 'piece_count',
        moveHistory: [],
        noCapturePly: 0,
        revision: 9,
    };
    return {
        id: 'match-hash-1',
        players: [
            { id: 'device-first', socketId: 'socket-a', name: 'Anonymous' },
            { id: 'device-second', socketId: 'socket-b', name: 'Anonymous' },
        ],
        spectators: [],
        gameState: state,
        colorBySocketId: { 'socket-a': 'black', 'socket-b': 'white' },
        startingPlayer: 'white',
        turnDeadlineEpochMs: 50_000,
        createdAt: 10_000,
    };
};
