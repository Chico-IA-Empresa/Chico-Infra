import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, copyFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { syntheticManifest as createSyntheticManifest, bundleSources as applicationBundleSources } from '../scripts/package-bundle.mjs';
import { validateManifest, updateComponent } from '../scripts/package-manifest.mjs';
import { fileURLToPath } from 'node:url';

// Contract tests must run in an isolated Chico-Infra checkout. Production bundles
// still consume the actual backend scripts, never these explicitly synthetic files.
const bundleSources = { ...applicationBundleSources };
for (const name of ['package_migrate.py', 'package_seed.py']) {
  bundleSources[name] = fileURLToPath(new URL(`./fixtures/package/${name}`, import.meta.url));
}
const syntheticManifest = () => createSyntheticManifest({ sources: bundleSources });

test('synthetic manifest validates but can never become a final release', () => {
  assert.equal(validateManifest(syntheticManifest()).promotable, false);
  assert.throws(() => validateManifest(syntheticManifest(), {final:true}), /synthetic/);
});
const mutations = {
  missing: m => delete m.images.workers,
  tag: m => m.images.api.reference = 'synthetic.invalid/chico-api:latest',
  wrongArch: m => m.images.frontend.platform = 'linux/amd64',
  wrongSha: m => m.images.workers.sourceSha = '3'.repeat(40),
  differentBuild: m => m.images.workers.buildId = 'other',
  missingScan: m => delete m.images.api.scan,
  failedScan: m => m.images.workers.scan.status = 'failed',
  wrongScanDigest: m => m.images.api.scan.digest = m.images.frontend.manifestDigest,
  missingEvidence: m => m.images.frontend.checks.evidence = '',
  wrongDigestLink: m => m.images.frontend.indexDigest = m.images.api.indexDigest,
  noAlembic: m => m.alembicHeads = [],
  mobileInvented: m => m.mobile = 'app-v1.0',
  leakedSecret: m => m.configuration[0].value = 'private-marker',
  leakedDsn: m => m.configuration[0].reference = 'postgresql://fake:fake@fixture/db',
  leakedTopLevel: m => m.secret = 'private-marker',
  badHash: m => m.bundle.files['compose.yaml'] = 'sha256:' + '0'.repeat(64),
  missingSeed: m => delete m.bundle.files['package_seed.py'],
  pathTraversal: m => m.bundle.files['../outside'] = m.bundle.files['compose.yaml'],
};
for (const [name, mutate] of Object.entries(mutations)) test(`rejects ${name}`, () => {
  const m = syntheticManifest(); mutate(m); assert.throws(() => validateManifest(m));
});
test('offline candidate checks pass only with a complete accepted trio', () => {
  const m = syntheticManifest(); m.synthetic = false;
  for (const image of Object.values(m.images)) {
    image.reference = image.reference.replace('synthetic.invalid', 'offline-candidate.invalid');
    for (const type of ['checks','scan']) { image[type].status = 'passed'; image[type].evidence = 'fixture-evidence.json'; }
  }
  assert.throws(() => validateManifest(m, {final:true}), /directory/);
  const root = mkdtempSync(join(tmpdir(), 'chico-manifest-test-'));
  try {
    for (const [name,p] of Object.entries(bundleSources)) copyFileSync(p,join(root,name));
    writeFileSync(join(root,'fixture-evidence.json'), '{"scope":"offline test fixture"}');
    const result = validateManifest(m, {final:true,root});
    assert.equal(result.candidateValidated, true);
    assert.equal(result.promotable, false);
    m.images.api.scan.status = 'synthetic';
    assert.throws(() => validateManifest(m, {final:true,root}));
  } finally { rmSync(root,{recursive:true,force:true}); }
});
test('frontend update preserves backend digests and detects incompatible schema', () => {
  const m = syntheticManifest(), image = structuredClone(m.images.frontend);
  image.sourceSha = '4'.repeat(40);
  const next = updateComponent(m,'frontend',image,image.sourceSha);
  assert.deepEqual(next.images.api,m.images.api); assert.deepEqual(next.images.workers,m.images.workers);
  assert.throws(() => validateManifest(next, {databaseHeads:['another_head']}), /schema compatibility/);
});
