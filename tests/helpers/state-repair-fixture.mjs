import { createHash } from 'node:crypto';
export const repairNow = new Date('2026-10-28T12:00:00Z');
export const sha = bytes => createHash('sha256').update(bytes).digest('hex');
export function fixture() {
  const make = (type, name, id, module, index_key) => ({ mode: 'managed', type, name, provider: 'provider["registry.terraform.io/hashicorp/aws"]', ...(module ? { module } : {}), instances: [{ ...(index_key !== undefined ? { index_key } : {}), status: 'tainted', schema_version: 0, identity_schema_version: 0, attributes: { id }, sensitive_attributes: [] }] });
  const state = { version: 4, terraform_version: '1.13.5', serial: 4, lineage: '11111111-1111-1111-1111-111111111111', outputs: { guard: { value: 'synthetic-preserve', type: 'string' } }, resources: [
    make('aws_s3_bucket', 'backup', 'chico-dev-backup-306915830875-sa-east-1', null, 0),
    make('aws_s3_bucket', 'this', 'chico-dev-access-306915830875-sa-east-1', 'module.backup_access_logs[0]'),
    make('aws_ssm_document', 'fixture_status', 'chico-dev-fixture-status', null, 0),
    make('aws_ssm_document', 'session', 'chico-dev-session', null, 0),
    make('aws_ssm_parameter', 'this', '/chico/dev/api/FIXTURE_MODE', 'module.configuration[0]', 'api/FIXTURE_MODE'),
    make('aws_eip', 'this', 'eipalloc-11111111111111111', 'module.dev_box[0]'),
  ], check_results: [
    { object_kind: 'var', config_addr: 'module.dev_box.var.provision_enabled', status: 'pass', objects: [
      { object_addr: 'module.dev_box[1].var.provision_enabled', status: 'pass' },
      { object_addr: 'module.dev_box[0].var.provision_enabled', status: 'pass' },
    ] },
    { object_kind: 'var', config_addr: 'var.account', status: 'pass', objects: [{ object_addr: 'var.account', status: 'pass' }] },
  ] };
  const backend = Buffer.from('synthetic-backend-only'), inputs = Buffer.from('{"synthetic":true}');
  const stateBytes = Buffer.from(JSON.stringify(state) + '\n');
  const resources = state.resources.map(r => ({ address: (r.module ? r.module + '.' : '') + r.type + '.' + r.name + (r.instances[0].index_key !== undefined ? '[' + JSON.stringify(r.instances[0].index_key) + ']' : ''), id: r.instances[0].attributes.id }));
  const manifest = { version: 1, account: '306915830875', scope: 'dev-exact-six-taints-only', commit: 'a'.repeat(40), createdAt: repairNow.toISOString(), expiresAt: new Date(repairNow.getTime() + 24 * 3600_000).toISOString(), state: { lineage: state.lineage, serial: 4, sha256: sha(stateBytes), versionId: 'synthetic-version' }, hashes: { backend: sha(backend), inputs: sha(inputs) }, resources };
  return { state, stateBytes, manifest, backend, inputs };
}
