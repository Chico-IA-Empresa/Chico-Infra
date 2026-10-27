import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

export function verifyExceptionSources(exceptions, readSource) {
  for (const entry of exceptions) {
    if (!/^(bootstrap|envs|modules)\/[a-zA-Z0-9_./-]+\.tf$/.test(entry.sourceFile ?? '') || entry.sourceFile.split('/').includes('..')) throw new Error('Unsafe exception source path');
    const text = readSource(entry.sourceFile).toString().replace(/\r\n/g, '\n');
    if (createHash('sha256').update(text).digest('hex') !== entry.sourceSha256) throw new Error(`Source changed; exception review required: ${entry.sourceFile}`);
  }
}

export function evaluateSecurity(report, exceptions, scope, now = new Date()) {
  if (!['bootstrap', 'shared', 'dev'].includes(scope)) throw new Error('Unknown security scope');
  if (!report?.summary || report.summary.parsing_errors !== 0 || report.summary.skipped !== 0 ||
      !Number.isInteger(report.summary.passed) || report.summary.passed < 1 ||
      !Array.isArray(report.results?.failed_checks) || report.summary.failed !== report.results.failed_checks.length) {
    throw new Error('Incomplete scan, parsing failure or scanner suppression');
  }
  const scoped = exceptions.filter(e => e.scope === scope);
  const signatures = new Set();
  for (const entry of scoped) {
    const signature = `${entry.check}:${entry.resource}`;
    if (signatures.has(signature) || !entry.reason?.trim() || !entry.compensatingControl?.trim() ||
        !entry.reference?.trim() || entry.reviewedBy !== 'Codex technical review' ||
        !Number.isFinite(Date.parse(entry.reviewedAt)) || Date.parse(entry.reviewedAt) > now.getTime() ||
        !Number.isFinite(Date.parse(entry.expiresAt)) || Date.parse(entry.expiresAt) <= now.getTime()) {
      throw new Error(`Invalid, duplicate or expired exception: ${signature}`);
    }
    signatures.add(signature);
  }
  const failures = report.results.failed_checks;
  const unreviewed = failures.filter(f => !signatures.has(`${f.check_id}:${f.resource}`));
  const actual = new Set(failures.map(f => `${f.check_id}:${f.resource}`));
  const obsolete = scoped.filter(e => !actual.has(`${e.check}:${e.resource}`));
  if (unreviewed.length || obsolete.length) throw new Error(JSON.stringify({ unreviewed: unreviewed.map(f => `${f.check_id}:${f.resource}`), obsolete: obsolete.map(e => `${e.check}:${e.resource}`) }));
  return { scope, passed: report.summary.passed, rawFindings: failures.length, reviewedExceptions: scoped.length, skipped: 0, operationalAcceptance: false };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [file, scope] = process.argv.slice(2);
    const report = JSON.parse(readFileSync(file, 'utf8'));
    const exceptions = JSON.parse(readFileSync(new URL('../security/dev-exceptions.json', import.meta.url), 'utf8'));
    verifyExceptionSources(exceptions, file => readFileSync(new URL(`../${file}`, import.meta.url)));
    console.log(JSON.stringify(evaluateSecurity(report, exceptions, scope)));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
