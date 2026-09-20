import type { Server as HttpServer } from 'node:http';

import { Server } from 'socket.io';

import type { ServerConfig } from '../config';
import { resolveClientIp } from './client_ip';
import { isOriginAllowed } from './origin_policy';
import { FixedWindowRateLimiter } from './rate_limiter';

export const createSecureSocketServer = (
    httpServer: HttpServer,
    config: ServerConfig,
    now: () => number = Date.now,
): Server => {
    const connectionLimiter = new FixedWindowRateLimiter(
        config.socketConnectionRateLimit,
        config.rateLimitMaxKeys,
        now,
    );
    const io = new Server(httpServer, {
        allowRequest: (request, callback) => {
            if (!isOriginAllowed(request.headers.origin, config.corsOrigins)) {
                callback('origin_denied', false);
                return;
            }
            const clientIp = resolveClientIp({
                remoteAddress: request.socket.remoteAddress,
                forwardedFor: request.headers['x-forwarded-for'],
            }, config.trustedProxyHops);
            if (!clientIp.valid) {
                callback('client_ip_unavailable', false);
                return;
            }
            const decision = connectionLimiter.consume(clientIp.clientIp);
            callback(decision.allowed ? null : 'rate_limited', decision.allowed);
        },
        cors: {
            origin: config.corsOrigins === '*'
                ? '*'
                : [...config.corsOrigins],
            methods: ['GET', 'POST'],
        },
        maxHttpBufferSize: config.socketMaxPayloadBytes,
        serveClient: false,
    });
    io.on('connection', (socket) => {
        const eventLimiter = new FixedWindowRateLimiter(
            config.socketEventRateLimit,
            1,
            now,
        );
        socket.use((_packet, next) => {
            const decision = eventLimiter.consume('socket');
            next(decision.allowed ? undefined : new Error('rate_limited'));
        });
        socket.on('error', (error) => {
            if (error instanceof Error && error.message === 'rate_limited') {
                socket.disconnect(true);
            }
        });
    });
    return io;
};
