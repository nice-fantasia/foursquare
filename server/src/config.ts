export class ConfigurationError extends Error {
    public constructor(message: string) {
        super(`invalid configuration: ${message}`);
        this.name = 'ConfigurationError';
    }
}

export type ServerConfig = {
    environment: 'development' | 'test' | 'production';
    port: number;
    databaseUrl?: string;
    corsOrigins: '*' | readonly string[];
    httpBodyLimitBytes: number;
    socketMaxPayloadBytes: number;
    httpRateLimit: RateLimitPolicy;
    socketConnectionRateLimit: RateLimitPolicy;
    socketEventRateLimit: RateLimitPolicy;
    rateLimitMaxKeys: number;
    trustedProxyHops: number;
    readinessTimeoutMs: number;
    shutdownTimeoutMs: number;
};

export type RateLimitPolicy = {
    windowMs: number;
    max: number;
};

export const loadServerConfig = (
    env: NodeJS.ProcessEnv = process.env,
): ServerConfig => {
    const environment = parseEnvironment(env.NODE_ENV);
    const databaseUrl = env.DATABASE_URL?.trim();
    if (environment === 'production' && !databaseUrl) {
        throw new ConfigurationError('DATABASE_URL is required');
    }
    if (databaseUrl) {
        const databaseUrlValidation = validatePostgreSqlUrl(databaseUrl);
        if (databaseUrlValidation === 'unsupported_protocol') {
            throw new ConfigurationError('DATABASE_URL must use PostgreSQL');
        }
        if (databaseUrlValidation === 'incomplete') {
            throw new ConfigurationError(
                'DATABASE_URL must be a complete PostgreSQL URL',
            );
        }
    }
    const rawCorsOrigins = env.CORS_ORIGINS?.trim();
    if (environment === 'production' && !rawCorsOrigins) {
        throw new ConfigurationError('CORS_ORIGINS is required');
    }
    if (environment === 'production' && rawCorsOrigins === '*') {
        throw new ConfigurationError('CORS_ORIGINS must be an allowlist');
    }
    const rawTrustedProxyHops = env.TRUSTED_PROXY_HOPS?.trim();
    if (environment === 'production' && !rawTrustedProxyHops) {
        throw new ConfigurationError('TRUSTED_PROXY_HOPS is required');
    }
    return {
        environment,
        port: boundedInteger(env, 'PORT', 3000, 1, 65_535),
        corsOrigins: rawCorsOrigins
            ? rawCorsOrigins === '*'
                ? '*'
                : normalizeOrigins(rawCorsOrigins)
            : '*',
        httpBodyLimitBytes: boundedInteger(
            env,
            'HTTP_BODY_LIMIT_BYTES',
            16 * 1024,
            1024,
            1024 * 1024,
        ),
        socketMaxPayloadBytes: boundedInteger(
            env,
            'SOCKET_MAX_PAYLOAD_BYTES',
            16 * 1024,
            1024,
            1024 * 1024,
        ),
        httpRateLimit: {
            windowMs: boundedInteger(
                env,
                'HTTP_RATE_LIMIT_WINDOW_MS',
                60_000,
                1000,
                3_600_000,
            ),
            max: boundedInteger(
                env,
                'HTTP_RATE_LIMIT_MAX',
                120,
                1,
                100_000,
            ),
        },
        socketConnectionRateLimit: {
            windowMs: boundedInteger(
                env,
                'SOCKET_CONNECTION_RATE_LIMIT_WINDOW_MS',
                60_000,
                1000,
                3_600_000,
            ),
            max: boundedInteger(
                env,
                'SOCKET_CONNECTION_RATE_LIMIT_MAX',
                30,
                1,
                100_000,
            ),
        },
        socketEventRateLimit: {
            windowMs: boundedInteger(
                env,
                'SOCKET_EVENT_RATE_LIMIT_WINDOW_MS',
                10_000,
                1000,
                3_600_000,
            ),
            max: boundedInteger(
                env,
                'SOCKET_EVENT_RATE_LIMIT_MAX',
                120,
                1,
                100_000,
            ),
        },
        rateLimitMaxKeys: boundedInteger(
            env,
            'RATE_LIMIT_MAX_KEYS',
            10_000,
            100,
            1_000_000,
        ),
        trustedProxyHops: boundedInteger(
            env,
            'TRUSTED_PROXY_HOPS',
            0,
            0,
            8,
        ),
        readinessTimeoutMs: boundedInteger(
            env,
            'READINESS_TIMEOUT_MS',
            2_000,
            100,
            30_000,
        ),
        shutdownTimeoutMs: boundedInteger(
            env,
            'SHUTDOWN_TIMEOUT_MS',
            10_000,
            1000,
            14_000,
        ),
        ...(databaseUrl ? { databaseUrl } : {}),
    };
};

const parseEnvironment = (
    value: string | undefined,
): ServerConfig['environment'] => {
    if (value === undefined || value === '' || value === 'development') {
        return 'development';
    }
    if (value === 'test' || value === 'production') return value;
    throw new ConfigurationError('NODE_ENV is unsupported');
};

const boundedInteger = (
    env: NodeJS.ProcessEnv,
    name: string,
    fallback: number,
    minimum: number,
    maximum: number,
): number => {
    const raw = env[name]?.trim();
    if (raw === undefined || raw === '') return fallback;
    const value = Number(raw);
    if (
        !/^[0-9]+$/.test(raw)
        || !Number.isSafeInteger(value)
        || value < minimum
        || value > maximum
    ) {
        throw new ConfigurationError(
            `${name} must be an integer between ${minimum} and ${maximum}`,
        );
    }
    return value;
};

const validatePostgreSqlUrl = (
    value: string,
): 'valid' | 'unsupported_protocol' | 'incomplete' => {
    try {
        const url = new URL(value);
        if (url.protocol !== 'postgresql:' && url.protocol !== 'postgres:') {
            return 'unsupported_protocol';
        }
        if (!url.hostname || url.pathname.length <= 1 || url.hash) {
            return 'incomplete';
        }
        return 'valid';
    } catch {
        return 'incomplete';
    }
};

const normalizeOrigins = (value: string): readonly string[] => {
    try {
        const normalized = value.split(',').map((rawOrigin) => {
            const trimmed = rawOrigin.trim();
            if (!trimmed) throw new Error('blank origin');
            const origin = new URL(trimmed);
            if (
                (origin.protocol !== 'http:' && origin.protocol !== 'https:')
                || (origin.pathname !== '/' && origin.pathname !== '')
                || origin.search
                || origin.hash
                || origin.username
                || origin.password
            ) {
                throw new Error('invalid origin');
            }
            return origin.origin;
        });
        return [...new Set(normalized)];
    } catch {
        throw new ConfigurationError(
            'CORS_ORIGINS contains an invalid origin',
        );
    }
};
