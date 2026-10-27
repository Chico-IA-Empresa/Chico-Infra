"""Sample only this task's fixture services; not an ARM64 host sizing benchmark."""
import json
from pathlib import Path
import re
import subprocess
import sys
import time

samples=[]
for _ in range(12):
    rows=subprocess.check_output(['docker','ps','--filter','name=chico-package-20261026-c-',
                                  '--format','{{.ID}}'],text=True).split()
    if rows:
        raw=subprocess.check_output(['docker','stats','--no-stream','--format','{{json .}}',*rows],text=True)
        samples.append({'at':time.time(),'services':[
            {k:r[k] for k in ('Name','CPUPerc','MemUsage','PIDs')} for line in raw.splitlines() if (r:=json.loads(line))]})
    time.sleep(1)
report={'scope':'QEMU ARM64 local fixture; sampled values, not capacity/true peak/load proof',
        'samples':samples}
Path(sys.argv[1]).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'resourceSamples':len(samples),'awsCapacityAccepted':False}))
