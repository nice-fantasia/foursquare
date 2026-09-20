import { createHash } from 'node:crypto';

import type {
    GameEndReason,
    GameState,
    GameWinner,
    PieceColor,
    RecordedMove,
    Room,
} from '../types/game';
import type { Position } from '../types/move';
import { PROTOCOL_VERSION } from '../types/protocol';

export type FinishedMatchParticipant = Readonly<{
    identityId: string;
    color: PieceColor;
}>;

export type FinishedRecordedMove = Readonly<{
    matchId: string;
    from: Readonly<Position>;
    to: Readonly<Position>;
    player: PieceColor;
    capturedPieces: readonly Readonly<Position>[];
}>;

export type FinishedMatchRecord = Readonly<{
    schemaVersion: 1;
    matchId: string;
    protocolVersion: typeof PROTOCOL_VERSION;
    players: readonly [FinishedMatchParticipant, FinishedMatchParticipant];
    winner: GameWinner;
    startingPlayer: PieceColor;
    endReason: GameEndReason;
    revision: number;
    moves: readonly FinishedRecordedMove[];
    startedAtEpochMs: number;
    finishedAtEpochMs: number;
}>;

export const createFinishedMatchRecord = (
    room: Room,
    state: GameState,
    finishedAtEpochMs: number,
): FinishedMatchRecord => {
    if (
        state.status !== 'finished'
        || state.winner == null
        || state.endReason == null
    ) {
        throw new Error('finished_match_state_invalid');
    }
    const first = Object.freeze({
        identityId: room.players[0].id,
        color: room.colorBySocketId[room.players[0].socketId],
    }) as FinishedMatchParticipant;
    const second = Object.freeze({
        identityId: room.players[1].id,
        color: room.colorBySocketId[room.players[1].socketId],
    }) as FinishedMatchParticipant;
    const players = Object.freeze([first, second]) as readonly [
        FinishedMatchParticipant,
        FinishedMatchParticipant,
    ];
    const moves = Object.freeze(
        state.moveHistory.map(copyMove),
    );

    const candidate = Object.freeze({
        schemaVersion: 1,
        matchId: room.id,
        protocolVersion: PROTOCOL_VERSION,
        players,
        winner: state.winner,
        startingPlayer: room.startingPlayer,
        endReason: state.endReason,
        revision: state.revision,
        moves,
        startedAtEpochMs: room.createdAt,
        finishedAtEpochMs,
    });
    return deserializeFinishedMatchRecord(
        serializeFinishedMatchRecord(candidate),
    );
};

export const serializeFinishedMatchRecord = (
    record: FinishedMatchRecord,
): string => JSON.stringify({
    schemaVersion: record.schemaVersion,
    matchId: record.matchId,
    protocolVersion: record.protocolVersion,
    players: record.players.map((player) => ({
        identityId: player.identityId,
        color: player.color,
    })),
    winner: record.winner,
    startingPlayer: record.startingPlayer,
    endReason: record.endReason,
    revision: record.revision,
    moves: record.moves.map((move) => ({
        matchId: move.matchId,
        from: { x: move.from.x, y: move.from.y },
        to: { x: move.to.x, y: move.to.y },
        player: move.player,
        capturedPieces: move.capturedPieces.map((position) => ({
            x: position.x,
            y: position.y,
        })),
    })),
    startedAtEpochMs: record.startedAtEpochMs,
    finishedAtEpochMs: record.finishedAtEpochMs,
});

export const finishedMatchContentHash = (
    record: FinishedMatchRecord,
): string => createHash('sha256')
    .update(serializeFinishedMatchRecord(record))
    .digest('hex');

export const deserializeFinishedMatchRecord = (
    payload: string,
): FinishedMatchRecord => {
    try {
        const value = JSON.parse(payload) as unknown;
        if (!isRecord(value)) throw new Error();
        if (value.schemaVersion !== 1) throw new Error();
        if (value.protocolVersion !== PROTOCOL_VERSION) throw new Error();
        const matchId = requiredIdentifier(value.matchId);
        const playersValue = value.players;
        if (!Array.isArray(playersValue) || playersValue.length !== 2) {
            throw new Error();
        }
        const players = playersValue.map(readParticipant);
        if (
            players[0].identityId === players[1].identityId
            || players[0].color === players[1].color
        ) {
            throw new Error();
        }
        const winner = readWinner(value.winner);
        const endReason = readEndReason(value.endReason);
        if (
            (winner === 'draw') !== (endReason === 'no_capture_limit')
        ) {
            throw new Error();
        }
        const movesValue = value.moves;
        if (!Array.isArray(movesValue)) throw new Error();
        const moves = movesValue.map((move) => readMove(move, matchId));
        const startedAtEpochMs = requiredNonNegativeInteger(
            value.startedAtEpochMs,
        );
        const finishedAtEpochMs = requiredNonNegativeInteger(
            value.finishedAtEpochMs,
        );
        if (finishedAtEpochMs < startedAtEpochMs) throw new Error();

        return Object.freeze({
            schemaVersion: 1,
            matchId,
            protocolVersion: PROTOCOL_VERSION,
            players: Object.freeze(players) as readonly [
                FinishedMatchParticipant,
                FinishedMatchParticipant,
            ],
            winner,
            startingPlayer: readColor(value.startingPlayer),
            endReason,
            revision: requiredNonNegativeInteger(value.revision),
            moves: Object.freeze(moves),
            startedAtEpochMs,
            finishedAtEpochMs,
        });
    } catch {
        throw new Error('finished_match_payload_invalid');
    }
};

const copyMove = (move: RecordedMove): FinishedRecordedMove => Object.freeze({
    matchId: move.matchId,
    from: copyPosition(move.from),
    to: copyPosition(move.to),
    player: move.player,
    capturedPieces: Object.freeze(move.capturedPieces.map(copyPosition)),
});

const copyPosition = (position: Position): Readonly<Position> => Object.freeze({
    x: position.x,
    y: position.y,
});

const readParticipant = (value: unknown): FinishedMatchParticipant => {
    if (!isRecord(value)) throw new Error();
    return Object.freeze({
        identityId: requiredIdentifier(value.identityId),
        color: readColor(value.color),
    });
};

const readMove = (
    value: unknown,
    expectedMatchId: string,
): FinishedRecordedMove => {
    if (!isRecord(value) || value.matchId !== expectedMatchId) {
        throw new Error();
    }
    const capturedValue = value.capturedPieces;
    if (!Array.isArray(capturedValue) || capturedValue.length > 2) {
        throw new Error();
    }
    const capturedPieces = capturedValue.map(readPosition);
    const uniqueCaptured = new Set(
        capturedPieces.map((position) => `${position.x}:${position.y}`),
    );
    if (uniqueCaptured.size !== capturedPieces.length) throw new Error();
    return Object.freeze({
        matchId: expectedMatchId,
        from: readPosition(value.from),
        to: readPosition(value.to),
        player: readColor(value.player),
        capturedPieces: Object.freeze(capturedPieces),
    });
};

const readPosition = (value: unknown): Readonly<Position> => {
    if (!isRecord(value)) throw new Error();
    const x = requiredNonNegativeInteger(value.x);
    const y = requiredNonNegativeInteger(value.y);
    if (x > 3 || y > 3) throw new Error();
    return Object.freeze({ x, y });
};

const readColor = (value: unknown): PieceColor => {
    if (value !== 'black' && value !== 'white') throw new Error();
    return value;
};

const readWinner = (value: unknown): GameWinner => {
    if (value !== 'black' && value !== 'white' && value !== 'draw') {
        throw new Error();
    }
    return value;
};

const readEndReason = (value: unknown): GameEndReason => {
    switch (value) {
        case 'piece_count':
        case 'no_capture_limit':
        case 'no_legal_moves':
        case 'timeout':
        case 'disconnect':
        case 'abandoned':
            return value;
        default:
            throw new Error();
    }
};

const requiredIdentifier = (value: unknown): string => {
    if (
        typeof value !== 'string'
        || value.length === 0
        || value.length > 128
        || !/^[A-Za-z0-9_-]+$/.test(value)
    ) {
        throw new Error();
    }
    return value;
};

const requiredNonNegativeInteger = (value: unknown): number => {
    if (!Number.isInteger(value) || (value as number) < 0) throw new Error();
    return value as number;
};

const isRecord = (value: unknown): value is Record<string, unknown> => (
    typeof value === 'object' && value !== null && !Array.isArray(value)
);
