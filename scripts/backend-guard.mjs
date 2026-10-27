import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
export function validateBackend(text, account, scope = 'dev') {
  if (!['bootstrap', 'shared', 'dev'].includes(scope)) throw new Error('Approved phase 1 backend scope required');
  if (!/^[0-9]{12}$/.test(account)) throw new Error('Exact approved account required');
  // Deliberately accept only the documented partial backend format. Reject role,
  // endpoint, credentials, duplicate fields and unknown options before init.
  const entries = new Map();
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim() || /^\s*#/.test(line)) continue;
    const match = line.match(/^\s*([a-z_]+)\s*=\s*("[a-zA-Z0-9./_-]+"|true|false|\[\s*"[0-9]{12}"\s*\])\s*$/);
    if (!match || entries.has(match[1])) throw new Error('Unsupported or duplicate backend field');
    entries.set(match[1], match[2]);
  }
  const required = { key: `"${scope}/terraform.tfstate"`, region: '"sa-east-1"', encrypt: 'true', use_lockfile: 'true' };
  if (entries.size !== 6 || !/^"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]"$/.test(entries.get('bucket') ?? '')) throw new Error('Explicit reviewed bucket and six backend fields required');
  for (const [field, expected] of Object.entries(required)) if (entries.get(field) !== expected) throw new Error(`Unsafe backend ${field}`);
  if (!new RegExp(`^\\[\\s*"${account}"\\s*\\]$`).test(entries.get('allowed_account_ids') ?? '')) throw new Error('Foreign backend account');
  return true;
}
export function validateDevBackend(text, account) { return validateBackend(text, account, 'dev'); }
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const scope = process.argv[4] ?? 'dev';
    validateBackend(readFileSync(process.argv[2], 'utf8'), process.argv[3], scope);
    console.log(`${scope} backend isolation verified before init`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
