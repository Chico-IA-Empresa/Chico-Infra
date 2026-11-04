"""Synthetic in-memory evidence tests. No network, .deb execution or extraction."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import struct
import tarfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('zlib_review', ROOT / 'operations/restore-toolchain/zlib_vex_review.py')
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
IMAGE = 'sha256:' + 'a' * 64


def elf(*, soname='libz.so.1', needed='libc.so.6', symbol_override=None, undefined=False):
    names = ['adler32', 'compress', 'crc32', 'deflate', 'inflate', 'zlibVersion']
    if symbol_override:
        names[0] = symbol_override
    strings, offsets = bytearray(b'\0'), {}
    for name in [soname, needed, *names]:
        if name is not None and name not in offsets:
            offsets[name] = len(strings)
            strings += name.encode() + b'\0'
    binary = bytearray(1088)
    ident = b'\x7fELF\x02\x01\x01' + b'\0' * 9
    binary[:64] = struct.pack('<16sHHIQQQIHHHHHH', ident, 3, 62, 1, 0, 64, 768, 0, 64, 56, 2, 64, 5, 0)
    entries = [(1, offsets[needed]), (5, 512), (10, len(strings)), (6, 320), (11, 24)]
    if soname is not None:
        entries.append((14, offsets[soname]))
    entries.append((0, 0))
    dynamic = b''.join(struct.pack('<qQ', *item) for item in entries)
    binary[64:120] = struct.pack('<IIQQQQQQ', 1, 5, 0, 0, 0, len(binary), len(binary), 4096)
    binary[120:176] = struct.pack('<IIQQQQQQ', 2, 6, 192, 192, 192, len(dynamic), len(dynamic), 8)
    binary[192:192 + len(dynamic)] = dynamic
    dynsym = b'\0' * 24 + b''.join(struct.pack('<IBBHQQ', offsets[name], 0x12, 0, 0 if undefined else 4, 640, 1) for name in names)
    binary[320:320 + len(dynsym)] = dynsym
    binary[512:512 + len(strings)] = strings
    binary[640] = 0xc3  # Synthetic unused function byte; never executed.
    sections = [b'\0' * 64,
                struct.pack('<IIQQQQIIQQ', 0, 3, 2, 512, 512, len(strings), 0, 0, 1, 0),
                struct.pack('<IIQQQQIIQQ', 0, 11, 2, 320, 320, len(dynsym), 1, 1, 8, 24),
                struct.pack('<IIQQQQIIQQ', 0, 6, 3, 192, 192, len(dynamic), 1, 0, 8, 16),
                struct.pack('<IIQQQQIIQQ', 0, 1, 6, 640, 640, 1, 0, 0, 1, 0)]
    binary[768:] = b''.join(sections)
    return bytes(binary)


def tar(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w:xz') as archive:
        for name, kind, value in entries:
            member = tarfile.TarInfo(name)
            if kind == 'file':
                member.size = len(value)
                archive.addfile(member, io.BytesIO(value))
            else:
                member.type = {'directory': tarfile.DIRTYPE, 'symlink': tarfile.SYMTYPE, 'hardlink': tarfile.LNKTYPE}[kind]
                if kind != 'directory':
                    member.linkname = value
                archive.addfile(member)
    return stream.getvalue()


def ar(entries):
    result = bytearray(b'!<arch>\n')
    for name, value in entries:
        header = ((name + '/').ljust(16) + '0'.ljust(12) + '0'.ljust(6) + '0'.ljust(6) + '100644'.ljust(8) + str(len(value)).ljust(10) + '`\n').encode()
        assert len(header) == 60
        result += header + value + (b'\n' if len(value) % 2 else b'')
    return bytes(result)


def deb(library, *, extra=None, control_extra=None):
    fields = {'Package': 'zlib1g', 'Version': review.VERSION, 'Architecture': 'amd64', 'Source': 'zlib'}
    fields.update(control_extra or {})
    control = tar([('control', 'file', ''.join(f'{key}: {value}\n' for key, value in fields.items()).encode())])
    entries = [('lib', 'directory', b''), ('lib/x86_64-linux-gnu', 'directory', b''),
               (review.LIBRARY, 'file', library), (review.SONAME_PATH, 'symlink', 'libz.so.1.2.13')]
    entries += extra or []
    return ar([('debian-binary', b'2.0\n'), ('control.tar.xz', control), ('data.tar.xz', tar(entries))])


def scan():
    finding = {'VulnerabilityID': review.CVE, 'PkgName': 'zlib1g', 'InstalledVersion': review.VERSION, 'Severity': 'CRITICAL',
               'PkgIdentifier': {'PURL': 'pkg:deb/debian/zlib1g@1.2.13.dfsg-1?arch=amd64&distro=debian-12.13&epoch=1'}}
    return {'SchemaVersion': 2, 'Metadata': {'ImageID': IMAGE, 'OS': {'Family': 'debian', 'Name': '12.13'}},
            'Results': [{'Class': 'os-pkgs', 'Type': 'debian', 'Vulnerabilities': [finding]}]}


class ZlibReviewTests(unittest.TestCase):
    def context(self, library=None, **changes):
        library = elf() if library is None else library
        archive = deb(library)
        result = {'image_id': IMAGE, 'raw_scan_bytes': json.dumps(scan()).encode(),
                  'os_release': {'ID': 'debian', 'VERSION_ID': '12', 'VERSION_CODENAME': 'bookworm'},
                  'package_inventory': 'zlib1g\t1:1.2.13.dfsg-1\tamd64\tii \n',
                  'package_files': '/.\n/lib\n/lib/x86_64-linux-gnu\n/' + review.LIBRARY + '\n/' + review.SONAME_PATH + '\n',
                  'installed_library_bytes': library, 'deb_bytes': archive, 'reviewed_deb_sha256': review.sha(archive)}
        return {**result, **changes}

    def validate(self, context):
        # Synthetic archives cannot equal the real official digest. This test
        # patch emulates a separately reviewed digest, never production data.
        with patch.object(review, 'OFFICIAL_DEB_SHA256', context['reviewed_deb_sha256']):
            return review.review_facts(**context)

    def test_positive_evidence_remains_pending_package_only_and_preserves_raw_scan(self):
        context = self.context()
        original = context['raw_scan_bytes']
        result = self.validate(context)
        self.assertEqual(result['status'], 'pending_technical_review')
        self.assertEqual(result['candidateStatus'], 'not_affected')
        self.assertTrue(result['packageScopeOnly'])
        self.assertTrue(result['reviewRequired'])
        self.assertEqual(result['rawFindingSeverity'], 'CRITICAL')
        for field in ('wholeImageNotAffected', 'riskAccepted', 'severityDowngraded', 'rawScanModified', 'gateOverrideApplied', 'realRestoreApproved', 'debianRepositorySignatureVerified', 'ciCollectorProvenanceVerified'):
            self.assertFalse(result[field], field)
        self.assertEqual(context['raw_scan_bytes'], original)

    def test_four_previously_accepted_fake_evidence_cases_are_rejected(self):
        variants = [self.context(elf(soname=None, needed='libz.so.1')), self.context(b'\x7fELF'),
                    self.context(package_inventory='zlib1g\t1:1.2.13.dfsg-1\tamd64\tiiR\n'),
                    self.context(package_inventory='zlib1g\tforeign\tarm64\tii \nzlib1g\t1:1.2.13.dfsg-1\tamd64\tii \n')]
        for context in variants:
            with self.subTest(case=review.sha(context['installed_library_bytes'])), self.assertRaises(review.EvidenceRejected):
                self.validate(context)

    def test_elf_class_endianness_machine_defined_api_and_minizip_are_checked(self):
        for offset, value in ((4, 1), (5, 2), (18, 183)):
            binary = bytearray(elf())
            binary[offset] = value
            with self.subTest(offset=offset), self.assertRaises(review.EvidenceRejected):
                self.validate(self.context(bytes(binary)))
        for library in (elf(undefined=True), elf(symbol_override='zipOpenNewFileInZip4_64'), elf(needed='libminizip.so.1'), elf(soname='other.so')):
            with self.assertRaises(review.EvidenceRejected):
                self.validate(self.context(library))

    def test_runtime_dynamic_tables_cannot_reference_unmapped_or_wrong_bytes(self):
        binary = bytearray(elf())
        struct.pack_into('<Q', binary, 192 + 16 + 8, 999999)  # DT_STRTAB unmapped.
        with self.assertRaises(review.EvidenceRejected):
            self.validate(self.context(bytes(binary)))

    def test_installed_bytes_package_paths_and_reviewed_deb_digest_must_match(self):
        context = self.context()
        for change in ({'installed_library_bytes': elf() + b'changed'}, {'deb_bytes': context['deb_bytes'] + b'tampered'},
                       {'package_files': '/tmp/libz.so.1.2.13.decoy\n'}, {'reviewed_deb_sha256': '0' * 64}):
            with self.subTest(change=list(change)), self.assertRaises(review.EvidenceRejected):
                self.validate({**context, **change})
        with self.assertRaises(review.EvidenceRejected):
            review.review_facts(**context)  # Real fixed digest cannot be caller-replaced.

    def test_exact_debian_package_identity_and_no_minizip_are_required(self):
        for fields in ({'Package': 'other'}, {'Version': 'other'}, {'Architecture': 'arm64'}, {'Source': 'other'}):
            context = self.context()
            context['deb_bytes'] = deb(context['installed_library_bytes'], control_extra=fields)
            context['reviewed_deb_sha256'] = review.sha(context['deb_bytes'])
            with self.assertRaises(review.EvidenceRejected):
                self.validate(context)
        with self.assertRaises(review.EvidenceRejected):
            self.validate(self.context(package_inventory='zlib1g\t1:1.2.13.dfsg-1\tamd64\tii \nlibminizip1\t1.1\tamd64\tii \n'))

    def test_archive_paths_links_duplicates_specials_and_truncation_are_refused_in_memory(self):
        cases = [[('../escape', 'file', b'no')], [('/absolute', 'file', b'no')],
                 [('unsafe', 'symlink', '../../escape')], [('unsafe', 'hardlink', review.LIBRARY)],
                 [(review.LIBRARY, 'file', b'duplicate')]]
        for extra in cases:
            context = self.context()
            context['deb_bytes'] = deb(context['installed_library_bytes'], extra=extra)
            context['reviewed_deb_sha256'] = review.sha(context['deb_bytes'])
            with self.subTest(kind=extra[0][1]), self.assertRaises(review.EvidenceRejected):
                self.validate(context)
        with self.assertRaises(review.EvidenceRejected):
            review.ar_members(self.context()['deb_bytes'][:-1])

    def test_raw_scan_os_purl_and_finding_bindings_cannot_be_reused_for_other_products(self):
        def mutations(data):
            yield {**data, 'SchemaVersion': 1}
            changed = copy.deepcopy(data); changed['Metadata']['ImageID'] = 'sha256:' + 'f' * 64; yield changed
            changed = copy.deepcopy(data); changed['Metadata']['OS']['Name'] = '13'; yield changed
            changed = copy.deepcopy(data); changed['Results'][0]['Vulnerabilities'][0]['InstalledVersion'] = 'other'; yield changed
            changed = copy.deepcopy(data); changed['Results'][0]['Vulnerabilities'][0]['PkgIdentifier']['PURL'] = 'pkg:deb/debian/zlib1g@1.2.13.dfsg-1?arch=arm64&distro=debian-12.13&epoch=1'; yield changed
            changed = copy.deepcopy(data); changed['Results'][0]['Vulnerabilities'][0]['PkgIdentifier']['PURL'] += '&arch=amd64'; yield changed
            changed = copy.deepcopy(data); changed['Results'][0]['Vulnerabilities'] *= 2; yield changed
        for data in mutations(scan()):
            with self.assertRaises(review.EvidenceRejected):
                self.validate(self.context(raw_scan_bytes=json.dumps(data).encode()))
        with self.assertRaises(review.EvidenceRejected):
            self.validate(self.context(os_release={'ID': 'debian', 'VERSION_ID': '13', 'VERSION_CODENAME': 'trixie'}))


if __name__ == '__main__':
    unittest.main()
