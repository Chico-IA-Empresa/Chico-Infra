// Restricted Docker inspection: environment values and health logs are omitted.
const {execFileSync}=require('node:child_process');
const fs=require('node:fs');
const format='{"name":{{json .Name}},"image":{{json .Image}},"user":{{json .Config.User}},"status":{{json .State.Status}},"health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}null{{end}},"ports":{{json .NetworkSettings.Ports}},"oom":{{json .State.OOMKilled}},"restartCount":{{json .RestartCount}}}';
const names=['b','c'].flatMap(p=>['postgres','redis','api','web','proxy'].map(s=>`chico-package-20261026-${p}-${s}-1`));
const result=execFileSync('docker',['inspect','--format',format,...names],{encoding:'utf8',windowsHide:true}).trim().split('\n').map(JSON.parse);
if(!result.every(x=>x.status==='running'&&x.health==='healthy'&&!x.oom))throw new Error('Fixture runtime not healthy');
fs.writeFileSync(process.argv[2],JSON.stringify({date:new Date().toISOString(),scope:'local fixtures only',containers:result},null,2)+'\n');
console.log(JSON.stringify({healthyFixtureContainers:result.length,environmentValuesRecorded:false}));
