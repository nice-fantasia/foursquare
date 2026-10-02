import type { FinishedMatchRecord } from './finished_match_record';
import type {
    MatchOutboxClaim,
    MatchOutboxRepository,
} from './match_outbox';

export type MatchOutboxLogEvent = Readonly<{
    code:
        | 'claim_failed'
        | 'materialize_failed'
        | 'acknowledge_failed'
        | 'reschedule_failed';
    attemptNumber?: number;
}>;

export type MatchOutboxWorkerOptions = Readonly<{
    maxConcurrency: number;
    leaseDurationMs: number;
    pollIntervalMs: number;
    baseRetryDelayMs: number;
    maxRetryDelayMs: number;
}>;

export type MatchOutboxWorkerDependencies = Readonly<{
    repository: MatchOutboxRepository;
    materialize: (record: FinishedMatchRecord) => Promise<unknown>;
    now: () => number;
    random: () => number;
    schedule: (callback: () => void, delayMs: number) => unknown;
    cancelSchedule: (handle: unknown) => void;
    log?: (event: MatchOutboxLogEvent) => void;
    options?: Partial<MatchOutboxWorkerOptions>;
}>;

const DEFAULT_OPTIONS: MatchOutboxWorkerOptions = {
    maxConcurrency: 2,
    leaseDurationMs: 30_000,
    pollIntervalMs: 1_000,
    baseRetryDelayMs: 1_000,
    maxRetryDelayMs: 30_000,
};

export class MatchOutboxWorker {
    private readonly repository: MatchOutboxRepository;
    private readonly materialize: (
        record: FinishedMatchRecord,
    ) => Promise<unknown>;
    private readonly now: () => number;
    private readonly random: () => number;
    private readonly schedule: (callback: () => void, delayMs: number) => unknown;
    private readonly cancelSchedule: (handle: unknown) => void;
    private readonly log: (event: MatchOutboxLogEvent) => void;
    private readonly options: MatchOutboxWorkerOptions;
    private readonly inFlight = new Set<Promise<void>>();

    private started = false;
    private shuttingDown = false;
    private scheduledHandle?: unknown;
    private drainPromise?: Promise<void>;
    private shutdownPromise?: Promise<void>;

    public constructor(dependencies: MatchOutboxWorkerDependencies) {
        this.repository = dependencies.repository;
        this.materialize = dependencies.materialize;
        this.now = dependencies.now;
        this.random = dependencies.random;
        this.schedule = dependencies.schedule;
        this.cancelSchedule = dependencies.cancelSchedule;
        this.log = dependencies.log ?? (() => undefined);
        this.options = { ...DEFAULT_OPTIONS, ...dependencies.options };
    }

    public start(): Promise<void> {
        if (!this.started) {
            this.started = true;
        }
        return this.wake();
    }

    public notify(): Promise<void> {
        return this.started ? this.wake() : Promise.resolve();
    }

    public shutdown(): Promise<void> {
        if (!this.shutdownPromise) {
            this.shuttingDown = true;
            if (this.scheduledHandle !== undefined) {
                this.cancelSchedule(this.scheduledHandle);
                this.scheduledHandle = undefined;
            }
            this.shutdownPromise = this.finishShutdown();
        }
        return this.shutdownPromise;
    }

    private async finishShutdown(): Promise<void> {
        await this.drainPromise;
        await Promise.allSettled([...this.inFlight]);
    }

    private wake(): Promise<void> {
        if (this.shuttingDown) return Promise.resolve();
        if (this.scheduledHandle !== undefined) {
            this.cancelSchedule(this.scheduledHandle);
            this.scheduledHandle = undefined;
        }
        if (!this.drainPromise) {
            this.drainPromise = this.claimAvailable().finally(() => {
                this.drainPromise = undefined;
            });
        }
        return this.drainPromise;
    }

    private async claimAvailable(): Promise<void> {
        const capacity = this.options.maxConcurrency - this.inFlight.size;
        if (capacity <= 0 || this.shuttingDown) return;

        let claims: readonly MatchOutboxClaim[];
        try {
            claims = await this.repository.claim({
                nowEpochMs: this.now(),
                leaseDurationMs: this.options.leaseDurationMs,
                limit: capacity,
            });
        } catch {
            this.log({ code: 'claim_failed' });
            this.scheduleNext(this.options.pollIntervalMs);
            return;
        }
        if (this.shuttingDown) return;
        if (claims.length === 0) {
            this.scheduleNext(this.options.pollIntervalMs);
            return;
        }
        for (const claim of claims) this.process(claim);
    }

    private process(claim: MatchOutboxClaim): void {
        let task: Promise<void>;
        task = this.processClaim(claim).finally(() => {
            this.inFlight.delete(task);
            if (!this.shuttingDown) void this.wake();
        });
        this.inFlight.add(task);
    }

    private async processClaim(claim: MatchOutboxClaim): Promise<void> {
        try {
            await this.materialize(claim.record);
        } catch {
            await this.rescheduleAfterFailure(claim, 'materialize_failed');
            return;
        }
        try {
            await this.repository.acknowledge(claim);
        } catch {
            await this.rescheduleAfterFailure(claim, 'acknowledge_failed');
        }
    }

    private async rescheduleAfterFailure(
        claim: MatchOutboxClaim,
        code: 'materialize_failed' | 'acknowledge_failed',
    ): Promise<void> {
        this.log({ code, attemptNumber: claim.attemptNumber });
        try {
            await this.repository.reschedule(
                claim,
                this.now() + this.retryDelay(claim.attemptNumber),
            );
        } catch {
            this.log({
                code: 'reschedule_failed',
                attemptNumber: claim.attemptNumber,
            });
        }
    }

    private retryDelay(attemptNumber: number): number {
        const exponent = Math.max(0, Math.min(30, attemptNumber - 1));
        const exponential = Math.min(
            this.options.maxRetryDelayMs,
            this.options.baseRetryDelayMs * (2 ** exponent),
        );
        const random = Math.max(0, Math.min(1, this.random()));
        return Math.max(1, Math.min(
            this.options.maxRetryDelayMs,
            Math.round(exponential * (0.5 + random)),
        ));
    }

    private scheduleNext(delayMs: number): void {
        if (this.shuttingDown || this.scheduledHandle !== undefined) return;
        let handle: unknown;
        handle = this.schedule(() => {
            if (handle !== undefined && this.scheduledHandle === handle) {
                this.scheduledHandle = undefined;
            }
            void this.wake();
        }, delayMs);
        if (handle !== undefined) this.scheduledHandle = handle;
    }
}
