import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import test from 'node:test';

test('Prisma schema and migration preserve durable outbox lease fields', () => {
    const schema = readFileSync(
        resolve(__dirname, '../../prisma/schema.prisma'),
        'utf8',
    );
    const migration = readFileSync(
        resolve(
            __dirname,
            '../../prisma/migrations/20260824_phase3_match_outbox/migration.sql',
        ),
        'utf8',
    );

    assert.match(schema, /model MatchOutbox \{/);
    assert.match(schema, /matchId\s+String\s+@unique/);
    assert.match(schema, /contentHash\s+String/);
    assert.match(schema, /payloadJson\s+String/);
    assert.match(schema, /attemptCount\s+Int\s+@default\(0\)/);
    assert.match(schema, /leaseToken\s+String\?/);
    assert.match(schema, /leaseExpiresAt\s+DateTime\?/);
    assert.match(schema, /startedAt\s+DateTime/);
    assert.match(migration, /CREATE TABLE "MatchOutbox"/);
    assert.match(migration, /CREATE UNIQUE INDEX "MatchOutbox_matchId_key"/);
    assert.match(migration, /"contentHash" = 'legacy:' \|\| "externalId"/);
});
