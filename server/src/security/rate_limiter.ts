import type { RateLimitPolicy } from '../config';

export type RateLimitDecision =
    | { allowed: true }
    | { allowed: false; retryAfterSeconds: number };

type WindowState = {
    startedAtMs: number;
    count: number;
};

export class FixedWindowRateLimiter {
    private readonly windows = new Map<string, WindowState>();

    public constructor(
        private readonly policy: RateLimitPolicy,
        private readonly maxKeys: number,
        private readonly now: () => number = Date.now,
    ) { }

    public consume(key: string): RateLimitDecision {
        const nowMs = this.now();
        let current = this.windows.get(key);
        if (current && nowMs >= current.startedAtMs + this.policy.windowMs) {
            this.windows.delete(key);
            current = undefined;
        }
        if (!current) {
            this.pruneExpired(nowMs);
            if (this.windows.size >= this.maxKeys) {
                return {
                    allowed: false,
                    retryAfterSeconds: this.retryAfterForCapacity(nowMs),
                };
            }
            this.windows.set(key, { startedAtMs: nowMs, count: 1 });
            return { allowed: true };
        }
        if (current.count < this.policy.max) {
            current.count += 1;
            return { allowed: true };
        }
        return {
            allowed: false,
            retryAfterSeconds: Math.max(
                1,
                Math.ceil(
                    (current.startedAtMs + this.policy.windowMs - nowMs)
                    / 1000,
                ),
            ),
        };
    }

    public clear(): void {
        this.windows.clear();
    }

    private pruneExpired(nowMs: number): void {
        for (const [key, window] of this.windows) {
            if (nowMs >= window.startedAtMs + this.policy.windowMs) {
                this.windows.delete(key);
            }
        }
    }

    private retryAfterForCapacity(nowMs: number): number {
        let earliestExpiry = nowMs + this.policy.windowMs;
        for (const window of this.windows.values()) {
            earliestExpiry = Math.min(
                earliestExpiry,
                window.startedAtMs + this.policy.windowMs,
            );
        }
        return Math.max(1, Math.ceil((earliestExpiry - nowMs) / 1000));
    }
}
