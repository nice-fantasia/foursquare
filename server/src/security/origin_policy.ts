import type { ServerConfig } from '../config';

export const isOriginAllowed = (
    origin: string | undefined,
    allowedOrigins: ServerConfig['corsOrigins'],
): boolean => origin === undefined
    || allowedOrigins === '*'
    || allowedOrigins.includes(origin);
