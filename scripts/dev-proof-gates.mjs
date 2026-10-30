import { createHash } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { validateExecutionGates } from './execution-gates.mjs';

export const proofTarget = Object.freeze({
  account: '306915830875', repository: 'Chico-IA-Empresa/Chico-Infra',
  instance: 'i-03b97e256bbba039c', document: 'chico-dev-fixture-status', version: '1',
  documentHash: 'f649ba0c60debb3beafa52828f643b14e5b3d9ea20a9a30f6024ca874e70983e',
});

function onlyKeys(value, keys) {
  return value && !Array.isArray(value) && Object.keys(value).every(key => keys.includes(key));
}

export function validateProofReview(raw, context) {
  const { operation, reviewHash, repository, ref, eventName, commit, roleArn, now = new Date() } = context;
  if (!['build', 'status'].includes(operation) || repository !== proofTarget.repository ||
      ref !== 'refs/heads/main' || eventName !== 'workflow_dispatch' || !/^[a-f0-9]{40}$/.test(commit ?? '')) throw new Error('Invalid proof execution context');
  if (typeof raw !== 'string' || !/^[a-f0-9]{64}$/.test(reviewHash ?? '') ||
      createHash('sha256').update(raw).digest('hex') !== reviewHash) throw new Error('Private proof review hash mismatch');
  const expectedRole = `arn:aws:iam::${proofTarget.account}:role/${operation === 'build' ? 'ci-build-dev' : 'ci-deploy-dev'}`;
  if (roleArn !== expectedRole) throw new Error('Dedicated proof role required');
  const review = JSON.parse(raw);
  if (!onlyKeys(review, ['account_id', 'provision_enabled', 'credit_approval', 'proof']) ||
      !onlyKeys(review.credit_approval, ['account_id', 'all_charges_covered', 'shutdown_reserve_confirmed', 'evidence_reference', 'reviewed_on', 'expires_on'])) throw new Error('Minimal private review metadata required');
  validateExecutionGates(review, { account: proofTarget.account, approved: context.approved, validUntil: context.validUntil, now });
  const proof = review.proof;
  if (!proof || proof.scope !== 'synthetic-dev-infra' || proof.operation !== operation || proof.source_commit !== commit) throw new Error('Proof review source or scope mismatch');
  if (operation === 'build') {
    // No mutable tag, build input from dispatch or business Dockerfile is accepted.
    if (!onlyKeys(proof, ['scope', 'operation', 'source_commit', 'base_platform', 'base_image']) || proof.base_platform !== 'linux/arm64' || typeof proof.base_image !== 'string' ||
        !/^[a-zA-Z0-9./_-]+@sha256:[a-f0-9]{64}$/.test(proof.base_image)) throw new Error('Reviewed ARM64 base digest required');
    return { roleArn: expectedRole, fixtureBase: proof.base_image };
  }
  if (!onlyKeys(proof, ['scope', 'operation', 'source_commit', 'instance_id', 'document_name', 'document_version', 'document_sha256', 'fixture_installed']) ||
      proof.instance_id !== proofTarget.instance || proof.document_name !== proofTarget.document ||
      proof.document_version !== proofTarget.version || proof.document_sha256 !== proofTarget.documentHash ||
      proof.fixture_installed !== true) throw new Error('Installed fixture and exact status document review required');
  return { roleArn: expectedRole };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const result = validateProofReview(process.env.DEV_PROOF_REVIEW_JSON, {
      operation: process.env.OPERATION, reviewHash: process.env.REVIEW_SHA256,
      repository: process.env.GITHUB_REPOSITORY, ref: process.env.GITHUB_REF,
      eventName: process.env.GITHUB_EVENT_NAME, commit: process.env.GITHUB_SHA,
      roleArn: process.env.PROOF_ROLE_ARN, approved: process.env.DEV_EXECUTION_APPROVED,
      validUntil: process.env.FUNDING_REVIEW_VALID_UNTIL,
    });
    if (process.env.GITHUB_OUTPUT) {
      appendFileSync(process.env.GITHUB_OUTPUT, `role_arn=${result.roleArn}\n`);
      if (result.fixtureBase) appendFileSync(process.env.GITHUB_OUTPUT, `fixture_base=${result.fixtureBase}\n`);
    }
    console.log('Private synthetic proof review and execution gates verified');
  } catch {
    // Never echo malformed private metadata or a JSON parser's input excerpt.
    console.error('Synthetic proof release blocked; inspect the private review');
    process.exitCode = 1;
  }
}
