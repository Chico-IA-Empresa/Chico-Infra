import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const sha256 = data => createHash('sha256').update(data).digest('hex');
const fields = ['plan', 'inputs', 'lockfile', 'backend'];
export function bindPlan({ commit, account, scope, files, now = new Date() }) {
  if (!/^[a-f0-9]{40}$/.test(commit) || !/^[0-9]{12}$/.test(account) || scope !== 'dev') throw new Error('Exact commit, account and Dev scope required');
  return { version: 1, commit, account, scope, createdAt: now.toISOString(), expiresAt: new Date(now.getTime() + 24 * 3600_000).toISOString(), hashes: Object.fromEntries(fields.map(k => [k, sha256(files[k])])) };
}
export function verifyPlan(manifestBytes, approvedHash, context) {
  if (!/^[a-f0-9]{64}$/.test(approvedHash) || sha256(manifestBytes) !== approvedHash) throw new Error('Manifest differs from approved review');
  const actual = JSON.parse(manifestBytes);
  const expected = bindPlan(context);
  const now = (context.now ?? new Date()).getTime();
  if (actual.version !== 1 || actual.commit !== expected.commit || actual.account !== expected.account || actual.scope !== 'dev') throw new Error('Foreign commit/account/scope');
  const start = Date.parse(actual.createdAt), end = Date.parse(actual.expiresAt);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start > now || end <= now || end - start !== 24 * 3600_000) throw new Error('Plan expired or invalid lifetime');
  for (const key of fields) if (actual.hashes?.[key] !== expected.hashes[key]) throw new Error(`Changed ${key}; re-plan and review required`);
  return actual;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [command, directory, commit, account, approvedHash] = process.argv.slice(2);
    const files = Object.fromEntries(fields.map(k => [k, readFileSync(resolve(directory, { plan: 'review.tfplan', inputs: 'ci.auto.tfvars.json', lockfile: '.terraform.lock.hcl', backend: 'backend.hcl' }[k]))]));
    const context = { commit, account, scope: 'dev', files };
    const manifestPath = resolve(directory, 'review-manifest.json');
    if (command === 'create') {
      const bytes = JSON.stringify(bindPlan(context), null, 2) + '\n';
      writeFileSync(manifestPath, bytes, { mode: 0o600 });
      console.log(sha256(bytes));
    } else if (command === 'verify') {
      verifyPlan(readFileSync(manifestPath), approvedHash, context);
      console.log('Approved plan binding verified');
    } else throw new Error('Expected create or verify');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
