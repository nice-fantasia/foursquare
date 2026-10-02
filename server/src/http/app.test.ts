import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import test from 'node:test';

import { loadServerConfig } from '../config';
import { createHttpApp } from './app';

test('liveness stays available when the database readiness probe fails', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({ NODE_ENV: 'test' }),
        checkReadiness: async () => {
            throw new Error('private database failure');
        },
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(
        `http://127.0.0.1:${address.port}/health/live`,
    );

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), { status: 'live' });
});

test('readiness reports ready after a successful database probe', async (t) => {
    let probeCalls = 0;
    const app = createHttpApp({
        config: loadServerConfig({ NODE_ENV: 'test' }),
        checkReadiness: async () => {
            probeCalls += 1;
        },
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(
        `http://127.0.0.1:${address.port}/health/ready`,
    );

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), { status: 'ready' });
    assert.equal(probeCalls, 1);
});

test('readiness contains database failures and returns a fixed response', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({ NODE_ENV: 'test' }),
        checkReadiness: async () => {
            throw new Error('postgresql://private:secret@db/foursquare');
        },
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(
        `http://127.0.0.1:${address.port}/health/ready`,
    );
    const body = await response.text();

    assert.equal(response.status, 503);
    assert.deepEqual(JSON.parse(body), { status: 'not_ready' });
    assert.equal(body.includes('private'), false);
    assert.equal(body.includes('secret'), false);
});

test('readiness fails closed during shutdown without probing the database', async (t) => {
    let probeCalls = 0;
    const app = createHttpApp({
        config: loadServerConfig({ NODE_ENV: 'test' }),
        checkReadiness: async () => {
            probeCalls += 1;
        },
        isShuttingDown: () => true,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(
        `http://127.0.0.1:${address.port}/health/ready`,
    );

    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { status: 'not_ready' });
    assert.equal(probeCalls, 0);
});

test('readiness fails closed when the database probe exceeds its timeout', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({
            NODE_ENV: 'test',
            READINESS_TIMEOUT_MS: '100',
        }),
        checkReadiness: () => new Promise<void>((resolve) => {
            const timer = setTimeout(resolve, 500);
            timer.unref();
        }),
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;
    const startedAt = Date.now();

    const response = await fetch(
        `http://127.0.0.1:${address.port}/health/ready`,
    );

    assert.equal(response.status, 503);
    assert.ok(Date.now() - startedAt < 350);
});

test('readiness stays single-flight and retries a permanently hung probe after cooldown', async (t) => {
    let probeCalls = 0;
    const app = createHttpApp({
        config: loadServerConfig({
            NODE_ENV: 'test',
            READINESS_TIMEOUT_MS: '100',
        }),
        checkReadiness: () => {
            probeCalls += 1;
            return probeCalls === 1
                ? new Promise<void>(() => undefined)
                : Promise.resolve();
        },
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;
    const url = `http://127.0.0.1:${address.port}/health/ready`;

    const responses = await Promise.all([fetch(url), fetch(url), fetch(url)]);

    assert.deepEqual(responses.map((response) => response.status), [503, 503, 503]);
    assert.equal(probeCalls, 1);
    const duringCooldown = await fetch(url);
    assert.equal(duringCooldown.status, 503);
    assert.equal(probeCalls, 1);
    const recovered = await fetch(url);
    assert.equal(recovered.status, 200);
    assert.equal(probeCalls, 2);
});

test('readiness caps abandoned permanently hung probe generations', async (t) => {
    let probeCalls = 0;
    const app = createHttpApp({
        config: loadServerConfig({
            NODE_ENV: 'test',
            READINESS_TIMEOUT_MS: '100',
        }),
        checkReadiness: () => {
            probeCalls += 1;
            return new Promise<void>(() => undefined);
        },
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;
    const url = `http://127.0.0.1:${address.port}/health/ready`;

    for (let generation = 0; generation < 4; generation += 1) {
        assert.equal((await fetch(url)).status, 503);
        await new Promise<void>((resolve) => setTimeout(resolve, 110));
    }

    assert.equal(probeCalls, 2);
});

test('an allowlisted browser origin receives the CORS response header', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({
            NODE_ENV: 'test',
            CORS_ORIGINS: 'https://game.example.com',
        }),
        checkReadiness: async () => undefined,
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(
        `http://127.0.0.1:${address.port}/health/live`,
        { headers: { Origin: 'https://game.example.com' } },
    );

    assert.equal(response.status, 200);
    assert.equal(
        response.headers.get('access-control-allow-origin'),
        'https://game.example.com',
    );
});

test('an unknown browser origin is rejected with a fixed response', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({
            NODE_ENV: 'test',
            CORS_ORIGINS: 'https://game.example.com',
        }),
        checkReadiness: async () => undefined,
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(
        `http://127.0.0.1:${address.port}/health/live`,
        { headers: { Origin: 'https://attacker.example' } },
    );

    assert.equal(response.status, 403);
    assert.deepEqual(await response.json(), { error: 'origin_denied' });
});

test('JSON request bodies above the configured limit return a fixed 413', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({
            NODE_ENV: 'test',
            HTTP_BODY_LIMIT_BYTES: '1024',
        }),
        checkReadiness: async () => undefined,
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(
        `http://127.0.0.1:${address.port}/missing`,
        {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ value: 'x'.repeat(2_000) }),
        },
    );

    assert.equal(response.status, 413);
    assert.deepEqual(await response.json(), { error: 'payload_too_large' });
});

test('malformed JSON returns a fixed 400 without echoing request data', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({ NODE_ENV: 'test' }),
        checkReadiness: async () => undefined,
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(`http://127.0.0.1:${address.port}/`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{"private":"secret",',
    });
    const body = await response.text();

    assert.equal(response.status, 400);
    assert.deepEqual(JSON.parse(body), { error: 'invalid_json' });
    assert.equal(body.includes('private'), false);
    assert.equal(body.includes('secret'), false);
});

test('HTTP traffic above the per-peer quota returns 429 with retry guidance', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({
            NODE_ENV: 'test',
            HTTP_RATE_LIMIT_WINDOW_MS: '1000',
            HTTP_RATE_LIMIT_MAX: '2',
        }),
        checkReadiness: async () => undefined,
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;
    const url = `http://127.0.0.1:${address.port}/missing`;

    assert.equal((await fetch(url)).status, 404);
    assert.equal((await fetch(url)).status, 404);
    const limited = await fetch(url);

    assert.equal(limited.status, 429);
    assert.equal(limited.headers.get('retry-after'), '1');
    assert.deepEqual(await limited.json(), { error: 'rate_limited' });
});

test('trusted proxy clients receive independent HTTP rate-limit buckets', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({
            NODE_ENV: 'test',
            HTTP_RATE_LIMIT_MAX: '1',
            TRUSTED_PROXY_HOPS: '1',
        }),
        checkReadiness: async () => undefined,
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;
    const url = `http://127.0.0.1:${address.port}/`;

    const first = await fetch(url, {
        headers: { 'X-Forwarded-For': '203.0.113.10' },
    });
    const second = await fetch(url, {
        headers: { 'X-Forwarded-For': '203.0.113.11' },
    });

    assert.equal(first.status, 200);
    assert.equal(second.status, 200);
});

test('HTTP requests fail closed when the configured proxy chain is missing', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({
            NODE_ENV: 'test',
            TRUSTED_PROXY_HOPS: '1',
        }),
        checkReadiness: async () => undefined,
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(`http://127.0.0.1:${address.port}/`);

    assert.equal(response.status, 403);
    assert.deepEqual(await response.json(), { error: 'client_ip_unavailable' });
});

test('the existing root endpoint remains available', async (t) => {
    const app = createHttpApp({
        config: loadServerConfig({ NODE_ENV: 'test' }),
        checkReadiness: async () => undefined,
        isShuttingDown: () => false,
    });
    const server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
    }));
    const address = server.address() as AddressInfo;

    const response = await fetch(`http://127.0.0.1:${address.port}/`);

    assert.equal(response.status, 200);
    assert.equal(await response.text(), 'Welcome to Foursquare Server');
});
