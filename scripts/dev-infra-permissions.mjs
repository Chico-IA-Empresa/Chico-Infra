// Terraform/CLI permissions, not application SDK policy inference. Actions are
// checked against AWS's service authorization reference by verify-iam-actions.mjs.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const document = Statement => ({ Version: '2012-10-17', Statement });
const allow = (Sid, Action, Resource, Condition) => ({ Sid, Effect: 'Allow', Action, Resource, ...(Condition ? { Condition } : {}) });
const region = { StringEquals: { 'aws:RequestedRegion': 'sa-east-1' } };
const owned = { StringEquals: { 'aws:ResourceTag/project': 'chicoai', 'aws:ResourceTag/env': 'dev', 'aws:RequestedRegion': 'sa-east-1' } };
const creating = { StringEquals: { 'aws:RequestTag/project': 'chicoai', 'aws:RequestTag/env': 'dev', 'aws:RequestedRegion': 'sa-east-1' } };

export function devInfraPolicies(i) {
  const fields = ['account', 'stateBucket', 'reviewBucket', 'backupBucket', 'accessLogBucket', 'amiId', 'kmsKeyArns', 'secretsKeyArn', 'vpcId', 'defaultSecurityGroupId'];
  if (!i || typeof i !== 'object' || Array.isArray(i) || Object.keys(i).some(key => !fields.includes(key))) throw new Error('Only reviewed metadata fields are accepted');
  const exact = (value, pattern, name) => { if (typeof value !== 'string' || !pattern.test(value)) throw new Error(`Invalid ${name}`); return value; };
  const account = exact(i.account, /^[0-9]{12}$/, 'account');
  const bucket = (name, prefix) => exact(name, new RegExp(`^${prefix}[a-z0-9-]{3,45}$`), 'bucket');
  const state = bucket(i.stateBucket, 'chico-tfstate-'), review = bucket(i.reviewBucket, 'chico-infra-review-');
  const backup = bucket(i.backupBucket, 'chico-dev-');
  const accessLogs = bucket(i.accessLogBucket, 'chico-dev-access-');
  if (new Set([state, review, backup, accessLogs]).size !== 4) throw new Error('Separate state, review, backup and access-log buckets required');
  const ami = exact(i.amiId, /^ami-[a-f0-9]{17}$/, 'AMI');
  if (!Array.isArray(i.kmsKeyArns) || !i.kmsKeyArns.length) throw new Error('Reviewed KMS keys required');
  i.kmsKeyArns.forEach(arn => exact(arn, new RegExp(`^arn:aws:kms:sa-east-1:${account}:key/[a-f0-9-]{36}$`), 'KMS key'));
  if (new Set(i.kmsKeyArns).size !== i.kmsKeyArns.length) throw new Error('Duplicate KMS key');
  const secretsKey = exact(i.secretsKeyArn, new RegExp(`^arn:aws:kms:sa-east-1:${account}:key/[a-f0-9-]{36}$`), 'Secrets CMK');
  if (!i.kmsKeyArns.includes(secretsKey)) throw new Error('Secrets CMK must be an explicitly reviewed Dev key');
  // The first human executor establishes the VPC. Exact IDs are required for
  // implicit resources (default SG, primary ENI), which cannot carry request tags.
  const vpc = exact(i.vpcId, /^vpc-[a-f0-9]{17}$/, 'reconciled Dev VPC');
  const defaultSg = exact(i.defaultSecurityGroupId, /^sg-[a-f0-9]{17}$/, 'reconciled Dev default SG');
  const runtime = `arn:aws:iam::${account}:role/chico/dev/chico-dev-runtime`;
  const flow = `arn:aws:iam::${account}:role/chico/dev/chico-dev-flow-logs`;
  const boundaries = {
    runtime: `arn:aws:iam::${account}:policy/chico/shared/chico-dev-runtime-boundary`,
    flow: `arn:aws:iam::${account}:policy/chico/shared/chico-dev-flow-boundary`,
  };
  const ec2 = type => `arn:aws:ec2:sa-east-1:${account}:${type}/*`;
  const logs = `arn:aws:logs:sa-east-1:${account}:log-group:/chico/dev/*`;
  const repos = ['api', 'workers', 'frontend'].map(name => `arn:aws:ecr:sa-east-1:${account}:repository/chico-${name}`);
  const parameter = `arn:aws:ssm:sa-east-1:${account}:parameter/chico/dev/*`;
  const secret = `arn:aws:secretsmanager:sa-east-1:${account}:secret:/chico/dev/*`;
  const reads = [
    allow('Ec2Metadata', ['ec2:DescribeVpcs', 'ec2:DescribeVpcAttribute', 'ec2:DescribeNetworkAcls', 'ec2:DescribeSubnets', 'ec2:DescribeRouteTables', 'ec2:DescribeInternetGateways', 'ec2:DescribeSecurityGroups', 'ec2:DescribeSecurityGroupRules', 'ec2:DescribeInstances', 'ec2:DescribeInstanceAttribute', 'ec2:DescribeInstanceCreditSpecifications', 'ec2:DescribeInstanceTypes', 'ec2:DescribeVolumes', 'ec2:DescribeAddresses', 'ec2:DescribeAddressesAttribute', 'ec2:DescribeImages', 'ec2:DescribeTags', 'ec2:DescribeNetworkInterfaces', 'ec2:DescribeFlowLogs', 'ec2:DescribeAvailabilityZones'], '*', region),
    allow('RuntimeRoleMetadata', ['iam:GetRole', 'iam:GetRolePolicy', 'iam:ListRolePolicies', 'iam:ListAttachedRolePolicies', 'iam:ListInstanceProfilesForRole'], [runtime, flow]),
    allow('ProfileMetadata', ['iam:GetInstanceProfile'], `arn:aws:iam::${account}:instance-profile/chico/dev/chico-dev-runtime`),
    allow('BoundaryMetadata', ['iam:GetPolicy', 'iam:GetPolicyVersion'], Object.values(boundaries)),
    allow('StateLocation', ['s3:ListBucket'], `arn:aws:s3:::${state}`, { StringLike: { 's3:prefix': ['dev/terraform.tfstate', 'dev/terraform.tfstate.tflock'] } }),
    allow('ReadDevState', ['s3:GetObject'], `arn:aws:s3:::${state}/dev/terraform.tfstate`),
    allow('DevStateLock', ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'], `arn:aws:s3:::${state}/dev/terraform.tfstate.tflock`),
    allow('ReviewBucketChecks', ['s3:GetBucketPublicAccessBlock', 's3:GetBucketVersioning'], `arn:aws:s3:::${review}`),
    // aws_s3_bucket Read also queries absent legacy configuration fields. Grant
    // their metadata reads, never writes or object access, on both owned buckets.
    allow('BackupConfiguration', ['s3:GetBucketLocation', 's3:GetBucketPolicy', 's3:GetBucketAcl', 's3:GetBucketCORS', 's3:GetBucketWebsite', 's3:GetAccelerateConfiguration', 's3:GetReplicationConfiguration', 's3:GetBucketTagging', 's3:GetBucketPublicAccessBlock', 's3:GetBucketOwnershipControls', 's3:GetBucketVersioning', 's3:GetEncryptionConfiguration', 's3:GetLifecycleConfiguration', 's3:GetBucketLogging', 's3:GetBucketObjectLockConfiguration', 's3:GetBucketRequestPayment'], [backup, accessLogs].map(name => `arn:aws:s3:::${name}`)),
    // HeadBucket requires ListBucket without s3:prefix. This grants metadata
    // listing of these two owned buckets, never their object bodies or legacy S3.
    allow('DevBucketExistenceMetadata', ['s3:ListBucket'], [backup, accessLogs].map(name => `arn:aws:s3:::${name}`), region),
    allow('LogGroupsMetadata', ['logs:DescribeLogGroups'], '*', region),
    allow('DevLogMetadata', ['logs:ListTagsForResource'], logs, region),
    allow('AlarmMetadata', ['cloudwatch:DescribeAlarms'], '*', region),
    allow('DevAlarmTags', ['cloudwatch:ListTagsForResource'], `arn:aws:cloudwatch:sa-east-1:${account}:alarm:chico-dev-*`, region),
    allow('KeyMetadata', ['kms:DescribeKey'], i.kmsKeyArns, region),
    allow('ConfigurationMetadata', ['secretsmanager:DescribeSecret', 'secretsmanager:GetResourcePolicy'], secret, region),
    allow('NonSecretParameters', ['ssm:GetParameter', 'ssm:ListTagsForResource'], parameter, region),
    // DescribeParameters has no resource-level permission support and returns
    // metadata only. Parameter values remain restricted to the Dev namespace.
    allow('ParameterMetadataDiscovery', ['ssm:DescribeParameters'], '*', region),
    allow('DevDocuments', ['ssm:DescribeDocument', 'ssm:DescribeDocumentPermission', 'ssm:GetDocument', 'ssm:ListDocumentVersions', 'ssm:ListTagsForResource'], `arn:aws:ssm:sa-east-1:${account}:document/chico-dev-*`, region),
  ];
  const plan = document([...reads, allow('UploadPrivatePlan', ['s3:PutObject'], `arn:aws:s3:::${review}/dev/*`)]);
  const writes = [
    allow('WriteDevState', ['s3:PutObject'], `arn:aws:s3:::${state}/dev/terraform.tfstate`),
    allow('ReadApprovedPlanVersion', ['s3:GetObjectVersion'], `arn:aws:s3:::${review}/dev/*`),
    // Existing Dev VPC only: bootstrap ownership is explicit, not guessed by name.
    allow('DevVpcOperations', ['ec2:ModifyVpcAttribute', 'ec2:CreateSubnet', 'ec2:CreateSecurityGroup', 'ec2:CreateRouteTable', 'ec2:AttachInternetGateway', 'ec2:DetachInternetGateway', 'ec2:CreateFlowLogs'], `arn:aws:ec2:sa-east-1:${account}:vpc/${vpc}`, owned),
    allow('CreateTaggedNetwork', ['ec2:CreateSubnet', 'ec2:CreateSecurityGroup', 'ec2:CreateRouteTable', 'ec2:CreateInternetGateway', 'ec2:AllocateAddress', 'ec2:CreateFlowLogs'], ['subnet', 'security-group', 'route-table', 'internet-gateway', 'elastic-ip', 'vpc-flow-log'].map(ec2), creating),
    allow('ManageTaggedNetwork', ['ec2:DeleteSubnet', 'ec2:ModifySubnetAttribute', 'ec2:DeleteSecurityGroup', 'ec2:AuthorizeSecurityGroupIngress', 'ec2:AuthorizeSecurityGroupEgress', 'ec2:RevokeSecurityGroupIngress', 'ec2:RevokeSecurityGroupEgress', 'ec2:ModifySecurityGroupRules', 'ec2:DeleteRouteTable', 'ec2:CreateRoute', 'ec2:ReplaceRoute', 'ec2:DeleteRoute', 'ec2:AssociateRouteTable', 'ec2:DisassociateRouteTable', 'ec2:ReplaceRouteTableAssociation', 'ec2:AttachInternetGateway', 'ec2:DetachInternetGateway', 'ec2:DeleteInternetGateway', 'ec2:AssociateAddress', 'ec2:DisassociateAddress', 'ec2:ReleaseAddress'], ['subnet', 'security-group', 'security-group-rule', 'route-table', 'internet-gateway', 'elastic-ip', 'instance'].map(ec2), owned),
    allow('DefaultSecurityGroupAdoption', ['ec2:CreateTags', 'ec2:RevokeSecurityGroupIngress', 'ec2:RevokeSecurityGroupEgress'], `arn:aws:ec2:sa-east-1:${account}:security-group/${defaultSg}`, region),
    allow('LaunchReviewedImage', ['ec2:RunInstances'], `arn:aws:ec2:sa-east-1::image/${ami}`, region),
    allow('LaunchDevNetwork', ['ec2:RunInstances'], ['subnet', 'security-group'].map(ec2), owned),
    allow('LaunchDevInterface', ['ec2:RunInstances', 'ec2:AssociateAddress'], ec2('network-interface'), { StringEquals: { 'aws:RequestedRegion': 'sa-east-1', 'ec2:Vpc': `arn:aws:ec2:sa-east-1:${account}:vpc/${vpc}` } }),
    allow('LaunchTaggedHost', ['ec2:RunInstances'], ec2('instance'), { StringEquals: { ...creating.StringEquals, 'ec2:InstanceType': 't4g.small', 'ec2:MetadataHttpTokens': 'required', 'ec2:InstanceProfile': `arn:aws:iam::${account}:instance-profile/chico/dev/chico-dev-runtime` } }),
    allow('LaunchEncryptedVolume', ['ec2:RunInstances'], ec2('volume'), { StringEquals: creating.StringEquals, Bool: { 'ec2:Encrypted': 'true' } }),
    allow('HostMaintenance', ['ec2:ModifyInstanceAttribute', 'ec2:ModifyInstanceMetadataOptions', 'ec2:ModifyInstanceCreditSpecification', 'ec2:ModifyVolume'], ['instance', 'volume'].map(ec2), owned),
    allow('MaintainDevHostPower', ['ec2:StopInstances', 'ec2:StartInstances'], ec2('instance'), owned),
    allow('TagsAtCreation', ['ec2:CreateTags'], ['subnet', 'security-group', 'route-table', 'internet-gateway', 'elastic-ip', 'instance', 'volume', 'vpc-flow-log'].map(ec2), { StringEquals: { ...creating.StringEquals, 'ec2:CreateAction': ['RunInstances', 'CreateSubnet', 'CreateSecurityGroup', 'CreateRouteTable', 'CreateInternetGateway', 'AllocateAddress', 'CreateFlowLogs'] } }),
    allow('UpdateOwnedTags', ['ec2:CreateTags', 'ec2:DeleteTags'], ['subnet', 'security-group', 'route-table', 'internet-gateway', 'elastic-ip', 'instance', 'volume', 'vpc-flow-log'].map(ec2), owned),
    ...[[runtime, boundaries.runtime], [flow, boundaries.flow]].map(([arn, boundary], n) => allow(`BoundedRole${n}`, ['iam:CreateRole', 'iam:PutRolePolicy', 'iam:PutRolePermissionsBoundary'], arn, { StringEquals: { 'iam:PermissionsBoundary': boundary } })),
    allow('ManageBoundedRoles', ['iam:UpdateAssumeRolePolicy', 'iam:UpdateRole', 'iam:TagRole', 'iam:UntagRole', 'iam:DeleteRolePolicy'], [runtime, flow]),
    allow('ManageRuntimeProfile', ['iam:CreateInstanceProfile', 'iam:TagInstanceProfile', 'iam:UntagInstanceProfile', 'iam:AddRoleToInstanceProfile', 'iam:RemoveRoleFromInstanceProfile'], `arn:aws:iam::${account}:instance-profile/chico/dev/chico-dev-runtime`),
    allow('PassRuntimeToEc2', ['iam:PassRole'], runtime, { StringEquals: { 'iam:PassedToService': 'ec2.amazonaws.com' } }),
    allow('PassFlowToVpc', ['iam:PassRole'], flow, { StringEquals: { 'iam:PassedToService': 'vpc-flow-logs.amazonaws.com' } }),
    allow('ManageBackupConfiguration', ['s3:CreateBucket', 's3:PutBucketPolicy', 's3:PutBucketTagging', 's3:PutBucketPublicAccessBlock', 's3:PutBucketOwnershipControls', 's3:PutBucketVersioning', 's3:PutEncryptionConfiguration', 's3:PutLifecycleConfiguration', 's3:PutBucketLogging'], [backup, accessLogs].map(name => `arn:aws:s3:::${name}`)),
    allow('TagDevBucketsAtCreation', ['s3:TagResource'], [backup, accessLogs].map(name => `arn:aws:s3:::${name}`), creating),
    allow('ManageDevLogGroups', ['logs:CreateLogGroup', 'logs:PutRetentionPolicy', 'logs:AssociateKmsKey', 'logs:TagResource', 'logs:UntagResource'], logs, region),
    allow('ManageDevAlarms', ['cloudwatch:PutMetricAlarm', 'cloudwatch:DeleteAlarms', 'cloudwatch:TagResource', 'cloudwatch:UntagResource'], `arn:aws:cloudwatch:sa-east-1:${account}:alarm:chico-dev-*`, region),
    allow('ManageSecretMetadata', ['secretsmanager:CreateSecret', 'secretsmanager:UpdateSecret', 'secretsmanager:TagResource', 'secretsmanager:UntagResource'], secret, region),
    // Secrets Manager validates a custom key even for metadata-only creation.
    // Permit only its validation context, never real secret versions or direct KMS.
    allow('ValidateDevSecretKeyMetadata', ['kms:GenerateDataKey', 'kms:Decrypt'], secretsKey, {
      StringEquals: { ...region.StringEquals, 'kms:CallerAccount': account, 'kms:ViaService': 'secretsmanager.sa-east-1.amazonaws.com', 'kms:EncryptionContext:SecretVersionId': 'RequestToValidateKeyAccess' },
      StringLike: { 'kms:EncryptionContext:SecretARN': ['api/SYNTHETIC_TOKEN', 'api/DEV_DATABASE_CREDENTIALS'].map(name => `arn:aws:secretsmanager:sa-east-1:${account}:secret:/chico/dev/${name}-??????`) },
    }),
    allow('ManageNonSecretParameters', ['ssm:PutParameter', 'ssm:DeleteParameter', 'ssm:AddTagsToResource', 'ssm:RemoveTagsFromResource'], parameter, region),
    allow('ManageDevDocuments', ['ssm:CreateDocument', 'ssm:UpdateDocument', 'ssm:UpdateDocumentDefaultVersion', 'ssm:DeleteDocument', 'ssm:AddTagsToResource', 'ssm:RemoveTagsFromResource'], `arn:aws:ssm:sa-east-1:${account}:document/chico-dev-*`, region),
  ];
  const runtimeBoundary = document([
    allow('AgentCore', ['ssm:DescribeAssociation', 'ssm:GetDeployablePatchSnapshotForInstance', 'ssm:GetDocument', 'ssm:DescribeDocument', 'ssm:GetManifest', 'ssm:ListAssociations', 'ssm:ListInstanceAssociations', 'ssm:PutInventory', 'ssm:PutComplianceItems', 'ssm:PutConfigurePackageResult', 'ssm:UpdateAssociationStatus', 'ssm:UpdateInstanceAssociationStatus', 'ssm:UpdateInstanceInformation', 'ssmmessages:CreateControlChannel', 'ssmmessages:CreateDataChannel', 'ssmmessages:OpenControlChannel', 'ssmmessages:OpenDataChannel', 'ec2messages:AcknowledgeMessage', 'ec2messages:DeleteMessage', 'ec2messages:FailMessage', 'ec2messages:GetEndpoint', 'ec2messages:GetMessages', 'ec2messages:SendReply'], '*', region),
    allow('RegistryToken', ['ecr:GetAuthorizationToken'], '*', region),
    allow('PullSharedImages', ['ecr:BatchGetImage', 'ecr:GetDownloadUrlForLayer', 'ecr:BatchCheckLayerAvailability'], repos, region),
    allow('DevLogs', ['logs:CreateLogStream', 'logs:DescribeLogStreams', 'logs:PutLogEvents'], `${logs}:*`, region),
    allow('DevMetrics', ['cloudwatch:PutMetricData'], '*', { StringEquals: { ...region.StringEquals, 'cloudwatch:namespace': 'Chico/Dev' } }),
    allow('DevBackupListing', ['s3:ListBucket'], `arn:aws:s3:::${backup}`, { StringLike: { 's3:prefix': ['dev/fixtures/*', 'dev/database/*'] } }),
    allow('DevBackupObjects', ['s3:GetObject', 's3:GetObjectVersion', 's3:PutObject', 's3:AbortMultipartUpload', 's3:ListMultipartUploadParts'], ['fixtures', 'database'].map(prefix => `arn:aws:s3:::${backup}/dev/${prefix}/*`)),
    allow('DevSecrets', ['secretsmanager:GetSecretValue'], secret, region),
    allow('DevSecretKeys', ['kms:Decrypt'], i.kmsKeyArns, { StringEquals: { 'kms:ViaService': 'secretsmanager.sa-east-1.amazonaws.com' }, StringLike: { 'kms:EncryptionContext:SecretARN': secret } }),
    allow('DevNonSecretParameters', ['ssm:GetParameters'], parameter, region),
  ]);
  const flowBoundary = document([
    allow('FlowLogStreams', ['logs:CreateLogStream', 'logs:DescribeLogStreams', 'logs:PutLogEvents'], `arn:aws:logs:sa-east-1:${account}:log-group:/chico/dev/flow:*`, region),
    allow('LogGroupDiscovery', ['logs:DescribeLogGroups'], '*', region),
  ]);
  const apply = document([...reads, ...writes]);
  for (const policy of [plan, runtimeBoundary, flowBoundary]) {
    if (JSON.stringify(policy).length > 6144) throw new Error('IAM managed policy quota exceeded; reduce/review inventory');
  }
  // Customer-managed IAM policies have a 6,144-character quota. Split on
  // statement boundaries; each part is independently valid and reviewable.
  const applyParts = [];
  for (const statement of apply.Statement) {
    let last = applyParts.at(-1);
    if (!last || JSON.stringify(document([...last.Statement, statement])).length > 6000) {
      last = document([]); applyParts.push(last);
    }
    last.Statement.push(statement);
    if (JSON.stringify(last).length > 6144) throw new Error('Single statement exceeds IAM managed policy quota');
  }
  return { plan, apply, applyParts, runtimeBoundary, flowBoundary, boundaryArns: boundaries, repositoryArns: repos };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const inventory = JSON.parse(readFileSync(process.argv[2], 'utf8'));
    const policies = devInfraPolicies(inventory);
    const destination = resolve(process.argv[3]);
    mkdirSync(destination, { recursive: true, mode: 0o700 });
    for (const name of ['plan', 'apply', 'runtimeBoundary', 'flowBoundary']) writeFileSync(resolve(destination, `${name}.json`), JSON.stringify(policies[name], null, 2) + '\n', { mode: 0o600 });
    writeFileSync(resolve(destination, 'shared-policy-inputs.json'), JSON.stringify({ dev_ci_policy_documents: {
      plan: JSON.stringify(policies.plan), apply_parts: policies.applyParts.map(p => JSON.stringify(p)),
      runtime_boundary: JSON.stringify(policies.runtimeBoundary), flow_boundary: JSON.stringify(policies.flowBoundary),
    } }, null, 2) + '\n', { mode: 0o600 });
    console.log('Generated private policy candidates; AWS validation, boundaries and live permission proofs are required before use.');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
