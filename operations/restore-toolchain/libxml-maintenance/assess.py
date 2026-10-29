"""Compare public ABI metadata; never claim full compatibility from smoke tests."""
import hashlib
import json
from pathlib import Path
import re

LAYOUT_NAMES = {'xmlEntity', 'xmlParserInput', 'xmlParserCtxt', 'xmlNode', 'xmlDoc', 'xmlSAXHandler',
                'xmlEntity.content', 'xmlEntity.length', 'xmlParserInput.cur', 'xmlParserInput.end', 'xmlParserCtxt.inputNr'}


def assess(directory):
    directory = Path(directory)
    def read(name):
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
            raise ValueError('Bounded regular metadata required')
        return path.read_text()
    before, after = read('layout-before.txt'), read('layout-after.txt')
    def layout(text):
        pairs = [line.split('=') for line in text.splitlines()]
        if len(pairs) != 11 or any(len(pair) != 2 or not pair[1].isdigit() for pair in pairs):
            raise ValueError('Complete reviewed layout probes required')
        result = dict(pairs)
        if set(result) != LAYOUT_NAMES:
            raise ValueError('Unique layout probe names required')
        return result
    old_layout, new_layout = layout(before), layout(after)
    if set(old_layout) != set(new_layout):
        raise ValueError('Layout probe set differs')
    symbols_before, symbols_after = set(read('symbols-before.txt').splitlines()), set(read('symbols-after.txt').splitlines())
    if len(symbols_before) < 100 or len(symbols_after) < 100:
        raise ValueError('Complete defined dynamic symbol inventories required')
    dynamic_before, dynamic_after = read('dynamic-before.txt'), read('dynamic-after.txt')
    def dynamic(text):
        soname = re.findall(r'\(SONAME\).*\[([^\]]+)\]', text)
        needed = sorted(re.findall(r'\(NEEDED\).*\[([^\]]+)\]', text))
        if soname != ['libxml2.so.2'] or not needed:
            raise ValueError('Expected SONAME and dependency metadata required')
        return needed
    old_needed, new_needed = dynamic(dynamic_before), dynamic(dynamic_after)
    def headers(text):
        rows = [line.split() for line in text.splitlines()]
        if not 10 <= len(rows) <= 128 or any(len(row) != 2 or not re.fullmatch('[a-f0-9]{64}', row[0]) or not re.fullmatch(r'[A-Za-z0-9_.-]+\.h', row[1]) for row in rows):
            raise ValueError('Complete header digest inventories required')
        result = {row[1]: row[0] for row in rows}
        if len(result) != len(rows):
            raise ValueError('Unique header names required')
        return result
    old_headers, new_headers = headers(read('headers-before.sha256')), headers(read('headers-after.sha256'))
    glibc_before = set(re.findall(r'Name: (GLIBC_[A-Za-z0-9_.]+)', read('baseline-libc-versions.txt')))
    glibc_after = set(re.findall(r'Name: (GLIBC_[A-Za-z0-9_.]+)', read('candidate-versions.txt')))
    if not glibc_before or not glibc_after:
        raise ValueError('Actual GLIBC version metadata required')
    source = json.loads(read('source-provenance.json'))
    if source.get('repositorySignatureVerified') is not True or source.get('sourceVersion') != '2.9.14+dfsg-1.3ubuntu3.10':
        raise ValueError('Authenticated exact vendor source required')
    smoke = read('normal-smoke-passed.txt').strip() == 'ordinary_xml_sqlxml_offline_backup_restore_passed'
    changed = sorted(key for key in old_layout if old_layout[key] != new_layout[key])
    removed = sorted(symbols_before - symbols_after)
    return {'schemaVersion': 1, 'status': 'blocked_pending_abi_and_scan_review',
            'sourceVersion': source['sourceVersion'], 'ordinarySmokePassed': smoke,
            'publicLayoutChanges': changed, 'removedVersionedSymbols': removed,
            'dependencySetEqual': old_needed == new_needed,
            'baselineDependencies': old_needed, 'candidateDependencies': new_needed,
            'headerDigestChanges': sorted(name for name in old_headers.keys() | new_headers.keys() if old_headers.get(name) != new_headers.get(name)),
            'candidateGLIBCRequirementsAvailableInBaseline': glibc_after <= glibc_before and 'GLIBC_PRIVATE' not in glibc_after,
            'symbolSetRetained': not removed, 'sampledHeaderLayoutsEqual': not changed,
            'fullABICompatibilityProven': False, 'defaultLibraryReplaced': False,
            'packageVersionChanged': False, 'riskAccepted': False,
            'gateOverrideApplied': False, 'rawScanModified': False, 'realRestoreApproved': False,
            'metadataSHA256': {name: hashlib.sha256(read(name).encode()).hexdigest() for name in
                               ['layout-before.txt', 'layout-after.txt', 'symbols-before.txt', 'symbols-after.txt',
                                'dynamic-before.txt', 'dynamic-after.txt', 'source-provenance.json',
                                'baseline-libc-versions.txt', 'candidate-versions.txt', 'headers-before.sha256', 'headers-after.sha256']}}
