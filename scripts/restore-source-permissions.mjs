// Offline candidates only. The private executor must bind this input and its
// SHA256 to the reviewed restore plan; this module never calls AWS.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const rootPrefix = 'pgbackrest/sofascore-postgres/';
const document = Statement => ({ Version: '2012-10-17', Statement });

export function restoreSourcePolicies(manifest) {
  if (manifest?.bucket !== 'chico-backup' || manifest.account !== '306915830875' || manifest.region !== 'sa-east-1' ||
      manifest.sourceReadOnly !== true || manifest.allSelectedPrefixListingsNotTruncated !== true ||
      manifest.inspectedMetadataVersionsUnchanged !== true || !Array.isArray(manifest.objects) ||
      !manifest.objects.length || manifest.objects.length !== manifest.objectCount) throw Error('Incomplete pinned source manifest');
  const seen = new Set(), prefixes = new Set(), parts = [];
  for (const object of manifest.objects) {
    const { key, versionId, bytes } = object;
    if (typeof key !== 'string' || !key.startsWith(rootPrefix) || /[*?\x00-\x1f\x7f]/.test(key) || key.includes('..') ||
        typeof versionId !== 'string' || !versionId || versionId === 'null' || /[\s\x00-\x1f\x7f]/.test(versionId) ||
        !Number.isSafeInteger(bytes) || bytes < 1 || seen.has(key)) throw Error('Invalid or duplicate pinned source object');
    seen.add(key);
    // Only selected full/diff directories need directory listing; metadata and
    // WAL use exact keys. Never grant a list of the entire legacy repository.
    const backupDirectory = key.match(/^(pgbackrest\/sofascore-postgres\/backup\/main\/[0-9]{8}-[0-9]{6}F(?:_[0-9]{8}-[0-9]{6}[DI])?\/)/)?.[1];
    prefixes.add(backupDirectory ?? key);
    const statement = {
      Effect: 'Allow', Action: ['s3:GetObjectVersion'], Resource: `arn:aws:s3:::chico-backup/${key}`,
      Condition: { StringEquals: { 's3:VersionId': versionId } },
    };
    let part = parts.at(-1);
    if (!part || JSON.stringify(document([...part.Statement, statement])).length > 6000) {
      part = document([]); parts.push(part);
    }
    part.Statement.push(statement);
    if (JSON.stringify(part).length > 6000) throw Error('Pinned object policy exceeds quota');
  }
  if (parts.length > 9) throw Error('Source selection exceeds reviewed role policy quota; split execution scope before granting');
  return { source_version_policy_documents: parts.map(p => JSON.stringify(p)), source_list_prefixes: [...prefixes].sort() };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const bytes = readFileSync(process.argv[2]);
    const manifest = JSON.parse(bytes.toString('utf8').replace(/^\uFEFF/, ''));
    const result = { ...restoreSourcePolicies(manifest), source_manifest_sha256: createHash('sha256').update(bytes).digest('hex') };
    writeFileSync(resolve(process.argv[3]), JSON.stringify(result, null, 2) + '\n', { mode: 0o600 });
    console.log(JSON.stringify({ pinnedObjects: manifest.objectCount, policyParts: result.source_version_policy_documents.length, sourceWrites: false, candidatesOnly: true }));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
