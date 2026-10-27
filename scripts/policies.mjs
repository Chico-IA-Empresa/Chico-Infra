// Generates permissions for explicit inventories only; does not contact AWS.
const arn = (v, service) => {
  if (typeof v !== 'string' || !v.startsWith(`arn:aws:${service}:`) || v.includes('*')) throw new Error(`Explicit ${service} ARN required`);
  return v;
};
export function deploymentPolicy({ clusterArn, serviceArns, taskDefinitionArns, executionRoleArns, taskRoleArns }) {
  arn(clusterArn, 'ecs');
  if (!/^arn:aws:ecs:sa-east-1:[0-9]{12}:cluster\/chico-(dev|uat|prod)$/.test(clusterArn)) throw new Error('Expected approved region/account/environment cluster');
  for (const values of [serviceArns, taskDefinitionArns, executionRoleArns, taskRoleArns]) if (!Array.isArray(values) || !values.length) throw new Error('Nonempty reviewed ARN inventory required');
  const account = clusterArn.split(':')[4];
  const region = clusterArn.split(':')[3];
  const scope = clusterArn.split('/').at(-1).match(/^chico-(dev|uat|prod)$/)?.[1];
  if (!scope) throw new Error('Expected chico-env cluster');
  for (const value of [...serviceArns, ...taskDefinitionArns]) {
    arn(value, 'ecs');
    if (value.split(':')[4] !== account || value.split(':')[3] !== region) throw new Error('Foreign account/region');
  }
  if (serviceArns.some(a => !a.includes(`:service/chico-${scope}/`))) throw new Error('Foreign service');
  if (taskDefinitionArns.some(a => !new RegExp(`:task-definition/chico-${scope}-[a-z0-9-]+:[0-9]+$`).test(a))) throw new Error('Foreign or unversioned task definition');
  for (const value of [...executionRoleArns, ...taskRoleArns]) {
    arn(value, 'iam');
    if (value.split(':')[4] !== account || !value.includes(`:role/chico/${scope}/`)) throw new Error('Foreign role');
  }
  return { Version: '2012-10-17', Statement: [
    { Effect: 'Allow', Action: ['ecs:UpdateService', 'ecs:DescribeServices'], Resource: serviceArns, Condition: { ArnEquals: { 'ecs:cluster': clusterArn } } },
    { Effect: 'Allow', Action: ['ecs:RunTask'], Resource: taskDefinitionArns, Condition: { ArnEquals: { 'ecs:cluster': clusterArn } } },
    { Effect: 'Allow', Action: ['iam:PassRole'], Resource: [...executionRoleArns, ...taskRoleArns], Condition: { StringEquals: { 'iam:PassedToService': 'ecs-tasks.amazonaws.com' } } },
  ] };
}
export function executionPolicy({ repositoryArns, secretArns, parameterArns, logGroupArn, kmsKeyArns = [] }) {
  if (!repositoryArns.length) throw new Error('Repository inventory required');
  repositoryArns.forEach(a => arn(a, 'ecr'));
  secretArns.forEach(a => arn(a, 'secretsmanager'));
  parameterArns.forEach(a => arn(a, 'ssm'));
  arn(logGroupArn, 'logs');
  const scope = logGroupArn.match(/^arn:aws:logs:sa-east-1:([0-9]{12}):log-group:\/chico\/(dev|uat|prod)\/(api|workers|frontend)$/);
  if (!scope) throw new Error('Expected reviewed environment/service log group');
  const [, account, env, service] = scope;
  for (const value of [...repositoryArns, ...secretArns, ...parameterArns, ...kmsKeyArns]) {
    if (value.split(':')[3] !== 'sa-east-1' || value.split(':')[4] !== account) throw new Error('Foreign execution resource');
  }
  if (secretArns.some(a => !a.includes(`:secret:/chico/${env}/${service}/`)) || parameterArns.some(a => !a.includes(`:parameter/chico/${env}/${service}/`))) throw new Error('Foreign environment/service configuration');
  if (secretArns.length && !kmsKeyArns.length) throw new Error('Reviewed CMK inventory required for encrypted secrets');
  kmsKeyArns.forEach(a => arn(a, 'kms'));
  const Statement = [
    { Effect: 'Allow', Action: ['ecr:GetAuthorizationToken'], Resource: '*' },
    { Effect: 'Allow', Action: ['ecr:BatchGetImage', 'ecr:GetDownloadUrlForLayer', 'ecr:BatchCheckLayerAvailability'], Resource: repositoryArns },
    { Effect: 'Allow', Action: ['logs:CreateLogStream', 'logs:PutLogEvents'], Resource: `${logGroupArn}:*` },
  ];
  if (secretArns.length) Statement.push({ Effect: 'Allow', Action: ['secretsmanager:GetSecretValue'], Resource: secretArns });
  if (parameterArns.length) Statement.push({ Effect: 'Allow', Action: ['ssm:GetParameters'], Resource: parameterArns });
  if (kmsKeyArns.length) Statement.push({ Effect: 'Allow', Action: ['kms:Decrypt'], Resource: kmsKeyArns, Condition: { StringEquals: { 'kms:ViaService': ['secretsmanager.sa-east-1.amazonaws.com', 'ssm.sa-east-1.amazonaws.com'] } } });
  return { Version: '2012-10-17', Statement };
}
export function retentionCandidates(images, protectedDigests, keep = 30, { inventoryComplete = false, manifestChildren = {} } = {}) {
  if (!inventoryComplete) throw new Error('Complete deployment/rollback/multiarch inventory required');
  if (!Array.isArray(protectedDigests) || !protectedDigests.length) throw new Error('Active and rollback digest inventory required');
  if (protectedDigests.some(d => !/^sha256:[a-f0-9]{64}$/.test(d))) throw new Error('Malformed protected digest');
  if (!Number.isInteger(keep) || keep < 30) throw new Error('Keep at least 30 builds plus protected releases');
  const protectedSet = new Set(protectedDigests);
  // Recursively protect platform manifests referenced by deployed image indexes.
  const queue = [...protectedSet];
  while (queue.length) {
    const digest = queue.shift();
    const children = manifestChildren[digest] ?? [];
    if (!Array.isArray(children)) throw new Error('Invalid manifest graph');
    for (const child of children) {
      if (!/^sha256:[a-f0-9]{64}$/.test(child)) throw new Error('Malformed child digest');
      if (!protectedSet.has(child)) { protectedSet.add(child); queue.push(child); }
    }
  }
  const ordered = [...images].sort((a, b) => Date.parse(b.pushedAt) - Date.parse(a.pushedAt));
  for (const image of ordered) {
    if (!/^sha256:[a-f0-9]{64}$/.test(image.digest) || !Number.isFinite(Date.parse(image.pushedAt)) || !Array.isArray(image.tags)) throw new Error('Invalid image metadata');
  }
  // A protected release remains kept even if outside the newest 30.
  const newest = new Set(ordered.slice(0, keep).map(i => i.digest));
  return ordered.filter(i => !newest.has(i.digest) && !protectedSet.has(i.digest) && i.tags.length > 0 && i.tags.every(t => /^[a-f0-9]{40}$/.test(t)));
}
export function promotionAllowed(scan) {
  return scan.status === 'COMPLETE' && Number.isInteger(scan.critical) && scan.critical === 0;
}
