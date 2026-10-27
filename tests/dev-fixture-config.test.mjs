import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const composeFile = fileURLToPath(new URL('../fixtures/dev/compose.yaml', import.meta.url));
const digest = 'a'.repeat(64); // Configuration validation only; no image is pulled or started.
const env = { ...process.env, POSTGRES_IMAGE: `postgres@sha256:${digest}`, STATIC_IMAGE: `busybox@sha256:${digest}`, CADDY_IMAGE: `caddy@sha256:${digest}` };
delete env.DEV_HOSTNAME;
delete env.COMPOSE_PROFILES;
const config = profiles => JSON.parse(execFileSync('docker', ['compose', '-f', composeFile, ...profiles.flatMap(p => ['--profile', p]), 'config', '--format', 'json'], { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));

test('fixtures and backup configuration do not require deferred external DNS', () => {
  const model = config([]);
  assert.ok(model.services.postgres && model.services.static);
  assert.ok(!model.services.proxy && !model.services['proxy-local']);
  assert.ok(!model.services.postgres.ports?.length);
  assert.ok(model.networks.isolated.internal);
});

test('local proxy proof exposes only HTTP/HTTPS and no database or application ports', () => {
  const model = config(['local']);
  assert.ok(model.services['proxy-local']);
  assert.ok(!model.services.proxy);
  const published = Object.values(model.services).flatMap(s => (s.ports ?? []).map(p => Number(p.published))).sort((a,b) => a-b);
  assert.deepEqual(published, [80, 443]);
  assert.ok(model.services['proxy-local'].volumes.some(v => v.source.endsWith('Caddyfile.local') && v.read_only));
});
