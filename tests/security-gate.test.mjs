import test from 'node:test';
import assert from 'node:assert/strict';
import { evaluateSecurity, verifyExceptionSources } from '../scripts/security-gate.mjs';
import { createHash } from 'node:crypto';
const now = new Date('2026-10-27T12:00:00Z');
const entry = { scope: 'dev', check: 'CKV_TEST', resource: 'aws_test.one', reason: 'Explicit architecture choice', compensatingControl: 'Named tested control', reference: 'PRD R01', reviewedBy: 'Codex technical review', reviewedAt: '2026-10-27', expiresAt: '2027-01-25' };
const report = { summary: { passed: 1, failed: 1, parsing_errors: 0, skipped: 0 }, results: { failed_checks: [{ check_id: entry.check, resource: entry.resource }] } };
test('accepts only exact reviewed findings and never grants operational acceptance', () => {
  assert.equal(evaluateSecurity(report, [entry], 'dev', now).operationalAcceptance, false);
});
test('new resource, check, suppression and parsing failures cannot inherit an exception', () => {
  for (const mutate of [r => { r.results.failed_checks[0].resource = 'aws_test.two'; }, r => { r.results.failed_checks[0].check_id = 'OTHER'; }, r => { r.summary.skipped = 1; }, r => { r.summary.parsing_errors = 1; }, r => { r.summary.failed = 0; }, r => { r.summary.passed = 0; }]) {
    const changed = structuredClone(report); mutate(changed); assert.throws(() => evaluateSecurity(changed, [entry], 'dev', now));
  }
});
test('expired, duplicate, future and obsolete exceptions fail closed', () => {
  for (const entries of [[{ ...entry, expiresAt: '2026-10-27' }], [entry, entry], [{ ...entry, reviewedAt: '2026-10-28' }], [entry, { ...entry, resource: 'aws_test.obsolete' }]]) assert.throws(() => evaluateSecurity(report, entries, 'dev', now));
});
test('source edits and path traversal invalidate a reviewed exception across platforms', () => {
  const source = 'synthetic resource\n';
  const item = { sourceFile: 'modules/synthetic/main.tf', sourceSha256: createHash('sha256').update(source).digest('hex') };
  verifyExceptionSources([item], () => Buffer.from(source.replace(/\n/g, '\r\n')));
  assert.throws(() => verifyExceptionSources([item], () => Buffer.from('changed resource\n')), /review required/);
  assert.throws(() => verifyExceptionSources([{ ...item, sourceFile: 'modules/../../private.tf' }], () => source), /Unsafe/);
});
