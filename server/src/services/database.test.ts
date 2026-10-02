import assert from 'node:assert/strict';
import test from 'node:test';

import {
    deserializeFinishedMatchRecord,
    finishedMatchContentHash,
} from '../persistence/finished_match_record';
import { MatchOutboxConflictError } from '../persistence/match_outbox';
import {
    DatabaseService,
    MatchPersistenceConflictError,
} from './database';

test('finished match persistence is idempotent and maps the winner by color', async () => {
    const userCalls: unknown[] = [];
    const matchCalls: Array<{
        where: { externalId: string };
        update: Record<string, never>;
        create: Record<string, unknown>;
    }> = [];
    const client = {
        user: {
            upsert: async (args: {
                where: { username: string };
                update: Record<string, never>;
                create: { username: string };
            }) => {
                userCalls.push(args);
                return { id: `db-${args.where.username}` };
            },
        },
        match: {
            upsert: async (args: {
                where: { externalId: string };
                update: Record<string, never>;
                create: Record<string, unknown>;
            }) => {
                matchCalls.push(args);
                return {
                    id: 'db-match-1',
                    contentHash: args.create.contentHash as string,
                };
            },
        },
    };
    const service = new DatabaseService(client);
    const record = deserializeFinishedMatchRecord(JSON.stringify({
        schemaVersion: 1,
        matchId: 'match-persisted-1',
        protocolVersion: 1,
        players: [
            { identityId: 'device-first', color: 'black' },
            { identityId: 'device-second', color: 'white' },
        ],
        winner: 'black',
        startingPlayer: 'white',
        endReason: 'piece_count',
        revision: 9,
        moves: [
            {
                matchId: 'match-persisted-1',
                from: { x: 1, y: 0 },
                to: { x: 1, y: 1 },
                player: 'black' as const,
                capturedPieces: [
                    { x: 2, y: 1 },
                    { x: 1, y: 2 },
                ],
            },
        ],
        startedAtEpochMs: 10_000,
        finishedAtEpochMs: 70_000,
    }));

    await service.saveMatchResult(record);
    await service.saveMatchResult(record);

    assert.equal(userCalls.length, 4);
    assert.equal(matchCalls.length, 2);
    for (const call of matchCalls) {
        assert.deepEqual(call.where, { externalId: record.matchId });
        assert.deepEqual(call.update, {});
        assert.equal(call.create.externalId, record.matchId);
        assert.equal(call.create.player1Id, 'db-device-first');
        assert.equal(call.create.player2Id, 'db-device-second');
        assert.equal(call.create.player1Color, 'black');
        assert.equal(call.create.player2Color, 'white');
        assert.equal(call.create.winnerId, 'db-device-first');
        assert.equal(call.create.winnerColor, 'black');
        assert.equal(call.create.startingPlayer, 'white');
        assert.equal(call.create.endReason, 'piece_count');
        assert.equal(call.create.revision, 9);
        assert.equal(call.create.contentHash, finishedMatchContentHash(record));
        assert.deepEqual(call.create.startedAt, new Date(10_000));
        assert.deepEqual(call.create.finishedAt, new Date(70_000));
        assert.deepEqual(JSON.parse(call.create.movesJson as string), record.moves);
    }
});

test('a draw persists no winner relation', async () => {
    let persisted: Record<string, unknown> | undefined;
    const service = new DatabaseService({
        user: {
            upsert: async (args) => ({ id: `db-${args.where.username}` }),
        },
        match: {
            upsert: async (args) => {
                persisted = args.create;
                return {
                    id: 'db-draw',
                    contentHash: args.create.contentHash as string,
                };
            },
        },
    });

    await service.saveMatchResult(deserializeFinishedMatchRecord(JSON.stringify({
        schemaVersion: 1,
        matchId: 'match-draw',
        protocolVersion: 1,
        players: [
            { identityId: 'device-first', color: 'black' },
            { identityId: 'device-second', color: 'white' },
        ],
        winner: 'draw',
        startingPlayer: 'black',
        endReason: 'no_capture_limit',
        revision: 50,
        moves: [],
        startedAtEpochMs: 10_000,
        finishedAtEpochMs: 70_000,
    })));

    assert.equal(persisted?.winnerId, null);
    assert.equal(persisted?.winnerColor, 'draw');
});

test('database lifecycle probes PostgreSQL and disconnects idempotently', async () => {
    let probeCalls = 0;
    let disconnectCalls = 0;
    const service = new DatabaseService({
        user: {
            upsert: async () => ({ id: 'unused-user' }),
        },
        match: {
            upsert: async () => ({
                id: 'unused-match',
                contentHash: 'unused-hash',
            }),
        },
        $queryRaw: async (query) => {
            probeCalls += 1;
            assert.deepEqual([...query], ['SELECT 1']);
            return [{ result: 1 }];
        },
        $disconnect: async () => {
            disconnectCalls += 1;
        },
    });

    await service.checkReadiness();
    await service.close();
    await service.close();

    assert.equal(probeCalls, 1);
    assert.equal(disconnectCalls, 1);
});

test('same match content is idempotent while conflicting content is rejected', async () => {
    let stored: { id: string; contentHash: string } | undefined;
    const service = new DatabaseService({
        user: {
            upsert: async (args) => ({ id: `db-${args.where.username}` }),
        },
        match: {
            upsert: async (args) => {
                if (!stored) {
                    stored = {
                        id: 'db-match-conflict',
                        contentHash: args.create.contentHash as string,
                    };
                }
                return stored;
            },
        },
    });
    const record = finishedRecord('match-content-1');

    await service.saveMatchResult(record);
    await service.saveMatchResult(record);
    assert.equal(stored?.contentHash, finishedMatchContentHash(record));

    await assert.rejects(
        service.saveMatchResult(Object.freeze({
            ...record,
            revision: record.revision + 1,
        })),
        (error) => error instanceof MatchPersistenceConflictError
            && error.message === 'match_persistence_content_conflict',
    );
});

test('database outbox enqueue is durable, idempotent, and conflict detecting', async () => {
    let stored: Record<string, unknown> | undefined;
    const service = new DatabaseService({
        user: { upsert: async () => ({ id: 'unused-user' }) },
        match: {
            upsert: async () => ({ id: 'unused-match', contentHash: 'unused' }),
        },
        matchOutbox: {
            createMany: async (args: { data: Record<string, unknown> }) => {
                if (stored) return { count: 0 };
                stored = { id: 'task-1', ...args.data };
                return { count: 1 };
            },
            findUnique: async () => stored,
            findMany: async () => [],
            updateMany: async () => ({ count: 0 }),
            deleteMany: async () => ({ count: 0 }),
        },
    });
    const record = finishedRecord('match-outbox-database');

    assert.equal(await service.enqueue(record, 1_000), 'enqueued');
    assert.equal(await service.enqueue(record, 2_000), 'duplicate');
    assert.equal(stored?.contentHash, finishedMatchContentHash(record));

    await assert.rejects(
        service.enqueue(Object.freeze({
            ...record,
            revision: record.revision + 1,
        }), 3_000),
        (error) => error instanceof MatchOutboxConflictError,
    );
});

test('database outbox claim applies a lease and restores immutable payload', async () => {
    const record = finishedRecord('match-outbox-claim');
    let update: Record<string, unknown> | undefined;
    const service = new DatabaseService({
        user: { upsert: async () => ({ id: 'unused-user' }) },
        match: {
            upsert: async () => ({ id: 'unused-match', contentHash: 'unused' }),
        },
        matchOutbox: {
            createMany: async () => ({ count: 0 }),
            findUnique: async () => null,
            findMany: async () => [{
                id: 'task-claim-1',
                matchId: record.matchId,
                contentHash: finishedMatchContentHash(record),
                payloadJson: JSON.stringify(record),
                attemptCount: 2,
                availableAt: new Date(1_000),
                leaseToken: null,
                leaseExpiresAt: null,
                createdAt: new Date(1_000),
            }],
            updateMany: async (args) => {
                update = args.data;
                return { count: 1 };
            },
            deleteMany: async () => ({ count: 0 }),
        },
    });

    const claims = await service.claim({
        nowEpochMs: 2_000,
        leaseDurationMs: 5_000,
        limit: 1,
    });

    assert.equal(claims.length, 1);
    assert.equal(claims[0].taskId, 'task-claim-1');
    assert.equal(claims[0].attemptNumber, 3);
    assert.deepEqual(claims[0].record, record);
    assert.equal(typeof claims[0].leaseToken, 'string');
    assert.deepEqual(update?.leaseExpiresAt, new Date(7_000));
    assert.deepEqual(update?.attemptCount, { increment: 1 });
});

test('database outbox completion and retry require the active lease', async () => {
    const updates: Array<Record<string, unknown>> = [];
    const deletes: Array<Record<string, unknown>> = [];
    const service = new DatabaseService({
        user: { upsert: async () => ({ id: 'unused-user' }) },
        match: {
            upsert: async () => ({ id: 'unused-match', contentHash: 'unused' }),
        },
        matchOutbox: {
            createMany: async () => ({ count: 0 }),
            findUnique: async () => null,
            findMany: async () => [],
            updateMany: async (args) => {
                updates.push(args);
                return { count: 1 };
            },
            deleteMany: async (args) => {
                deletes.push(args.where);
                return { count: 1 };
            },
        },
    });
    const claim = Object.freeze({
        taskId: 'task-current',
        leaseToken: 'lease-current',
        attemptNumber: 3,
        record: finishedRecord('match-current'),
    });

    await service.reschedule(claim, 8_000);
    await service.acknowledge(claim);

    assert.deepEqual(updates[0], {
        where: { id: 'task-current', leaseToken: 'lease-current' },
        data: {
            availableAt: new Date(8_000),
            leaseToken: null,
            leaseExpiresAt: null,
        },
    });
    assert.deepEqual(deletes[0], {
        id: 'task-current',
        leaseToken: 'lease-current',
    });
});

test('database outbox claim rejects payload that differs from its content hash', async () => {
    const record = finishedRecord('match-outbox-tampered');
    const tampered = { ...JSON.parse(JSON.stringify(record)), revision: 99 };
    const service = new DatabaseService({
        user: { upsert: async () => ({ id: 'unused-user' }) },
        match: {
            upsert: async () => ({ id: 'unused-match', contentHash: 'unused' }),
        },
        matchOutbox: {
            createMany: async () => ({ count: 0 }),
            findUnique: async () => null,
            findMany: async () => [{
                id: 'task-tampered',
                matchId: record.matchId,
                contentHash: finishedMatchContentHash(record),
                payloadJson: JSON.stringify(tampered),
                attemptCount: 0,
                availableAt: new Date(1_000),
                leaseToken: null,
                leaseExpiresAt: null,
                createdAt: new Date(1_000),
            }],
            updateMany: async () => ({ count: 1 }),
            deleteMany: async () => ({ count: 0 }),
        },
    });

    await assert.rejects(
        service.claim({
            nowEpochMs: 2_000,
            leaseDurationMs: 5_000,
            limit: 1,
        }),
        /match_outbox_payload_conflict/,
    );
});

const finishedRecord = (matchId: string) => deserializeFinishedMatchRecord(
    JSON.stringify({
        schemaVersion: 1,
        matchId,
        protocolVersion: 1,
        players: [
            { identityId: 'device-first', color: 'black' },
            { identityId: 'device-second', color: 'white' },
        ],
        winner: 'black',
        startingPlayer: 'white',
        endReason: 'piece_count',
        revision: 9,
        moves: [],
        startedAtEpochMs: 10_000,
        finishedAtEpochMs: 70_000,
    }),
);
