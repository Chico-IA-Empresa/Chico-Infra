import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateDevBackend } from '../scripts/backend-guard.mjs';
const backend = 'bucket = "synthetic-state"\nkey = "dev/terraform.tfstate"\nregion = "sa-east-1"\nencrypt = true\nuse_lockfile = true\nallowed_account_ids = ["123456789012"]\n';
test('strict Dev key, native lock, encryption and account accepted', () => assert.equal(validateDevBackend(backend, '123456789012'), true));
test('foreign key/account/region, duplicate key and unsafe options fail before init', () => {
  for (const changed of [backend.replace('dev/', 'prod/'), backend.replace('123456789012', '999999999999'), backend.replace('sa-east-1', 'us-east-1'), backend.replace('encrypt = true', 'encrypt = false'), backend.replace('use_lockfile = true', 'use_lockfile = false'), backend + 'key = "prod/terraform.tfstate"\n', backend + 'skip_credentials_validation = true\n']) assert.throws(() => validateDevBackend(changed, '123456789012'));
});
