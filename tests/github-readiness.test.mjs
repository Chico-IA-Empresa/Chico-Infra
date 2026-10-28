import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validateGithubReadiness } from '../scripts/github-readiness.mjs';

const ready = {
  expectedRepository: 'Chico-IA-Empresa/Chico-Infra', operation: 'plan',
  repository: { full_name: 'Chico-IA-Empresa/Chico-Infra', visibility: 'public', archived: false, default_branch: 'main' },
  branch: {
    required_status_checks: { strict: true, contexts: ['Infra validation', 'Terraform security'] },
    required_pull_request_reviews: { required_approving_review_count: 1 },
    enforce_admins: { enabled: true }, allow_force_pushes: { enabled: false }, allow_deletions: { enabled: false },
  },
  environments: ['infra-plan-dev', 'infra-apply-dev'].map(name => ({
    name, can_admins_bypass: false,
    protection_rules: [{ type: 'required_reviewers', prevent_self_review: true, reviewers: [{ type: 'User', reviewer: { id: 1 } }] }],
    deployment_branch_policy: { custom_branch_policies: true }, branches: [{ name: 'main', type: 'branch' }],
  })),
};

test('accepts complete verified protections before plan or apply', () => {
  for (const operation of ['plan', 'apply']) assert.equal(validateGithubReadiness({ ...ready, operation }), true);
});
test('blocks absent protections, missing security check and visibility drift', () => {
  for (const mutate of [
    c => { c.branch = null; },
    c => { c.environments = []; },
    c => { c.branch.required_status_checks.contexts = ['Infra validation']; },
    c => { c.branch.enforce_admins.enabled = false; },
    c => { c.branch.allow_force_pushes.enabled = true; },
    c => { c.branch.required_pull_request_reviews.required_approving_review_count = 0; },
    c => { c.repository.visibility = 'private'; },
  ]) { const changed = structuredClone(ready); mutate(changed); assert.throws(() => validateGithubReadiness(changed)); }
});
test('blocks bypass, self review, tag deployments and extra branches on either environment', () => {
  for (const index of [0, 1]) for (const mutate of [
    e => { e.can_admins_bypass = true; },
    e => { e.protection_rules[0].prevent_self_review = false; },
    e => { e.protection_rules[0].reviewers = []; },
    e => { e.branches[0].type = 'tag'; },
    e => { e.branches.push({ name: '*', type: 'branch' }); },
    e => { e.deployment_branch_policy.custom_branch_policies = false; },
  ]) { const changed = structuredClone(ready); mutate(changed.environments[index]); assert.throws(() => validateGithubReadiness(changed)); }
});
test('shared/UAT/Prod plan requires its own protected environment', () => {
  for (const scope of ['shared', 'uat', 'prod']) {
    assert.throws(() => validateGithubReadiness({ ...ready, scope }), /environment/);
    const context = structuredClone(ready);
    context.scope = scope;
    context.environments = [{ ...context.environments[0], name: `infra-plan-${scope}` }];
    assert.equal(validateGithubReadiness(context), true);
    assert.throws(() => validateGithubReadiness({ ...context, operation: 'apply' }), /scope/);
  }
});

test('explicit single-maintainer exception permits zero main approvals and preserves every other gate', () => {
  const context = structuredClone(ready);
  context.mainReviewPolicy = JSON.parse(readFileSync(new URL('../security/main-review-policy.json', import.meta.url), 'utf8'));
  context.branch.required_pull_request_reviews.required_approving_review_count = 0;
  assert.equal(validateGithubReadiness(context), true);
  for (const mutate of [
    c => { c.branch.required_status_checks.contexts = ['Infra validation']; },
    c => { c.branch.required_status_checks.strict = false; },
    c => { c.branch.enforce_admins.enabled = false; },
    c => { c.branch.allow_force_pushes.enabled = true; },
    c => { c.branch.allow_deletions.enabled = true; },
    c => { c.branch.required_pull_request_reviews = null; },
    c => { c.environments[0].protection_rules[0].prevent_self_review = false; },
    c => { c.environments[1].can_admins_bypass = true; },
  ]) { const changed = structuredClone(context); mutate(changed); assert.throws(() => validateGithubReadiness(changed)); }
});

test('main review exception rejects another repository, scope or undocumented decision', () => {
  const context = structuredClone(ready);
  context.mainReviewPolicy = JSON.parse(readFileSync(new URL('../security/main-review-policy.json', import.meta.url), 'utf8'));
  context.branch.required_pull_request_reviews.required_approving_review_count = 0;
  for (const change of [{ repository: 'other/repo' }, { scope: 'all-protections' }, { approvedBy: '' }, { approvedOn: '' }, { reason: '' }, { minimumApprovingReviews: -1 }]) {
    assert.throws(() => validateGithubReadiness({ ...context, mainReviewPolicy: { ...context.mainReviewPolicy, ...change } }));
  }
});

function withDevReviewException() {
  const context = structuredClone(ready);
  context.devEnvironmentReviewPolicy = JSON.parse(readFileSync(new URL('../security/dev-environment-review-policy.json', import.meta.url), 'utf8'));
  for (const environment of context.environments) {
    environment.protection_rules[0].prevent_self_review = false;
    environment.protection_rules[0].reviewers = context.devEnvironmentReviewPolicy.reviewers.map(({ type, id }) => ({ type, reviewer: { id } }));
  }
  return context;
}

test('explicit Dev exception allows manual self approval for every listed collaborator', () => {
  for (const operation of ['plan', 'apply']) {
    const context = withDevReviewException();
    context.operation = operation;
    assert.equal(validateGithubReadiness(context), true);
  }
});

test('Dev exception still requires manual approval, exact reviewers, no bypass and main only', () => {
  for (const index of [0, 1]) for (const mutate of [
    e => { e.protection_rules = []; },
    e => { e.protection_rules[0].reviewers = []; },
    e => { e.protection_rules[0].reviewers.pop(); },
    e => { e.protection_rules[0].reviewers.push({ type: 'User', reviewer: { id: 999 } }); },
    e => { e.protection_rules[0].reviewers[0].type = 'Team'; },
    e => { e.protection_rules[0].prevent_self_review = true; },
    e => { e.can_admins_bypass = true; },
    e => { e.branches.push({ name: '*', type: 'branch' }); },
    e => { e.deployment_branch_policy.custom_branch_policies = false; },
  ]) {
    const context = withDevReviewException();
    mutate(context.environments[index]);
    assert.throws(() => validateGithubReadiness(context));
  }
});

test('Dev exception rejects missing authorization, invalid scope or disabled manual review', () => {
  for (const change of [
    { repository: 'other/repo' }, { scope: 'all-environments' }, { reason: '' }, { approvedBy: '' }, { approvedOn: '' },
    { preventSelfReview: true }, { manualApprovalRequired: false }, { reviewerSelection: 'any-public-user' },
    { reviewers: [] }, { reviewers: [{ type: 'User', id: 0, login: 'bad' }] },
    { reviewers: [{ type: 'User', id: 1, login: 'same' }, { type: 'User', id: 1, login: 'duplicate' }] },
  ]) {
    const context = withDevReviewException();
    Object.assign(context.devEnvironmentReviewPolicy, change);
    assert.throws(() => validateGithubReadiness(context));
  }
});

test('Dev approval exception does not relax shared, UAT or Prod self review prevention', () => {
  for (const scope of ['shared', 'uat', 'prod']) {
    const context = withDevReviewException();
    context.scope = scope;
    context.environments = [{ ...context.environments[0], name: `infra-plan-${scope}` }];
    assert.throws(() => validateGithubReadiness(context), /environment/);
    context.environments[0].protection_rules[0].prevent_self_review = true;
    assert.equal(validateGithubReadiness(context), true);
  }
});
