import assert from 'node:assert/strict';
import test from 'node:test';

import { resolveClientIp } from './client_ip';

test('direct mode ignores spoofed forwarding headers', () => {
    assert.deepEqual(
        resolveClientIp({
            remoteAddress: '203.0.113.10',
            forwardedFor: '198.51.100.1',
        }, 0),
        { valid: true, clientIp: '203.0.113.10' },
    );
});

test('one trusted proxy selects the rightmost forwarded address', () => {
    assert.deepEqual(
        resolveClientIp({
            remoteAddress: '10.0.0.10',
            forwardedFor: '198.51.100.99, 203.0.113.20',
        }, 1),
        { valid: true, clientIp: '203.0.113.20' },
    );
});

test('multiple trusted proxies ignore attacker-controlled left prefixes', () => {
    assert.deepEqual(
        resolveClientIp({
            remoteAddress: '10.0.0.10',
            forwardedFor: '192.0.2.99, 203.0.113.30, 10.0.0.20',
        }, 2),
        { valid: true, clientIp: '203.0.113.30' },
    );
});

test('missing, ambiguous, or invalid trusted proxy chains fail closed', () => {
    assert.deepEqual(
        resolveClientIp({ remoteAddress: '10.0.0.10' }, 1),
        { valid: false },
    );
    assert.deepEqual(
        resolveClientIp({
            remoteAddress: '10.0.0.10',
            forwardedFor: ['203.0.113.40'],
        }, 1),
        { valid: false },
    );
    assert.deepEqual(
        resolveClientIp({
            remoteAddress: '10.0.0.10',
            forwardedFor: '203.0.113.40, not-an-ip',
        }, 2),
        { valid: false },
    );
});
