// Offline policy generators. Each returned document requires separate review and
// attachment by the owning root. No AWS calls, policy publication or assumptions.
function exact(value, expression, label) {
  if (typeof value !== 'string' || !expression.test(value)) throw new Error(`Invalid ${label}`);
  return value;
}
const accountId = value => exact(value, /^[0-9]{12}$/, 'account');
export function buildPushPolicy({ account, repositoryArns }) {
  accountId(account);
  if (repositoryArns?.length !== 3 || new Set(repositoryArns).size !== 3) throw new Error('Three exact shared repositories required');
  repositoryArns.forEach(a => exact(a, new RegExp(`^arn:aws:ecr:sa-east-1:${account}:repository/chico-(api|workers|frontend)$`), 'repository'));
  return { Version: '2012-10-17', Statement: [
    { Effect: 'Allow', Action: ['ecr:GetAuthorizationToken'], Resource: '*' },
    { Effect: 'Allow', Action: ['ecr:BatchCheckLayerAvailability', 'ecr:InitiateLayerUpload', 'ecr:UploadLayerPart', 'ecr:CompleteLayerUpload', 'ecr:PutImage', 'ecr:BatchGetImage', 'ecr:DescribeImages', 'ecr:DescribeRepositories', 'ecr:DescribeImageScanFindings'], Resource: repositoryArns },
    { Effect: 'Allow', Action: ['ecr:GetRegistryScanningConfiguration'], Resource: '*' },
  ] };
}
export function ssmDeployPolicy({ account, instanceArn, documentArn }) {
  accountId(account);
  exact(instanceArn, new RegExp(`^arn:aws:ec2:sa-east-1:${account}:instance/i-[a-f0-9]{8,17}$`), 'Dev instance');
  exact(documentArn, new RegExp(`^arn:aws:ssm:sa-east-1:${account}:document/chico-dev-[a-z0-9-]+$`), 'reviewed Dev document');
  return { Version: '2012-10-17', Statement: [
    { Effect: 'Allow', Action: ['ssm:SendCommand'], Resource: [documentArn] },
    { Effect: 'Allow', Action: ['ssm:SendCommand'], Resource: [instanceArn], Condition: { StringEquals: { 'ssm:resourceTag/env': 'dev', 'ssm:resourceTag/project': 'chicoai' } } },
    { Effect: 'Allow', Action: ['ssm:GetCommandInvocation'], Resource: '*', Condition: { StringEquals: { 'aws:RequestedRegion': 'sa-east-1' } } },
  ] };
}
export function devPassRolePolicy({ account, roleArns }) {
  accountId(account);
  if (!Array.isArray(roleArns) || roleArns.length !== 1) throw new Error('One reviewed runtime role required');
  roleArns.forEach(a => exact(a, new RegExp(`^arn:aws:iam::${account}:role/chico/dev/chico-dev-runtime$`), 'Dev runtime role'));
  return { Version: '2012-10-17', Statement: [{ Effect: 'Allow', Action: ['iam:PassRole'], Resource: roleArns, Condition: { StringEquals: { 'iam:PassedToService': 'ec2.amazonaws.com' } } }] };
}
