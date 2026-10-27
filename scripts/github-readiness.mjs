import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export function validateGithubReadiness({ repository, branch, environments, expectedRepository, operation, scope = 'dev' }) {
  if (!['plan', 'apply'].includes(operation)) throw new Error('Invalid operation');
  if (!['dev', 'shared', 'uat', 'prod'].includes(scope) || (scope !== 'dev' && operation !== 'plan')) throw new Error('Invalid scope/operation');
  if (repository.full_name !== expectedRepository || repository.visibility !== 'public' || repository.archived) {
    throw new Error('Expected active public infrastructure repository');
  }
  if (repository.default_branch !== 'main' || !branch?.required_status_checks?.strict ||
      !branch.required_status_checks.contexts.includes('Infra validation') ||
      !branch.required_status_checks.contexts.includes('Terraform security') ||
      !branch.required_pull_request_reviews || branch.required_pull_request_reviews.required_approving_review_count < 1 ||
      !branch.enforce_admins?.enabled || branch.allow_force_pushes?.enabled !== false || branch.allow_deletions?.enabled !== false) {
    throw new Error('Main branch protection and required checks are not ready');
  }
  const requiredEnvironments = scope === 'dev' ? ['infra-plan-dev', 'infra-apply-dev'] : [`infra-plan-${scope}`];
  for (const name of requiredEnvironments) {
    const environment = environments.find(item => item.name === name);
    const reviewers = environment?.protection_rules?.find(rule => rule.type === 'required_reviewers');
    if (!reviewers?.prevent_self_review || !reviewers.reviewers?.length || environment.can_admins_bypass !== false ||
        environment.deployment_branch_policy?.custom_branch_policies !== true ||
        environment.branches?.length !== 1 || environment.branches[0].name !== 'main' || environment.branches[0].type !== 'branch') {
      throw new Error(`Protected environment ${name} is not ready`);
    }
  }
  return true;
}

async function github(path) {
  // Governance metadata is public. No administrative token is needed, and AWS
  // credentials/OIDC are still unavailable until this entire preflight succeeds.
  const response = await fetch(`https://api.github.com/${path}`, {
    headers: { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' },
    signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) throw new Error(`GitHub metadata unavailable (${response.status}): ${path}`);
  return response.json();
}

export function normalizeBranchProtection(rules) {
  const exact = rules.filter(rule => rule.pattern === 'main');
  if (exact.length !== 1) throw new Error('Exactly one main branch protection rule is required');
  const rule = exact[0];
  return {
    required_status_checks: { strict: rule.requiresStrictStatusChecks, contexts: rule.requiresStatusChecks ? rule.requiredStatusCheckContexts : [] },
    required_pull_request_reviews: rule.requiresApprovingReviews ? { required_approving_review_count: rule.requiredApprovingReviewCount } : null,
    enforce_admins: { enabled: rule.isAdminEnforced },
    allow_force_pushes: { enabled: rule.allowsForcePushes },
    allow_deletions: { enabled: rule.allowsDeletions },
  };
}

function readBranchProtection() {
  // REST protection details require Administration:read even for public repos.
  // Public GraphQL governance metadata works with the standard read-only job
  // token. gh handles credentials internally; no token is returned or logged.
  const query = '{repository(owner:"Chico-IA-Empresa",name:"Chico-Infra"){branchProtectionRules(first:100){pageInfo{hasNextPage} nodes{pattern isAdminEnforced requiresStatusChecks requiresStrictStatusChecks requiredStatusCheckContexts requiresApprovingReviews requiredApprovingReviewCount allowsForcePushes allowsDeletions}}}}';
  const result = JSON.parse(execFileSync('gh', ['api', 'graphql', '-f', `query=${query}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 15000 }));
  const rules = result.data?.repository?.branchProtectionRules;
  if (!rules || rules.pageInfo.hasNextPage) throw new Error('Incomplete branch protection metadata');
  return normalizeBranchProtection(rules.nodes);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const repository = process.env.GITHUB_REPOSITORY;
    if (repository !== 'Chico-IA-Empresa/Chico-Infra') throw new Error('Unexpected repository');
    const base = `repos/${repository}`;
    const metadata = await github(base);
    const branch = readBranchProtection();
    const scope = process.argv[3] ?? 'dev';
    const names = scope === 'dev' ? ['infra-plan-dev', 'infra-apply-dev'] : [`infra-plan-${scope}`];
    const environments = await Promise.all(names.map(async name => {
      const environment = await github(`${base}/environments/${name}`);
      environment.branches = (await github(`${base}/environments/${name}/deployment-branch-policies`)).branch_policies;
      return environment;
    }));
    validateGithubReadiness({ repository: metadata, branch, environments, expectedRepository: repository, operation: process.argv[2], scope });
    console.log('GitHub branch and environment protections verified before OIDC');
  } catch (error) {
    console.error('GitHub readiness blocked: ' + (error.stderr?.toString().trim() || error.message));
    process.exitCode = 1;
  }
}
