"""Compose the exact baseline and candidate stages, without modifying either."""
import hashlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASELINE_SHA256 = '27af00c45b4918f22d4f9b8993e42766d7b85f8b9791f908677573c49fce6413'
BASE_FROM = 'FROM postgres:16.13-bookworm@sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d'


def compose(baseline, candidate):
    baseline = baseline.replace(b'\r\n', b'\n')
    if hashlib.sha256(baseline).hexdigest() != BASELINE_SHA256:
        raise ValueError('Baseline source differs from reviewed 45909f8')
    text = baseline.decode()
    if text.count(BASE_FROM) != 2 or text.count(BASE_FROM + '\n') != 1:
        raise ValueError('Exact two-stage pinned baseline required')
    # Only add an alias to its existing final FROM. No base/files/libraries change.
    text = text.replace(BASE_FROM + '\n', BASE_FROM + ' AS baseline\n', 1)
    return (text + '\n' + candidate.decode()).encode()


if __name__ == '__main__':
    data = compose((HERE.parent / 'Dockerfile').read_bytes(), (HERE / 'Dockerfile').read_bytes())
    with (HERE / 'Dockerfile.combined').open('xb') as output:
        output.write(data)
    print('Candidate context prepared; no Docker build or approval performed.')
