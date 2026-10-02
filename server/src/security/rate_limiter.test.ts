import assert from 'node:assert/strict';
import test from 'node:test';

import { FixedWindowRateLimiter } from './rate_limiter';

test('a fixed window allows its quota and reports when the key can retry', () => {
    let now = 1_000;
    const limiter = new FixedWindowRateLimiter(
        { windowMs: 1_000, max: 2 },
        10,
        () => now,
    );

    assert.deepEqual(limiter.consume('client-a'), { allowed: true });
    assert.deepEqual(limiter.consume('client-a'), { allowed: true });
    assert.deepEqual(limiter.consume('client-a'), {
        allowed: false,
        retryAfterSeconds: 1,
    });

    now = 2_000;
    assert.deepEqual(limiter.consume('client-a'), { allowed: true });
});

test('the limiter denies new keys when active key capacity is exhausted', () => {
    let now = 5_000;
    const limiter = new FixedWindowRateLimiter(
        { windowMs: 1_000, max: 1 },
        2,
        () => now,
    );

    assert.deepEqual(limiter.consume('client-a'), { allowed: true });
    assert.deepEqual(limiter.consume('client-b'), { allowed: true });
    assert.deepEqual(limiter.consume('client-c'), {
        allowed: false,
        retryAfterSeconds: 1,
    });

    now = 6_000;
    assert.deepEqual(limiter.consume('client-c'), { allowed: true });
});
