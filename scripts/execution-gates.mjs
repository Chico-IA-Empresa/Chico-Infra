import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

function utcDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error('Invalid credit review date');
  const milliseconds = Date.parse(`${value}T00:00:00Z`);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toISOString().slice(0, 10) !== value) throw new Error('Invalid credit review date');
  return milliseconds;
}
export function validateExecutionGates(inputs, { account, approved, validUntil, now = new Date() }) {
  const current = now.getTime();
  if (!Number.isFinite(current) || !/^[0-9]{12}$/.test(account) || inputs.account_id !== account) throw new Error('Execution account mismatch');
  if (approved !== 'true' || inputs.provision_enabled !== true) throw new Error('Dev execution not explicitly enabled');
  const outsideExpiry = Date.parse(validUntil);
  if (!validUntil || !Number.isFinite(outsideExpiry) || outsideExpiry <= current) throw new Error('External funding release expired or missing');
  const review = inputs.credit_approval;
  if (!review || review.account_id !== account || review.all_charges_covered !== true || review.shutdown_reserve_confirmed !== true || typeof review.evidence_reference !== 'string' || !review.evidence_reference.trim()) throw new Error('Complete private credit review metadata required');
  if (utcDate(review.reviewed_on) > current || utcDate(review.expires_on) <= current) throw new Error('Credit review is future-dated or expired; re-plan and review');
  return true;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    validateExecutionGates(JSON.parse(readFileSync(process.argv[2], 'utf8')), { account: process.env.ACCOUNT, approved: process.env.DEV_EXECUTION_APPROVED, validUntil: process.env.FUNDING_REVIEW_VALID_UNTIL });
    console.log('Execution release and current credit metadata verified');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
