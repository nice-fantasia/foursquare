import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import test from 'node:test';

test('production Dockerfile uses a Node 24 multi-stage non-root runtime', () => {
    const dockerfile = readFileSync(
        resolve(__dirname, '../../Dockerfile'),
        'utf8',
    );

    assert.match(dockerfile, /FROM node:24[^\s]* AS build/);
    assert.match(dockerfile, /FROM node:24[^\s]* AS runtime/);
    assert.match(dockerfile, /USER node/);
    assert.match(dockerfile, /CMD \["node", "dist\/index\.js"\]/);
    assert.doesNotMatch(dockerfile, /npm run dev/);
});

test('Docker build context excludes secrets, archives, and local outputs', () => {
    const dockerignore = readFileSync(
        resolve(__dirname, '../../.dockerignore'),
        'utf8',
    );

    for (const requiredEntry of [
        '.env',
        '.env.*',
        '.git',
        'node_modules',
        'dist',
        '*.zip',
        '*.log',
        'src/**/*.test.ts',
    ]) {
        assert.ok(
            dockerignore.split(/\r?\n/).includes(requiredEntry),
            `missing ${requiredEntry}`,
        );
    }
});

test('production TypeScript build excludes test sources', () => {
    const productionTsconfig = JSON.parse(readFileSync(
        resolve(__dirname, '../../tsconfig.production.json'),
        'utf8',
    )) as { extends?: string; exclude?: string[] };

    assert.equal(productionTsconfig.extends, './tsconfig.json');
    assert.ok(productionTsconfig.exclude?.includes('src/**/*.test.ts'));
});

test('package scripts separate production and test builds on supported LTS lines', () => {
    const packageJson = JSON.parse(readFileSync(
        resolve(__dirname, '../../package.json'),
        'utf8',
    )) as {
        engines?: { node?: string };
        scripts?: Record<string, string>;
    };

    assert.equal(packageJson.engines?.node, '>=22 <23 || >=24 <25');
    assert.match(
        packageJson.scripts?.['build:production'] ?? '',
        /tsconfig\.production\.json/,
    );
    assert.match(packageJson.scripts?.test ?? '', /build:test/);
    assert.match(packageJson.scripts?.test ?? '', /socket_security\.integration\.test\.js/);
});

test('production Compose is external-database, fail-closed, and health checked', () => {
    const compose = readFileSync(
        resolve(__dirname, '../../docker-compose.production.yml'),
        'utf8',
    );

    assert.match(compose, /NODE_ENV: production/);
    assert.match(compose, /DATABASE_URL: \$\{DATABASE_URL:\?DATABASE_URL is required\}/);
    assert.match(compose, /CORS_ORIGINS: \$\{CORS_ORIGINS:\?CORS_ORIGINS is required\}/);
    assert.match(compose, /TRUSTED_PROXY_HOPS: \$\{TRUSTED_PROXY_HOPS:\?TRUSTED_PROXY_HOPS is required\}/);
    assert.match(compose, /\/health\/ready/);
    assert.match(compose, /read_only: true/);
    assert.match(compose, /no-new-privileges:true/);
    assert.doesNotMatch(compose, /npm run dev/);
    assert.doesNotMatch(compose, /postgresql:\/\/user:password/);
    assert.doesNotMatch(compose, /^\s+ports:/m);
    assert.doesNotMatch(compose, /^\s+redis:/m);
    assert.doesNotMatch(compose, /^\s+db:/m);
});

test('development Compose targets the dependency-complete build stage', () => {
    const compose = readFileSync(
        resolve(__dirname, '../../docker-compose.yml'),
        'utf8',
    );

    assert.match(compose, /build:\s*\r?\n\s+context: \.\s*\r?\n\s+target: build/);
    assert.match(compose, /npm run dev/);
    assert.match(compose, /\.:\/app/);
});

test('production deployment runs migrations before starting the server', () => {
    const dockerfile = readFileSync(
        resolve(__dirname, '../../Dockerfile'),
        'utf8',
    );
    const compose = readFileSync(
        resolve(__dirname, '../../docker-compose.production.yml'),
        'utf8',
    );

    assert.match(dockerfile, /FROM build AS migration/);
    assert.match(dockerfile, /CMD \["npm", "run", "db:migrate:deploy"\]/);
    assert.match(compose, /^\s{2}migrate:/m);
    assert.match(compose, /target: migration/);
    assert.match(compose, /condition: service_completed_successfully/);
    assert.match(compose, /DATABASE_URL: \$\{DATABASE_URL:\?DATABASE_URL is required\}/);
    assert.doesNotMatch(compose, /^\s{4}ports:/m);
});
