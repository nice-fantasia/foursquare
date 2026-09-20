import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';

import { GameRules } from './rules';
import type { PieceColor, Player, Room } from '../types/game';
import {
    AuthoritativeSnapshot,
    MoveDecision,
    MoveIntent,
    MoveRejectionReason,
    PROTOCOL_VERSION,
} from '../types/protocol';

const TURN_DURATION_MS = 60_000;
const RECONNECT_GRACE_MS = 30_000;
const ROOM_RETENTION_MS = 5 * 60_000;
const MAX_REJECTED_COMMANDS_PER_ROOM = 256;

export type MatchmakingRejectionReason =
    | 'identity_in_use'
    | 'socket_in_use';

export type MatchmakingResult =
    | { status: 'queued' }
    | { status: 'matched'; room: Room }
    | { status: 'rejected'; reason: MatchmakingRejectionReason };

type RoomManagerOptions = {
    now: () => number;
    random: () => number;
    id: () => string;
    schedule: (callback: () => void, delayMs: number) => unknown;
    cancelSchedule: (handle: unknown) => void;
};

type ProcessedCommand = {
    fingerprint: string;
    decision: MoveDecision;
};

type DisconnectedPlayer = {
    roomId: string;
    color: PieceColor;
    previousSocketId: string;
    deadlineEpochMs: number;
    timer?: unknown;
};

const defaultOptions: RoomManagerOptions = {
    now: Date.now,
    random: Math.random,
    id: randomUUID,
    schedule: (callback, delayMs) => setTimeout(callback, delayMs),
    cancelSchedule: (handle) => clearTimeout(handle as NodeJS.Timeout),
};

export class RoomManager extends EventEmitter {
    private readonly rooms = new Map<string, Room>();
    private readonly playerRoomMap = new Map<string, string>();
    private readonly matchmakingQueue: Player[] = [];
    private readonly processedCommands = new Map<
        string,
        Map<string, ProcessedCommand>
    >();
    private readonly disconnectedPlayers = new Map<string, DisconnectedPlayer>();
    private readonly cleanupScheduledRooms = new Set<string>();
    private readonly options: RoomManagerOptions;

    public constructor(options: Partial<RoomManagerOptions> = {}) {
        super();
        this.options = { ...defaultOptions, ...options };
    }

    public queuePlayer(player: Player): MatchmakingResult {
        const mappedRoomId = this.playerRoomMap.get(player.socketId);
        const mappedRoom = mappedRoomId
            ? this.rooms.get(mappedRoomId)
            : undefined;
        if (mappedRoom && mappedRoom.gameState.status !== 'playing') {
            this.playerRoomMap.delete(player.socketId);
        }
        if (
            (mappedRoom?.gameState.status === 'playing')
            || this.matchmakingQueue.some(
                (queued) => queued.socketId === player.socketId,
            )
        ) {
            return { status: 'rejected', reason: 'socket_in_use' };
        }
        if (
            this.matchmakingQueue.some((queued) => queued.id === player.id)
            || [...this.rooms.values()].some(
                (room) => room.gameState.status === 'playing'
                    && room.players.some(
                        (roomPlayer) => roomPlayer.id === player.id,
                    ),
            )
        ) {
            return { status: 'rejected', reason: 'identity_in_use' };
        }
        this.matchmakingQueue.push(player);
        if (this.matchmakingQueue.length < 2) return { status: 'queued' };
        return {
            status: 'matched',
            room: this.createRoom(
                this.matchmakingQueue.shift()!,
                this.matchmakingQueue.shift()!,
            ),
        };
    }

    public removePlayerFromQueue(playerId: string, socketId: string): boolean {
        const index = this.matchmakingQueue.findIndex(
            (player) => player.id === playerId && player.socketId === socketId,
        );
        if (index < 0) return false;
        this.matchmakingQueue.splice(index, 1);
        return true;
    }

    public createRoom(first: Player, second: Player): Room {
        if (first.id === second.id || first.socketId === second.socketId) {
            throw new Error('room_players_must_be_distinct');
        }
        const id = this.options.id();
        const currentTurn: PieceColor = this.options.random() < 0.5
            ? 'black'
            : 'white';
        const room: Room = {
            id,
            players: [first, second],
            spectators: [],
            gameState: {
                board: GameRules.getInitialBoard(),
                currentTurn,
                status: 'playing',
                moveHistory: [],
                noCapturePly: 0,
                revision: 0,
            },
            colorBySocketId: {
                [first.socketId]: 'black',
                [second.socketId]: 'white',
            },
            startingPlayer: currentTurn,
            turnDeadlineEpochMs: this.options.now() + TURN_DURATION_MS,
            createdAt: this.options.now(),
        };
        this.rooms.set(id, room);
        this.playerRoomMap.set(first.socketId, id);
        this.playerRoomMap.set(second.socketId, id);
        this.processedCommands.set(id, new Map());
        this.scheduleTurnTimeout(room);
        return room;
    }

    public getRoomBySocketId(socketId: string): Room | undefined {
        const roomId = this.playerRoomMap.get(socketId);
        return roomId ? this.rooms.get(roomId) : undefined;
    }

    public handleMove(socketId: string, intent: MoveIntent): MoveDecision {
        const room = this.getRoomBySocketId(socketId);
        if (!room || room.id !== intent.matchId) {
            return this.reject(intent, 'room_not_found', room?.gameState.revision ?? 0);
        }
        const player = room.colorBySocketId[socketId];
        if (!player) {
            return this.reject(intent, 'not_room_player', room.gameState.revision);
        }

        const fingerprint = JSON.stringify([
            intent.protocolVersion,
            intent.matchId,
            intent.expectedRevision,
            intent.from.x,
            intent.from.y,
            intent.to.x,
            intent.to.y,
        ]);
        const commandCache = this.processedCommands.get(room.id)!;
        const processed = commandCache.get(intent.commandId);
        if (processed) {
            return processed.fingerprint === fingerprint
                ? processed.decision
                : this.reject(intent, 'command_conflict', room.gameState.revision);
        }
        const rejectedCommandCount = [...commandCache.values()].filter(
            (command) => command.decision.type === 'rejected',
        ).length;
        if (rejectedCommandCount >= MAX_REJECTED_COMMANDS_PER_ROOM) {
            return this.reject(
                intent,
                'rate_limited',
                room.gameState.revision,
            );
        }
        const rejectAndRemember = (
            reason: MoveRejectionReason,
        ): MoveDecision => {
            const decision = this.reject(
                intent,
                reason,
                room.gameState.revision,
            );
            commandCache.set(intent.commandId, { fingerprint, decision });
            return decision;
        };

        if (room.gameState.status !== 'playing') {
            return rejectAndRemember('game_finished');
        }
        if (this.options.now() >= room.turnDeadlineEpochMs) {
            this.finalizeTimeout(room);
            return rejectAndRemember('game_finished');
        }
        if (intent.expectedRevision !== room.gameState.revision) {
            return rejectAndRemember('stale_revision');
        }
        if (room.gameState.currentTurn !== player) {
            return rejectAndRemember('wrong_turn');
        }

        const validation = GameRules.validateMove(room.gameState, {
            matchId: room.id,
            from: intent.from,
            to: intent.to,
            player,
        });
        if (!validation.valid) {
            return rejectAndRemember(
                validation.message as MoveRejectionReason,
            );
        }

        const applied = GameRules.applyMove(room.gameState, {
            matchId: room.id,
            from: intent.from,
            to: intent.to,
            player,
        });
        room.gameState = applied.state;
        if (room.gameState.status === 'playing') {
            room.turnDeadlineEpochMs = this.options.now() + TURN_DURATION_MS;
            this.scheduleTurnTimeout(room);
        } else {
            this.cancelTurnTimer(room);
            this.clearDisconnectedPlayers(room.id);
        }

        const decision: MoveDecision = {
            type: 'committed',
            protocolVersion: PROTOCOL_VERSION,
            commandId: intent.commandId,
            state: room.gameState,
            capturedPieces: applied.capturedPieces,
            turnDeadlineEpochMs: room.turnDeadlineEpochMs,
        };
        commandCache.set(intent.commandId, { fingerprint, decision });
        if (room.gameState.status === 'finished') {
            this.scheduleRoomCleanup(room);
        }
        return decision;
    }

    public removePlayer(socketId: string): Room | undefined {
        const roomId = this.playerRoomMap.get(socketId);
        if (!roomId) {
            const queueIndex = this.matchmakingQueue.findIndex(
                (player) => player.socketId === socketId,
            );
            if (queueIndex >= 0) this.matchmakingQueue.splice(queueIndex, 1);
            return undefined;
        }
        const room = this.rooms.get(roomId);
        if (!room) return undefined;
        if (this.isFinished(room)) {
            this.playerRoomMap.delete(socketId);
            return undefined;
        }
        const player = room.players.find(
            (candidate) => candidate.socketId === socketId,
        );
        const color = room.colorBySocketId[socketId];
        if (!player || !color) return undefined;
        this.playerRoomMap.delete(socketId);
        const disconnected: DisconnectedPlayer = {
            roomId,
            color,
            previousSocketId: socketId,
            deadlineEpochMs: this.options.now() + RECONNECT_GRACE_MS,
        };
        this.disconnectedPlayers.set(player.id, disconnected);
        this.scheduleDisconnectTimeout(player.id, disconnected);
        return room;
    }

    public getDisconnectDeadline(socketId: string): number | undefined {
        for (const disconnected of this.disconnectedPlayers.values()) {
            if (disconnected.previousSocketId === socketId) {
                return disconnected.deadlineEpochMs;
            }
        }
        return undefined;
    }

    public dispose(): void {
        for (const room of this.rooms.values()) {
            this.cancelTurnTimer(room);
            if (room.cleanupTimer !== undefined) {
                this.options.cancelSchedule(room.cleanupTimer);
                room.cleanupTimer = undefined;
            }
        }
        for (const disconnected of this.disconnectedPlayers.values()) {
            this.cancelDisconnectTimer(disconnected);
        }
        this.rooms.clear();
        this.playerRoomMap.clear();
        this.matchmakingQueue.length = 0;
        this.processedCommands.clear();
        this.disconnectedPlayers.clear();
        this.cleanupScheduledRooms.clear();
        this.removeAllListeners();
    }

    public resumePlayer(
        playerId: string,
        socketId: string,
        matchId: string,
    ): AuthoritativeSnapshot | undefined {
        if (
            this.playerRoomMap.has(socketId)
            || this.matchmakingQueue.some(
                (player) => player.socketId === socketId,
            )
        ) {
            return undefined;
        }
        const room = this.rooms.get(matchId);
        const playerIndex = room?.players.findIndex(
            (player) => player.id === playerId,
        ) ?? -1;
        if (!room || playerIndex < 0) return undefined;

        const disconnected = this.disconnectedPlayers.get(playerId);
        if (this.isFinished(room)) {
            const color = room.colorBySocketId[
                room.players[playerIndex].socketId
            ];
            return color
                ? this.createSnapshot(room, playerId, color)
                : undefined;
        }
        if (!disconnected || disconnected.roomId !== matchId) return undefined;

        if (this.options.now() >= room.turnDeadlineEpochMs) {
            this.finalizeTimeout(room);
        } else if (this.options.now() >= disconnected.deadlineEpochMs) {
            this.finalizeDisconnect(playerId, disconnected);
        }
        if (this.isFinished(room)) {
            return this.createSnapshot(
                room,
                playerId,
                disconnected.color,
            );
        }

        room.players[playerIndex] = {
            ...room.players[playerIndex],
            socketId,
        };
        delete room.colorBySocketId[disconnected.previousSocketId];
        room.colorBySocketId[socketId] = disconnected.color;
        this.playerRoomMap.set(socketId, room.id);
        this.cancelDisconnectTimer(disconnected);
        this.disconnectedPlayers.delete(playerId);

        return this.createSnapshot(room, playerId, disconnected.color);
    }

    public createSnapshotForSocket(
        socketId: string,
        matchId: string,
    ): AuthoritativeSnapshot | undefined {
        if (this.playerRoomMap.get(socketId) !== matchId) return undefined;
        const room = this.rooms.get(matchId);
        if (!room) return undefined;
        const player = room.players.find(
            (candidate) => candidate.socketId === socketId,
        );
        const color = room.colorBySocketId[socketId];
        if (!player || !color) return undefined;
        return this.createSnapshot(room, player.id, color);
    }

    private createSnapshot(
        room: Room,
        playerId: string,
        color: PieceColor,
    ): AuthoritativeSnapshot {
        const opponent = room.players.find(
            (candidate) => candidate.id !== playerId,
        );
        const opponentDisconnect = opponent
            ? this.disconnectedPlayers.get(opponent.id)
            : undefined;

        return {
            protocolVersion: PROTOCOL_VERSION,
            matchId: room.id,
            color,
            state: {
                ...room.gameState,
                board: room.gameState.board.map((row) => [...row]),
                moveHistory: room.gameState.moveHistory.map((move) => ({
                    ...move,
                    from: { ...move.from },
                    to: { ...move.to },
                    capturedPieces: move.capturedPieces.map((position) => ({
                        ...position,
                    })),
                })),
            },
            turnDeadlineEpochMs: room.turnDeadlineEpochMs,
            opponentConnected: opponentDisconnect === undefined,
            ...(opponentDisconnect
                ? {
                    opponentReconnectDeadlineEpochMs:
                        opponentDisconnect.deadlineEpochMs,
                }
                : {}),
        };
    }

    private isFinished(room: Room): boolean {
        return room.gameState.status === 'finished';
    }

    private scheduleTurnTimeout(room: Room): void {
        this.cancelTurnTimer(room);
        const delay = Math.max(0, room.turnDeadlineEpochMs - this.options.now());
        room.turnTimer = this.options.schedule(() => {
            if (room.gameState.status !== 'playing') return;
            if (this.options.now() < room.turnDeadlineEpochMs) {
                this.scheduleTurnTimeout(room);
                return;
            }
            this.finalizeTimeout(room);
        }, delay);
    }

    private finalizeTimeout(room: Room): void {
        if (room.gameState.status !== 'playing') return;
        const timedOut = room.gameState.currentTurn;
        room.gameState = {
            ...room.gameState,
            status: 'finished',
            winner: timedOut === 'black' ? 'white' : 'black',
            endReason: 'timeout',
            revision: room.gameState.revision + 1,
        };
        this.cancelTurnTimer(room);
        this.clearDisconnectedPlayers(room.id);
        this.emit('game_finished', {
            roomId: room.id,
            state: room.gameState,
        });
        this.scheduleRoomCleanup(room);
    }

    private cancelTurnTimer(room: Room): void {
        if (room.turnTimer !== undefined) {
            this.options.cancelSchedule(room.turnTimer);
            room.turnTimer = undefined;
        }
    }

    private scheduleDisconnectTimeout(
        playerId: string,
        disconnected: DisconnectedPlayer,
    ): void {
        const delay = Math.max(
            0,
            disconnected.deadlineEpochMs - this.options.now(),
        );
        disconnected.timer = this.options.schedule(() => {
            disconnected.timer = undefined;
            if (this.options.now() < disconnected.deadlineEpochMs) {
                this.scheduleDisconnectTimeout(playerId, disconnected);
                return;
            }
            this.finalizeDisconnect(playerId, disconnected);
        }, delay);
    }

    private finalizeDisconnect(
        playerId: string,
        disconnected: DisconnectedPlayer,
    ): void {
        if (this.disconnectedPlayers.get(playerId) !== disconnected) {
            this.cancelDisconnectTimer(disconnected);
            return;
        }
        const room = this.rooms.get(disconnected.roomId);
        if (!room || room.gameState.status !== 'playing') {
            this.cancelDisconnectTimer(disconnected);
            this.disconnectedPlayers.delete(playerId);
            return;
        }
        if (this.options.now() >= room.turnDeadlineEpochMs) {
            this.finalizeTimeout(room);
            return;
        }
        room.gameState = {
            ...room.gameState,
            status: 'finished',
            winner: disconnected.color === 'black' ? 'white' : 'black',
            endReason: 'disconnect',
            revision: room.gameState.revision + 1,
        };
        this.cancelTurnTimer(room);
        this.clearDisconnectedPlayers(room.id);
        this.emit('game_finished', {
            roomId: room.id,
            state: room.gameState,
        });
        this.scheduleRoomCleanup(room);
    }

    private cancelDisconnectTimer(disconnected: DisconnectedPlayer): void {
        if (disconnected.timer !== undefined) {
            this.options.cancelSchedule(disconnected.timer);
            disconnected.timer = undefined;
        }
    }

    private clearDisconnectedPlayers(roomId: string): void {
        for (const [playerId, disconnected] of this.disconnectedPlayers) {
            if (disconnected.roomId !== roomId) continue;
            this.cancelDisconnectTimer(disconnected);
            this.disconnectedPlayers.delete(playerId);
        }
    }

    private scheduleRoomCleanup(room: Room): void {
        if (this.cleanupScheduledRooms.has(room.id)) return;
        this.cleanupScheduledRooms.add(room.id);
        room.cleanupTimer = this.options.schedule(() => {
            room.cleanupTimer = undefined;
            this.cleanupScheduledRooms.delete(room.id);
            this.rooms.delete(room.id);
            this.processedCommands.delete(room.id);
            this.clearDisconnectedPlayers(room.id);
            for (const [socketId, roomId] of this.playerRoomMap) {
                if (roomId === room.id) this.playerRoomMap.delete(socketId);
            }
        }, ROOM_RETENTION_MS);
    }

    private reject(
        intent: MoveIntent,
        reason: MoveRejectionReason,
        currentRevision: number,
    ): MoveDecision {
        return {
            type: 'rejected',
            protocolVersion: PROTOCOL_VERSION,
            commandId: intent.commandId,
            reason,
            currentRevision,
        };
    }
}
