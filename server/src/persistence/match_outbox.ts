import { randomUUID } from 'node:crypto';

import {
    finishedMatchContentHash,
    type FinishedMatchRecord,
} from './finished_match_record';

export type MatchOutboxEnqueueResult = 'enqueued' | 'duplicate';

export type MatchOutboxClaim = Readonly<{
    taskId: string;
    leaseToken: string;
    attemptNumber: number;
    record: FinishedMatchRecord;
}>;

export type MatchOutboxClaimOptions = Readonly<{
    nowEpochMs: number;
    leaseDurationMs: number;
    limit: number;
}>;

export interface MatchOutboxRepository {
    enqueue(
        record: FinishedMatchRecord,
        nowEpochMs: number,
    ): Promise<MatchOutboxEnqueueResult>;
    claim(
        options: MatchOutboxClaimOptions,
    ): Promise<readonly MatchOutboxClaim[]>;
    acknowledge(claim: MatchOutboxClaim): Promise<void>;
    reschedule(
        claim: MatchOutboxClaim,
        availableAtEpochMs: number,
    ): Promise<void>;
}

export class MatchOutboxConflictError extends Error {
    public constructor() {
        super('match_outbox_content_conflict');
        this.name = 'MatchOutboxConflictError';
    }
}

type InMemoryOutboxEntry = {
    readonly record: FinishedMatchRecord;
    readonly contentHash: string;
    readonly enqueuedAtEpochMs: number;
    availableAtEpochMs: number;
    attemptCount: number;
    leaseToken?: string;
    leaseExpiresAtEpochMs?: number;
};

export class InMemoryMatchOutboxRepository implements MatchOutboxRepository {
    private readonly entries = new Map<string, InMemoryOutboxEntry>();

    public constructor(
        private readonly options: {
            leaseToken: () => string;
        } = { leaseToken: randomUUID },
    ) { }

    public async enqueue(
        record: FinishedMatchRecord,
        nowEpochMs: number,
    ): Promise<MatchOutboxEnqueueResult> {
        const contentHash = finishedMatchContentHash(record);
        const existing = this.entries.get(record.matchId);
        if (existing) {
            if (existing.contentHash !== contentHash) {
                throw new MatchOutboxConflictError();
            }
            return 'duplicate';
        }
        this.entries.set(record.matchId, {
            record,
            contentHash,
            enqueuedAtEpochMs: nowEpochMs,
            availableAtEpochMs: nowEpochMs,
            attemptCount: 0,
        });
        return 'enqueued';
    }

    public async claim(
        options: MatchOutboxClaimOptions,
    ): Promise<readonly MatchOutboxClaim[]> {
        const eligible = [...this.entries.entries()]
            .filter(([, entry]) => (
                entry.leaseExpiresAtEpochMs !== undefined
                    ? entry.leaseExpiresAtEpochMs <= options.nowEpochMs
                    : entry.availableAtEpochMs <= options.nowEpochMs
            ))
            .sort((first, second) => (
                first[1].enqueuedAtEpochMs - second[1].enqueuedAtEpochMs
                || first[0].localeCompare(second[0])
            ))
            .slice(0, Math.max(0, options.limit));

        return eligible.map(([taskId, entry]) => {
            entry.attemptCount += 1;
            entry.leaseToken = this.options.leaseToken();
            entry.leaseExpiresAtEpochMs = options.nowEpochMs
                + options.leaseDurationMs;
            return Object.freeze({
                taskId,
                leaseToken: entry.leaseToken,
                attemptNumber: entry.attemptCount,
                record: entry.record,
            });
        });
    }

    public async acknowledge(claim: MatchOutboxClaim): Promise<void> {
        this.requireCurrentLease(claim);
        this.entries.delete(claim.taskId);
    }

    public async reschedule(
        claim: MatchOutboxClaim,
        availableAtEpochMs: number,
    ): Promise<void> {
        const entry = this.requireCurrentLease(claim);
        entry.availableAtEpochMs = availableAtEpochMs;
        entry.leaseToken = undefined;
        entry.leaseExpiresAtEpochMs = undefined;
    }

    private requireCurrentLease(claim: MatchOutboxClaim): InMemoryOutboxEntry {
        const entry = this.entries.get(claim.taskId);
        if (!entry || entry.leaseToken !== claim.leaseToken) {
            throw new Error('match_outbox_claim_lost');
        }
        return entry;
    }
}
