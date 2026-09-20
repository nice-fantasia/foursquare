import { randomUUID } from 'node:crypto';

import { PrismaClient } from '@prisma/client';
import {
    deserializeFinishedMatchRecord,
    finishedMatchContentHash,
    serializeFinishedMatchRecord,
    type FinishedMatchRecord,
} from '../persistence/finished_match_record';
import {
    MatchOutboxConflictError,
    type MatchOutboxClaim,
    type MatchOutboxClaimOptions,
    type MatchOutboxEnqueueResult,
    type MatchOutboxRepository,
} from '../persistence/match_outbox';

export type { FinishedMatchRecord } from '../persistence/finished_match_record';

export class MatchPersistenceConflictError extends Error {
    public constructor() {
        super('match_persistence_content_conflict');
        this.name = 'MatchPersistenceConflictError';
    }
}

type DatabaseOutboxRow = {
    id: string;
    matchId: string;
    contentHash: string;
    payloadJson: string;
    attemptCount: number;
    availableAt: Date;
    leaseToken: string | null;
    leaseExpiresAt: Date | null;
    createdAt: Date;
};

type DatabaseClient = {
    $queryRaw?: (query: TemplateStringsArray) => Promise<unknown>;
    $disconnect?: () => Promise<void>;
    user: {
        upsert: (args: {
            where: { username: string };
            update: Record<string, never>;
            create: { username: string };
        }) => Promise<{ id: string }>;
    };
    match: {
        upsert: (args: {
            where: { externalId: string };
            update: Record<string, never>;
            create: Record<string, unknown>;
        }) => Promise<{ id: string; contentHash: string }>;
    };
    matchOutbox?: {
        createMany: (args: {
            data: Record<string, unknown>;
            skipDuplicates: true;
        }) => Promise<{ count: number }>;
        findUnique: (args: {
            where: { matchId: string };
        }) => Promise<Record<string, unknown> | null | undefined>;
        findMany: (args: {
            where: Record<string, unknown>;
            orderBy: readonly Record<string, 'asc' | 'desc'>[];
            take: number;
        }) => Promise<DatabaseOutboxRow[]>;
        updateMany: (args: {
            where: Record<string, unknown>;
            data: Record<string, unknown>;
        }) => Promise<{ count: number }>;
        deleteMany: (args: {
            where: Record<string, unknown>;
        }) => Promise<{ count: number }>;
    };
};

export class DatabaseService implements MatchOutboxRepository {
    private closePromise?: Promise<void>;

    public constructor(
        private readonly client: DatabaseClient,
    ) { }

    async findOrCreateUser(userId: string) {
        return this.client.user.upsert({
            where: { username: userId },
            update: {},
            create: { username: userId },
        });
    }

    async saveMatchResult(record: FinishedMatchRecord) {
        const [first, second] = record.players;
        const [p1, p2] = await Promise.all([
            this.findOrCreateUser(first.identityId),
            this.findOrCreateUser(second.identityId),
        ]);
        const winnerDbId = record.winner === 'draw'
            ? null
            : record.winner === first.color
                ? p1.id
                : p2.id;
        const contentHash = finishedMatchContentHash(record);

        const saved = await this.client.match.upsert({
            where: { externalId: record.matchId },
            update: {},
            create: {
                externalId: record.matchId,
                protocolVersion: record.protocolVersion,
                player1Id: p1.id,
                player2Id: p2.id,
                player1Color: first.color,
                player2Color: second.color,
                winnerId: winnerDbId,
                winnerColor: record.winner,
                startingPlayer: record.startingPlayer,
                endReason: record.endReason,
                revision: record.revision,
                status: 'finished',
                movesJson: JSON.stringify(record.moves),
                contentHash,
                startedAt: new Date(record.startedAtEpochMs),
                finishedAt: new Date(record.finishedAtEpochMs),
            },
        });
        if (saved.contentHash !== contentHash) {
            throw new MatchPersistenceConflictError();
        }
        return saved;
    }

    async enqueue(
        record: FinishedMatchRecord,
        nowEpochMs: number,
    ): Promise<MatchOutboxEnqueueResult> {
        const outbox = this.client.matchOutbox;
        if (!outbox) throw new Error('match_outbox_unavailable');
        const contentHash = finishedMatchContentHash(record);
        const inserted = await outbox.createMany({
            data: {
                matchId: record.matchId,
                contentHash,
                payloadJson: serializeFinishedMatchRecord(record),
                availableAt: new Date(nowEpochMs),
                attemptCount: 0,
            },
            skipDuplicates: true,
        });
        const stored = await outbox.findUnique({
            where: { matchId: record.matchId },
        });
        if (!stored || stored.contentHash !== contentHash) {
            throw new MatchOutboxConflictError();
        }
        return inserted.count === 1 ? 'enqueued' : 'duplicate';
    }

    async claim(
        options: MatchOutboxClaimOptions,
    ): Promise<readonly MatchOutboxClaim[]> {
        const outbox = this.requireOutbox();
        const available = await outbox.findMany({
            where: {
                OR: [
                    {
                        leaseToken: null,
                        availableAt: { lte: new Date(options.nowEpochMs) },
                    },
                    {
                        leaseExpiresAt: { lte: new Date(options.nowEpochMs) },
                    },
                ],
            },
            orderBy: [{ availableAt: 'asc' }, { createdAt: 'asc' }],
            take: Math.max(0, options.limit),
        });
        const claims: MatchOutboxClaim[] = [];
        for (const candidate of available) {
            const leaseToken = randomUUID();
            const updated = await outbox.updateMany({
                where: {
                    id: candidate.id,
                    OR: [
                        {
                            leaseToken: null,
                            availableAt: { lte: new Date(options.nowEpochMs) },
                        },
                        {
                            leaseExpiresAt: { lte: new Date(options.nowEpochMs) },
                        },
                    ],
                },
                data: {
                    leaseToken,
                    leaseExpiresAt: new Date(
                        options.nowEpochMs + options.leaseDurationMs,
                    ),
                    attemptCount: { increment: 1 },
                },
            });
            if (updated.count !== 1) continue;
            const record = deserializeFinishedMatchRecord(candidate.payloadJson);
            if (
                record.matchId !== candidate.matchId
                || finishedMatchContentHash(record) !== candidate.contentHash
            ) {
                throw new Error('match_outbox_payload_conflict');
            }
            claims.push(Object.freeze({
                taskId: candidate.id,
                leaseToken,
                attemptNumber: candidate.attemptCount + 1,
                record,
            }));
        }
        return Object.freeze(claims);
    }

    async acknowledge(claim: MatchOutboxClaim): Promise<void> {
        const deleted = await this.requireOutbox().deleteMany({
            where: { id: claim.taskId, leaseToken: claim.leaseToken },
        });
        if (deleted.count !== 1) throw new Error('match_outbox_claim_lost');
    }

    async reschedule(
        claim: MatchOutboxClaim,
        availableAtEpochMs: number,
    ): Promise<void> {
        const updated = await this.requireOutbox().updateMany({
            where: { id: claim.taskId, leaseToken: claim.leaseToken },
            data: {
                availableAt: new Date(availableAtEpochMs),
                leaseToken: null,
                leaseExpiresAt: null,
            },
        });
        if (updated.count !== 1) throw new Error('match_outbox_claim_lost');
    }

    async checkReadiness(): Promise<void> {
        if (!this.client.$queryRaw) {
            throw new Error('database_readiness_unavailable');
        }
        await this.client.$queryRaw`SELECT 1`;
    }

    close(): Promise<void> {
        if (!this.closePromise) {
            this.closePromise = this.client.$disconnect
                ? this.client.$disconnect()
                : Promise.resolve();
        }
        return this.closePromise;
    }

    private requireOutbox(): NonNullable<DatabaseClient['matchOutbox']> {
        if (!this.client.matchOutbox) {
            throw new Error('match_outbox_unavailable');
        }
        return this.client.matchOutbox;
    }
}

export const createDatabaseService = (
    databaseUrl?: string,
): DatabaseService => {
    const prisma = new PrismaClient(
        databaseUrl
            ? { datasources: { db: { url: databaseUrl } } }
            : undefined,
    );
    return new DatabaseService(prisma as unknown as DatabaseClient);
};
