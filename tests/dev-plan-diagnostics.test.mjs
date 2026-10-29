import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, symlinkSync, linkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { preservePlanFailure } from '../scripts/dev-plan-diagnostics.mjs';
function fixture() {
  const directory = resolve(mkdtempSync(join(tmpdir(), 'private-plan-diagnostic-')));
  const log = join(directory, 'plan.log');
  writeFileSync(log, 'SYNTHETIC_PRIVATE_INPUT', {mode:0o600});
  return { directory, log, env:{OPERATION:'plan',ACCOUNT:'306915830875',REVIEW_BUCKET:'chico-infra-review-306915830875-sa-east-1',
    GITHUB_REPOSITORY:'Chico-IA-Empresa/Chico-Infra',GITHUB_REF:'refs/heads/main',GITHUB_SHA:'a'.repeat(40),GITHUB_RUN_ID:'123',
    GITHUB_WORKFLOW_REF:'Chico-IA-Empresa/Chico-Infra/.github/workflows/dev-reviewed-plan-apply.yml@refs/heads/main',RUNNER_TEMP:directory},
    clean(){rmSync(directory,{recursive:true,force:true});}};
}
test('failed plan uploads only exact private log with owner/encryption/version binding; no contents in result',()=>{
  const f=fixture();try {
    let calls=0;
    const result=preservePlanFailure(1,f.env,(cmd,args,options)=>{
      calls++;assert.equal(cmd,'aws');assert.equal(args[args.indexOf('--body')+1],f.log);
      assert.equal(args[args.indexOf('--key')+1],`dev/${'a'.repeat(40)}/123/diagnostics/plan-failure.log`);
      assert.equal(args[args.indexOf('--expected-bucket-owner')+1],'306915830875');
      assert.equal(args[args.indexOf('--server-side-encryption')+1],'AES256');
      assert.deepEqual(options.stdio,['ignore','pipe','pipe']);assert.equal(options.timeout,30000);
      return '{"VersionId":"synthetic-version"}';
    });assert.equal(calls,1);assert.equal(result.uploaded,true);assert.ok(!JSON.stringify(result).includes('SYNTHETIC_PRIVATE_INPUT'));
  }finally{f.clean();}
});
test('success and apply never upload diagnostics with a role lacking this grant',()=>{
  const execute=()=>assert.fail('unexpected upload');assert.deepEqual(preservePlanFailure(0,{},execute),{uploaded:false});
  assert.deepEqual(preservePlanFailure(1,{OPERATION:'apply'},execute),{uploaded:false});
});
test('foreign context and invalid exit statuses fail before AWS',()=>{
  const f=fixture();try{
    for(const key of ['ACCOUNT','REVIEW_BUCKET','GITHUB_REPOSITORY','GITHUB_REF','GITHUB_WORKFLOW_REF','GITHUB_SHA','GITHUB_RUN_ID'])
      assert.throws(()=>preservePlanFailure(1,{...f.env,[key]:'foreign'},()=>assert.fail('unexpected upload')));
    for(const status of [-1,256,'1;echo private','']) assert.throws(()=>preservePlanFailure(status,f.env));
  }finally{f.clean();}
});
test('missing empty directory and multiply linked logs fail closed',()=>{
  const f=fixture();try{
    rmSync(f.log);assert.throws(()=>preservePlanFailure(1,f.env));writeFileSync(f.log,'');assert.throws(()=>preservePlanFailure(1,f.env));
    writeFileSync(f.log,'synthetic');linkSync(f.log,join(f.directory,'linked'));assert.throws(()=>preservePlanFailure(1,f.env));
  }finally{f.clean();}
});
test('symlink cannot redirect upload to another file',{skip:process.platform==='win32'},()=>{
  const f=fixture();try{rmSync(f.log);writeFileSync(join(f.directory,'other'),'private');symlinkSync(join(f.directory,'other'),f.log);assert.throws(()=>preservePlanFailure(1,f.env));}finally{f.clean();}
});
test('CLI failure output and malformed unversioned responses never become metadata',()=>{
  const f=fixture();try{
    assert.throws(()=>preservePlanFailure(1,f.env,()=>{throw Object.assign(Error('private'),{stderr:'SYNTHETIC_PRIVATE_INPUT'});}));
    for(const value of [undefined,'null','','unsafe\nvalue','a'.repeat(1025),'é'.repeat(513)]) assert.throws(()=>preservePlanFailure(1,f.env,()=>JSON.stringify({VersionId:value})));
  }finally{f.clean();}
});
test('opaque S3 version IDs preserve punctuation and count UTF8 bytes',()=>{
  const f=fixture();try{
    for(const value of ['opaque+/=version','é'.repeat(512)]) assert.equal(preservePlanFailure(1,f.env,()=>JSON.stringify({VersionId:value})).versionId,value);
  }finally{f.clean();}
});
