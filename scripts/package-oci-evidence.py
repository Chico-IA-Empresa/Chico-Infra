"""Verify exported OCI bytes and loaded IDs. Emits hashes, never image env values."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def inspect(directory, name):
    directory = Path(directory)
    metadata = json.loads((directory / (name + '.metadata.json')).read_text())
    with tarfile.open(directory / (name + '.oci.tar')) as archive:
        def blob(ref):
            data = archive.extractfile('blobs/sha256/' + ref.split(':')[1]).read()
            assert digest(data) == ref
            return json.loads(data)
        exported = json.load(archive.extractfile('index.json'))
        index_ref = metadata['containerimage.digest']
        index = blob(index_ref)
        assert any(x['digest'] == index_ref for x in exported['manifests'])
        manifests = [x for x in index['manifests'] if x.get('platform',{}).get('architecture') == 'arm64']
        assert len(manifests) == 1
        manifest_ref = manifests[0]['digest']
        manifest = blob(manifest_ref)
        config_ref = manifest['config']['digest']
        config = blob(config_ref)
        assert config['os'] == 'linux' and config['architecture'] == 'arm64'
        expected_user = '1001' if name == 'frontend' else '10001:10001'
        assert config['config']['User'] in ({'1001','nextjs'} if name == 'frontend' else {'10001:10001'})
        source = {}
        for layer in manifest['layers']:
            stream = archive.extractfile('blobs/sha256/' + layer['digest'].split(':')[1])
            layer_hash = hashlib.sha256()
            while chunk := stream.read(1024 * 1024):
                layer_hash.update(chunk)
            assert 'sha256:' + layer_hash.hexdigest() == layer['digest']
            stream.seek(0)
            # gzip/tar stream includes only filesystem metadata/bytes locally.
            with tarfile.open(fileobj=stream, mode='r|*') as files:
                for member in files:
                    path = member.name.removeprefix('./')
                    if path.startswith('app/') and member.isfile():
                        assert '/.env' not in path and not path.endswith(('.pem','.key','.dump','.db'))
                        source[path] = digest(files.extractfile(member).read())
        loaded = json.loads(subprocess.check_output(['docker','image','inspect','--format',
            '{{json .Id}}', 'chico-'+name+':local-fixture'],text=True))
        assert loaded == index_ref  # Docker Desktop containerd OCI store
        return {'indexDigest':index_ref,'manifestDigest':manifest_ref,'configDigest':config_ref,
                'localImageId':loaded,'platform':'linux/arm64','user':config['config']['User'],
                'baseSourceSha':config['config']['Labels']['org.opencontainers.image.revision'],
                'buildRef':metadata['buildx.build.ref'],
                'layers':[x['digest'] for x in manifest['layers']], 'layerHashesVerified':True,
                'appFileCount':len(source),'appTreeChecksum':digest(json.dumps(source,sort_keys=True).encode()),
                'ociFile':str(directory / (name+'.oci.tar')),'sourceIncludesUncommittedChanges':True}


if __name__ == '__main__':
    backend, frontend, output = sys.argv[1:]
    result = {'kind':'local-oci-evidence','syntheticImages':False,'promotable':False,'awsAcceptance':False,
              'scan':'pending DEV-PACOTE-007','images':{name:inspect(frontend if name=='frontend' else backend,name)
                  for name in ('api','workers','frontend')}}
    assert result['images']['api']['baseSourceSha'] == result['images']['workers']['baseSourceSha']
    assert result['images']['api']['layers'] == result['images']['workers']['layers']
    assert result['images']['api']['appTreeChecksum'] == result['images']['workers']['appTreeChecksum']
    Path(output).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'verified':True,'images':3,'sharedBackendLayers':True,'promotable':False}))
