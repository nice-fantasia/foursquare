import assert from 'node:assert/strict';
import test from 'node:test';

import type { GameState, Room } from '../types/game';
import { createFinishedMatchRecord } from './finished_match_record';
import {
    InMemoryMatchOutboxRepository,
    MatchOutboxConflictError,
} from './match_outbox';

test('outbox enqueue is idempotent for equal content and rejects conflicts', async () => {
    const repository = new InMemoryMatchOutboxRepository();
    const record = finishedRecord();

    assert.equal(await repository.enqueue(record, 1_000), 'enqueued');
    assert.equal(await repository.enqueue(record, 2_000), 'duplicate');
    await assert.rejects(
        repository.enqueue(
            Object.freeze({ ...record, revision: record.revision + 1 }),
            3_000,
        ),
        (error) => error instanceof MatchOutboxConflictError
            && error.message === 'match_outbox_content_conflict',
    );
});

test('outbox claims are leased and expired leases are recovered', async () => {
    let lease = 0;
    const repository = new InMemoryMatchOutboxRepository({
        leaseToken: () => `lease-${++lease}`,
    });
    await repository.enqueue(finishedRecord(), 1_000);

    const first = await repository.claim({
        nowEpochMs: 1_000,
        leaseDurationMs: 5_000,
        limit: 1,
    });
    assert.equal(first.length, 1);
    assert.equal(first[0].attemptNumber, 1);
    assert.equal(first[0].leaseToken, 'lease-1');

    assert.deepEqual(await repository.claim({
        nowEpochMs: 5_999,
        leaseDurationMs: 5_000,
        limit: 1,
    }), []);

    const recovered = await repository.claim({
        nowEpochMs: 6_000,
        leaseDurationMs: 5_000,
        limit: 1,
    });
    assert.equal(recovered.length, 1);
    assert.equal(recovered[0].attemptNumber, 2);
    assert.equal(recovered[0].leaseToken, 'lease-2');
});

test('only the current lease can acknowledge or reschedule a task', async () => {
    const repository = new InMemoryMatchOutboxRepository({
        leaseToken: () => 'lease-current',
    });
    await repository.enqueue(finishedRecord(), 1_000);
    const [claim] = await repository.claim({
        nowEpochMs: 1_000,
        leaseDurationMs: 5_000,
        limit: 1,
    });

    await assert.rejects(
        repository.acknowledge({ ...claim, leaseToken: 'lease-stale' }),
        /match_outbox_claim_lost/,
    );
    await repository.reschedule(claim, 8_000);
    assert.deepEqual(await repository.claim({
        nowEpochMs: 7_999,
        leaseDurationMs: 5_000,
        limit: 1,
    }), []);

    const [retried] = await repository.claim({
        nowEpochMs: 8_000,
        leaseDurationMs: 5_000,
        limit: 1,
    });
    await repository.acknowledge(retried);
    assert.deepEqual(await repository.claim({
        nowEpochMs: 20_000,
        leaseDurationMs: 5_000,
        limit: 1,
    }), []);
});

const finishedRecord = () => {
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
        id: 'match-outbox-1',
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
