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

test('temporary restore findings require their own scope and exact source-bound exception', () => {
  const restoreEntry = { ...entry, scope: 'restore-staging' };
  assert.equal(evaluateSecurity(report, [restoreEntry], 'restore-staging', now).operationalAcceptance, false);
  assert.throws(() => evaluateSecurity(report, [entry], 'restore-staging', now), /unreviewed/);
  assert.throws(() => evaluateSecurity(report, [restoreEntry], 'dev', now), /unreviewed/);
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

test('reviewed root source addresses accept source or complete instance reports without accepting a new sibling', () => {
  const entries = ['bootstrap', 'ssm'].map(name => ({...entry, resource:`aws_cloudwatch_log_group.dev["${name}"]`, sourceResource:'aws_cloudwatch_log_group.dev', sourceFile:'envs/dev/observability.tf', sourceSha256:'same-reviewed-file-hash'}));
  const source = {summary:{passed:1,failed:1,parsing_errors:0,skipped:0},results:{failed_checks:[{check_id:entry.check,resource:'aws_cloudwatch_log_group.dev'}]}};
  assert.equal(evaluateSecurity(source, entries, 'dev', now).reviewedExceptions, 2);
  const expanded = {summary:{passed:1,failed:2,parsing_errors:0,skipped:0},results:{failed_checks:entries.map(e=>({check_id:e.check,resource:e.resource}))}};
  assert.equal(evaluateSecurity(expanded, entries, 'dev', now).reviewedExceptions, 2);
  const partial = structuredClone(expanded); partial.results.failed_checks.pop(); partial.summary.failed=1;
  assert.throws(()=>evaluateSecurity(partial, entries, 'dev', now), /obsolete/);
  const extra = structuredClone(expanded); extra.results.failed_checks.push({check_id:entry.check,resource:'aws_cloudwatch_log_group.dev["unknown"]'});extra.summary.failed=3;
  assert.throws(()=>evaluateSecurity(extra, entries, 'dev', now), /unreviewed/);
});

test('source address metadata cannot point to a different block, module, wildcard or file owner', () => {
  const item = {...entry, resource:'aws_cloudwatch_log_group.dev[0]', sourceResource:'aws_cloudwatch_log_group.dev', sourceFile:'envs/dev/observability.tf', sourceSha256:'reviewed'};
  for(const change of [{sourceResource:'aws_cloudwatch_log_group.other'},{sourceResource:'aws_cloudwatch_log_group.*'},{sourceResource:'module.host.aws_cloudwatch_log_group.dev'},{sourceFile:'envs/shared/other.tf'}]) {
    assert.throws(()=>evaluateSecurity(report,[{...item,...change}],'dev',now),/source address/);
  }
  const conflicting = {...item,resource:'aws_cloudwatch_log_group.dev[1]',sourceFile:'envs/dev/other.tf'};
  assert.throws(()=>evaluateSecurity(report,[item,conflicting],'dev',now),/conflicting owners/);
});


test('RDS findings remain isolated from other scopes and fail on new findings', () => {
  for (const scope of ['rds-recovery-foundation', 'rds-importer']) {
    const reviewed = {...entry, scope};
    assert.equal(evaluateSecurity(report, [reviewed], scope, now).operationalAcceptance, false);
    assert.throws(() => evaluateSecurity(report, [entry], scope, now), /unreviewed/);
    assert.throws(() => evaluateSecurity(report, [reviewed], 'restore-staging', now), /unreviewed/);
    const changed = structuredClone(report); changed.results.failed_checks[0].resource += '_new';
    assert.throws(() => evaluateSecurity(changed, [reviewed], scope, now), /unreviewed/);
  }
});
const scannerNow = new Date('2026-11-06T14:00:00Z');
const scannerEntry = {...entry, scope:'restore-staging', check:'CKV_AWS_126', resource:'module.host[0].aws_instance.stage[0]', sourceFile:'modules/restore-staging/main.tf', sourceSha256:'a'.repeat(64), reviewedScannerAddress:{resource:'module.host[0].aws_instance.stage', version:'3.3.29', reviewedAt:'2026-11-06', reference:'synthetic exact-address review'}};
const scannerReport = {summary:{passed:1,failed:1,parsing_errors:0,skipped:0,checkov_version:'3.3.29'},results:{failed_checks:[{check_id:'CKV_AWS_126',resource:'module.host[0].aws_instance.stage',file_path:'/../../../modules/restore-staging/main.tf'}]}};
test('reviewed staging scanner address preserves raw finding and source ownership on both platforms', () => {
  for (const file of ['/../../../modules/restore-staging/main.tf', '\\..\\..\\..\\modules\\restore-staging\\main.tf']) {
    const r=structuredClone(scannerReport);r.results.failed_checks[0].file_path=file;
    const result=evaluateSecurity(r,[scannerEntry],'restore-staging',scannerNow);
    assert.equal(result.rawFindings,1);assert.equal(result.reviewedExceptions,1);assert.equal(result.skipped,0);assert.equal(result.operationalAcceptance,false);
  }
  const canonical=structuredClone(scannerReport);canonical.results.failed_checks[0].resource=scannerEntry.resource;
  assert.equal(evaluateSecurity(canonical,[scannerEntry],'restore-staging',scannerNow).rawFindings,1);
});
test('scanner address does not accept another instance module check scope or wildcard', () => {
  for(const change of [{resource:'module.host[1].aws_instance.stage[0]'},{scope:'dev'},{check:'CKV_NEW'},{sourceFile:'modules/foreign/main.tf'},{sourceSha256:'missing'},{reviewedScannerAddress:{...scannerEntry.reviewedScannerAddress,resource:'module.host[*].aws_instance.stage'}},{reviewedScannerAddress:{...scannerEntry.reviewedScannerAddress,version:'other'}},{reviewedScannerAddress:{...scannerEntry.reviewedScannerAddress,reviewedAt:'2026-11-07'}},{reviewedScannerAddress:{...scannerEntry.reviewedScannerAddress,reference:''}}]) {
    assert.throws(()=>evaluateSecurity(scannerReport,[{...scannerEntry,...change}],'restore-staging',scannerNow));
  }
  const sibling=structuredClone(scannerReport);sibling.results.failed_checks[0].resource='module.host[1].aws_instance.stage';
  assert.throws(()=>evaluateSecurity(sibling,[scannerEntry],'restore-staging',scannerNow),/unreviewed/);
});
test('staging alias requires exact scanner version source file and complete reports', () => {
  for(const change of [r=>{r.summary.checkov_version='3.3.30';},r=>{delete r.summary.checkov_version;},r=>{r.results.failed_checks[0].file_path='/../../../modules/foreign/main.tf';},r=>{delete r.results.failed_checks[0].file_path;},r=>{r.summary.skipped=1;},r=>{r.summary.parsing_errors=1;}]) {
    const r=structuredClone(scannerReport);change(r);assert.throws(()=>evaluateSecurity(r,[scannerEntry],'restore-staging',scannerNow));
  }
});
test('address alias cannot hide an additional or obsolete finding', () => {
  const extra=structuredClone(scannerReport);extra.results.failed_checks.push({...extra.results.failed_checks[0],check_id:'NEW'});extra.summary.failed=2;
  assert.throws(()=>evaluateSecurity(extra,[scannerEntry],'restore-staging',scannerNow),/unreviewed/);
  const missing=structuredClone(scannerReport);missing.results.failed_checks=[];missing.summary.failed=0;
  assert.throws(()=>evaluateSecurity(missing,[scannerEntry],'restore-staging',scannerNow),/obsolete/);
});
