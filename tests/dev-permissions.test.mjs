import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildPushPolicy, ssmDeployPolicy, devPassRolePolicy } from '../scripts/dev-permissions.mjs';
const account = '123456789012';
const repositoryArns = ['api', 'workers', 'frontend'].map(n => `arn:aws:ecr:sa-east-1:${account}:repository/chico-${n}`);
const instanceArn = `arn:aws:ec2:sa-east-1:${account}:instance/i-0123456789abcdef0`;
const documentArn = `arn:aws:ssm:sa-east-1:${account}:document/chico-dev-fixture-status`;
test('build can push only the three explicit repositories', () => {
  const policy = buildPushPolicy({ account, repositoryArns });
  assert.deepEqual(policy.Statement[1].Resource, repositoryArns);
  assert.ok(policy.Statement[1].Action.includes('ecr:PutImage'));
  for (const bad of ['*', repositoryArns[0].replace(account, '999999999999'), repositoryArns[0].replace('chico-api', 'foreign')]) assert.throws(() => buildPushPolicy({ account, repositoryArns: [bad, ...repositoryArns.slice(1)] }));
});
test('deployment permits only reviewed document and tagged instance; no arbitrary shell document', () => {
  const policy = ssmDeployPolicy({ account, instanceArn, documentArn });
  assert.equal(policy.Statement[1].Condition.StringEquals['ssm:resourceTag/env'], 'dev');
  for (const bad of ['arn:aws:ssm:sa-east-1::document/AWS-RunShellScript', documentArn.replace('dev', 'prod'), '*']) assert.throws(() => ssmDeployPolicy({ account, instanceArn, documentArn: bad }));
  assert.throws(() => ssmDeployPolicy({ account, instanceArn: instanceArn.replace(account, '999999999999'), documentArn }));
});
test('PassRole rejects Prod, wildcard, foreign account and multiple roles', () => {
  const role = `arn:aws:iam::${account}:role/chico/dev/chico-dev-runtime`;
  assert.equal(devPassRolePolicy({ account, roleArns: [role] }).Statement[0].Condition.StringEquals['iam:PassedToService'], 'ec2.amazonaws.com');
  for (const roles of [['*'], [role.replace('/dev/', '/prod/')], [role.replace(account, '999999999999')], [role, role]]) assert.throws(() => devPassRolePolicy({ account, roleArns: roles }));
});
