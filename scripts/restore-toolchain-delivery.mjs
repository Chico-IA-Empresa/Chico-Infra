// Bound toolchain publication contracts. Import performs no AWS/process execution.
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {pathToFileURL, fileURLToPath} from 'node:url';
import {validateExecutionGates} from './execution-gates.mjs';

export const target=Object.freeze({account:'306915830875',region:'sa-east-1',repository:'chico-workers',github:'Chico-IA-Empresa/Chico-Infra',role:'arn:aws:iam::306915830875:role/ci-build-dev'});
const hash=x=>createHash('sha256').update(x).digest('hex');
const digest=x=>typeof x==='string'&&/^sha256:[a-f0-9]{64}$/.test(x);
const sha=x=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const keys=(x,k)=>x&&typeof x==='object'&&!Array.isArray(x)&&Object.keys(x).length===k.length&&k.every(a=>Object.hasOwn(x,a));
const reference=x=>typeof x==='string'&&x.trim().length>0&&x.length<=200&&!/[\r\n]/.test(x);
const utc=x=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(x)&&Number.isFinite(Date.parse(x));
export const maxImageBytes=1024**3;
const awsTime=x=>typeof x==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(x)?Date.parse(x):NaN;
const requiredInputs=['.github/workflows/restore-toolchain.yml','operations/restore-toolchain/Dockerfile','operations/restore-toolchain/.dockerignore','operations/restore-toolchain/fixture_prepare.sh','operations/restore-toolchain/isolated_run.py','operations/restore-toolchain/verify_report.py','tests/restore-toolchain-integration.py'];
export function guardedInputs(root){
 const manifest=JSON.parse(fs.readFileSync(new URL('./restore-toolchain-delivery-inputs.json',import.meta.url)));
 if(manifest.canonicalSource!=='40d0373808b8f5648c3c8d326107b87345cef7f0'||!Array.isArray(manifest.files)||manifest.files.length!==requiredInputs.length||JSON.stringify(manifest.files.map(f=>f.path).sort())!==JSON.stringify([...requiredInputs].sort()))throw Error('Canonical source input set differs');
 for(const f of manifest.files){const p=path.resolve(root,f.path);if(!p.startsWith(path.resolve(root)+path.sep)||fs.lstatSync(p).isSymbolicLink()||!sha(f.sha256)||hash(fs.readFileSync(p))!==f.sha256)throw Error('Canonical toolchain source or existing CI gates changed');}
 return hash(JSON.stringify(manifest.files));
}
export function validateReview(raw,c,{publication=false}={}){
 const now=c.now??new Date(),remaining=Date.parse(c.validUntil)-now.getTime();
 if(c.repository!==target.github||c.ref!=='refs/heads/main'||c.eventName!=='workflow_dispatch'||!/^[a-f0-9]{40}$/.test(c.commit??'')||!/^[1-9][0-9]{0,19}$/.test(c.runId??'')||c.runAttempt!=='1'||c.roleArn!==target.role)throw Error('Exact first-attempt protected main context required');
 if(typeof raw!=='string'||!sha(c.reviewHash)||hash(raw)!==c.reviewHash||!sha(c.inputsHash))throw Error('Private release/source bytes differ');
 const r=JSON.parse(raw);
 if(!keys(r,['account_id','provision_enabled','credit_approval','proof'])||!keys(r.credit_approval,['account_id','all_charges_covered','shutdown_reserve_confirmed','evidence_reference','reviewed_on','expires_on'])||!keys(r.proof,['scope','operation','source_commit','repository_name','platform','inputs_sha256','reviewed_findings_sha256','reviewed_inventory_sha256','repository_inventory_sha256','package_review_reference','storage']))throw Error('Exact minimal release metadata required');
 validateExecutionGates(r,{account:target.account,approved:c.approved,validUntil:c.validUntil,now});
 const p=r.proof,s=p.storage;
 if(p.scope!=='restore-toolchain-delivery'||p.operation!=='publish-existing-ecr'||p.source_commit!==c.commit||p.repository_name!==target.repository||p.platform!=='linux/amd64'||p.inputs_sha256!==c.inputsHash||!sha(p.reviewed_findings_sha256)||!sha(p.reviewed_inventory_sha256)||!sha(p.repository_inventory_sha256)||!reference(p.package_review_reference))throw Error('Reviewed source/package scope differs');
 if(!keys(s,['approval_reference','retention_until_utc','cleanup_review_reference','max_image_size_bytes'])||!reference(s.approval_reference)||!reference(s.cleanup_review_reference)||!utc(s.retention_until_utc)||Date.parse(s.retention_until_utc)<=now.getTime()||Date.parse(s.retention_until_utc)>Date.parse(r.credit_approval.expires_on+'T00:00:00Z')||!Number.isSafeInteger(s.max_image_size_bytes)||s.max_image_size_bytes<=0||s.max_image_size_bytes>maxImageBytes)throw Error('Concrete privately approved storage/retention bounds required');
 if(publication&&remaining<25*60*1000)throw Error('At least twenty-five minutes of actual funding release required before publication');
 return {review:r,tag:`restore-${c.commit}-${c.runId}`,roleArn:target.role};
}
const stableRows=rows=>rows.map(x=>JSON.stringify(x)).sort().map(x=>JSON.parse(x));
export function scanFacts(report){
 if(report?.SchemaVersion!==2||!Array.isArray(report.Results)||!report.Results.length||!digest(report.Metadata?.ImageID)||report.Metadata?.OS?.Family!=='ubuntu'||report.Metadata.OS.Name!=='24.04'||report.Metadata.ImageConfig?.architecture!=='amd64'||report.Metadata.ImageConfig?.os!=='linux')throw Error('Complete native Noble image scan required');
 const os=report.Results.filter(r=>r.Class==='os-pkgs'&&r.Type==='ubuntu'&&Array.isArray(r.Packages)&&r.Packages.length);
 if(os.length!==1)throw Error('Exactly one complete Ubuntu package inventory required');
 const inventory=stableRows(os[0].Packages.map(p=>({name:p.Name,version:p.Version,release:p.Release??'',epoch:p.Epoch??0,arch:p.Arch??''})));
 if(inventory.some(p=>typeof p.name!=='string'||!p.name||typeof p.version!=='string'||!p.version||typeof p.release!=='string'||!Number.isSafeInteger(p.epoch)||p.epoch<0||!['amd64','all'].includes(p.arch)))throw Error('Incomplete package identity');
 if(new Set(inventory.map(p=>p.name)).size!==inventory.length)throw Error('Duplicate OS package identity');
 const findings=[],counts={};
 for(const r of report.Results)for(const v of r.Vulnerabilities??[]){
  if(!['CRITICAL','HIGH','MEDIUM','LOW','UNKNOWN'].includes(v.Severity)||typeof v.VulnerabilityID!=='string'||typeof v.PkgName!=='string'||typeof v.InstalledVersion!=='string')throw Error('Unknown finding schema');
  counts[v.Severity]=(counts[v.Severity]??0)+1;
  findings.push({type:r.Type,target:r.Class==='os-pkgs'?r.Type:r.Target,id:v.VulnerabilityID,severity:v.Severity,package:v.PkgName,version:v.InstalledVersion,status:v.Status??'',fixed:v.FixedVersion??''});
 }
 if((counts.CRITICAL??0)||(counts.HIGH??0)||(counts.UNKNOWN??0))throw Error('Critical, high or unknown severity is outside this delivery candidate');
 return {imageId:report.Metadata.ImageID,inventoryHash:hash(JSON.stringify(inventory)),findingsHash:hash(JSON.stringify(stableRows(findings))),counts,packages:inventory.length};
}
export function validateEvidence({scan,summary,inspect},release){
 const f=scanFacts(scan),i=inspect?.[0],p=release.review.proof;
 if(!digest(f.imageId)||!Array.isArray(inspect)||inspect.length!==1||i.Id!==f.imageId||i.Architecture!=='amd64'||i.Os!=='linux'||!Number.isSafeInteger(i.Size)||i.Size<=0||i.Size>p.storage.max_image_size_bytes||JSON.stringify(i.RootFS?.Layers)!==JSON.stringify(scan.Metadata.DiffIDs))throw Error('Scanned image/size/layer binding differs');
 if(f.findingsHash!==p.reviewed_findings_sha256||f.inventoryHash!==p.reviewed_inventory_sha256)throw Error('New or changed findings/packages require fresh private review');
 if(summary?.schemaVersion!==1||summary.baseAmd64Digest!=='sha256:78d4744ead1f5b19b04d0df558ab182a5300903900755e515b2ca4d10eb2044d'||summary.pgBackRestSourceCommit!=='d9773a31c97077761ee8e7d06e073b0b0734e26f'||summary.syntheticOnly!==true||summary.imageId!==i.Id||summary.realBinaryCorruptionRejected!==true||summary.syntheticFullDiffRecoveryRows!==3||summary.independentSyntheticWalValidated!==true||summary.syntheticSqlXmlRoundTrip!==true||summary.runtimePostgresLibxmlEnabled!==true||summary.realBackupValidated!==false||summary.realDatabaseRestored!==false||summary.restoreApproved!==false)throw Error('Synthetic acceptance/image binding incomplete');
 if(!Array.isArray(summary.reports)||summary.reports.length!==2||summary.reports.some(r=>r.reportAccepted!==true||r.privateDiagnosticsAccepted!==true||r.pgBackRestVersion!=='2.57.0'))throw Error('Both full/diff reports required');
 const negatives=summary.metadataMainAndCopyNegativeCases;
 if(!Array.isArray(negatives)||negatives.length!==8||new Set(negatives.map(x=>x.case)).size!==8||negatives.some((x)=>!Number.isInteger(x.case)||x.case<0||x.case>7||x.summaryWasOk!==true||x.privateDiagnosticsRejected!==true))throw Error('All eight real synthetic metadata-fallback negatives required');
 return {...f,imageBytes:i.Size,tag:release.tag,reviewedPackagesAndFindingsExact:true,realRestoreApproved:false,hostPullApproved:false};
}
export function repositoryInventory(response){
 if(!Array.isArray(response?.imageDetails)||response.nextToken||response.NextToken)throw Error('Complete repository inventory required');
 if(response.imageDetails.some(d=>d.imageTags!==undefined&&!Array.isArray(d.imageTags)))throw Error('Unknown image tag schema');
 const rows=response.imageDetails.map(d=>({digest:d.imageDigest,bytes:d.imageSizeInBytes,tags:[...(d.imageTags??[])].sort()}));
 if(response.imageDetails.some(d=>d.registryId!==target.account||d.repositoryName!==target.repository)||rows.some(d=>!digest(d.digest)||!Number.isSafeInteger(d.bytes)||d.bytes<=0||d.tags.some(t=>typeof t!=='string'||!t)||new Set(d.tags).size!==d.tags.length)||new Set(rows.map(d=>d.digest)).size!==rows.length)throw Error('Unknown repository image identity');
 const bytes=rows.reduce((n,d)=>n+d.bytes,0);if(!Number.isSafeInteger(bytes))throw Error('Repository size overflow');
 return {hash:hash(JSON.stringify(stableRows(rows))),images:rows.length,bytes,tags:rows.flatMap(d=>d.tags)};
}
export function validateAwsContext(identity,repositories,scanning,images,release,runId){
 if(identity?.Account!==target.account||identity.Arn!==`arn:aws:sts::${target.account}:assumed-role/ci-build-dev/restore-toolchain-${runId}`)throw Error('Exact dedicated live build identity required');
 const r=repositories?.repositories;
 if(!Array.isArray(r)||r.length!==1||r[0].registryId!==target.account||r[0].repositoryName!==target.repository||r[0].repositoryArn!==`arn:aws:ecr:${target.region}:${target.account}:repository/${target.repository}`||r[0].repositoryUri!==`${target.account}.dkr.ecr.${target.region}.amazonaws.com/${target.repository}`||r[0].imageTagMutability!=='IMMUTABLE'||r[0].imageScanningConfiguration?.scanOnPush!==true||r[0].encryptionConfiguration?.encryptionType!=='AES256'||scanning?.registryId!==target.account||scanning?.scanningConfiguration?.scanType!=='BASIC')throw Error('Existing immutable/basic-scanned repository controls differ');
 const inventory=repositoryInventory(images);if(inventory.hash!==release.review.proof.repository_inventory_sha256||inventory.tags.includes(release.tag))throw Error('Reviewed repository changed or tag consumed; reconcile before another release');
 return r[0].repositoryUri;
}
export function verifyManifest(response,details,imageId,tag,maxBytes,now=new Date()){
 const images=response?.images,d=details?.imageDetails;
 if(response?.failures?.length||!Array.isArray(images)||images.length!==1||!Array.isArray(d)||d.length!==1||d[0].registryId!==target.account||d[0].repositoryName!==target.repository||!digest(d[0].imageDigest)||!d[0].imageTags?.includes(tag)||images[0].imageId?.imageDigest!==d[0].imageDigest||!Number.isSafeInteger(d[0].imageSizeInBytes)||d[0].imageSizeInBytes<=0||d[0].imageSizeInBytes>maxBytes)throw Error('Published tag/digest/size binding incomplete');
 const raw=images[0].imageManifest,m=JSON.parse(raw);
 if(hash(raw)!==d[0].imageDigest.slice(7)||m.schemaVersion!==2||!['application/vnd.docker.distribution.manifest.v2+json','application/vnd.oci.image.manifest.v1+json'].includes(m.mediaType)||m.manifests||m.config?.digest!==imageId||!Array.isArray(m.layers)||!m.layers.length||m.layers.some(l=>!digest(l.digest)||!Number.isSafeInteger(l.size)||l.size<=0)||m.layers.reduce((s,l)=>s+l.size,0)>maxBytes)throw Error('Registry manifest/config does not identify the scanned image bytes');
 const pushed=awsTime(d[0].imagePushedAt);if(!Number.isFinite(pushed)||pushed>now.getTime()+60000||now.getTime()-pushed>30*60*1000)throw Error('Fresh publication timestamp required');
 return {manifestDigest:d[0].imageDigest,configDigest:m.config.digest,imagePushedAtUTC:new Date(pushed).toISOString(),reportedRegistryBytes:d[0].imageSizeInBytes,layerCompressedBytes:m.layers.reduce((s,l)=>s+l.size,0)};
}
export function verifyEcrScan(report,manifestDigest,pushedAtUTC,now=new Date()){
 if(report?.registryId!==target.account||report.repositoryName!==target.repository||report.imageId?.imageDigest!==manifestDigest||report.imageScanStatus?.status!=='COMPLETE')throw Error('Known complete scan of exact published digest required');
 const f=report.imageScanFindings,counts=f?.findingSeverityCounts;
 if(!counts||typeof counts!=='object'||Array.isArray(counts)||!Array.isArray(f.findings)||Object.entries(counts).some(([k,v])=>!['CRITICAL','HIGH','MEDIUM','LOW','INFORMATIONAL','UNDEFINED'].includes(k)||!Number.isSafeInteger(v)||v<0)||(counts.CRITICAL??0)||(counts.UNDEFINED??0)||Object.values(counts).reduce((a,b)=>a+b,0)!==f.findings.length)throw Error('Critical, undefined or incomplete ECR findings block completion');
 const actual={};for(const finding of f.findings){if(!['CRITICAL','HIGH','MEDIUM','LOW','INFORMATIONAL','UNDEFINED'].includes(finding.severity))throw Error('Unknown ECR finding severity');actual[finding.severity]=(actual[finding.severity]??0)+1;}
 if(Object.keys({...actual,...counts}).some(k=>(actual[k]??0)!==(counts[k]??0)))throw Error('ECR finding/count severity mismatch');
 const completed=awsTime(f.imageScanCompletedAt),updated=awsTime(f.vulnerabilitySourceUpdatedAt),pushed=awsTime(pushedAtUTC);
 if(!Number.isFinite(completed)||!Number.isFinite(updated)||!Number.isFinite(pushed)||completed+1000<pushed||completed>now.getTime()+60000||updated>now.getTime()+60000||now.getTime()-completed>3600000||now.getTime()-updated>48*3600000)throw Error('Fresh exact-publication scan/database timestamps required');
 return {knownScanComplete:true,counts,noncriticalReviewPending:f.findings.length>0,hostPullApproved:false,stagingPullApproved:false};
}

function context(){return {repository:process.env.GITHUB_REPOSITORY,ref:process.env.GITHUB_REF,eventName:process.env.GITHUB_EVENT_NAME,commit:process.env.GITHUB_SHA,runId:process.env.GITHUB_RUN_ID,runAttempt:process.env.GITHUB_RUN_ATTEMPT,roleArn:process.env.BUILD_ROLE_ARN,reviewHash:process.env.REVIEW_SHA256,approved:process.env.DEV_EXECUTION_APPROVED,validUntil:process.env.FUNDING_REVIEW_VALID_UNTIL,inputsHash:guardedInputs(process.cwd())};}
if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href){
 try{
  const mode=process.argv[2],read=p=>JSON.parse(fs.readFileSync(p,'utf8'));
  const c=context(),release=validateReview(process.env.RESTORE_TOOLCHAIN_DELIVERY_REVIEW_JSON,c,{publication:['aws-context','publication-gate'].includes(mode)});
  const out=(p,v)=>fs.writeFileSync(p,JSON.stringify(v,null,2)+'\n',{flag:'wx',mode:0o600});
  if(mode==='gate'||mode==='publication-gate'){
   if(process.env.GITHUB_OUTPUT)fs.appendFileSync(process.env.GITHUB_OUTPUT,`role_arn=${release.roleArn}\ntag=${release.tag}\n`);
   console.log('Bound toolchain delivery/source/funding/storage gates verified');
  }else if(mode==='evidence'){
   const d=process.argv[3],f=validateEvidence({scan:read(path.join(d,'scan.json')),summary:read(path.join(d,'summary.json')),inspect:read(path.join(d,'image-inspect.json'))},release);
   const file=path.join(d,'prepublication-review.json'),value={...f,sourceCommit:c.commit,runId:c.runId,privateReviewSHA256:c.reviewHash};
   if(fs.existsSync(file)){if(fs.readFileSync(file,'utf8')!==JSON.stringify(value,null,2)+'\n')throw Error('Existing prepublication evidence changed');}else out(file,value);
   console.log('Fresh final-image scan and synthetic evidence match privately reviewed package/finding sets');
  }else if(mode==='aws-context')validateAwsContext(read(process.argv[3]),read(process.argv[4]),read(process.argv[5]),read(process.argv[6]),release,c.runId);
  else if(mode==='manifest'){
   const pre=read(process.argv[3]),bound=verifyManifest(read(process.argv[4]),read(process.argv[5]),pre.imageId,release.tag,release.review.proof.storage.max_image_size_bytes);
   out(process.argv[6],{...pre,...bound,imageUri:`${target.account}.dkr.ecr.${target.region}.amazonaws.com/${target.repository}@${bound.manifestDigest}`,published:true,hostPullApproved:false,stagingPullApproved:false});
  }else if(mode==='ecr-scan'){
   const bound=read(process.argv[3]),scan=verifyEcrScan(read(process.argv[4]),bound.manifestDigest,bound.imagePushedAtUTC);
   out(process.argv[5],{...bound,ecrScan:scan,deliveryCompleted:true,realDataUsed:false,fixtureInstalled:false});
  }else throw Error('Unreviewed command');
 }catch{console.error('Toolchain delivery blocked; private inputs/responses omitted; reconcile any consumed tag without retry/deletion');process.exitCode=1;}
}
