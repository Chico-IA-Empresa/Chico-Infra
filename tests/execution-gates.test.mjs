import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validateExecutionGates } from '../scripts/execution-gates.mjs';
const context = { account: '123456789012', approved: 'true', validUntil: '2026-10-24T00:00:00Z', now: new Date('2026-10-22T12:00:00Z') };
const inputs = { account_id: context.account, provision_enabled: true, credit_approval: { account_id: context.account, reviewed_on: '2026-10-22', expires_on: '2026-10-23', all_charges_covered: true, shutdown_reserve_confirmed: true, evidence_reference: 'synthetic-unit-test-not-an-approval' } };
test('matching current review and external release accepted', () => assert.equal(validateExecutionGates(inputs, context), true));
test('saved plan cannot bypass credit expiry despite a still-valid outside release', () => {
  assert.throws(() => validateExecutionGates(inputs, { ...context, now: new Date('2026-10-23T00:00:00Z') }), /Credit review/);
});
test('foreign account, missing release and disabled provisioning refused', () => {
  assert.throws(() => validateExecutionGates(inputs, { ...context, account: '999999999999' }));
  assert.throws(() => validateExecutionGates(inputs, { ...context, approved: 'false' }));
  assert.throws(() => validateExecutionGates({ ...inputs, provision_enabled: false }, context));
  assert.throws(() => validateExecutionGates(inputs, { ...context, validUntil: '2026-10-22T00:00:00Z' }));
});
test('incomplete or uncovered private review refused', () => {
  for (const changes of [{ all_charges_covered: false }, { shutdown_reserve_confirmed: false }, { evidence_reference: ' ' }, { account_id: '999999999999' }]) assert.throws(() => validateExecutionGates({ ...inputs, credit_approval: { ...inputs.credit_approval, ...changes } }, context));
});
test('invalid dates and future review refused', () => {
  for (const changes of [{ reviewed_on: '2026-10-23' }, { reviewed_on: '2026-02-30' }, { expires_on: 'invalid' }]) assert.throws(() => validateExecutionGates({ ...inputs, credit_approval: { ...inputs.credit_approval, ...changes } }, context));
});
