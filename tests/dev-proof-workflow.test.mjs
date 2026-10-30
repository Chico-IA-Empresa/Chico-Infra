import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { validateProofReview, proofTarget } from '../scripts/dev-proof-gates.mjs';
import { runStatusProof, verifyStatusOutput } from '../scripts/dev-proof-status.mjs';

const commit = 'a'.repeat(40);
const base = `docker.io/library/alpine@sha256:${'b'.repeat(64)}`;
function release(operation = 'build') {
  return {
    account_id: proofTarget.account, provision_enabled: true,
    credit_approval: { account_id: proofTarget.account, all_charges_covered: true, shutdown_reserve_confirmed: true, evidence_reference: 'synthetic-test-metadata-only', reviewed_on: '2026-10-29', expires_on: '2026-11-01' },
    proof: operation === 'build' ? { scope: 'synthetic-dev-infra', operation, source_commit: commit, base_image: base, base_platform: 'linux/arm64' } : {
      scope: 'synthetic-dev-infra', operation, source_commit: commit, instance_id: proofTarget.instance,
      document_name: proofTarget.document, document_version: proofTarget.version, document_sha256: proofTarget.documentHash, fixture_installed: true,
    },
  };
}
function check(value = release(), overrides = {}, rawOverride) {
  const raw = rawOverride ?? JSON.stringify(value);
  return validateProofReview(raw, {
    operation: value.proof?.operation ?? 'build', repository: proofTarget.repository, ref: 'refs/heads/main',
    eventName: 'workflow_dispatch', commit, roleArn: `arn:aws:iam::${proofTarget.account}:role/${value.proof?.operation === 'status' ? 'ci-deploy-dev' : 'ci-build-dev'}`,
    approved: 'true', validUntil: '2026-10-30T00:00:00Z', now: new Date('2026-10-29T22:00:00Z'),
    reviewHash: createHash('sha256').update(raw).digest('hex'), ...overrides,
  });
}

test('minimal private review reuses funding gates and returns only reviewed role/base', () => {
  assert.deepEqual(check(), { roleArn: 'arn:aws:iam::306915830875:role/ci-build-dev', fixtureBase: base });
  assert.deepEqual(check(release('status')), { roleArn: 'arn:aws:iam::306915830875:role/ci-deploy-dev' });
});
test('blocks wrong source, scope, event, ref, dedicated role and review bytes', () => {
  for (const context of [
    { operation: 'deploy' }, { repository: 'other/repo' }, { ref: 'refs/heads/topic' }, { eventName: 'pull_request' },
    { commit: 'c'.repeat(40) }, { roleArn: 'arn:aws:iam::306915830875:role/ci-infra-apply-dev' },
    { roleArn: 'arn:aws:iam::111122223333:role/ci-build-dev' }, { reviewHash: '0'.repeat(64) },
  ]) assert.throws(() => check(release(), context));
  for (const mutate of [r => { r.proof.scope = 'business'; }, r => { r.proof.source_commit = 'c'.repeat(40); }]) {
    const changed = release(); mutate(changed); assert.throws(() => check(changed));
  }
  assert.throws(() => check(release(), {}, '{malformed-private-review}'));
});
test('does not manufacture funding or reuse an expired release after manual wait', () => {
  for (const context of [{ approved: 'false' }, { validUntil: '' }, { validUntil: '2026-10-29T21:00:00Z' }, { now: new Date('2026-11-02T00:00:00Z') }]) assert.throws(() => check(release(), context));
  for (const mutate of [r => { r.provision_enabled = false; }, r => { r.credit_approval.all_charges_covered = false; }, r => { r.credit_approval.shutdown_reserve_confirmed = false; }, r => { r.credit_approval.evidence_reference = ''; }, r => { r.credit_approval.reviewed_on = '2026-10-30'; }]) {
    const changed = release(); mutate(changed); assert.throws(() => check(changed));
  }
});
test('rejects full tfvars, secret values and fields outside the metadata contract', () => {
  for (const mutate of [r => { r.backend = {}; }, r => { r.oidc_bindings = {}; }, r => { r.secret_value = 'synthetic'; }, r => { r.credit_approval.amount = 1; }, r => { r.proof.commands = ['whoami']; }]) {
    const changed = release(); mutate(changed); assert.throws(() => check(changed));
  }
});
test('requires pinned ARM64 base and installed local fixture with exact SSM pin', () => {
  for (const image of ['alpine:latest', base + '\n', 'alpine@sha256:no', '--privileged']) {
    const changed = release(); changed.proof.base_image = image; assert.throws(() => check(changed));
  }
  const amd = release(); amd.proof.base_platform = 'linux/amd64'; assert.throws(() => check(amd));
  for (const key of ['instance_id', 'document_name', 'document_version', 'document_sha256', 'fixture_installed']) {
    const changed = release('status'); changed.proof[key] = key === 'fixture_installed' ? false : 'wrong'; assert.throws(() => check(changed));
  }
});

const id = '12345678-1234-1234-1234-123456789abc';
const success = { Status: 'Success', ResponseCode: 0, StandardOutputContent: 'active\nactive\nstatic\npostgres\nproxy-local\n', StandardErrorContent: '' };
function fakeAws(sequence) {
  const calls = [];
  const aws = (service, operation, parameters) => {
    calls.push({ service, operation, parameters });
    if (service === 'sts') return { Account: proofTarget.account, Arn: 'arn:aws:sts::306915830875:assumed-role/ci-deploy-dev/test' };
    if (operation === 'send-command') return { Command: { CommandId: id } };
    const next = sequence.shift();
    if (next instanceof Error) throw next;
    return next;
  };
  return { aws, calls };
}
test('status pins one fixed document/instance and tolerates only eventual invocation absence', async () => {
  const absent = Object.assign(new Error('not yet visible'), { awsCode: 'InvocationDoesNotExist' });
  const fake = fakeAws([absent, { Status: 'Pending' }, { Status: 'InProgress' }, success]);
  const sleeps = [];
  const result = await runStatusProof({ aws: fake.aws, sleep: async ms => sleeps.push(ms), now: () => 0 });
  assert.deepEqual(result, { commandId: id, status: 'Success', responseCode: 0, localSyntheticServicesVerified: true });
  const send = fake.calls.find(c => c.operation === 'send-command').parameters;
  assert.deepEqual(send.InstanceIds, [proofTarget.instance]);
  assert.equal(send.DocumentName, proofTarget.document); assert.equal(send.DocumentVersion, '1');
  assert.equal(send.DocumentHash, proofTarget.documentHash); assert.equal(send.DocumentHashType, 'Sha256');
  assert.equal(send.Parameters, undefined); assert.equal(send.CloudWatchOutputConfig.CloudWatchOutputEnabled, true);
  assert.equal(sleeps.length, 3);
  assert.ok(fake.calls.filter(c => c.operation === 'get-command-invocation').every(c => c.parameters.CommandId === id && c.parameters.InstanceId === proofTarget.instance));
});
test('status rejects partial fixture, stderr, nonzero code and failed or unknown terminal states', async () => {
  for (const changed of [
    { ...success, StandardOutputContent: 'active\nactive\npostgres\n' },
    { ...success, StandardOutputContent: 'active\nactive\npostgres\nstatic\nproxy\n' },
    { ...success, StandardOutputContent: success.StandardOutputContent + 'business\n' },
    { ...success, StandardErrorContent: 'synthetic-warning' }, { ...success, ResponseCode: 1 },
  ]) assert.throws(() => verifyStatusOutput(changed));
  for (const Status of ['Failed', 'Cancelled', 'TimedOut', 'Cancelling', 'FutureState']) await assert.rejects(runStatusProof({ ...fakeAws([{ Status }]), sleep: async () => {}, now: () => 0 }));
  await assert.rejects(runStatusProof({ ...fakeAws([new Error('access denied')]), sleep: async () => {}, now: () => 0 }));
});
test('status requires dedicated role and bounds attempt count/deadline', async () => {
  const wrong = fakeAws([]);
  await assert.rejects(runStatusProof({ aws: (s, o, p) => s === 'sts' ? { Account: proofTarget.account, Arn: 'arn:aws:sts::306915830875:assumed-role/ci-infra-apply-dev/test' } : wrong.aws(s, o, p) }));
  assert.equal(wrong.calls.length, 0);
  const pending = fakeAws(Array.from({ length: 24 }, () => ({ Status: 'Delayed' })));
  await assert.rejects(runStatusProof({ ...pending, sleep: async () => {}, now: () => 0 }));
  assert.equal(pending.calls.filter(c => c.operation === 'get-command-invocation').length, 24);
  const deadline = fakeAws([{ Status: 'Pending' }]); let time = 0;
  await assert.rejects(runStatusProof({ ...deadline, sleep: async () => { time = 240_000; }, now: () => time }));
  assert.equal(deadline.calls.filter(c => c.operation === 'get-command-invocation').length, 1);
});
test('manual workflow keeps OIDC out of preflight and uses reviewed helpers without state inputs', () => {
  const workflow = readFileSync(new URL('../.github/workflows/dev-synthetic-proof.yml', import.meta.url), 'utf8');
  const preflight = workflow.slice(workflow.indexOf('  preflight:'), workflow.indexOf('  execute:'));
  assert.doesNotMatch(preflight, /id-token|configure-aws-credentials/);
  assert.doesNotMatch(workflow, /TF_VARS_JSON|BACKEND_CONFIG|APPLY_ROLE_ARN|PLAN_ROLE_ARN|terraform|upload-artifact/);
  assert.match(workflow, /environment: infra-apply-dev/); assert.match(workflow, /runs-on: ubuntu-24\.04-arm/);
  assert.ok(workflow.indexOf('id: release') < workflow.indexOf('uses: aws-actions/configure-aws-credentials'));
  assert.match(workflow, /role-to-assume: \$\{\{ steps\.release\.outputs\.role_arn \}\}/);
  assert.equal((workflow.match(/node scripts\/github-readiness\.mjs apply/g) ?? []).length, 2);
  assert.equal((workflow.match(/node scripts\/dev-proof-gates\.mjs/g) ?? []).length, 2);
  assert.match(workflow, /assumed-role\/ci-build-dev\/\*/);
  assert.match(workflow, /bash fixtures\/dev\/ecr-proof\.sh/);
  assert.match(workflow, /run: node scripts\/dev-proof-status\.mjs/);
});
