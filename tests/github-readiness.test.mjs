import test from 'node:test';
import assert from 'node:assert/strict';
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
