import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve, relative, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';

const sha = /^[a-f0-9]{40}$/;
const digest = /^sha256:[a-f0-9]{64}$/;
const reference = /^[a-z0-9.-]+(?::[0-9]+)?\/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$/;
function requireThat(condition, field) { if (!condition) throw new Error(`Invalid ${field}`); }
function keys(value, allowed, field) {
  requireThat(value && typeof value === 'object' && !Array.isArray(value), field);
  requireThat(Object.keys(value).every(k => allowed.includes(k)), `${field} fields`);
}
export function checksum(buffer) { return 'sha256:' + createHash('sha256').update(buffer).digest('hex'); }

export function validateManifest(m, { final = false, root, databaseHeads } = {}) {
  keys(m, ['schemaVersion','synthetic','backendSha','frontendSha','images','alembicHeads','bundle','apiContract','mobile','configuration'], 'manifest');
  requireThat(m.schemaVersion === 1 && typeof m.synthetic === 'boolean', 'schemaVersion/synthetic');
  requireThat(!final || !m.synthetic, 'synthetic candidate cannot be promoted');
  requireThat(!final || root, 'final candidate requires bundle/evidence directory');
  if (root) root = resolve(root);
  requireThat(sha.test(m.backendSha) && sha.test(m.frontendSha), 'source SHAs');
  keys(m.images, ['api','workers','frontend'], 'images');
  for (const name of ['api','workers','frontend']) {
    const i = m.images[name];
    keys(i, ['reference','sourceSha','buildId','platform','indexDigest','manifestDigest','localImageId','checks','scan'], name);
    requireThat(reference.test(i.reference) && i.platform === 'linux/arm64', `${name} reference/platform`);
    requireThat(m.synthetic || !i.reference.startsWith('synthetic.invalid/'), `${name} synthetic registry`);
    requireThat(i.sourceSha === (name === 'frontend' ? m.frontendSha : m.backendSha), `${name} sourceSha`);
    requireThat(typeof i.buildId === 'string' && i.buildId.length > 0, `${name} buildId`);
    requireThat(digest.test(i.indexDigest) && digest.test(i.manifestDigest), `${name} OCI digests`);
    requireThat(i.reference.endsWith('@' + i.indexDigest), `${name} digest linkage`);
    requireThat(i.localImageId === null || digest.test(i.localImageId), `${name} localImageId`);
    for (const kind of ['checks','scan']) {
      const e = i[kind];
      keys(e, ['status','evidence','digest'], `${name} ${kind}`);
      requireThat(typeof e.evidence === 'string' && /^[a-zA-Z0-9_./-]+$/.test(e.evidence), `${name} ${kind} evidence`);
      requireThat(m.synthetic || !e.evidence.startsWith('SYNTHETIC'), `${name} synthetic evidence`);
      requireThat(e.digest === i.manifestDigest, `${name} ${kind} digest`);
      requireThat(e.status === 'passed' || (m.synthetic && e.status === 'synthetic'), `${name} ${kind} result`);
      if (root && !m.synthetic) {
        const evidence = resolve(root, e.evidence);
        requireThat(!relative(root,evidence).startsWith('..') && !isAbsolute(relative(root,evidence)), 'evidence path');
        requireThat(readFileSync(evidence).length > 0, 'evidence file');
      }
    }
  }
  requireThat(m.images.api.buildId === m.images.workers.buildId, 'backend buildId');
  requireThat(Array.isArray(m.alembicHeads) && m.alembicHeads.length > 0 && new Set(m.alembicHeads).size === m.alembicHeads.length && m.alembicHeads.every(h => /^[a-zA-Z0-9_]+$/.test(h)), 'alembicHeads');
  if (databaseHeads) requireThat([...databaseHeads].sort().join() === [...m.alembicHeads].sort().join(), 'schema compatibility; no automatic downgrade');
  requireThat(typeof m.apiContract === 'string' && m.apiContract.length > 0, 'apiContract');
  requireThat(m.mobile === 'pending-no-released-clients', 'mobile versions unknown');
  requireThat(Array.isArray(m.configuration), 'configuration');
  for (const c of m.configuration) {
    keys(c, ['name','reference','version'], 'configuration item');
    requireThat(/^[A-Z][A-Z0-9_]*$/.test(c.name) && /^\/chico\/(dev|uat|prod)\/[a-z-]+\/[A-Z][A-Z0-9_]*$/.test(c.reference) && /^[a-zA-Z0-9._-]+$/.test(c.version), 'configuration reference');
  }
  keys(m.bundle, ['version','files','checksum'], 'bundle');
  requireThat(typeof m.bundle.version === 'string' && m.bundle.version.length > 0, 'bundle version');
  keys(m.bundle.files, ['compose.yaml','init-roles.sh','nginx.conf','package_migrate.py','package_seed.py','configuration-matrix.json','manifest.schema.json'], 'bundle files');
  requireThat(Object.keys(m.bundle.files).length === 7 && Object.values(m.bundle.files).every(d => digest.test(d)), 'bundle required hashes');
  const bundleHash = checksum(Buffer.from(JSON.stringify(Object.entries(m.bundle.files).sort())));
  requireThat(m.bundle.checksum === bundleHash, 'bundle checksum');
  if (root) for (const [p, hash] of Object.entries(m.bundle.files)) requireThat(checksum(readFileSync(resolve(root,p))) === hash, `bundle ${p}`);
  return { valid: true, candidateValidated: !m.synthetic && final, promotable: false, awsAcceptance: 'not-evaluated', synthetic: m.synthetic };
}

export function updateComponent(previous, name, image, sourceSha) {
  const next = structuredClone(previous);
  requireThat(['backend','frontend'].includes(name), 'component');
  if (name === 'backend') {
    keys(image, ['api','workers'], 'backend images');
    next.backendSha = sourceSha;
    next.images.api = image.api;
    next.images.workers = image.workers;
  } else { next.frontendSha = sourceSha; next.images.frontend = image; }
  validateManifest(next);
  return next;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const rootIndex = process.argv.indexOf('--root');
    console.log(JSON.stringify(validateManifest(JSON.parse(readFileSync(process.argv[2])), { final: process.argv.includes('--final'), root: rootIndex < 0 ? undefined : process.argv[rootIndex+1] })));
  }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
