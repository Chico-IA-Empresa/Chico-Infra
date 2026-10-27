// Requires Playwright on NODE_PATH. No credentials/tokens or response bodies
// are logged. All browser network traffic is restricted to the two fixtures.
const {chromium} = require('playwright');
const {execFileSync} = require('node:child_process');
const assert = require('node:assert/strict');
const cases = [
  {origin:'http://127.0.0.1:18080',run:'package-20261026-run5',project:'fixture-c',backend:'api:8000'},
  {origin:'http://localhost:18081',run:'package-20261026-run4',project:'fixture-b',backend:'backend-fixture:8000'},
];
function credential(run) {
  // The private fixture value moves only through this child-process pipe.
  return execFileSync('docker',['run','--rm','--network','none','--platform','linux/arm64',
    '--mount',`type=bind,source=/srv/chico/fixture/${run}/config/seed.json,target=/checks/seed.json,readonly`,
    '--entrypoint','python','chico-api:local-fixture','-c',
    'import json;from pathlib import Path;print(json.loads(Path("/checks/seed.json").read_text())["DEV_SEED_PASSWORD"])'],
    {encoding:'utf8',windowsHide:true}).trim();
}
(async()=>{
 const browser = await chromium.launch({channel:'msedge',headless:true});
 const context = await browser.newContext();
 await context.route('**/*',route=>['127.0.0.1','localhost'].includes(new URL(route.request().url()).hostname) ? route.continue() : route.abort());
 const pages=[], tokens=[], reports=[];
 try {
  for(const c of cases) {
   const page = await context.newPage(); pages.push(page);
   await page.goto(c.origin+'/contact',{waitUntil:'domcontentloaded',timeout:60000});
   await page.waitForFunction(()=>Boolean(window.__CHICO_PUBLIC_CONFIG__),{},{timeout:30000});
   assert.equal((await context.cookies(c.origin)).some(x=>x.name==='chico_refresh'),false);
   const publicConfig = await page.evaluate(()=>window.__CHICO_PUBLIC_CONFIG__);
   assert.equal(publicConfig.firebase.projectId,c.project);
   assert.deepEqual(Object.keys(publicConfig),['firebase']);
   assert.ok(await page.locator('meta[property="og:url"]').getAttribute('content').then(x=>x.startsWith(c.origin)));
   const result = await page.evaluate(async({password,backend})=>{
    const post=(path,body)=>fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),credentials:'same-origin'});
    const login=await post('/api/auth/login',{email:'package@example.com',password});
    if(login.status!==200) throw new Error('fixture login status '+login.status);
    const token=(await login.json()).access_token;
    const auth={Authorization:'Bearer '+token};
    if((await fetch('/api/auth/me',{headers:auth})).status!==200) throw new Error('auth me');
    const concurrent=await Promise.all([post('/api/auth/refresh',{}),post('/api/auth/refresh',{})]);
    if(!concurrent.every(r=>r.status===200)) throw new Error('concurrent refresh');
    if((await fetch('/api/matches/package-v1-match',{headers:auth})).status!==200) throw new Error('seed read');
    for(let i=0;i<2;i++) await new Promise((resolve,reject)=>{
     const ws=new WebSocket(location.origin.replace('http:','ws:')+'/api/ws/odds?token='+token);
     const timer=setTimeout(()=>{ws.close();reject(new Error('ws timeout'));},20000);
     ws.onopen=()=>{clearTimeout(timer);ws.close();resolve(true);};ws.onerror=()=>reject(new Error('ws connection'));
    });
    const stream=await fetch('/api/chat/stream',{method:'POST',headers:{...auth,'Content-Type':'application/json'},body:JSON.stringify({message:'synthetic fixture'})});
    if(stream.status!==200 || !stream.headers.get('content-type').includes('text/event-stream')) throw new Error('SSE status');
    const reader=stream.body.getReader(),start=performance.now();
    const first=await reader.read(),firstAt=performance.now();let text=new TextDecoder().decode(first.value);
    for(;;){const part=await reader.read();if(part.done)break;text+=new TextDecoder().decode(part.value);}
    if(!text.includes(backend)||!text.includes('[DONE]')||performance.now()-firstAt<700) throw new Error('SSE buffering/runtime destination');
    const email=await post('/api/contact',{name:'Synthetic fixture',email:'fixture@example.com',subject:'fixture',message:'isolated mock delivery'});
    if(email.status!==201 || (await email.json()).messageId!=='fixture-captured') throw new Error('email capture');
    return {token,streaming:true,refresh:true,wsReconnect:true,emailCapture:true};
   },{password:credential(c.run),backend:c.backend});
   tokens.push(result.token);
   const cookies=await context.cookies(c.origin),refresh=cookies.find(x=>x.name==='chico_refresh');
   assert.ok(refresh?.httpOnly && refresh.sameSite==='Lax');
   assert.equal(refresh.domain,new URL(c.origin).hostname);
   const robots=await page.request.get(c.origin+'/robots.txt');assert.ok((await robots.text()).includes('Disallow: /'));
   const image=await page.request.get(c.origin+'/_next/image?url=%2Ficon.png&w=64&q=75');assert.equal(image.status(),200);
   reports.push({origin:c.origin,publicProject:c.project,backendHost:c.backend,login:true,hostOnlyCookie:true,
    concurrentRefresh:true,seedRead:true,wsReconnect:true,sseUnbufferedMock:true,emailCapturedMock:true,imageOptimizer:true,nonIndexable:true});
  }
  // Both origins coexist in one browser context; each has a different key and cookie.
  for(let i=0;i<cases.length;i++) {
   if(i===1) {
    // Synthetic signing-key rotation. chmod is restored even on write failure;
    // no private value crosses this child-process pipe.
    execFileSync('docker',['run','--rm','--network','none','--platform','linux/arm64','--user','10001:10001',
     '--mount',`type=bind,source=/srv/chico/fixture/${cases[i].run}/config/api.json,target=/checks/config`,
     '--entrypoint','python','chico-api:local-fixture','-c',
     'import json,secrets,os;from pathlib import Path;p=Path("/checks/config");v=json.loads(p.read_text());v["SECRET_KEY"]=secrets.token_urlsafe(48);os.chmod(p,0o600)\ntry:p.write_text(json.dumps(v))\nfinally:os.chmod(p,0o400)'],{windowsHide:true,stdio:'pipe'});
    execFileSync('docker',['restart','chico-package-20261026-b-api-1'],{windowsHide:true,stdio:'pipe'});
    let ready=false;
    for(let attempt=0;attempt<90;attempt++) {
     try {ready=(await pages[i].request.get(cases[i].origin+'/api/health/ready',{timeout:2000})).status()===200;}catch{}
     if(ready)break;await new Promise(resolve=>setTimeout(resolve,1000));
    }
    assert.ok(ready,'API readiness after synthetic key rotation');
    const rotation=await pages[i].evaluate(async({oldToken,password})=>{
     const old=await fetch('/api/auth/me',{headers:{Authorization:'Bearer '+oldToken}});
     const login=await fetch('/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:'package@example.com',password})});
     return {old:old.status,newLogin:login.status};
    },{oldToken:tokens[i],password:credential(cases[i].run)});
    assert.deepEqual(rotation,{old:401,newLogin:200});reports[i].syntheticSigningKeyRotation=true;
   }
   const result=await pages[i].evaluate(async(otherToken)=>{
    const cross=await fetch('/api/auth/me',{headers:{Authorization:'Bearer '+otherToken}});
    const logout=await fetch('/api/auth/logout',{method:'POST'});
    const refresh=await fetch('/api/auth/refresh',{method:'POST'});
    return {cross:cross.status,logout:logout.status,refresh:refresh.status};
   },tokens[1-i]);
   assert.deepEqual(result,{cross:401,logout:200,refresh:401});
   reports[i].crossEnvironmentTokenDenied=true;reports[i].logoutRevokesRefresh=true;
  }
  const ids = name=>['b','c'].map(project=>execFileSync('docker',['inspect','--format','{{.Image}}',
    `chico-package-20261026-${project}-${name}-1`],{encoding:'utf8',windowsHide:true}).trim());
  const imageIds={frontend:ids('web'),api:ids('api')};
  for(const pair of Object.values(imageIds)) assert.equal(pair[0],pair[1]);
  const report={browser:'headless Edge/Chromium',providers:'isolated mocks',imageIds,checks:reports};
  if(process.argv[2]) require('node:fs').writeFileSync(process.argv[2],JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report));
 } finally {await browser.close();}
})().catch(e=>{console.error('Browser fixture smoke failed: '+e.message.replace(/Bearer\s+\S+/g,'Bearer [redacted]'));process.exitCode=1;});
