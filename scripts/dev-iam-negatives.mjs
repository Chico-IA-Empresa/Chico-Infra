import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { validateExecutionGates } from './execution-gates.mjs';

const account = '306915830875';
const repository = 'Chico-IA-Empresa/Chico-Infra';
const roleNames = Object.freeze({ build: 'ci-build-dev', status: 'ci-deploy-dev' });
const owner = { ExpectedBucketOwner: account };
// Metadata only. Version pins identify existing objects; bodies are never read.
const probes = [
  { id: 'state-current-head', service: 's3api', operation: 'head-object', input: { Bucket: 'chico-tfstate-306915830875-sa-east-1', Key: 'dev/terraform.tfstate', ...owner } },
  { id: 'state-version-head', service: 's3api', operation: 'head-object', input: { Bucket: 'chico-tfstate-306915830875-sa-east-1', Key: 'dev/terraform.tfstate', VersionId: 'QJ9Ge81k1PAdRbVIjRPCzFi_.wapbeBK', ...owner } },
  { id: 'review-version-head', service: 's3api', operation: 'head-object', input: { Bucket: 'chico-infra-review-306915830875-sa-east-1', Key: 'dev/3fef20f0b7e485fdd13da6e0b9adaa89a735b2b7/41657962157/review.tfplan', VersionId: 'XfJZwBDuAMKse.wEAioiXxwAEOAc5xHY', ...owner } },
  { id: 'state-prefix-list', service: 's3api', operation: 'list-objects-v2', input: { Bucket: 'chico-tfstate-306915830875-sa-east-1', Prefix: 'dev/terraform.tfstate', MaxKeys: 1, ...owner } },
  { id: 'key-metadata', service: 'kms', operation: 'describe-key', input: { KeyId: 'arn:aws:kms:sa-east-1:306915830875:key/cbd8eebf-1bcf-41bc-bf5f-5926cf57f541' } },
  { id: 'secret-metadata', service: 'secretsmanager', operation: 'describe-secret', input: { SecretId: 'arn:aws:secretsmanager:sa-east-1:306915830875:secret:/chico/dev/api/SYNTHETIC_TOKEN-1fYDuY' } },
  { id: 'shared-log-metadata', service: 'logs', operation: 'describe-log-streams', input: { logGroupName: '/chico/shared/audit', limit: 1 } },
].map(value => ({ ...value, region: 'sa-east-1' }));
const canonicalProbes = JSON.stringify(probes);
export const probeSetHash = createHash('sha256').update(canonicalProbes).digest('hex');
export const fixedProbes = () => JSON.parse(canonicalProbes);
const only = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(key => keys.includes(key));
const exactKeys = (value, keys) => only(value, keys) && keys.every(key => Object.hasOwn(value, key));

export function validateNegativeReview(raw, context) {
  const { role, reviewHash, commit, roleArn, now = new Date() } = context;
  if (!Object.hasOwn(roleNames, role ?? '') || context.repository !== repository || context.ref !== 'refs/heads/main' ||
      context.eventName !== 'workflow_dispatch' || !/^[a-f0-9]{40}$/.test(commit ?? '')) throw new Error('Invalid negative-proof context');
  if (typeof raw !== 'string' || !/^[a-f0-9]{64}$/.test(reviewHash ?? '') || createHash('sha256').update(raw).digest('hex') !== reviewHash) throw new Error('Review bytes differ');
  const expectedRole = `arn:aws:iam::${account}:role/${roleNames[role]}`;
  if (roleArn !== expectedRole) throw new Error('Wrong dedicated role');
  const review = JSON.parse(raw);
  if (!exactKeys(review, ['account_id', 'provision_enabled', 'credit_approval', 'proof']) ||
      !exactKeys(review.credit_approval, ['account_id', 'all_charges_covered', 'shutdown_reserve_confirmed', 'evidence_reference', 'reviewed_on', 'expires_on']) ||
      !exactKeys(review.proof, ['scope', 'operation', 'role', 'source_commit', 'probe_set_sha256', 'inventory_reference', 'inventory_checked_at_utc'])) throw new Error('Minimal exact metadata required');
  validateExecutionGates(review, { account, approved: context.approved, validUntil: context.validUntil, now });
  const proof = review.proof, inventoryTime = Date.parse(proof.inventory_checked_at_utc);
  if (proof.scope !== 'synthetic-dev-infra' || proof.operation !== 'iam-read-negatives' || proof.role !== role ||
      proof.source_commit !== commit || proof.probe_set_sha256 !== probeSetHash ||
      typeof proof.inventory_reference !== 'string' || !proof.inventory_reference.trim() || proof.inventory_reference.length > 200 ||
      typeof proof.inventory_checked_at_utc !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(proof.inventory_checked_at_utc) ||
      !Number.isFinite(inventoryTime) || inventoryTime > now.getTime() || now.getTime() - inventoryTime >= 8 * 60 * 60 * 1000) throw new Error('Bound source, fixed probes and fresh inventory required');
  return { roleArn: expectedRole, role, probeSetHash };
}

export function classifyProbe(result, probe = {}) {
  if (result.success === true) return 'unexpected-allow';
  // NoSuchKey, NotFound, generic failures and invalid parameters never pass.
  if (['AccessDenied', 'AccessDeniedException'].includes(result.code)) return 'authorization-denied';
  // HeadObject deliberately returns generic 403 rather than a policy detail.
  // The separate inventory gate must establish exact object/version/owner exists.
  return result.code === '403' && result.headForbidden === true && probe.service === 's3api' && probe.operation === 'head-object'
    ? 'authorization-denied' : 'inconclusive';
}

export function verifyIdentity(identity, role) {
  if (!Object.hasOwn(roleNames, role ?? '') || identity?.Account !== account ||
      !new RegExp(`^arn:aws:sts::${account}:assumed-role/${roleNames[role]}/[A-Za-z0-9+=,.@_-]+$`).test(identity?.Arn ?? '')) throw new Error('Dedicated live identity required');
}

export function runReadNegatives({ role, aws, beforeEach = () => {} }) {
  const identity = aws('sts', 'get-caller-identity', {}, 'sa-east-1');
  if (!identity.success) throw new Error('Identity unavailable');
  verifyIdentity(identity.value, role);
  const results = [];
  for (const probe of fixedProbes()) {
    beforeEach();
    const result = aws(probe.service, probe.operation, probe.input, probe.region);
    const classification = classifyProbe(result, probe);
    if (classification !== 'authorization-denied') throw new Error('A negative was allowed or inconclusive');
    results.push({ id: probe.id, result: classification });
    // IDs and classifications only, never raw API/CLI output, values or errors.
  }
  return { role, probes: probes.length, result: 'authorization-denied', probeSetHash, results };
}

export function parseAwsFailure(errorText, operation) {
  const code = errorText.match(/An error occurred \(([A-Za-z0-9]+)\) when calling/)?.[1];
  const headForbidden = operation === 'head-object' && /An error occurred \(403\) when calling the HeadObject operation(?: \(reached max retries: 0\))?: Forbidden\s*$/.test(errorText);
  return { success: false, code, headForbidden };
}

export function invokeAws(service, operation, input, region) {
  const env = { ...process.env, AWS_PAGER: '', AWS_MAX_ATTEMPTS: '1', AWS_RETRY_MODE: 'standard', AWS_IGNORE_CONFIGURED_ENDPOINT_URLS: 'true', AWS_CONFIG_FILE: '/dev/null', AWS_SHARED_CREDENTIALS_FILE: '/dev/null' };
  for (const key of Object.keys(env)) if (/^AWS_(ENDPOINT_URL(?:_|$)|PROFILE$|DEFAULT_PROFILE$|WEB_IDENTITY_TOKEN_FILE$|ROLE_ARN$|CONTAINER_CREDENTIALS_)/.test(key)) delete env[key];
  try {
    const output = execFileSync('aws', [service, operation, '--cli-input-json', JSON.stringify(input), '--region', region, '--no-cli-pager', '--output', 'json', '--cli-connect-timeout', '5', '--cli-read-timeout', '10'], {
      env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 20000, maxBuffer: 1024 * 1024,
    });
    // Only STS fields are parsed; unexpected probe success is discarded intact.
    return { success: true, ...(service === 'sts' ? { value: JSON.parse(output) } : {}) };
  } catch (error) {
    const errorText = error.stderr?.toString() ?? '';
    return parseAwsFailure(errorText, operation);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    if (!['gate', 'probe'].includes(process.argv[2])) throw new Error('Explicit entrypoint required');
    const selectedRoleArn = () => {
      if (!Object.hasOwn(roleNames, process.env.NEGATIVE_ROLE ?? '')) throw new Error('Invalid role selection');
      if (process.env.PROOF_ROLE_ARN) return process.env.PROOF_ROLE_ARN;
      if (process.env.NEGATIVE_ROLE === 'build') return process.env.BUILD_ROLE_ARN;
      if (process.env.NEGATIVE_ROLE === 'status') return process.env.STATUS_ROLE_ARN;
      throw new Error('No role selected');
    };
    const revalidate = () => validateNegativeReview(process.env.DEV_IAM_NEGATIVES_REVIEW_JSON, {
      role: process.env.NEGATIVE_ROLE, reviewHash: process.env.REVIEW_SHA256, commit: process.env.GITHUB_SHA,
      repository: process.env.GITHUB_REPOSITORY, ref: process.env.GITHUB_REF, eventName: process.env.GITHUB_EVENT_NAME,
      roleArn: selectedRoleArn(), approved: process.env.DEV_EXECUTION_APPROVED, validUntil: process.env.FUNDING_REVIEW_VALID_UNTIL,
    });
    const release = revalidate();
    if (process.argv[2] === 'gate') {
      if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `role_arn=${release.roleArn}\n`);
      console.log('Private read-only IAM proof gates verified');
    } else console.log(JSON.stringify(runReadNegatives({ role: release.role, aws: invokeAws, beforeEach: revalidate })));
  } catch {
    console.error('Read-only IAM proof blocked or failed; no raw response emitted');
    process.exitCode = 1;
  }
}
