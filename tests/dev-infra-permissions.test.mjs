import test from 'node:test';
import assert from 'node:assert/strict';
import { devInfraPolicies } from '../scripts/dev-infra-permissions.mjs';

export const inventory = {
  account: '123456789012', stateBucket: 'chico-tfstate-unit-test', reviewBucket: 'chico-infra-review-unit-test',
  backupBucket: 'chico-dev-unit-backup', amiId: 'ami-0123456789abcdef0',
  kmsKeyArns: ['arn:aws:kms:sa-east-1:123456789012:key/00000000-0000-0000-0000-000000000001'],
  vpcId: 'vpc-0123456789abcdef0', defaultSecurityGroupId: 'sg-0123456789abcdef0',
};
test('plan reads only Dev state and can write only its lock and review bundle', () => {
  const { plan } = devInfraPolicies(inventory);
  const mutations = plan.Statement.filter(s => s.Action.some(a => /:(Put|Delete|Create|Update)/.test(a)));
  assert.deepEqual(mutations.map(s => s.Sid), ['DevStateLock', 'UploadPrivatePlan']);
  assert.equal(plan.Statement.find(s => s.Sid === 'ReadDevState').Resource, 'arn:aws:s3:::chico-tfstate-unit-test/dev/terraform.tfstate');
  assert.ok(!JSON.stringify(plan).includes('GetSecretValue'));
});
test('apply cannot change its own policies or boundaries, and role writes require the fixed boundary', () => {
  const { apply, applyParts, runtimeBoundary, flowBoundary } = devInfraPolicies(inventory);
  const roleWrites = apply.Statement.filter(s => s.Action.includes('iam:PutRolePolicy'));
  assert.equal(roleWrites.length, 2);
  for (const s of roleWrites) {
    assert.match(s.Resource, /^arn:aws:iam::123456789012:role\/chico\/dev\/chico-dev-(runtime|flow-logs)$/);
    assert.match(s.Condition.StringEquals['iam:PermissionsBoundary'], /^arn:aws:iam::123456789012:policy\/chico\/shared\/chico-dev-(runtime|flow)-boundary$/);
  }
  const actions = apply.Statement.flatMap(s => s.Action);
  for (const forbidden of ['iam:CreatePolicy', 'iam:CreatePolicyVersion', 'iam:AttachRolePolicy', 'iam:DeleteRolePermissionsBoundary', 'iam:DeletePolicy', 'secretsmanager:GetSecretValue', 'ssm:SendCommand']) assert.ok(!actions.includes(forbidden), forbidden);
  for (const part of applyParts) assert.ok(JSON.stringify(part).length <= 6144);
  assert.deepEqual(applyParts.flatMap(p => p.Statement), apply.Statement);
  for (const boundary of [runtimeBoundary, flowBoundary]) assert.ok(!boundary.Statement.flatMap(s => s.Action).some(a => a.startsWith('iam:')));
  assert.ok(!JSON.stringify(runtimeBoundary).includes('tfstate'));
});
test('rejects missing ownership, foreign keys, wildcard inputs and legacy buckets', () => {
  for (const change of [
    { vpcId: undefined }, { defaultSecurityGroupId: undefined }, { account: '*' }, { amiId: 'ami-*' },
    { stateBucket: 'chico-backup' }, { reviewBucket: 'chico-backup' }, { backupBucket: 'chico-backup' },
    { kmsKeyArns: [] }, { kmsKeyArns: ['arn:aws:kms:sa-east-1:999999999999:key/00000000-0000-0000-0000-000000000001'] },
  ]) assert.throws(() => devInfraPolicies({ ...inventory, ...change }));
});
