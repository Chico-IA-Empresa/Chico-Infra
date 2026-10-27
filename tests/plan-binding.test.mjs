import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { bindPlan, verifyPlan } from '../scripts/plan-binding.mjs';
const context = { commit: 'a'.repeat(40), account: '123456789012', scope: 'dev', now: new Date('2026-10-22T12:00:00Z'), files: { plan: Buffer.from('synthetic plan'), inputs: Buffer.from('{}'), backend: Buffer.from('synthetic backend'), lockfile: Buffer.from('lock') } };
const bytes = Buffer.from(JSON.stringify(bindPlan(context)));
const hash = createHash('sha256').update(bytes).digest('hex');
test('same approved saved plan and inputs accepted', () => assert.equal(verifyPlan(bytes, hash, context).scope, 'dev'));
test('altered plan, inputs, backend or lockfile rejected', () => {
  for (const field of Object.keys(context.files)) assert.throws(() => verifyPlan(bytes, hash, { ...context, files: { ...context.files, [field]: Buffer.from('tampered') } }), /Changed/);
});
test('foreign account, revision, scope and unapproved manifest rejected', () => {
  for (const change of [{ account: '999999999999' }, { commit: 'b'.repeat(40) }, { scope: 'prod' }]) assert.throws(() => verifyPlan(bytes, hash, { ...context, ...change }));
  assert.throws(() => verifyPlan(Buffer.from(bytes.toString().replace('123456789012', '999999999999')), hash, context), /approved/);
});
test('expired and future plans rejected', () => {
  for (const time of ['2026-10-23T12:00:00Z', '2026-10-22T11:59:59Z']) assert.throws(() => verifyPlan(bytes, hash, { ...context, now: new Date(time) }), /expired|lifetime/);
});
