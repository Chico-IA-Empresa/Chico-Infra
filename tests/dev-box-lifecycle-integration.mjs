// Native AWS provider planning against generated SYNTHETIC LOCAL state only.
// Never apply/refresh/import/push state; all service endpoints fail on loopback.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, readdirSync, realpathSync, rmSync } from 'node:fs';
import { join, sep, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const moduleRoot = fileURLToPath(new URL('../modules/dev-box/', import.meta.url));
const privateRoot = fileURLToPath(new URL('../reports/private/', import.meta.url));
mkdirSync(privateRoot, { recursive: true });
const root = realpathSync(privateRoot), directory = mkdtempSync(join(root, 'eip-lifecycle-'));
const terraform = process.env.TERRAFORM_BINARY ?? 'terraform';
const original = readFileSync(join(moduleRoot, 'main.tf'), 'utf8');
const beforeData = '#!/bin/bash\necho synthetic-old\n';
const env = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
  !/^AWS_|^TF_LOG|^TF_CLI_ARGS|^TF_DATA_DIR$|^TF_WORKSPACE$|^(?:HTTP|HTTPS|ALL)_PROXY$/i.test(key)));
Object.assign(env, { AWS_ACCESS_KEY_ID: 'synthetic-only-not-an-AWS-key', AWS_SECRET_ACCESS_KEY: 'synthetic-only',
  AWS_EC2_METADATA_DISABLED: 'true', AWS_SHARED_CREDENTIALS_FILE: join(directory, 'empty'),
  AWS_CONFIG_FILE: join(directory, 'empty'), NO_PROXY: '127.0.0.1,localhost', TF_IN_AUTOMATION: 'true' });
const run = (...args) => {
  try { return { status: 0, stdout: execFileSync(terraform, [`-chdir=${directory}`, ...args], { env, encoding: 'utf8', timeout: 120_000, stdio: ['ignore', 'pipe', 'pipe'] }), stderr: '' }; }
  catch (error) { return { status: error.status ?? -1, stdout: String(error.stdout ?? ''), stderr: String(error.stderr ?? '') }; }
};
const requireSuccess = result => {
  assert.equal(result.status, 0, result.stderr + result.stdout);
  return result.stdout;
};
const sourceFor = (ignore = true) => {
  let text = original.split('resource "aws_eip" "this" {')[0];
  // This is the ONLY data-source seam. Real lookup is never invoked in the test.
  text = text.replace(/data "aws_ami" "selected" \{[\s\S]*?\n\}/, '');
  text = text.replaceAll('data.aws_ami.selected', 'local.synthetic_ami');
  if (!ignore) text = text.replace(/^\s*ignore_changes\s*=\s*\[associate_public_ip_address\]\s*$/m, '');
  return text;
};
const configuration = (source = sourceFor(), changes = {}) => {
  writeFileSync(join(directory, 'main.tf'), source);
  writeFileSync(join(directory, 'input.auto.tfvars.json'), JSON.stringify({
    ami_id: 'ami-0123456789abcdef0', subnet_id: 'subnet-0123456789abcdef0', security_group_id: 'sg-0123456789abcdef0',
    instance_profile_name: 'synthetic-runtime', compose_version: 'v5.6.0', compose_sha256: 'a'.repeat(64),
    root_volume_size_gib: 80, bootstrap_user_data: beforeData, ...changes,
  }));
};
const seed = (changes = {}) => {
  const attributes = { id: 'i-0123456789abcdef0', ami: 'ami-0123456789abcdef0', instance_type: 't4g.small',
    subnet_id: 'subnet-0123456789abcdef0', vpc_security_group_ids: ['sg-0123456789abcdef0'], iam_instance_profile: 'synthetic-runtime',
    associate_public_ip_address: true, ebs_optimized: true, monitoring: false, source_dest_check: true,
    security_groups: [], region: 'sa-east-1', force_destroy: false, get_password_data: false,
    ipv6_addresses: [], secondary_private_ips: [],
    disable_api_stop: false, disable_api_termination: false,
    user_data: beforeData, user_data_replace_on_change: false,
    metadata_options: [{ http_endpoint: 'enabled', http_tokens: 'required', http_put_response_hop_limit: 1, http_protocol_ipv6: 'disabled', instance_metadata_tags: 'disabled' }],
    root_block_device: [{ delete_on_termination: false, encrypted: true, volume_type: 'gp3', volume_size: 80,
      device_name: '/dev/xvda', volume_id: 'vol-0123456789abcdef0', kms_key_id: '', iops: 3000, throughput: 125, tags: {}, tags_all: {} }],
    credit_specification: [{ cpu_credits: 'standard' }], tags: { Name: 'chico-dev' }, tags_all: { Name: 'chico-dev' },
    volume_tags: { project: 'chicoai', env: 'dev' }, ...changes };
  writeFileSync(join(directory, 'terraform.tfstate'), JSON.stringify({ version: 4, terraform_version: '1.13.5', serial: 1,
    lineage: '00000000-0000-0000-0000-000000000001', outputs: {}, resources: [{ mode: 'managed', type: 'aws_instance', name: 'this',
      provider: 'provider["registry.terraform.io/hashicorp/aws"]', instances: [{ schema_version: 2, attributes, sensitive_attributes: [] }] }] }));
};
const plan = () => run('plan', '-refresh=false', '-input=false', '-lock-timeout=0s', '-detailed-exitcode', '-out=synthetic.tfplan', '-no-color');
const change = () => JSON.parse(requireSuccess(run('show', '-json', 'synthetic.tfplan'))).resource_changes.find(item => item.address === 'aws_instance.this').change;
const protectedFailure = (result, label, field) => {
  assert.equal(result.status, 1, `${label}: ${result.stderr}${result.stdout}`);
  assert.match(result.stderr + result.stdout, /prevent_destroy|cannot be destroyed/i, label);
  assert.match(result.stdout, new RegExp(`\\b${field}\\s*=.*# forces replacement`), 'Expected replacement field must be explicit');
  assert.doesNotMatch(result.stderr + result.stdout, /connection refused|no such host|EC2:|STS:/i, 'No service call is allowed');
};
try {
  writeFileSync(join(directory, 'empty'), '');
  for (const name of readdirSync(moduleRoot).filter(name => /\.(sh|py)$/.test(name) || name === '.terraform.lock.hcl' || name === 'versions.tf')) {
    writeFileSync(join(directory, name), readFileSync(join(moduleRoot, name)));
  }
  writeFileSync(join(directory, 'offline-provider.tf'), `
provider "aws" {
  region = "sa-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check = true
  skip_region_validation = true
  skip_requesting_account_id = true
  max_retries = 0
  endpoints {
    ec2 = "http://127.0.0.1:1"
    sts = "http://127.0.0.1:1"
  }
}
locals { synthetic_ami = { architecture = "arm64", state = "available", name = "al2023-ami-synthetic-only" } }
`);
  configuration();
  requireSuccess(run('init', '-backend=false', '-input=false', '-lockfile=readonly', '-no-color'));
  seed();
  const corrected = plan();
  assert.ok([0, 2].includes(corrected.status), corrected.stderr + corrected.stdout);
  const stable = change();
  assert.deepEqual(stable.actions, ['no-op'], 'Unexpected fixture differences: ' + Object.keys(stable.before).filter(key => JSON.stringify(stable.before[key]) !== JSON.stringify(stable.after[key])).join(','));
  assert.equal(stable.after.associate_public_ip_address, true, 'Refresh observation retained; configuration still launches false');
  configuration(sourceFor(false)); seed();
  protectedFailure(plan(), 'Control without ignore reproduces EIP flag replacement protection', 'associate_public_ip_address');
  configuration(sourceFor(), { bootstrap_user_data: '#!/bin/bash\necho synthetic-new\n' }); seed({ user_data_replace_on_change: true });
  const userdata = plan();
  assert.equal(userdata.status, 2, userdata.stderr + userdata.stdout);
  const update = change();
  assert.deepEqual(update.actions, ['update']);
  assert.deepEqual(update.replace_paths ?? [], []);
  assert.equal(update.after.user_data_replace_on_change, false);
  assert.notEqual(update.before.user_data, update.after.user_data);
  assert.equal(update.before.id, update.after.id);
  assert.equal(update.after.root_block_device[0].encrypted, true);
  assert.equal(update.after.root_block_device[0].delete_on_termination, false);
  configuration(sourceFor(), { ami_id: 'ami-11111111111111111' }); seed();
  protectedFailure(plan(), 'AMI replacement remains blocked', 'ami');
  configuration(); seed({ root_block_device: [{ delete_on_termination: false, encrypted: false, volume_type: 'gp3', volume_size: 80,
    device_name: '/dev/xvda', volume_id: 'vol-0123456789abcdef0', iops: 3000, throughput: 125, tags: {}, tags_all: {} }] });
  protectedFailure(plan(), 'Destructive root encryption replacement remains blocked', 'encrypted');
  configuration();
  const statePath = join(directory, 'terraform.tfstate');
  rmSync(statePath);
  const fresh = plan();
  assert.equal(fresh.status, 2, fresh.stderr + fresh.stdout);
  const create = change();
  assert.deepEqual(create.actions, ['create']);
  assert.equal(create.after.associate_public_ip_address, false, 'Ignore is not applied to initial creation');
  const report = { nativeTerraform: '1.13.5', nativeAWSProvider: '6.69.1', syntheticLocalStateOnly: true,
    serviceEndpoints: 'loopback-only', correctedFlagNoOp: true, originalReplacementBlocked: true,
    userDataUpdateInPlace: true, amiReplacementBlocked: true, rootEncryptionReplacementBlocked: true,
    freshLaunchPublicIpFalse: true, sourceSHA256: createHash('sha256').update(original).digest('hex'), awsExecutionProven: false };
  writeFileSync(join(root, 'dev-eip-lifecycle-last.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report));
} finally {
  const resolved = realpathSync(directory);
  assert.ok(resolved.startsWith(root + sep) && basename(resolved).startsWith('eip-lifecycle-'));
  rmSync(resolved, { recursive: true, force: true });
}
