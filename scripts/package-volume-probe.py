"""Only public sentinels in fixture files/TLS paths; no certificate or data dumps."""
import hashlib
import json
import os
from pathlib import Path
import sys

mode=sys.argv[1]
result={}
for name,uid in [('files',10001),('tls',101)]:
    root=Path('/fixture')/name
    path=root/'package-public-sentinel.txt'
    content=b'CHICO disposable package persistence sentinel v1\n'
    if mode=='create':
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as stream:stream.write(content)
        os.chown(path,uid,uid)
    assert path.read_bytes()==content
    stat=path.stat()
    assert stat.st_uid==stat.st_gid==uid and (stat.st_mode&0o777)==0o600
    result[name]={'sha256':hashlib.sha256(content).hexdigest(),'uid':uid,'gid':uid,'mode':'0600'}
print(json.dumps(result))
