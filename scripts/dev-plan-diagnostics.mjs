import { lstatSync, realpathSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

// A failed plan may contain private input values. Never publish it in Actions.
export function preservePlanFailure(status, env, execute = execFileSync) {
  if (!/^(?:0|[1-9][0-9]{0,2})$/.test(String(status)) || Number(status) > 255) throw Error('Invalid exit status');
  if (Number(status) === 0 || env.OPERATION !== 'plan') return { uploaded: false };
  if (env.ACCOUNT !== '306915830875' || env.REVIEW_BUCKET !== 'chico-infra-review-306915830875-sa-east-1' ||
      env.GITHUB_REPOSITORY !== 'Chico-IA-Empresa/Chico-Infra' || env.GITHUB_REF !== 'refs/heads/main' ||
      env.GITHUB_WORKFLOW_REF !== 'Chico-IA-Empresa/Chico-Infra/.github/workflows/dev-reviewed-plan-apply.yml@refs/heads/main' ||
      !/^[a-f0-9]{40}$/.test(env.GITHUB_SHA ?? '') || !/^[1-9][0-9]*$/.test(env.GITHUB_RUN_ID ?? '') || !env.RUNNER_TEMP) throw Error('Foreign diagnostic context');
  const directory = resolve(env.RUNNER_TEMP), log = join(directory, 'plan.log');
  const stat = lstatSync(log);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size < 1 || stat.size > 16 * 1024 * 1024 ||
      realpathSync(directory) !== directory || realpathSync(log) !== log) throw Error('Unsafe private log');
  const key = `dev/${env.GITHUB_SHA}/${env.GITHUB_RUN_ID}/diagnostics/plan-failure.log`;
  const raw = execute('aws', ['s3api', 'put-object', '--bucket', env.REVIEW_BUCKET, '--expected-bucket-owner', env.ACCOUNT,
    '--key', key, '--body', log, '--server-side-encryption', 'AES256', '--region', 'sa-east-1', '--no-cli-pager',
    '--query', '{VersionId:VersionId}', '--output', 'json'], { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8', timeout: 30_000, maxBuffer: 64 * 1024 });
  const result = JSON.parse(raw);
  if (typeof result.VersionId !== 'string' || !result.VersionId || result.VersionId === 'null' ||
      Buffer.byteLength(result.VersionId, 'utf8') > 1024 || /[\u0000-\u001f\u007f-\u009f]/u.test(result.VersionId)) throw Error('Versioned diagnostic upload required');
  return { uploaded: true, key, versionId: result.VersionId };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { console.log(JSON.stringify(preservePlanFailure(process.argv[2], process.env))); }
  catch { console.error('Private plan diagnostics could not be preserved; no log contents published.'); process.exitCode = 1; }
}
