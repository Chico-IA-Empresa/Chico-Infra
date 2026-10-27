import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checksum, validateManifest } from './package-manifest.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const bundleSources = {'compose.yaml': resolve(root,'package/compose.yaml'), 'nginx.conf': resolve(root,'package/nginx.conf'),
    'init-roles.sh': resolve(root,'package/init-roles.sh'), 'package_migrate.py': resolve(root,'../backend/scripts/package_migrate.py'),
    'package_seed.py': resolve(root,'../backend/scripts/package_seed.py'), 'configuration-matrix.json': resolve(root,'package/configuration-matrix.json'),
    'manifest.schema.json': resolve(root,'package/manifest.schema.json')};
export function syntheticManifest({ sources = bundleSources } = {}) {
  const backendSha = '1'.repeat(40), frontendSha = '2'.repeat(40);
  const images = Object.fromEntries(['api','workers','frontend'].map((name, n) => {
    const digest = 'sha256:' + String(n+1).repeat(64);
    return [name, {reference: `synthetic.invalid/chico-${name}@${digest}`, sourceSha: name === 'frontend' ? frontendSha : backendSha,
      buildId: name === 'frontend' ? 'synthetic-frontend-build' : 'synthetic-backend-build', platform: 'linux/arm64', indexDigest: digest,
      manifestDigest: digest, localImageId: null,
      checks: {status: 'synthetic', evidence: 'SYNTHETIC-NOT-A-BUILD', digest}, scan: {status: 'synthetic', evidence: 'SYNTHETIC-NOT-A-SCAN', digest}}];
  }));
  const files = Object.fromEntries(Object.entries(sources).map(([name,p]) => [name,checksum(readFileSync(p))]));
  return {schemaVersion: 1, synthetic: true, backendSha, frontendSha, images,
    alembicHeads: ['SYNTHETIC_NOT_OBSERVED'], apiContract: 'existing-web-unversioned-mobile-pending', mobile: 'pending-no-released-clients',
    configuration: [{name: 'DATABASE_URL', reference: '/chico/dev/api/DATABASE_URL', version: 'synthetic-v1'}],
    bundle: {version: 'dev-package-v1', files, checksum: checksum(Buffer.from(JSON.stringify(Object.entries(files).sort())))}};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const manifest = syntheticManifest();
  validateManifest(manifest);
  const output = resolve(root, 'package/manifest.synthetic.json');
  writeFileSync(output, JSON.stringify(manifest,null,2) + '\n');
  if (process.argv[2]) {
    const destination = resolve(process.argv[2]);
    mkdirSync(destination, {recursive:false});
    for (const [name,p] of Object.entries(bundleSources)) copyFileSync(p,resolve(destination,name));
    copyFileSync(output,resolve(destination,'manifest.json'));
    validateManifest(manifest, {root:destination});
    const files = {...manifest.bundle.files, 'manifest.json':checksum(readFileSync(output))};
    writeFileSync(resolve(destination,'bundle-index.json'), JSON.stringify({synthetic:true,promotable:false,files,checksum:checksum(Buffer.from(JSON.stringify(Object.entries(files).sort())))},null,2)+'\n');
  }
  console.log(JSON.stringify({synthetic:true, promotable:false, bundleChecksum:manifest.bundle.checksum}));
}
