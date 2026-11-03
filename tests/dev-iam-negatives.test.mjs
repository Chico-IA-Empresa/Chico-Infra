import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { validateNegativeReview, probeSetHash, fixedProbes, classifyProbe, parseAwsFailure, runReadNegatives, verifyIdentity } from '../scripts/dev-iam-negatives.mjs';

const now = new Date('2026-11-03T16:30:00.000Z');
const review = () => ({ account_id: '306915830875', provision_enabled: true, credit_approval: {
  account_id: '306915830875', all_charges_covered: true, shutdown_reserve_confirmed: true,
  evidence_reference: 'TEST-ONLY-not-release', reviewed_on: '2026-11-03', expires_on: '2026-11-04',
}, proof: { scope: 'synthetic-dev-infra', operation: 'iam-read-negatives', role: 'build', source_commit: 'a'.repeat(40),
  probe_set_sha256: probeSetHash, inventory_reference: 'TEST-ONLY-inventory', inventory_checked_at_utc: '2026-11-03T16:00:00.000Z' } });
const context = () => ({ role: 'build', commit: 'a'.repeat(40), roleArn: 'arn:aws:iam::306915830875:role/ci-build-dev',
  repository: 'Chico-IA-Empresa/Chico-Infra', ref: 'refs/heads/main', eventName: 'workflow_dispatch', approved: 'true',
  validUntil: '2026-11-03T20:00:00Z', now });
function check(value, ctx = context()) { const raw = JSON.stringify(value); return validateNegativeReview(raw, { reviewHash: createHash('sha256').update(raw).digest('hex'), ...ctx }); }
const identity = role => ({ success: true, value: { Account: '306915830875', Arn: `arn:aws:sts::306915830875:assumed-role/${role === 'build' ? 'ci-build-dev' : 'ci-deploy-dev'}/test-session` } });

test('both explicit dedicated roles pass with source funding inventory and exact bytes', () => {
  assert.equal(check(review()).role, 'build');
  const value = review(); value.proof.role = 'status';
  assert.equal(check(value, { ...context(), role: 'status', roleArn: 'arn:aws:iam::306915830875:role/ci-deploy-dev' }).role, 'status');
});
test('context allowlist and role cannot silently fall through to status', () => {
  for (const delta of [{ role: 'runtime' }, { role: '__proto__' }, { role: 'negative-build' }, { roleArn: 'arn:aws:iam::306915830875:role/ci-deploy-dev' },
    { ref: 'refs/heads/test' }, { repository: 'other/repo' }, { eventName: 'push' }, { commit: 'b'.repeat(40) }, { approved: 'false' }]) assert.throws(() => check(review(), { ...context(), ...delta }));
});
test('real release cannot use test fixture assumptions or extra payload fields', () => {
  for (const mutate of [v => v.proof.probe_set_sha256 = 'b'.repeat(64), v => v.proof.instance_id = 'fake',
    v => v.proof.operation = 'status', v => v.proof.fixture_installed = true, v => v.credit_approval.amount = 0,
    v => v.backend = {}, v => v.proof.inventory_reference = '', v => delete v.credit_approval.evidence_reference]) {
    const value = review(); mutate(value); assert.throws(() => check(value));
  }
});
test('stale future invalid inventory and expired funding reject after manual wait', () => {
  for (const stamp of ['2026-11-03T08:30:00.000Z', '2026-11-03T16:31:00.000Z', 'bad', '2026-11-03']) {
    const value = review(); value.proof.inventory_checked_at_utc = stamp; assert.throws(() => check(value));
  }
  assert.throws(() => check(review(), { ...context(), now: new Date('2026-11-03T20:00:00Z') }));
});
test('hash binds exact JSON bytes, never accepts malformed or differently hashed review', () => {
  const raw = JSON.stringify(review());
  assert.throws(() => validateNegativeReview(raw + '\n', { ...context(), reviewHash: createHash('sha256').update(raw).digest('hex') }));
  assert.throws(() => validateNegativeReview('{', { ...context(), reviewHash: createHash('sha256').update('{').digest('hex') }));
});
test('classifier accepts only authorization codes and exact HEAD403 context', () => {
  for (const code of ['AccessDenied', 'AccessDeniedException']) assert.equal(classifyProbe({ success: false, code }), 'authorization-denied');
  for (const code of ['NotFound', '404', 'NoSuchKey', 'InvalidParameter', 'ResourceNotFoundException', 'DryRunOperation', 'Forbidden', undefined]) assert.equal(classifyProbe({ success: false, code }), 'inconclusive');
  assert.equal(classifyProbe({ success: true, code: 'AccessDenied' }), 'unexpected-allow');
  assert.equal(classifyProbe({ success: false, code: '403', headForbidden: true }, { service: 's3api', operation: 'head-object' }), 'authorization-denied');
  assert.equal(classifyProbe({ success: false, code: '403', headForbidden: true }, { service: 's3api', operation: 'get-object' }), 'inconclusive');
});
test('SDK max-attempts1 HEAD403 decoration is recognized, generic403 and wrong operations stay inconclusive', () => {
  const probe = fixedProbes()[0];
  for (const suffix of ['', ' (reached max retries: 0)']) {
    const parsed = parseAwsFailure(`An error occurred (403) when calling the HeadObject operation${suffix}: Forbidden\n`, 'head-object');
    assert.equal(classifyProbe(parsed, probe), 'authorization-denied');
  }
  for (const text of ['403 Forbidden',
    'An error occurred (403) when calling the HeadObject operation (reached max retries: 0): Network Error',
    'An error occurred (404) when calling the HeadObject operation (reached max retries: 0): Forbidden',
    'An error occurred (403) when calling the GetObject operation (reached max retries: 0): Forbidden',
    'An error occurred (403) when calling the HeadObject operation (reached max retries: 1): Forbidden',
    'An error occurred (403) when calling the HeadObject operation: Forbidden private-extra']) {
    assert.equal(classifyProbe(parseAwsFailure(text, 'head-object'), probe), 'inconclusive');
  }
  const exact = 'An error occurred (403) when calling the HeadObject operation (reached max retries: 0): Forbidden';
  assert.equal(classifyProbe(parseAwsFailure(exact, 'get-object'), probe), 'inconclusive');
});
test('all probes are fixed existing-resource metadata calls; pin objects and ownership', () => {
  const list = fixedProbes(); assert.equal(list.length, 7);
  assert.equal(createHash('sha256').update(JSON.stringify(list)).digest('hex'), probeSetHash);
  for (const p of list) {
    assert.equal(p.region, 'sa-east-1');
    assert.ok(['head-object', 'list-objects-v2', 'describe-key', 'describe-secret', 'describe-log-streams'].includes(p.operation));
    if (p.service === 's3api') assert.equal(p.input.ExpectedBucketOwner, '306915830875');
    assert.ok(!/get-secret-value|put-|delete-|send-command|pass-role|initiate-layer/i.test(JSON.stringify(p)));
  }
  assert.ok(list.find(p => p.id === 'state-version-head').input.VersionId);
  assert.ok(list.find(p => p.id === 'review-version-head').input.VersionId);
  list[0].operation = 'delete-object'; assert.equal(fixedProbes()[0].operation, 'head-object');
});
test('unexpected allow or ambiguous error aborts immediately without later probes', () => {
  for (const response of [{ success: true, value: { SecretString: 'SENTINEL' } }, { success: false, code: '404' }]) {
    let calls = 0;
    assert.throws(() => runReadNegatives({ role: 'build', aws: () => ++calls === 1 ? identity('build') : response }), error => !error.message.includes('SENTINEL'));
    assert.equal(calls, 2);
  }
});
test('valid run proves exact role and denies each fixed request', () => {
  const called = [];
  const result = runReadNegatives({ role: 'status', aws: (s, o, i, r) => {
    called.push([s, o, i, r]); return called.length === 1 ? identity('status') : { success: false, code: 'AccessDenied' };
  } });
  assert.equal(result.probes, 7); assert.equal(called.length, 8);
  assert.deepEqual(called.slice(1), fixedProbes().map(p => [p.service, p.operation, p.input, p.region]));
  for (const value of [{ Account: '000000000000', Arn: identity('build').value.Arn }, identity('status').value,
    { Account: '306915830875', Arn: 'arn:aws:iam::306915830875:root' }]) assert.throws(() => verifyIdentity(value, 'build'));
});
test('workflow puts governance and funding gates on both sides of manual Environment, before OIDC', () => {
  const yaml = readFileSync(new URL('../.github/workflows/dev-iam-read-negatives.yml', import.meta.url), 'utf8');
  assert.equal((yaml.match(/node scripts\/github-readiness\.mjs apply/g) ?? []).length, 2);
  assert.equal((yaml.match(/node scripts\/dev-iam-negatives\.mjs gate/g) ?? []).length, 2);
  assert.equal((yaml.match(/if: github.ref == 'refs\/heads\/main'/g) ?? []).length, 2);
  assert.ok(yaml.indexOf('environment: infra-apply-dev') < yaml.indexOf('configure-aws-credentials@'));
  assert.ok(yaml.lastIndexOf('dev-iam-negatives.mjs gate') < yaml.indexOf('configure-aws-credentials@'));
  assert.ok(!/TF_VARS_JSON|BACKEND|upload-artifact|GetSecretValue|workflow_call|pull_request_target/.test(yaml));
});
test('runtime subset excludes its own legitimate config metadata allows', () => {
  const python = readFileSync(new URL('../fixtures/dev/runtime-iam-read-negatives.py', import.meta.url), 'utf8');
  const encoded = python.match(/PROBES = json\.loads\(r'''([\s\S]*?)'''\)/)?.[1];
  assert.ok(encoded);
  assert.deepEqual(JSON.parse(encoded), fixedProbes().filter(p => !['key-metadata', 'secret-metadata'].includes(p.id)));
});
test('expiry recheck can stop next probe without contacting AWS again', () => {
  let calls = 0, rechecks = 0;
  assert.throws(() => runReadNegatives({ role: 'build', aws: () => ++calls === 1 ? identity('build') : { success: false, code: 'AccessDenied' },
    beforeEach: () => { if (++rechecks === 2) throw new Error('Expired'); } }));
  assert.equal(calls, 2);
});
