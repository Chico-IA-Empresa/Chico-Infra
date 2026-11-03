"""Fail closed on unknown image inventory, incomplete gosu inventory or CRITICAL."""
import json
import sys


def verify(report, require_gosu=False, require_brotli=False):
    if report.get('SchemaVersion') != 2 or not report.get('Results'):
        raise ValueError('Unknown scan report')
    if not report.get('Metadata', {}).get('OS', {}).get('Family'):
        raise ValueError('OS inventory missing')
    family = report['Metadata']['OS']['Family']
    if not any(r.get('Class') == 'os-pkgs' and r.get('Type') == family
               and r.get('Packages') for r in report['Results']):
        raise ValueError('Complete OS package inventory missing')
    vulnerabilities = [v for r in report['Results'] for v in r.get('Vulnerabilities', [])]
    if any(v.get('Severity') == 'CRITICAL' for v in vulnerabilities):
        raise ValueError('Critical findings block')
    if require_gosu:
        gosu = [r for r in report['Results'] if r.get('Type') == 'gobinary'
                and r.get('Target', '').lstrip('/').endswith('usr/local/bin/gosu')]
        if len(gosu) != 1 or not any(p.get('Name') == 'stdlib' and p.get('Version') == 'v1.27.3'
                                      for p in gosu[0].get('Packages', [])):
            raise ValueError('Rebuilt gosu standard-library inventory missing')
    if require_brotli:
        packages = [p for r in report['Results'] if r.get('Class') == 'os-pkgs'
                    for p in r.get('Packages', [])]
        if not any(p.get('Name') == 'brotli-libs' and p.get('Version') == '1.2.1-r0'
                   for p in packages):
            raise ValueError('Pinned Brotli package inventory missing')
    counts = {}
    for v in vulnerabilities:
        severity = v.get('Severity', 'UNKNOWN')
        counts[severity] = counts.get(severity, 0) + 1
    return {'scanKnown': True, 'critical': 0, 'counts': counts,
            'noncriticalReviewPending': bool(vulnerabilities), 'hostPullApproved': False}


if __name__ == '__main__':
    try:
        print(json.dumps(verify(json.load(open(sys.argv[1], encoding='utf-8')),
                                require_gosu='--require-gosu' in sys.argv[2:],
                                require_brotli='--require-brotli' in sys.argv[2:])))
    except (ValueError, KeyError, OSError, IndexError, TypeError):
        print('Image maintenance scan refused; inspect the package-only evidence', file=sys.stderr)
        raise SystemExit(1)
