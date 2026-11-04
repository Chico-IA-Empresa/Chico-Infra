import test from 'node:test';
import assert from 'node:assert/strict';
import { restoreSourcePolicies } from '../scripts/restore-source-permissions.mjs';

const base = () => ({
  bucket: 'chico-backup', account: '306915830875', region: 'sa-east-1', sourceReadOnly: true,
  allSelectedPrefixListingsNotTruncated: true, inspectedMetadataVersionsUnchanged: true, objectCount: 2,
  objects: [
    { key: 'pgbackrest/sofascore-postgres/backup/main/20260906-060005F/bundle/0', versionId: 'synthetic-version-one', bytes: 1 },
    { key: 'pgbackrest/sofascore-postgres/backup/main/backup.info', versionId: 'synthetic-version-two', bytes: 1 },
  ],
});

test('restore candidates bind every source key to its own VersionId without source writes or current reads', () => {
  const manifest = base(), result = restoreSourcePolicies(manifest);
  const statements = result.source_version_policy_documents.flatMap(s => JSON.parse(s).Statement);
  assert.equal(statements.length, 2);
  for (const [i, statement] of statements.entries()) {
    assert.deepEqual(statement.Action, ['s3:GetObjectVersion']);
    assert.equal(statement.Resource, `arn:aws:s3:::chico-backup/${manifest.objects[i].key}`);
    assert.equal(statement.Condition.StringEquals['s3:VersionId'], manifest.objects[i].versionId);
  }
  assert.deepEqual(result.source_list_prefixes, [
    'pgbackrest/sofascore-postgres/backup/main/20260906-060005F/',
    'pgbackrest/sofascore-postgres/backup/main/backup.info',
  ]);
});

test('restore refuses incomplete listing, changed metadata, wrong account, bucket or region', () => {
  for (const change of [{allSelectedPrefixListingsNotTruncated:false},{inspectedMetadataVersionsUnchanged:false},{sourceReadOnly:false},{account:'123456789012'},{bucket:'different-bucket'},{region:'us-east-1'},{objectCount:3}]) {
    assert.throws(() => restoreSourcePolicies({...base(),...change}));
  }
});

test('restore refuses missing/current versions, duplicate keys, wildcards and traversal', () => {
  for (const change of [{versionId:null},{versionId:''},{versionId:'null'},{versionId:'contains whitespace'},{key:'pgbackrest/sofascore-postgres/*'},{key:'pgbackrest/sofascore-postgres/../other'},{key:'other-project/file'}]) {
    const manifest=base();Object.assign(manifest.objects[0],change);
    assert.throws(() => restoreSourcePolicies(manifest));
  }
  const manifest=base();manifest.objects[1].key=manifest.objects[0].key;
  assert.throws(() => restoreSourcePolicies(manifest));
});

test('splitting preserves every exact binding under IAM document and attachment quotas', () => {
  const manifest=base();manifest.objects=Array.from({length:178},(_,i)=>({key:`pgbackrest/sofascore-postgres/backup/main/20260906-060005F/bundle/${i}`,versionId:`synthetic-version-${i}`,bytes:1}));manifest.objectCount=178;
  const result=restoreSourcePolicies(manifest);
  assert.ok(result.source_version_policy_documents.length>1 && result.source_version_policy_documents.length<=9);
  assert.ok(result.source_version_policy_documents.every(s=>s.length<=6000));
  assert.equal(result.source_version_policy_documents.flatMap(s=>JSON.parse(s).Statement).length,178);
  manifest.objects=Array.from({length:2000},(_,i)=>({key:`pgbackrest/sofascore-postgres/backup/main/20260906-060005F/bundle/${i}`,versionId:`synthetic-version-${i}`,bytes:1}));manifest.objectCount=2000;
  assert.throws(()=>restoreSourcePolicies(manifest),/quota/);
});
