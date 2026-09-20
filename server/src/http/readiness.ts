export class SingleFlightReadinessProbe {
    private static readonly maxOutstandingProbes = 2;

    private inFlight?: Promise<void>;
    private recoveryTimer?: NodeJS.Timeout;
    private recoveryBlockedFor?: Promise<void>;
    private readonly outstanding = new Set<Promise<void>>();

    public constructor(
        private readonly probe: () => Promise<void>,
        private readonly timeoutMs: number,
    ) { }

    public check(): Promise<void> {
        if (!this.inFlight) {
            let tracked: Promise<void>;
            tracked = Promise.resolve()
                .then(() => this.probe())
                .finally(() => {
                    this.outstanding.delete(tracked);
                    if (this.inFlight === tracked) {
                        this.inFlight = undefined;
                        this.recoveryBlockedFor = undefined;
                        if (this.recoveryTimer) {
                            clearTimeout(this.recoveryTimer);
                            this.recoveryTimer = undefined;
                        }
                    } else if (
                        this.recoveryBlockedFor === this.inFlight
                        && this.inFlight
                        && this.outstanding.size
                            < SingleFlightReadinessProbe.maxOutstandingProbes
                    ) {
                        const blocked = this.inFlight;
                        this.recoveryBlockedFor = undefined;
                        this.scheduleRecovery(blocked);
                    }
                });
            this.inFlight = tracked;
            this.outstanding.add(tracked);
        }
        const tracked = this.inFlight;
        return withTimeout(tracked, this.timeoutMs).catch((error: unknown) => {
            if (error instanceof ReadinessTimeoutError) {
                this.scheduleRecovery(tracked);
            }
            throw error;
        });
    }

    private scheduleRecovery(tracked: Promise<void>): void {
        if (
            this.recoveryTimer
            || this.recoveryBlockedFor === tracked
            || this.inFlight !== tracked
        ) return;
        this.recoveryTimer = setTimeout(() => {
            this.recoveryTimer = undefined;
            if (this.inFlight !== tracked) return;
            if (
                this.outstanding.size
                    >= SingleFlightReadinessProbe.maxOutstandingProbes
            ) {
                this.recoveryBlockedFor = tracked;
                return;
            }
            this.recoveryBlockedFor = undefined;
            this.inFlight = undefined;
        }, this.timeoutMs);
        this.recoveryTimer.unref();
    }
}

class ReadinessTimeoutError extends Error {
    public constructor() {
        super('readiness_timeout');
        this.name = 'ReadinessTimeoutError';
    }
}

const withTimeout = async <T>(
    promise: Promise<T>,
    timeoutMs: number,
): Promise<T> => {
    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<never>((_resolve, reject) => {
        timer = setTimeout(
            () => reject(new ReadinessTimeoutError()),
            timeoutMs,
        );
        timer.unref();
    });
    try {
        return await Promise.race([promise, timeout]);
    } finally {
        if (timer) clearTimeout(timer);
    }
};
