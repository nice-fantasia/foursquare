import { isIP } from 'node:net';

export type ClientIpSource = Readonly<{
    remoteAddress?: string;
    forwardedFor?: string | readonly string[];
}>;

export type ClientIpResolution =
    | Readonly<{ valid: true; clientIp: string }>
    | Readonly<{ valid: false }>;

export const resolveClientIp = (
    source: ClientIpSource,
    trustedProxyHops: number,
): ClientIpResolution => {
    if (!Number.isInteger(trustedProxyHops) || trustedProxyHops < 0) {
        return { valid: false };
    }
    const remoteAddress = source.remoteAddress?.trim();
    if (!remoteAddress || isIP(remoteAddress) === 0) return { valid: false };
    if (trustedProxyHops === 0) {
        return { valid: true, clientIp: remoteAddress };
    }
    if (typeof source.forwardedFor !== 'string') return { valid: false };

    const forwarded = source.forwardedFor.split(',').map((value) => value.trim());
    const candidateIndex = forwarded.length - trustedProxyHops;
    if (candidateIndex < 0) return { valid: false };
    const trustedSegment = forwarded.slice(candidateIndex);
    if (
        trustedSegment.some((address) => !address || isIP(address) === 0)
    ) {
        return { valid: false };
    }
    return { valid: true, clientIp: forwarded[candidateIndex] };
};
