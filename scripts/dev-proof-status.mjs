import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { proofTarget } from './dev-proof-gates.mjs';

export function verifyStatusOutput(invocation) {
  if (invocation.Status !== 'Success' || invocation.ResponseCode !== 0 || invocation.StandardErrorContent?.trim()) throw new Error('Fixed status command did not succeed cleanly');
  const lines = (invocation.StandardOutputContent ?? '').trim().split(/\r?\n/).map(line => line.trim());
  if (lines[0] !== 'active' || lines[1] !== 'active' ||
      JSON.stringify(lines.slice(2).sort()) !== JSON.stringify(['postgres', 'proxy-local', 'static'])) throw new Error('Required local synthetic services absent');
  return true;
}

export async function runStatusProof({ aws, sleep = ms => new Promise(done => setTimeout(done, ms)), now = () => Date.now() }) {
  const identity = aws('sts', 'get-caller-identity', {});
  if (identity.Account !== proofTarget.account || !/^arn:aws:sts::306915830875:assumed-role\/ci-deploy-dev\/[^/]+$/.test(identity.Arn ?? '')) throw new Error('Dedicated status identity required');
  const sent = aws('ssm', 'send-command', {
    InstanceIds: [proofTarget.instance], DocumentName: proofTarget.document,
    DocumentVersion: proofTarget.version, DocumentHash: proofTarget.documentHash, DocumentHashType: 'Sha256',
    Comment: 'Phase1 fixed synthetic local fixture status; no business commands',
    TimeoutSeconds: 120, MaxConcurrency: '1', MaxErrors: '0',
    CloudWatchOutputConfig: { CloudWatchLogGroupName: '/chico/dev/ssm', CloudWatchOutputEnabled: true },
  });
  const commandId = sent.Command?.CommandId;
  if (!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(commandId ?? '')) throw new Error('SSM did not return a command ID');
  const deadline = now() + 240_000;
  for (let attempt = 0; attempt < 24 && now() < deadline; attempt++) {
    let invocation;
    try { invocation = aws('ssm', 'get-command-invocation', { CommandId: commandId, InstanceId: proofTarget.instance }); }
    catch (error) { if (error.awsCode !== 'InvocationDoesNotExist') throw error; }
    if (invocation?.Status === 'Success') {
      verifyStatusOutput(invocation);
      return { commandId, status: 'Success', responseCode: 0, localSyntheticServicesVerified: true };
    }
    if (invocation && !['Pending', 'Delayed', 'InProgress'].includes(invocation.Status)) throw new Error('SSM reached a failed or unknown terminal state');
    if (attempt < 23 && now() < deadline) await sleep(Math.min(10_000, Math.max(0, deadline - now())));
  }
  throw new Error('SSM status polling deadline exceeded');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const directory = mkdtempSync(join(tmpdir(), 'chico-proof-status-'));
  try {
    const aws = (service, operation, parameters) => {
      const input = join(directory, 'request.json');
      writeFileSync(input, JSON.stringify(parameters), { mode: 0o600 });
      try {
        return JSON.parse(execFileSync('aws', [service, operation, '--cli-input-json', `file://${input}`, '--region', 'sa-east-1', '--no-cli-pager', '--output', 'json', '--cli-connect-timeout', '5', '--cli-read-timeout', '10'], {
          encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 20_000, maxBuffer: 1024 * 1024,
          env: { ...process.env, AWS_MAX_ATTEMPTS: '2', AWS_RETRY_MODE: 'standard' },
        }));
      } catch (error) {
        const captured = error.stderr?.toString() ?? '';
        writeFileSync(join(directory, 'error-private.log'), captured, { mode: 0o600 });
        const safe = new Error('AWS status call failed');
        if (/\(InvocationDoesNotExist\)/.test(captured)) safe.awsCode = 'InvocationDoesNotExist';
        throw safe;
      }
    };
    console.log(JSON.stringify(await runStatusProof({ aws })));
  } catch {
    console.error('Synthetic fixed status proof failed; command output is not published');
    process.exitCode = 1;
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
