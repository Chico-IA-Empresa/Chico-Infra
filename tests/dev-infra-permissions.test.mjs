import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { devInfraPolicies } from '../scripts/dev-infra-permissions.mjs';

export const inventory = {
  account: '123456789012', stateBucket: 'chico-tfstate-unit-test', reviewBucket: 'chico-infra-review-unit-test',
  backupBucket: 'chico-dev-unit-backup', accessLogBucket: 'chico-dev-access-unit-test', amiId: 'ami-0123456789abcdef0',
  kmsKeyArns: ['arn:aws:kms:sa-east-1:123456789012:key/00000000-0000-0000-0000-000000000001'],
  secretsKeyArn: 'arn:aws:kms:sa-east-1:123456789012:key/00000000-0000-0000-0000-000000000001',
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
    { stateBucket: 'chico-backup' }, { reviewBucket: 'chico-backup' }, { backupBucket: 'chico-backup' }, { accessLogBucket: 'chico-backup' }, { accessLogBucket: undefined },
    { kmsKeyArns: [] }, { kmsKeyArns: ['arn:aws:kms:sa-east-1:999999999999:key/00000000-0000-0000-0000-000000000001'] },
    { secretsKeyArn: undefined }, { secretsKeyArn: 'arn:aws:kms:sa-east-1:123456789012:key/00000000-0000-0000-0000-000000000002' },
  ]) assert.throws(() => devInfraPolicies({ ...inventory, ...change }));
});
test('runtime backs up only Dev database/fixtures and never reads the legacy source or log objects', () => {
  const { runtimeBoundary, apply } = devInfraPolicies(inventory);
  const objects = runtimeBoundary.Statement.find(s => s.Sid === 'DevBackupObjects');
  assert.deepEqual(objects.Resource, ['arn:aws:s3:::chico-dev-unit-backup/dev/fixtures/*', 'arn:aws:s3:::chico-dev-unit-backup/dev/database/*']);
  assert.ok(!objects.Action.includes('s3:DeleteObject'));
  assert.ok(!JSON.stringify(runtimeBoundary).includes('chico-backup'));
  assert.ok(!JSON.stringify(runtimeBoundary).includes('chico-dev-access'));
  assert.deepEqual(apply.Statement.find(s => s.Sid === 'ManageBackupConfiguration').Resource, ['arn:aws:s3:::chico-dev-unit-backup','arn:aws:s3:::chico-dev-access-unit-test']);
});
test('rejects credential fields, duplicate keys and policies exceeding AWS quotas', () => {
  assert.throws(() => devInfraPolicies({ ...inventory, accessKey: 'synthetic-forbidden-field' }), /metadata/);
  assert.throws(() => devInfraPolicies({ ...inventory, kmsKeyArns: [...inventory.kmsKeyArns, ...inventory.kmsKeyArns] }), /Duplicate/);
  const keys = Array.from({ length: 40 }, (_, n) => `arn:aws:kms:sa-east-1:123456789012:key/00000000-0000-0000-0000-${String(n).padStart(12, '0')}`);
  assert.throws(() => devInfraPolicies({ ...inventory, kmsKeyArns: keys }), /quota/);
});
test('four distinct foundation keys fit managed-policy quotas', () => {
  const kmsKeyArns = Array.from({length:4}, (_, n) => `arn:aws:kms:sa-east-1:123456789012:key/00000000-0000-0000-0000-${String(n + 1).padStart(12,'0')}`);
  const policies = devInfraPolicies({...inventory, kmsKeyArns});
  for (const policy of [policies.plan, policies.runtimeBoundary, policies.flowBoundary, ...policies.applyParts]) assert.ok(JSON.stringify(policy).length <= 6144);
});

test('HeadBucket metadata access is bounded to the two owned buckets without granting object reads', () => {
  const policies = devInfraPolicies(inventory);
  for (const policy of [policies.plan, policies.apply]) {
    const head = policy.Statement.find(s => s.Sid === 'DevBucketExistenceMetadata');
    assert.deepEqual(head.Action, ['s3:ListBucket']);
    assert.deepEqual(head.Resource, ['arn:aws:s3:::chico-dev-unit-backup', 'arn:aws:s3:::chico-dev-access-unit-test']);
    assert.deepEqual(head.Condition, { StringEquals: { 'aws:RequestedRegion': 'sa-east-1' } });
  }
  const tag = policies.apply.Statement.find(s => s.Sid === 'TagDevBucketsAtCreation');
  assert.deepEqual(tag.Action, ['s3:TagResource']);
  assert.deepEqual(tag.Resource, policies.apply.Statement.find(s => s.Sid === 'DevBucketExistenceMetadata').Resource);
  assert.equal(tag.Condition.StringEquals['aws:RequestTag/env'], 'dev');
  assert.equal(tag.Condition.StringEquals['aws:RequestTag/project'], 'chicoai');
});

test('CI KMS grant permits validation only, not actual secret versions, other keys or direct KMS', () => {
  const policies = devInfraPolicies(inventory);
  const validation = policies.apply.Statement.find(s => s.Sid === 'ValidateDevSecretKeyMetadata');
  assert.deepEqual(validation.Action, ['kms:GenerateDataKey', 'kms:Decrypt']);
  assert.equal(validation.Resource, inventory.secretsKeyArn);
  assert.deepEqual(validation.Condition.StringEquals, {
    'aws:RequestedRegion': 'sa-east-1', 'kms:CallerAccount': inventory.account,
    'kms:ViaService': 'secretsmanager.sa-east-1.amazonaws.com',
    'kms:EncryptionContext:SecretVersionId': 'RequestToValidateKeyAccess',
  });
  assert.deepEqual(validation.Condition.StringLike['kms:EncryptionContext:SecretARN'], [
    'arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/dev/api/SYNTHETIC_TOKEN-??????',
    'arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/dev/api/DEV_DATABASE_CREDENTIALS-??????',
  ]);
  const planActions = policies.plan.Statement.flatMap(s => s.Action);
  assert.ok(!planActions.includes('kms:GenerateDataKey'));
  assert.ok(!planActions.includes('kms:Decrypt'));
  assert.ok(!policies.apply.Statement.flatMap(s => s.Action).includes('secretsmanager:GetSecretValue'));
});

test('provider post-create reads are metadata only and keep document/value scope bounded', () => {
  for (const policy of [devInfraPolicies(inventory).plan, devInfraPolicies(inventory).apply]) {
    assert.ok(policy.Statement.find(s => s.Sid === 'Ec2Metadata').Action.includes('ec2:DescribeAddressesAttribute'));
    const parameters = policy.Statement.find(s => s.Sid === 'ParameterMetadataDiscovery');
    assert.deepEqual(parameters.Action, ['ssm:DescribeParameters']);
    assert.equal(parameters.Resource, '*');
    assert.deepEqual(parameters.Condition, { StringEquals: { 'aws:RequestedRegion': 'sa-east-1' } });
    const documents = policy.Statement.find(s => s.Sid === 'DevDocuments');
    assert.ok(documents.Action.includes('ssm:DescribeDocumentPermission'));
    assert.equal(documents.Resource, 'arn:aws:ssm:sa-east-1:123456789012:document/chico-dev-*');
    assert.equal(policy.Statement.find(s => s.Sid === 'NonSecretParameters').Resource, 'arn:aws:ssm:sa-east-1:123456789012:parameter/chico/dev/*');
    assert.ok(!policy.Statement.flatMap(s => s.Action).includes('ssm:GetParametersByPath'));
  }
  const power = devInfraPolicies(inventory).apply.Statement.find(s => s.Sid === 'MaintainDevHostPower');
  assert.deepEqual(power.Action, ['ec2:StopInstances', 'ec2:StartInstances']);
  assert.equal(power.Resource, 'arn:aws:ec2:sa-east-1:123456789012:instance/*');
  assert.equal(power.Condition.StringEquals['aws:ResourceTag/project'], 'chicoai');
  assert.equal(power.Condition.StringEquals['aws:ResourceTag/env'], 'dev');
});

test('S3 bucket refresh covers the complete pinned provider metadata path on both exact Dev buckets', () => {
  // resourceBucketRead calls these even when CORS/website/acceleration/replication
  // are absent. AccessDenied is not the same as an absent configuration.
  const required = [
    's3:GetBucketPolicy', 's3:GetBucketAcl', 's3:GetBucketCORS', 's3:GetBucketWebsite',
    's3:GetBucketVersioning', 's3:GetAccelerateConfiguration', 's3:GetBucketRequestPayment',
    's3:GetBucketLogging', 's3:GetLifecycleConfiguration', 's3:GetReplicationConfiguration',
    's3:GetEncryptionConfiguration', 's3:GetBucketObjectLockConfiguration',
  ];
  for (const policy of [devInfraPolicies(inventory).plan, devInfraPolicies(inventory).apply]) {
    const metadata = policy.Statement.find(s => s.Sid === 'BackupConfiguration');
    for (const action of required) assert.ok(metadata.Action.includes(action), action);
    assert.deepEqual(metadata.Resource, [
      'arn:aws:s3:::chico-dev-unit-backup', 'arn:aws:s3:::chico-dev-access-unit-test',
    ]);
    assert.ok(metadata.Action.every(action => action.startsWith('s3:Get')));
    for (const action of ['s3:GetBucketCORS', 's3:GetBucketWebsite', 's3:GetAccelerateConfiguration', 's3:GetReplicationConfiguration']) {
      const grants = policy.Statement.filter(s => s.Action.includes(action));
      assert.equal(grants.length, 1);
      assert.equal(grants[0].Sid, 'BackupConfiguration');
    }
    for (const action of ['s3:PutBucketCORS', 's3:PutBucketWebsite', 's3:PutAccelerateConfiguration', 's3:PutReplicationConfiguration', 's3:GetObjectVersionForReplication']) {
      assert.ok(!policy.Statement.some(s => s.Action.includes(action)), action);
    }
  }
});

test('VPC refresh can discover its default NACL with regional metadata only', () => {
  const policies = devInfraPolicies(inventory);
  for (const policy of [policies.plan, policies.apply]) {
    const metadata = policy.Statement.find(s => s.Sid === 'Ec2Metadata');
    for (const action of ['ec2:DescribeVpcs', 'ec2:DescribeVpcAttribute', 'ec2:DescribeNetworkAcls', 'ec2:DescribeRouteTables', 'ec2:DescribeSecurityGroups']) {
      assert.ok(metadata.Action.includes(action), action);
    }
    assert.equal(metadata.Resource, '*');
    assert.deepEqual(metadata.Condition, { StringEquals: { 'aws:RequestedRegion': 'sa-east-1' } });
    assert.ok(metadata.Action.every(action => action.startsWith('ec2:Describe')));
    for (const action of ['ec2:CreateNetworkAcl', 'ec2:ReplaceNetworkAclEntry', 'ec2:ReplaceNetworkAclAssociation', 'ec2:DeleteNetworkAcl']) {
      assert.ok(!policy.Statement.some(s => s.Action.includes(action)), action);
    }
  }
  for (const boundary of [policies.runtimeBoundary, policies.flowBoundary]) {
    const actions = boundary.Statement.flatMap(s => s.Action);
    for (const action of ['ec2:DescribeNetworkAcls', 's3:GetBucketCORS', 's3:GetBucketWebsite', 's3:GetAccelerateConfiguration', 's3:GetReplicationConfiguration']) {
      assert.ok(!actions.includes(action), action);
    }
  }
});

test('runtime permits SSM log-group discovery only in Sao Paulo without group administration', () => {
  const { runtimeBoundary } = devInfraPolicies(inventory);
  const grants = runtimeBoundary.Statement.filter(s => s.Action.includes('logs:DescribeLogGroups'));
  assert.deepEqual(grants, [{
    Sid: 'LogGroupDiscovery', Effect: 'Allow', Action: ['logs:DescribeLogGroups'], Resource: '*',
    Condition: { StringEquals: { 'aws:RequestedRegion': 'sa-east-1' } },
  }]);
  // Offline scope check, not an AWS IAM simulator or proof of agent delivery.
  for (const [region, expected] of [['sa-east-1', true], ['us-east-1', false], ['', false], [undefined, false]]) {
    assert.equal(grants.some(s => s.Condition.StringEquals['aws:RequestedRegion'] === region), expected);
  }
  const actions = runtimeBoundary.Statement.flatMap(s => s.Action);
  for (const action of ['logs:CreateLogGroup', 'logs:DeleteLogGroup', 'logs:PutRetentionPolicy', 'logs:AssociateKmsKey', 'logs:GetLogEvents', 'logs:FilterLogEvents']) {
    assert.ok(!actions.includes(action), action);
  }
});

test('SSM discovery is the only delta in the complete existing generated policy set', () => {
  const policies = devInfraPolicies(inventory);
  policies.runtimeBoundary.Statement = policies.runtimeBoundary.Statement.filter(s => s.Sid !== 'LogGroupDiscovery');
  // Exact e42f266 baseline for this synthetic inventory: guards all writes,
  // existing grants, flow boundary, resources and conditions against expansion.
  assert.equal(createHash('sha256').update(JSON.stringify(policies)).digest('hex'),
    '7e84154ec4db569eab90d5262b73d1d351d06a8e8903722a5e712035c6319d80');
});
