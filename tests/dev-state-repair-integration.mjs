// Native Terraform edits a synthetic LOCAL state. No provider or AWS API calls.
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, basename, join, isAbsolute, delimiter } from 'node:path';
import { fixture, sha } from './helpers/state-repair-fixture.mjs';
import { verifyRepairProgress, exclusiveAttestation } from '../scripts/dev-state-repair.mjs';
const reports = fileURLToPath(new URL('../reports/', import.meta.url));
mkdirSync(reports, { recursive: true });
const allowed = realpathSync(reports), directory = mkdtempSync(join(allowed, 'state-repair-test-'));
const terraform = process.env.TERRAFORM_BINARY ?? 'terraform';
let original, statePath;
try {
  const { state, manifest } = fixture();
  original = state;
  // Backend bytes and S3 VersionIds below are synthetic validation inputs only.
  // Terraform itself uses only main.tf's implicit LOCAL backend in this test.
  const backend = Buffer.from('bucket = "chico-tfstate-306915830875-sa-east-1"\nkey = "dev/terraform.tfstate"\nregion = "sa-east-1"\nencrypt = true\nuse_lockfile = true\nallowed_account_ids = ["306915830875"]\n');
  const inputs = Buffer.from('{"synthetic":true}');
  manifest.hashes.backend = sha(backend);
  const now = new Date();
  manifest.createdAt = now.toISOString();
  manifest.expiresAt = new Date(now.getTime() + 24 * 3600_000).toISOString();
  const manifestBytes = Buffer.from(JSON.stringify(manifest));
  const identity = { account: '306915830875', repository: 'Chico-IA-Empresa/Chico-Infra', commit: manifest.commit, actor: 'FelipeTorresHora', runId: '12345', runAttempt: '1', workflowRef: 'Chico-IA-Empresa/Chico-Infra/.github/workflows/dev-state-repair.yml@refs/heads/main' };
  const localRoot = join(directory, 'envs', 'dev');
  mkdirSync(localRoot, { recursive: true });
  writeFileSync(join(localRoot, 'main.tf'), 'terraform { required_version = "= 1.13.5" }\n');
  statePath = join(localRoot, 'terraform.tfstate');
  const beforeBytes = Buffer.from(JSON.stringify(state) + '\n');
  writeFileSync(statePath, beforeBytes);
  const files = Object.fromEntries(['manifest', 'backend', 'inputs', 'receipt', 'before', 'expected', 'expected-download', 'pre', 'pre-download', 'current-download', 'evidence', 'untaint.log'].map(name => [name, join(directory, name)]));
  for (const [name, bytes] of Object.entries({ manifest: manifestBytes, backend, inputs, before: beforeBytes, expected: beforeBytes, 'expected-download': JSON.stringify({ VersionId: 'synthetic-version' }) })) writeFileSync(files[name], bytes);
  const env = { ...process.env, ACCOUNT: identity.account, GITHUB_REPOSITORY: identity.repository, GITHUB_SHA: identity.commit, GITHUB_ACTOR: identity.actor,
    GITHUB_RUN_ID: identity.runId, GITHUB_RUN_ATTEMPT: identity.runAttempt, GITHUB_WORKFLOW_REF: identity.workflowRef,
    APPROVED_HASH: sha(manifestBytes), EXCLUSIVE_WRITER_ATTESTATION: exclusiveAttestation, EXCLUSIVE_WINDOW_START_UTC: now.toISOString(), EXCLUSIVE_WINDOW_END_UTC: new Date(now.getTime() + 30 * 60_000).toISOString() };
  const pathKey = Object.keys(env).find(key => key.toLowerCase() === 'path') ?? 'PATH';
  if (isAbsolute(terraform)) env[pathKey] = dirname(terraform) + delimiter + (env[pathKey] ?? '');
  const cli = fileURLToPath(new URL('../scripts/dev-state-repair.mjs', import.meta.url));
  const run = (...args) => execFileSync(process.execPath, [cli, ...args], { cwd: directory, env, stdio: ['ignore', 'pipe', 'pipe'] });
  run('attest', files.manifest, files.receipt, files.backend);
  for (let i = 0; i < 6; i++) {
    writeFileSync(files.pre, readFileSync(statePath));
    writeFileSync(files['pre-download'], readFileSync(files['expected-download']));
    // The production CLI calls native Terraform, using the implicit LOCAL
    // backend above. No backend.hcl is installed in this Terraform directory.
    run('step', files.manifest, files.before, files.expected, files['expected-download'], files.pre, files['pre-download'], files.backend, files.inputs, files.receipt, String(i), files['untaint.log']);
    verifyRepairProgress(manifest, state, JSON.parse(readFileSync(statePath)), i + 1, now);
    writeFileSync(files['current-download'], JSON.stringify({ VersionId: `synthetic-version-${i + 1}` }));
    run('post', files.manifest, files.before, statePath, files['current-download'], files['expected-download'], files.backend, files.receipt, String(i + 1), files.evidence);
    writeFileSync(files.expected, readFileSync(statePath));
    writeFileSync(files['expected-download'], readFileSync(files['current-download']));
  }
  console.log('Native Terraform local-state integration: six guarded untaints; all IDs/content preserved; synthetic window/version bindings; no AWS calls.');
} catch (error) {
  console.error('Native local-state repair integration failed: ' + error.message);
  const current = statePath ? JSON.parse(readFileSync(statePath)) : null;
  const differences = [];
  function compare(a, b, path = '') {
    if (a && b && typeof a === 'object' && typeof b === 'object') {
      for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) compare(a[key], b[key], path + '/' + key);
    } else if (JSON.stringify(a) !== JSON.stringify(b)) differences.push({ path, beforeType: Array.isArray(a) ? 'array' : typeof a, afterType: Array.isArray(b) ? 'array' : typeof b });
  }
  compare(original, current);
  console.error(JSON.stringify({ syntheticStateDifferences: differences }));
  process.exitCode = 1;
} finally {
  const target = realpathSync(directory);
  if (dirname(target) !== allowed || !basename(target).startsWith('state-repair-test-')) throw Error('Unsafe temporary cleanup target');
  rmSync(target, { recursive: true });
}
