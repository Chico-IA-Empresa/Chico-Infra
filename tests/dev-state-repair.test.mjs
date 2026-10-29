import test from 'node:test';
import assert from 'node:assert/strict';
import { validateRepairManifest, validateRepairStart, verifyRepairProgress, createExclusiveWindow, validateExclusiveWindow, runReviewedRepairStep, verifyRepairPostStep, exclusiveAttestation } from '../scripts/dev-state-repair.mjs';
import { fixture, repairNow, sha } from './helpers/state-repair-fixture.mjs';

function context() {
  const value = fixture();
  const manifestBytes = Buffer.from(JSON.stringify(value.manifest));
  return { ...value, manifestBytes, approvedHash: sha(manifestBytes), download: { VersionId: 'synthetic-version' }, commit: value.manifest.commit, now: repairNow };
}
function advance(state, count) {
  const result = structuredClone(state);
  result.serial += count;
  for (let i = 0; i < count; i++) delete result.resources[i].instances[0].status;
  return result;
}
test('exact reviewed six-resource repair preserves all IDs and content', () => {
  const c = context();
  assert.equal(validateRepairStart(c).length, 6);
  for (let i = 1; i <= 6; i++) assert.equal(verifyRepairProgress(c.manifest, c.state, advance(c.state, i), i, repairNow).infrastructureMutations, false);
});
test('changed state version, bytes, backend, inputs or commit block before a repair', () => {
  for (const change of [{ download: { VersionId: 'other' } }, { stateBytes: Buffer.from('{}') }, { backend: Buffer.from('other') }, { inputs: Buffer.from('{}') }, { commit: 'b'.repeat(40) }, { approvedHash: '0'.repeat(64) }]) assert.throws(() => validateRepairStart({ ...context(), ...change }));
});
test('arbitrary resource addresses, duplicate IDs, other buckets and expired manifests are rejected', () => {
  for (const change of [m => { m.resources[0].address = 'aws_iam_role.other'; }, m => { m.resources[0].id = 'chico-backup'; }, m => { m.resources[1].address = m.resources[0].address; }, m => { m.expiresAt = m.createdAt; }, m => { m.scope = 'all-roots'; }]) {
    const { manifest } = fixture(); change(manifest); assert.throws(() => validateRepairManifest(manifest, repairNow));
  }
});
test('repair cannot hide an ID, output, attribute or unexpected serial change', () => {
  for (const change of [s => { s.serial++; }, s => { s.resources[0].instances[0].attributes.id = 'foreign'; }, s => { s.outputs.guard.value = 'changed'; }, s => { s.resources[1].instances[0].attributes.extra = 'changed'; }, s => { delete s.resources[1].instances[0].status; }]) {
    const { manifest, state } = fixture(), changed = advance(state, 1); change(changed);
    assert.throws(() => verifyRepairProgress(manifest, state, changed, 1, repairNow));
  }
});
test('Terraform may reorder check groups and their objects without changing their meaning', () => {
  const { manifest, state } = fixture();
  state.check_results = [
    { object_kind: 'var', config_addr: 'module.dev_box.var.provision_enabled', status: 'pass', objects: [
      { object_addr: 'module.dev_box[1].var.provision_enabled', status: 'pass' },
      { object_addr: 'module.dev_box[0].var.provision_enabled', status: 'pass' },
    ] },
    { object_kind: 'var', config_addr: 'var.account', status: 'pass', objects: [{ object_addr: 'var.account', status: 'pass' }] },
  ];
  const current = advance(state, 1);
  current.check_results[0].objects.reverse();
  current.check_results.reverse();
  assert.equal(verifyRepairProgress(manifest, state, current, 1, repairNow).resourceIdsPreserved, true);
});
test('check normalization still rejects changed status, address, content, missing and duplicate objects', () => {
  for (const change of [
    s => { s.check_results[0].status = 'fail'; },
    s => { s.check_results[0].config_addr = 'var.other'; },
    s => { s.check_results[0].objects[0].status = 'fail'; },
    s => { s.check_results[0].objects[0].object_addr = 'var.other'; },
    s => { s.check_results[0].objects[0].failure_messages = ['changed']; },
    s => { s.check_results[0].objects.pop(); },
    s => { s.check_results[0].objects.push(structuredClone(s.check_results[0].objects[0])); },
    s => { s.check_results = null; },
  ]) {
    const { manifest, state } = fixture();
    state.check_results = [{ object_kind: 'var', config_addr: 'var.account', status: 'pass', objects: [{ object_addr: 'var.account', status: 'pass' }] }];
    const current = advance(state, 1);
    change(current);
    assert.throws(() => verifyRepairProgress(manifest, state, current, 1, repairNow), /State changed beyond/);
  }
});
test('check normalization does not reorder arbitrary content arrays or mutate its inputs', () => {
  const { manifest, state } = fixture();
  state.check_results[0].objects[0].failure_messages = ['first', 'second'];
  const current = advance(state, 1), beforeBytes = JSON.stringify(state), currentBytes = JSON.stringify(current);
  verifyRepairProgress(manifest, state, current, 1, repairNow);
  assert.equal(JSON.stringify(state), beforeBytes);
  assert.equal(JSON.stringify(current), currentBytes);
  current.check_results[0].objects[0].failure_messages.reverse();
  assert.throws(() => verifyRepairProgress(manifest, state, current, 1, repairNow), /State changed beyond/);
});
function exclusiveContext() {
  const c = context();
  c.backend = Buffer.from('bucket = "chico-tfstate-306915830875-sa-east-1"\nkey = "dev/terraform.tfstate"\nregion = "sa-east-1"\nencrypt = true\nuse_lockfile = true\nallowed_account_ids = ["306915830875"]\n');
  c.manifest.hashes.backend = sha(c.backend);
  c.manifestBytes = Buffer.from(JSON.stringify(c.manifest));
  c.approvedHash = sha(c.manifestBytes);
  c.identity = { account: '306915830875', repository: 'Chico-IA-Empresa/Chico-Infra', commit: c.manifest.commit, actor: 'FelipeTorresHora', runId: '12345', runAttempt: '1', workflowRef: 'Chico-IA-Empresa/Chico-Infra/.github/workflows/dev-state-repair.yml@refs/heads/main' };
  c.authorizedActors = ['FelipeTorresHora'];
  c.receipt = createExclusiveWindow({ ...c, attestation: exclusiveAttestation, startsAt: repairNow.toISOString(), expiresAt: new Date(repairNow.getTime() + 30 * 60_000).toISOString() });
  c.beforeBytes = c.stateBytes;
  c.expectedBytes = c.stateBytes;
  c.currentBytes = c.stateBytes;
  c.expectedDownload = c.download;
  c.currentDownload = c.download;
  c.completed = 0;
  return c;
}
test('exclusive human declaration is mandatory, UTC bounded to thirty minutes and scoped to its executor', () => {
  const c = exclusiveContext();
  assert.equal(validateExclusiveWindow(c.receipt, c).identity.runId, '12345');
  for (const change of [
    { attestation: undefined }, { attestation: 'yes' }, { startsAt: '2026-10-28T12:00:00' },
    { startsAt: '2026-10-28T12:00:01Z' }, { expiresAt: '2026-10-28T12:00:00Z' },
    { expiresAt: '2026-10-28T12:30:01Z' }, { authorizedActors: [] },
    { identity: { ...c.identity, actor: 'unauthorized' } },
    { identity: { ...c.identity, account: '999999999999' } },
    { identity: { ...c.identity, workflowRef: c.identity.workflowRef.replace('main', 'other') } },
  ]) assert.throws(() => createExclusiveWindow({ ...c, attestation: exclusiveAttestation, startsAt: repairNow.toISOString(), expiresAt: c.receipt.expiresAt, ...change }));
  for (const field of ['runId', 'runAttempt', 'actor', 'commit', 'repository', 'account', 'workflowRef']) {
    assert.throws(() => validateExclusiveWindow(c.receipt, { ...c, identity: { ...c.identity, [field]: field === 'runId' ? '54321' : 'changed' } }));
  }
  for (const change of [
    r => { r.backend.key = 'shared/terraform.tfstate'; }, r => { r.backend.bucket = 'other'; },
    r => { r.manifestSha256 = '0'.repeat(64); }, r => { r.backendSha256 = '0'.repeat(64); },
    r => { r.identity.runAttempt = '2'; }, r => { r.expiresAt = '2026-10-28T12:31:00Z'; },
  ]) {
    const receipt = structuredClone(c.receipt); change(receipt);
    assert.throws(() => validateExclusiveWindow(receipt, c));
  }
});
test('a changed snapshot, version or expired window prevents invoking the state writer', () => {
  for (const change of [
    { currentBytes: Buffer.from('{}') }, { currentDownload: { VersionId: 'concurrent-writer-version' } },
    { currentDownload: { VersionId: 'null' } }, { expectedDownload: {} },
    { completed: 6 }, { now: new Date('2026-10-28T12:30:00Z') },
    { approvedHash: '0'.repeat(64) }, { inputs: Buffer.from('{}') },
    { backend: Buffer.from('foreign') }, { beforeBytes: Buffer.from('{}') },
  ]) {
    const c = { ...exclusiveContext(), ...change };
    let writes = 0;
    assert.throws(() => runReviewedRepairStep(c, () => { writes++; }));
    assert.equal(writes, 0);
  }
});
test('every step is rebound to the exact prior version and verifies progression before writing', () => {
  const c = exclusiveContext();
  let writes = 0;
  for (let completed = 0; completed < 6; completed++) {
    const bytes = completed === 0 ? c.beforeBytes : Buffer.from(JSON.stringify(advance(c.state, completed)));
    const download = { VersionId: completed === 0 ? 'synthetic-version' : `synthetic-version-${completed}` };
    const step = { ...c, completed, expectedBytes: bytes, currentBytes: bytes, expectedDownload: download, currentDownload: download };
    const result = runReviewedRepairStep(step, address => { assert.equal(address, c.manifest.resources[completed].address); writes++; });
    assert.equal(result.postVerificationRequired, true);
    const raced = JSON.parse(bytes); raced.serial++;
    assert.throws(() => runReviewedRepairStep({ ...step, currentBytes: Buffer.from(JSON.stringify(raced)) }, () => { writes++; }));
    assert.equal(writes, completed + 1);
    // Even an accidentally replaced expected snapshot cannot authorize a
    // different serial/progression once bytes and VersionIds match again.
    const racedBytes = Buffer.from(JSON.stringify(raced));
    assert.throws(() => runReviewedRepairStep({ ...step, expectedBytes: racedBytes, currentBytes: racedBytes }, () => { writes++; }));
    assert.equal(writes, completed + 1);
  }
  assert.equal(writes, 6);
});
test('post-step evidence contains metadata only and rejects unchanged versions or semantic changes', () => {
  const c = exclusiveContext(), currentBytes = Buffer.from(JSON.stringify(advance(c.state, 1)));
  const post = { ...c, completed: 1, currentBytes, currentDownload: { VersionId: 'synthetic-version-1' }, priorDownload: c.download };
  const evidence = verifyRepairPostStep(post);
  assert.equal(evidence.serial, 5);
  assert.equal(evidence.stateSha256, sha(currentBytes));
  assert.equal(evidence.atomicPrecondition, false);
  assert.ok(!JSON.stringify(evidence).includes('synthetic-preserve'));
  assert.throws(() => verifyRepairPostStep({ ...post, currentDownload: c.download }));
  const changed = JSON.parse(currentBytes); changed.outputs.guard.value = 'changed';
  assert.throws(() => verifyRepairPostStep({ ...post, currentBytes: Buffer.from(JSON.stringify(changed)) }));
});
