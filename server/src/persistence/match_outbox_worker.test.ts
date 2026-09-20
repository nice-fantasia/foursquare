import assert from 'node:assert/strict';
import test from 'node:test';

import type { GameState, Room } from '../types/game';
import { createFinishedMatchRecord } from './finished_match_record';
import {
    InMemoryMatchOutboxRepository,
    type MatchOutboxClaim,
} from './match_outbox';
import {
    MatchOutboxWorker,
    type MatchOutboxLogEvent,
} from './match_outbox_worker';

test('worker start recovers and materializes an already-enqueued task', async () => {
    const repository = new InMemoryMatchOutboxRepository();
    const record = finishedRecord('match-recovery');
    await repository.enqueue(record, 1_000);
    const materialized: string[] = [];
    const worker = new MatchOutboxWorker({
        repository,
        materialize: async (candidate) => {
            materialized.push(candidate.matchId);
        },
        now: () => 1_000,
        random: () => 0.5,
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });

    await worker.start();
    await waitUntil(() => materialized.length === 1);
    await worker.shutdown();

    assert.deepEqual(materialized, ['match-recovery']);
    assert.deepEqual(await repository.claim({
        nowEpochMs: 100_000,
        leaseDurationMs: 1_000,
        limit: 1,
    }), []);
});

test('acknowledgement failure is logged without record data and safely replayed', async () => {
    class FailFirstAcknowledgement extends InMemoryMatchOutboxRepository {
        private failed = false;

        public override async acknowledge(claim: MatchOutboxClaim): Promise<void> {
            if (!this.failed) {
                this.failed = true;
                throw new Error(
                    `private ${claim.record.players[0].identityId} ${claim.record.matchId}`,
                );
            }
            await super.acknowledge(claim);
        }
    }

    let now = 1_000;
    const repository = new FailFirstAcknowledgement();
    const record = finishedRecord('match-ack-replay');
    await repository.enqueue(record, now);
    const logs: MatchOutboxLogEvent[] = [];
    let materializeCalls = 0;
    const createWorker = () => new MatchOutboxWorker({
        repository,
        materialize: async () => {
            materializeCalls += 1;
        },
        now: () => now,
        random: () => 0.5,
        schedule: () => undefined,
        cancelSchedule: () => undefined,
        log: (event) => logs.push(event),
    });
    const first = createWorker();

    await first.start();
    await waitUntil(() => logs.length === 1);
    await first.shutdown();

    assert.equal(logs[0].code, 'acknowledge_failed');
    assert.equal(JSON.stringify(logs).includes('device-first'), false);
    assert.equal(JSON.stringify(logs).includes('match-ack-replay'), false);

    now = 2_000;
    const restarted = createWorker();
    await restarted.start();
    await waitUntil(() => materializeCalls === 2);
    await restarted.shutdown();

    assert.equal(materializeCalls, 2);
    assert.deepEqual(await repository.claim({
        nowEpochMs: 100_000,
        leaseDurationMs: 1_000,
        limit: 1,
    }), []);
});

test('worker enforces one global materialization concurrency limit', async () => {
    const repository = new InMemoryMatchOutboxRepository();
    await repository.enqueue(finishedRecord('match-concurrency-1'), 1_000);
    await repository.enqueue(finishedRecord('match-concurrency-2'), 1_000);
    await repository.enqueue(finishedRecord('match-concurrency-3'), 1_000);
    const releases: Array<() => void> = [];
    const started: string[] = [];
    let active = 0;
    let maximumActive = 0;
    const worker = new MatchOutboxWorker({
        repository,
        materialize: (record) => new Promise<void>((resolve) => {
            started.push(record.matchId);
            active += 1;
            maximumActive = Math.max(maximumActive, active);
            releases.push(() => {
                active -= 1;
                resolve();
            });
        }),
        now: () => 1_000,
        random: () => 0.5,
        schedule: () => undefined,
        cancelSchedule: () => undefined,
        options: { maxConcurrency: 2 },
    });

    await worker.start();
    await waitUntil(() => started.length === 2);
    assert.equal(maximumActive, 2);
    assert.equal(started.length, 2);

    releases.shift()!();
    releases.shift()!();
    await waitUntil(() => started.length === 3);
    assert.equal(maximumActive, 2);
    releases.shift()!();
    await worker.shutdown();
});

test('failed work uses jittered backoff without blocking the next task', async () => {
    const repository = new InMemoryMatchOutboxRepository();
    await repository.enqueue(finishedRecord('match-a-bad'), 1_000);
    await repository.enqueue(finishedRecord('match-b-good'), 1_000);
    const materialized: string[] = [];
    const worker = new MatchOutboxWorker({
        repository,
        materialize: async (record) => {
            materialized.push(record.matchId);
            if (record.matchId === 'match-a-bad') {
                throw new Error(
                    `private ${record.players[0].identityId} ${record.matchId}`,
                );
            }
        },
        now: () => 1_000,
        random: () => 0,
        schedule: () => undefined,
        cancelSchedule: () => undefined,
        options: {
            maxConcurrency: 1,
            baseRetryDelayMs: 1_000,
            maxRetryDelayMs: 30_000,
        },
    });

    await worker.start();
    await waitUntil(() => materialized.includes('match-b-good'));
    await worker.shutdown();

    assert.deepEqual(materialized, ['match-a-bad', 'match-b-good']);
    assert.deepEqual(await repository.claim({
        nowEpochMs: 1_499,
        leaseDurationMs: 1_000,
        limit: 1,
    }), []);
    const [retry] = await repository.claim({
        nowEpochMs: 1_500,
        leaseDurationMs: 1_000,
        limit: 1,
    });
    assert.equal(retry.record.matchId, 'match-a-bad');
    assert.equal(retry.attemptNumber, 2);
});

test('worker shutdown is idempotent and waits for active materialization', async () => {
    const repository = new InMemoryMatchOutboxRepository();
    await repository.enqueue(finishedRecord('match-shutdown'), 1_000);
    let finish: (() => void) | undefined;
    let started = false;
    const worker = new MatchOutboxWorker({
        repository,
        materialize: () => new Promise<void>((resolve) => {
            started = true;
            finish = resolve;
        }),
        now: () => 1_000,
        random: () => 0.5,
        schedule: () => undefined,
        cancelSchedule: () => undefined,
    });
    await worker.start();
    await waitUntil(() => started);

    let shutdownFinished = false;
    const first = worker.shutdown().then(() => {
        shutdownFinished = true;
    });
    const second = worker.shutdown();
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(shutdownFinished, false);

    finish!();
    await Promise.all([first, second]);
    assert.equal(shutdownFinished, true);
});

const waitUntil = async (condition: () => boolean): Promise<void> => {
    for (let attempt = 0; attempt < 50; attempt += 1) {
        if (condition()) return;
        await new Promise<void>((resolve) => setImmediate(resolve));
    }
    throw new Error('condition_not_met');
};

const finishedRecord = (matchId: string) => {
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
    const room: Room = {
        id: matchId,
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
    return createFinishedMatchRecord(room, state, 70_000);
};
