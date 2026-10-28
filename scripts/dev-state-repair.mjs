import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, openSync, closeSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { validateDevBackend } from './backend-guard.mjs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const account = '306915830875';
export const repairIds = {
  'aws_s3_bucket.backup[0]': /^chico-dev-backup-306915830875-sa-east-1$/,
  'module.backup_access_logs[0].aws_s3_bucket.this': /^chico-dev-access-306915830875-sa-east-1$/,
  'aws_ssm_document.fixture_status[0]': /^chico-dev-fixture-status$/,
  'aws_ssm_document.session[0]': /^chico-dev-session$/,
  'module.configuration[0].aws_ssm_parameter.this["api/FIXTURE_MODE"]': /^\/chico\/dev\/api\/FIXTURE_MODE$/,
  'module.dev_box[0].aws_eip.this': /^eipalloc-[a-f0-9]{17}$/,
};
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const repository = 'Chico-IA-Empresa/Chico-Infra';
const stateBucket = `chico-tfstate-${account}-sa-east-1`;
const stateKey = 'dev/terraform.tfstate';
export const exclusiveAttestation = 'ALL_EXTERNAL_WRITERS_QUIESCED';
const stable = value => JSON.stringify(order(value));
function order(value) {
  if (Array.isArray(value)) return value.map(order);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, order(value[k])]));
  return value;
}
function address(resource, instance) {
  return (resource.module ? resource.module + '.' : '') + (resource.mode === 'data' ? 'data.' : '') + resource.type + '.' + resource.name +
    (instance.index_key === undefined ? '' : '[' + JSON.stringify(instance.index_key) + ']');
}
function index(state) {
  const result = new Map();
  for (const resource of state.resources ?? []) for (const instance of resource.instances ?? []) {
    const key = address(resource, instance);
    if (result.has(key)) throw Error('Duplicate state address');
    result.set(key, instance);
  }
  return result;
}
export function validateRepairManifest(manifest, now = new Date()) {
  const start = Date.parse(manifest.createdAt), end = Date.parse(manifest.expiresAt);
  if (manifest.version !== 1 || manifest.account !== account || manifest.scope !== 'dev-exact-six-taints-only' ||
      !/^[a-f0-9]{40}$/.test(manifest.commit) || !Number.isFinite(start) || !Number.isFinite(end) ||
      start > now.getTime() || end <= now.getTime() || end - start !== 24 * 3600_000 ||
      !/^[a-f0-9-]{36}$/.test(manifest.state?.lineage) || !Number.isInteger(manifest.state.serial) || manifest.state.serial < 1 ||
      typeof manifest.state.versionId !== 'string' || !manifest.state.versionId || manifest.state.versionId === 'null' ||
      ![manifest.state.sha256, manifest.hashes?.backend, manifest.hashes?.inputs].every(v => /^[a-f0-9]{64}$/.test(v)) ||
      !Array.isArray(manifest.resources) || manifest.resources.length !== 6 || new Set(manifest.resources.map(r => r.address)).size !== 6 ||
      manifest.resources.some(r => !Object.hasOwn(repairIds, r.address) || typeof r.id !== 'string' || !repairIds[r.address].test(r.id))) {
    throw Error('Invalid exact Dev state repair manifest');
  }
  return manifest;
}
export function validateRepairStart({ manifestBytes, approvedHash, stateBytes, download, backend, inputs, commit, now }) {
  if (!/^[a-f0-9]{64}$/.test(approvedHash) || hash(manifestBytes) !== approvedHash) throw Error('Unapproved repair manifest');
  const manifest = validateRepairManifest(JSON.parse(manifestBytes), now);
  if (manifest.commit !== commit || hash(backend) !== manifest.hashes.backend || hash(inputs) !== manifest.hashes.inputs ||
      hash(stateBytes) !== manifest.state.sha256 || download.VersionId !== manifest.state.versionId) throw Error('Changed repair binding or active state version');
  const state = JSON.parse(stateBytes), resources = index(state);
  if (state.version !== 4 || state.lineage !== manifest.state.lineage || state.serial !== manifest.state.serial) throw Error('Foreign or changed state');
  const tainted = [...resources].filter(([, item]) => item.status === 'tainted').map(([name]) => name).sort();
  if (stable(tainted) !== stable(manifest.resources.map(r => r.address).sort()) ||
      manifest.resources.some(r => resources.get(r.address)?.attributes?.id !== r.id)) throw Error('Taints or ownership differ from reviewed repair');
  return manifest.resources.map(r => r.address);
}
function normalized(state, resourcesToMask) {
  const clone = structuredClone(state);
  delete clone.serial;
  for (const resource of clone.resources ?? []) {
    for (const instance of resource.instances ?? []) if (resourcesToMask.has(address(resource, instance))) delete instance.status;
    resource.instances?.sort((a, b) => stable(a.index_key ?? '').localeCompare(stable(b.index_key ?? '')));
  }
  clone.resources?.sort((a, b) => stable({ ...a, instances: [] }).localeCompare(stable({ ...b, instances: [] })));
  // Terraform serializes check object sets in a different order after untaint.
  // Preserve every object and field; normalize only these set-like arrays.
  for (const result of clone.check_results ?? []) result.objects?.sort((a, b) => stable(a).localeCompare(stable(b)));
  clone.check_results?.sort((a, b) => stable(a).localeCompare(stable(b)));
  return stable(clone);
}
export function verifyRepairProgress(manifest, before, current, completed, now) {
  validateRepairManifest(manifest, now);
  if (!Number.isInteger(completed) || completed < 1 || completed > 6 || before.serial !== manifest.state.serial ||
      current.lineage !== manifest.state.lineage || current.serial !== before.serial + completed) throw Error('Unexpected state repair progression');
  const beforeResources = index(before), currentResources = index(current);
  for (const [i, resource] of manifest.resources.entries()) {
    const old = beforeResources.get(resource.address), next = currentResources.get(resource.address);
    if (old?.status !== 'tainted' || old.attributes?.id !== resource.id || next?.attributes?.id !== resource.id ||
        (i < completed ? next.status !== undefined : next.status !== 'tainted')) throw Error('Unexpected resource status or ID change');
  }
  const mask = new Set(manifest.resources.map(r => r.address));
  if (normalized(before, mask) !== normalized(current, mask)) throw Error('State changed beyond reviewed taint flags and serial');
  return { completed, total: 6, resourceIdsPreserved: true, infrastructureMutations: false };
}
function reviewedIdentity(identity, manifest, authorizedActors) {
  const fields = ['account', 'repository', 'commit', 'actor', 'runId', 'runAttempt', 'workflowRef'];
  if (!identity || Object.keys(identity).length !== fields.length || fields.some(field => typeof identity[field] !== 'string') ||
      identity.account !== account || identity.repository !== repository || identity.commit !== manifest.commit ||
      identity.workflowRef !== `${repository}/.github/workflows/dev-state-repair.yml@refs/heads/main` ||
      !/^[1-9][0-9]*$/.test(identity.runId) || !/^[1-9][0-9]*$/.test(identity.runAttempt) ||
      !Array.isArray(authorizedActors) || !authorizedActors.includes(identity.actor)) throw Error('Unapproved repair executor identity');
}
function reviewedBackend(backend) {
  const text = backend.toString();
  validateDevBackend(text, account);
  if (text.match(/^\s*bucket\s*=\s*"([^"]+)"\s*$/m)?.[1] !== stateBucket) throw Error('Repair backend differs from exact reviewed bucket');
  return { bucket: stateBucket, key: stateKey, region: 'sa-east-1' };
}
export function createExclusiveWindow({ manifestBytes, backend, identity, authorizedActors, attestation, startsAt, expiresAt, now = new Date() }) {
  const manifest = validateRepairManifest(JSON.parse(manifestBytes), now);
  reviewedIdentity(identity, manifest, authorizedActors);
  const start = Date.parse(startsAt), end = Date.parse(expiresAt);
  const utc = value => {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value) || !Number.isFinite(Date.parse(value))) return false;
    const normalized = new Date(value).toISOString();
    return value === normalized || value === normalized.replace('.000Z', 'Z');
  };
  if (attestation !== exclusiveAttestation || !utc(startsAt) || !utc(expiresAt) || !Number.isFinite(start) || !Number.isFinite(end) ||
      start > now.getTime() || end <= now.getTime() || end <= start || end - start > 30 * 60_000 ||
      start < Date.parse(manifest.createdAt) || end > Date.parse(manifest.expiresAt)) throw Error('Missing or expired human exclusive-writer window');
  return { version: 1, attestation, startsAt: new Date(start).toISOString(), expiresAt: new Date(end).toISOString(),
    identity: structuredClone(identity), backend: reviewedBackend(backend), manifestSha256: hash(manifestBytes), backendSha256: hash(backend) };
}
export function validateExclusiveWindow(receipt, context) {
  const expected = createExclusiveWindow({ ...context, attestation: receipt?.attestation, startsAt: receipt?.startsAt, expiresAt: receipt?.expiresAt });
  if (stable(receipt) !== stable(expected)) throw Error('Exclusive-writer receipt binding changed');
  return receipt;
}
function versionId(download) {
  if (typeof download?.VersionId !== 'string' || !download.VersionId || download.VersionId === 'null') throw Error('Versioned state snapshot required');
  return download.VersionId;
}
export function verifyRepairPreStep({ manifestBytes, approvedHash, beforeBytes, expectedBytes, expectedDownload, currentBytes, currentDownload, backend, inputs, receipt, identity, authorizedActors, completed, now = new Date() }) {
  if (!/^[a-f0-9]{64}$/.test(approvedHash) || hash(manifestBytes) !== approvedHash) throw Error('Unapproved repair manifest');
  const manifest = validateRepairManifest(JSON.parse(manifestBytes), now);
  validateExclusiveWindow(receipt, { manifestBytes, backend, identity, authorizedActors, now });
  if (!Number.isInteger(completed) || completed < 0 || completed > 5 || hash(beforeBytes) !== manifest.state.sha256 ||
      hash(backend) !== manifest.hashes.backend || hash(inputs) !== manifest.hashes.inputs ||
      hash(currentBytes) !== hash(expectedBytes) || versionId(currentDownload) !== versionId(expectedDownload)) throw Error('State or binding changed before repair step');
  if (completed === 0) validateRepairStart({ manifestBytes, approvedHash, stateBytes: currentBytes, download: currentDownload, backend, inputs, commit: identity.commit, now });
  else verifyRepairProgress(manifest, JSON.parse(beforeBytes), JSON.parse(currentBytes), completed, now);
  return manifest.resources[completed].address;
}
export function runReviewedRepairStep(context, execute) {
  // This precondition and Terraform's native lock acquisition are NOT atomic.
  // The explicit human exclusive-writer window is required for this interval.
  const address = verifyRepairPreStep(context);
  execute(address);
  return { completed: context.completed + 1, postVerificationRequired: true };
}
export function verifyRepairPostStep({ manifestBytes, approvedHash, beforeBytes, currentBytes, currentDownload, priorDownload, backend, receipt, identity, authorizedActors, completed, now = new Date() }) {
  const manifest = validateRepairManifest(JSON.parse(manifestBytes), now);
  validateExclusiveWindow(receipt, { manifestBytes, backend, identity, authorizedActors, now });
  if (hash(beforeBytes) !== manifest.state.sha256 || hash(manifestBytes) !== approvedHash ||
      versionId(currentDownload) === versionId(priorDownload)) throw Error('Unexpected post-repair snapshot binding');
  const result = verifyRepairProgress(manifest, JSON.parse(beforeBytes), JSON.parse(currentBytes), completed, now);
  return { observedAt: now.toISOString(), runId: receipt.identity.runId, runAttempt: receipt.identity.runAttempt, manifestSha256: receipt.manifestSha256,
    ...result, serial: JSON.parse(currentBytes).serial, stateSha256: hash(currentBytes), stateVersionId: currentDownload.VersionId,
    exclusiveWindowExpiresAt: receipt.expiresAt, atomicPrecondition: false };
}
function githubIdentity() {
  return { account: process.env.ACCOUNT, repository: process.env.GITHUB_REPOSITORY, commit: process.env.GITHUB_SHA,
    actor: process.env.GITHUB_ACTOR, runId: process.env.GITHUB_RUN_ID, runAttempt: process.env.GITHUB_RUN_ATTEMPT, workflowRef: process.env.GITHUB_WORKFLOW_REF };
}
function authorizedActors() {
  return JSON.parse(readFileSync(new URL('../security/dev-environment-review-policy.json', import.meta.url))).reviewers.map(item => item.login);
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [command, manifestFile, ...args] = process.argv.slice(2);
    const manifestBytes = readFileSync(manifestFile), manifest = JSON.parse(manifestBytes);
    if (command === 'check') {
      const [state, download, backend, inputs, commit, approvedHash] = args;
      const addresses = validateRepairStart({ manifestBytes, stateBytes: readFileSync(state), download: JSON.parse(readFileSync(download)), backend: readFileSync(backend), inputs: readFileSync(inputs), commit, approvedHash });
      console.log(JSON.stringify({ exactTaintsVerified: addresses.length, infrastructureMutations: false }));
    } else if (command === 'addresses') {
      validateRepairManifest(manifest);
      console.log(manifest.resources.map(r => r.address).join('\n'));
    } else if (command === 'verify') {
      const [before, current, completed] = args;
      console.log(JSON.stringify(verifyRepairProgress(manifest, JSON.parse(readFileSync(before)), JSON.parse(readFileSync(current)), Number(completed))));
    } else if (command === 'attest') {
      const [receiptFile, backendFile] = args;
      const receipt = createExclusiveWindow({ manifestBytes, backend: readFileSync(backendFile), identity: githubIdentity(), authorizedActors: authorizedActors(),
        attestation: process.env.EXCLUSIVE_WRITER_ATTESTATION, startsAt: process.env.EXCLUSIVE_WINDOW_START_UTC, expiresAt: process.env.EXCLUSIVE_WINDOW_END_UTC });
      writeFileSync(receiptFile, JSON.stringify(receipt, null, 2) + '\n', { mode: 0o600 });
      console.log('Explicit human exclusive-writer declaration bound to this run; quiescence is an operational requirement, not an atomic guarantee.');
    } else if (command === 'step') {
      const [before, expected, expectedDownload, current, currentDownload, backendFile, inputsFile, receiptFile, completed, logFile] = args;
      const context = { manifestBytes, approvedHash: process.env.APPROVED_HASH, beforeBytes: readFileSync(before), expectedBytes: readFileSync(expected),
        expectedDownload: JSON.parse(readFileSync(expectedDownload)), currentBytes: readFileSync(current), currentDownload: JSON.parse(readFileSync(currentDownload)),
        backend: readFileSync(backendFile), inputs: readFileSync(inputsFile), receipt: JSON.parse(readFileSync(receiptFile)), identity: githubIdentity(), authorizedActors: authorizedActors(), completed: Number(completed) };
      const result = runReviewedRepairStep(context, address => {
        const log = openSync(logFile, 'w', 0o600);
        try { execFileSync('terraform', ['-chdir=envs/dev', 'untaint', '-lock-timeout=0s', address], { stdio: ['ignore', log, log] }); }
        finally { closeSync(log); }
      });
      console.log(JSON.stringify(result));
    } else if (command === 'post') {
      const [before, current, currentDownload, priorDownload, backendFile, receiptFile, completed, evidenceFile] = args;
      const evidence = verifyRepairPostStep({ manifestBytes, approvedHash: process.env.APPROVED_HASH, beforeBytes: readFileSync(before), currentBytes: readFileSync(current),
        currentDownload: JSON.parse(readFileSync(currentDownload)), priorDownload: JSON.parse(readFileSync(priorDownload)), backend: readFileSync(backendFile),
        receipt: JSON.parse(readFileSync(receiptFile)), identity: githubIdentity(), authorizedActors: authorizedActors(), completed: Number(completed) });
      writeFileSync(evidenceFile, JSON.stringify(evidence, null, 2) + '\n', { mode: 0o600 });
      // Hashes, version identifiers and booleans only; never state values.
      console.log(JSON.stringify(evidence));
    } else throw Error('Unknown state repair operation');
  } catch (error) {
    console.error('Dev state repair validation failed; private diagnostics only');
    process.exitCode = 1;
  }
}
