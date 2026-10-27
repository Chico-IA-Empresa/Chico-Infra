import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deploymentPolicy, executionPolicy, retentionCandidates, promotionAllowed } from '../scripts/policies.mjs';
const inventory = { clusterArn: 'arn:aws:ecs:sa-east-1:123456789012:cluster/chico-uat', serviceArns: ['arn:aws:ecs:sa-east-1:123456789012:service/chico-uat/api'], taskDefinitionArns: ['arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-api:2'], executionRoleArns: ['arn:aws:iam::123456789012:role/chico/uat/api-execution'], taskRoleArns: ['arn:aws:iam::123456789012:role/chico/uat/api'] };
test('deploy policy scopes PassRole and RunTask to reviewed inventory', () => {
  const policy = deploymentPolicy(inventory);
  assert.deepEqual(policy.Statement.at(-1).Resource, [...inventory.executionRoleArns, ...inventory.taskRoleArns]);
  assert.equal(policy.Statement[1].Condition.ArnEquals['ecs:cluster'], inventory.clusterArn);
});
test('reject production roles/services, wildcards, foreign account and unversioned task family', () => {
  assert.throws(() => deploymentPolicy({ ...inventory, taskRoleArns: [inventory.taskRoleArns[0].replace('/uat/', '/prod/')] }));
  assert.throws(() => deploymentPolicy({ ...inventory, serviceArns: [inventory.serviceArns[0].replace('chico-uat', 'chico-prod')] }));
  assert.throws(() => deploymentPolicy({ ...inventory, taskDefinitionArns: ['*'] }));
  assert.throws(() => deploymentPolicy({ ...inventory, taskDefinitionArns: [inventory.taskDefinitionArns[0].replace(':2', '')] }));
  assert.throws(() => deploymentPolicy({ ...inventory, executionRoleArns: [inventory.executionRoleArns[0].replace('123456789012', '999999999999')] }));
});
test('keeps oldest deployed digest beyond 30 newest SHA builds', () => {
  const images = Array.from({ length: 35 }, (_, n) => ({ digest: `sha256:${n.toString(16).padStart(64, '0')}`, pushedAt: new Date(Date.UTC(2026, 8, n + 1)).toISOString(), tags: [n.toString(16).padStart(40, '0')] }));
  const candidates = retentionCandidates(images, [images[0].digest], 30, { inventoryComplete: true });
  assert.equal(candidates.length, 4);
  assert.ok(!candidates.some(i => i.digest === images[0].digest));
  assert.throws(() => retentionCandidates(images, []));
  assert.throws(() => retentionCandidates(images, [images[0].digest]), /Complete/);
  const graph = { [images[0].digest]: [images[1].digest] };
  const protectedChildren = retentionCandidates(images, [images[0].digest], 30, { inventoryComplete: true, manifestChildren: graph });
  assert.equal(protectedChildren.length, 3);
  assert.ok(!protectedChildren.some(i => i.digest === images[1].digest));
});
test('unknown or critical scan results block promotion', () => {
  for (const scan of [{}, { status: 'IN_PROGRESS', critical: 0 }, { status: 'COMPLETE' }, { status: 'COMPLETE', critical: 1 }]) assert.equal(promotionAllowed(scan), false);
  assert.equal(promotionAllowed({ status: 'COMPLETE', critical: 0 }), true);
});
test('execution decrypt is scoped to reviewed service keys; foreign secrets or missing CMK rejected', () => {
  const input = { repositoryArns: ['arn:aws:ecr:sa-east-1:123456789012:repository/chico-api'], secretArns: ['arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/api/SECRET-test'], parameterArns: [], logGroupArn: 'arn:aws:logs:sa-east-1:123456789012:log-group:/chico/uat/api', kmsKeyArns: ['arn:aws:kms:sa-east-1:123456789012:key/test'] };
  const statement = executionPolicy(input).Statement.at(-1);
  assert.deepEqual(statement.Resource, input.kmsKeyArns);
  assert.ok(statement.Condition.StringEquals['kms:ViaService'].includes('secretsmanager.sa-east-1.amazonaws.com'));
  assert.throws(() => executionPolicy({ ...input, kmsKeyArns: [] }));
  assert.throws(() => executionPolicy({ ...input, secretArns: [input.secretArns[0].replace('/uat/', '/prod/')] }));
  assert.throws(() => deploymentPolicy({ ...inventory, clusterArn: inventory.clusterArn.replace('sa-east-1', 'us-east-1') }));
});
