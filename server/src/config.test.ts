import assert from 'node:assert/strict';
import test from 'node:test';

import { ConfigurationError, loadServerConfig } from './config';

test('production configuration rejects a missing database URL', () => {
    assert.throws(
        () => loadServerConfig({
            NODE_ENV: 'production',
            CORS_ORIGINS: 'https://game.example.com',
        }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message === 'invalid configuration: DATABASE_URL is required',
    );
});

test('production configuration rejects a missing CORS allowlist', () => {
    assert.throws(
        () => loadServerConfig({
            NODE_ENV: 'production',
            DATABASE_URL: 'postgresql://user:password@db:5432/foursquare',
        }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message === 'invalid configuration: CORS_ORIGINS is required',
    );
});

test('production configuration requires an explicit trusted proxy hop count', () => {
    assert.throws(
        () => loadServerConfig({
            NODE_ENV: 'production',
            DATABASE_URL: 'postgresql://user:password@db:5432/foursquare',
            CORS_ORIGINS: 'https://game.example.com',
        }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message
                === 'invalid configuration: TRUSTED_PROXY_HOPS is required',
    );
});

test('database URL validation rejects unsupported values without leaking them', () => {
    const secretValue = 'mysql://private-user:private-password@db/foursquare';
    assert.throws(
        () => loadServerConfig({
            NODE_ENV: 'production',
            DATABASE_URL: secretValue,
            CORS_ORIGINS: 'https://game.example.com',
        }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message === 'invalid configuration: DATABASE_URL must use PostgreSQL'
            && !error.message.includes(secretValue)
            && !error.message.includes('private-password'),
    );
});

test('production configuration rejects an incomplete PostgreSQL URL', () => {
    assert.throws(
        () => loadServerConfig({
            NODE_ENV: 'production',
            DATABASE_URL: 'postgresql:',
            CORS_ORIGINS: 'https://game.example.com',
            TRUSTED_PROXY_HOPS: '1',
        }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message
                === 'invalid configuration: DATABASE_URL must be a complete PostgreSQL URL'
            && !error.message.includes('postgresql:'),
    );
});

test('complete PostgreSQL URLs retain supported connection options', () => {
    const databaseUrl = 'postgresql://user:p%40ss@[2001:db8::1]:5432/foursquare?schema=game&sslmode=require';
    const config = loadServerConfig({
        NODE_ENV: 'production',
        DATABASE_URL: databaseUrl,
        CORS_ORIGINS: 'https://game.example.com',
        TRUSTED_PROXY_HOPS: '1',
    });

    assert.equal(config.databaseUrl, databaseUrl);
});

test('PostgreSQL URLs without a database or with an invalid port fail closed', () => {
    for (const databaseUrl of [
        'postgresql://db.example.com',
        'postgresql://db.example.com:99999/foursquare',
    ]) {
        assert.throws(
            () => loadServerConfig({
                NODE_ENV: 'production',
                DATABASE_URL: databaseUrl,
                CORS_ORIGINS: 'https://game.example.com',
                TRUSTED_PROXY_HOPS: '1',
            }),
            (error: unknown) => error instanceof ConfigurationError
                && error.message
                    === 'invalid configuration: DATABASE_URL must be a complete PostgreSQL URL'
                && !error.message.includes(databaseUrl),
        );
    }
});

test('trusted proxy hops reject negative, fractional, and excessive values', () => {
    for (const trustedProxyHops of ['-1', '1.5', '9']) {
        assert.throws(
            () => loadServerConfig({ TRUSTED_PROXY_HOPS: trustedProxyHops }),
            (error: unknown) => error instanceof ConfigurationError
                && error.message
                    === 'invalid configuration: TRUSTED_PROXY_HOPS must be an integer between 0 and 8',
        );
    }
});

test('production configuration rejects a wildcard CORS origin', () => {
    assert.throws(
        () => loadServerConfig({
            NODE_ENV: 'production',
            DATABASE_URL: 'postgresql://user:password@db:5432/foursquare',
            CORS_ORIGINS: '*',
        }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message === 'invalid configuration: CORS_ORIGINS must be an allowlist',
    );
});

test('CORS origins are normalized and de-duplicated', () => {
    const config = loadServerConfig({
        NODE_ENV: 'production',
        DATABASE_URL: 'postgresql://user:password@db:5432/foursquare',
        CORS_ORIGINS: [
            ' https://game.example.com/ ',
            'http://localhost:3000',
            'https://game.example.com',
        ].join(','),
        TRUSTED_PROXY_HOPS: '1',
    });

    assert.deepEqual(config.corsOrigins, [
        'https://game.example.com',
        'http://localhost:3000',
    ]);
});

test('CORS allowlist rejects non-origin URLs', () => {
    assert.throws(
        () => loadServerConfig({
            NODE_ENV: 'production',
            DATABASE_URL: 'postgresql://user:password@db:5432/foursquare',
            CORS_ORIGINS: 'https://game.example.com/private?token=secret',
            TRUSTED_PROXY_HOPS: '1',
        }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message === 'invalid configuration: CORS_ORIGINS contains an invalid origin'
            && !error.message.includes('token=secret'),
    );
});

test('development configuration exposes bounded local defaults', () => {
    const config = loadServerConfig({});

    assert.equal(config.environment, 'development');
    assert.equal(config.port, 3000);
    assert.equal(config.databaseUrl, undefined);
    assert.equal(config.corsOrigins, '*');
    assert.equal(config.httpBodyLimitBytes, 16 * 1024);
    assert.equal(config.socketMaxPayloadBytes, 16 * 1024);
    assert.deepEqual(config.httpRateLimit, { windowMs: 60_000, max: 120 });
    assert.deepEqual(config.socketConnectionRateLimit, {
        windowMs: 60_000,
        max: 30,
    });
    assert.deepEqual(config.socketEventRateLimit, {
        windowMs: 10_000,
        max: 120,
    });
    assert.equal(config.rateLimitMaxKeys, 10_000);
    assert.equal(config.trustedProxyHops, 0);
    assert.equal(config.readinessTimeoutMs, 2_000);
    assert.equal(config.shutdownTimeoutMs, 10_000);
});

test('operational limits accept bounded integer overrides', () => {
    const config = loadServerConfig({
        PORT: '4040',
        HTTP_BODY_LIMIT_BYTES: '32768',
        SOCKET_MAX_PAYLOAD_BYTES: '8192',
        HTTP_RATE_LIMIT_WINDOW_MS: '30000',
        HTTP_RATE_LIMIT_MAX: '80',
        SOCKET_CONNECTION_RATE_LIMIT_WINDOW_MS: '45000',
        SOCKET_CONNECTION_RATE_LIMIT_MAX: '12',
        SOCKET_EVENT_RATE_LIMIT_WINDOW_MS: '5000',
        SOCKET_EVENT_RATE_LIMIT_MAX: '70',
        RATE_LIMIT_MAX_KEYS: '20000',
        TRUSTED_PROXY_HOPS: '2',
        READINESS_TIMEOUT_MS: '1500',
        SHUTDOWN_TIMEOUT_MS: '8000',
    });

    assert.equal(config.port, 4040);
    assert.equal(config.httpBodyLimitBytes, 32768);
    assert.equal(config.socketMaxPayloadBytes, 8192);
    assert.deepEqual(config.httpRateLimit, { windowMs: 30000, max: 80 });
    assert.deepEqual(config.socketConnectionRateLimit, {
        windowMs: 45000,
        max: 12,
    });
    assert.deepEqual(config.socketEventRateLimit, {
        windowMs: 5000,
        max: 70,
    });
    assert.equal(config.rateLimitMaxKeys, 20000);
    assert.equal(config.trustedProxyHops, 2);
    assert.equal(config.readinessTimeoutMs, 1500);
    assert.equal(config.shutdownTimeoutMs, 8000);
});

test('unknown runtime environments are rejected', () => {
    assert.throws(
        () => loadServerConfig({ NODE_ENV: 'prod' }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message === 'invalid configuration: NODE_ENV is unsupported',
    );
});

test('operational limits reject non-decimal integer syntax', () => {
    assert.throws(
        () => loadServerConfig({ PORT: '1e3' }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message === 'invalid configuration: PORT must be an integer between 1 and 65535',
    );
});

test('shutdown deadline stays below the fifteen-second container grace period', () => {
    assert.throws(
        () => loadServerConfig({
            SHUTDOWN_TIMEOUT_MS: '15000',
        }),
        (error: unknown) => error instanceof ConfigurationError
            && error.message
                === 'invalid configuration: SHUTDOWN_TIMEOUT_MS must be an integer between 1000 and 14000',
    );
});
