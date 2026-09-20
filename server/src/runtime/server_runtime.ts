import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';

import type { ServerConfig } from '../config';
import { RoomManager } from '../game/room_manager';
import { createSocketGateway } from '../gateway/socket';
import { createHttpApp } from '../http/app';
import type { MatchOutboxRepository } from '../persistence/match_outbox';
import { MatchOutboxWorker } from '../persistence/match_outbox_worker';
import type { FinishedMatchRecord } from '../services/database';
import { createSecureSocketServer } from '../security/socket_security';

export type RuntimeDatabase = {
    checkReadiness: () => Promise<void>;
    close: () => Promise<void>;
    saveMatchResult: (record: FinishedMatchRecord) => Promise<unknown>;
};

export type ServerRuntimeDependencies = {
    database: RuntimeDatabase;
    outboxRepository: MatchOutboxRepository;
    roomManager?: RoomManager;
};

export type StartedServerAddress = {
    host: string;
    port: number;
};

export type ServerRuntime = {
    start: () => Promise<StartedServerAddress>;
    shutdown: () => Promise<void>;
    isShuttingDown: () => boolean;
};

export const createServerRuntime = (
    config: ServerConfig,
    dependencies: ServerRuntimeDependencies,
): ServerRuntime => {
    let shuttingDown = false;
    const roomManager = dependencies.roomManager ?? new RoomManager();
    const app = createHttpApp({
        config,
        checkReadiness: () => dependencies.database.checkReadiness(),
        isShuttingDown: () => shuttingDown,
    });
    const httpServer = createServer(app);
    const io = createSecureSocketServer(httpServer, config);
    const outboxWorker = new MatchOutboxWorker({
        repository: dependencies.outboxRepository,
        materialize: (record) => dependencies.database.saveMatchResult(record),
        now: Date.now,
        random: Math.random,
        schedule: (callback, delayMs) => {
            const timer = setTimeout(callback, delayMs);
            timer.unref();
            return timer;
        },
        cancelSchedule: (handle) => clearTimeout(handle as NodeJS.Timeout),
        log: (event) => console.error(
            `Match outbox ${event.code}`,
            event.attemptNumber ?? '',
        ),
    });
    const gateway = createSocketGateway(
        io as unknown as Parameters<typeof createSocketGateway>[0],
        roomManager,
        async (record) => {
            const result = await dependencies.outboxRepository.enqueue(
                record,
                Date.now(),
            );
            await outboxWorker.notify();
            return result;
        },
    );
    let startPromise: Promise<StartedServerAddress> | undefined;
    let shutdownPromise: Promise<void> | undefined;

    const start = (): Promise<StartedServerAddress> => {
        if (!startPromise) {
            startPromise = outboxWorker.start().then(() => new Promise<StartedServerAddress>(
                (resolve, reject) => {
                    const handleError = (error: Error): void => reject(error);
                    httpServer.once('error', handleError);
                    httpServer.listen(config.port, '0.0.0.0', () => {
                        httpServer.off('error', handleError);
                        const address = httpServer.address() as AddressInfo;
                        resolve({ host: address.address, port: address.port });
                    });
                },
            )).catch(async (error: unknown) => {
                try {
                    await shutdown();
                } catch {
                    console.error('Server startup cleanup failed');
                }
                throw error;
            });
        }
        return startPromise;
    };

    const shutdown = (): Promise<void> => {
        if (!shutdownPromise) {
            shuttingDown = true;
            shutdownPromise = shutdownOwnedResources();
        }
        return shutdownPromise;
    };

    const shutdownOwnedResources = async (): Promise<void> => {
        const deadlineEpochMs = Date.now() + config.shutdownTimeoutMs;
        const gatewayShutdown = gateway.shutdown();
        const outboxShutdown = outboxWorker.shutdown();
        roomManager.dispose();
        const socketsClosed = new Promise<void>((resolve) => {
            io.close(() => resolve());
        });
        let failure: 'server_shutdown_timeout' | 'server_shutdown_failed'
            | undefined;
        try {
            const results = await withinDeadline(
                Promise.allSettled([
                    gatewayShutdown,
                    outboxShutdown,
                    socketsClosed,
                ]),
                deadlineEpochMs,
            );
            if (results.some((result) => result.status === 'rejected')) {
                failure = 'server_shutdown_failed';
            }
        } catch {
            failure = 'server_shutdown_timeout';
        }

        httpServer.closeAllConnections();
        try {
            await withinDeadline(
                Promise.resolve().then(() => dependencies.database.close()),
                deadlineEpochMs,
            );
        } catch (error) {
            if (error instanceof ShutdownTimeoutError) {
                failure = 'server_shutdown_timeout';
            } else if (!failure) {
                failure = 'server_shutdown_failed';
            }
        }
        if (failure) throw new Error(failure);
    };

    return {
        start,
        shutdown,
        isShuttingDown: () => shuttingDown,
    };
};

class ShutdownTimeoutError extends Error {
    public constructor() {
        super('server_shutdown_timeout');
        this.name = 'ShutdownTimeoutError';
    }
}

const withinDeadline = async <T>(
    operation: Promise<T>,
    deadlineEpochMs: number,
): Promise<T> => {
    const remainingMs = Math.max(0, deadlineEpochMs - Date.now());
    if (remainingMs === 0) {
        void operation.catch(() => undefined);
        throw new ShutdownTimeoutError();
    }
    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<never>((_resolve, reject) => {
        timer = setTimeout(
            () => reject(new ShutdownTimeoutError()),
            remainingMs,
        );
    });
    try {
        return await Promise.race([operation, timeout]);
    } finally {
        if (timer) clearTimeout(timer);
    }
};
