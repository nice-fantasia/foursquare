import cors from 'cors';
import express from 'express';
import type { Express, NextFunction, Request, Response } from 'express';

import type { ServerConfig } from '../config';
import { resolveClientIp } from '../security/client_ip';
import { isOriginAllowed } from '../security/origin_policy';
import { FixedWindowRateLimiter } from '../security/rate_limiter';
import { SingleFlightReadinessProbe } from './readiness';

export type HttpAppOptions = {
    config: ServerConfig;
    checkReadiness: () => Promise<void>;
    isShuttingDown: () => boolean;
    now?: () => number;
};

export const createHttpApp = (options: HttpAppOptions): Express => {
    const app = express();
    const limiter = new FixedWindowRateLimiter(
        options.config.httpRateLimit,
        options.config.rateLimitMaxKeys,
        options.now,
    );
    const readiness = new SingleFlightReadinessProbe(
        options.checkReadiness,
        options.config.readinessTimeoutMs,
    );

    app.use((request, response, next) => {
        if (request.path === '/health/live' || request.path === '/health/ready') {
            next();
            return;
        }
        const clientIp = resolveClientIp({
            remoteAddress: request.socket.remoteAddress,
            forwardedFor: request.headers['x-forwarded-for'],
        }, options.config.trustedProxyHops);
        if (!clientIp.valid) {
            response.status(403).json({ error: 'client_ip_unavailable' });
            return;
        }
        const decision = limiter.consume(clientIp.clientIp);
        if (decision.allowed) {
            next();
            return;
        }
        response.set('Retry-After', String(decision.retryAfterSeconds));
        response.status(429).json({ error: 'rate_limited' });
    });

    app.use(cors({
        origin: (origin, callback) => {
            if (isOriginAllowed(origin, options.config.corsOrigins)) {
                callback(null, true);
                return;
            }
            callback(new Error('cors_origin_denied'));
        },
        methods: ['GET', 'POST', 'OPTIONS'],
    }));
    app.use(express.json({ limit: options.config.httpBodyLimitBytes }));

    app.get('/health/live', (_request, response) => {
        response.set('Cache-Control', 'no-store');
        response.status(200).json({ status: 'live' });
    });

    app.get('/health/ready', async (_request, response) => {
        response.set('Cache-Control', 'no-store');
        if (options.isShuttingDown()) {
            response.status(503).json({ status: 'not_ready' });
            return;
        }
        try {
            await readiness.check();
            response.status(200).json({ status: 'ready' });
        } catch {
            response.status(503).json({ status: 'not_ready' });
        }
    });

    app.get('/', (_request, response) => {
        response.send('Welcome to Foursquare Server');
    });

    app.use((
        error: unknown,
        _request: Request,
        response: Response,
        next: NextFunction,
    ) => {
        if (response.headersSent) {
            next(error);
            return;
        }
        if (error instanceof Error && error.message === 'cors_origin_denied') {
            response.status(403).json({ error: 'origin_denied' });
            return;
        }
        if (
            error instanceof SyntaxError
            && 'status' in error
            && error.status === 400
        ) {
            response.status(400).json({ error: 'invalid_json' });
            return;
        }
        if (
            typeof error === 'object'
            && error !== null
            && 'status' in error
            && error.status === 413
        ) {
            response.status(413).json({ error: 'payload_too_large' });
            return;
        }
        response.status(500).json({ error: 'internal_error' });
    });

    return app;
};
