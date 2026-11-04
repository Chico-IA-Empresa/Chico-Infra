"""Package-scoped evidence review only; never a scan exception or approved VEX.

No network, subprocess, binary execution, or filesystem extraction. The fixed
Debian package digest was checked against Debian's official download page.
Repository-signature/CI provenance and technical acceptance remain pending.
"""
import hashlib
import io
import json
from pathlib import PurePosixPath
import posixpath
import re
import struct
import tarfile
from urllib.parse import parse_qsl

CVE = 'CVE-2023-45853'
VERSION = '1:1.2.13.dfsg-1'
DEB_FILENAME = 'pool/main/z/zlib/zlib1g_1.2.13.dfsg-1_amd64.deb'
OFFICIAL_DEB_SHA256 = 'd7dd1d1411fedf27f5e27650a6eff20ef294077b568f4c8c5e51466dc7c08ce4'
DIGEST_SOURCE = 'https://packages.debian.org/bookworm/amd64/zlib1g/download'
ADVISORY = 'https://security-tracker.debian.org/tracker/CVE-2023-45853'
LIBRARY = 'lib/x86_64-linux-gnu/libz.so.1.2.13'
SONAME_PATH = 'lib/x86_64-linux-gnu/libz.so.1'
MAX_ARCHIVE = 16 * 1024 * 1024


class EvidenceRejected(ValueError):
    """Static codes only; no package/scan contents in exceptions."""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def bounded(data, offset, size):
    if offset < 0 or size < 0 or offset + size > len(data):
        raise EvidenceRejected('truncated_binary_structure')
    return data[offset:offset + size]


def cstring(data, offset):
    if not 0 <= offset < len(data):
        raise EvidenceRejected('invalid_elf_string_offset')
    end = data.find(b'\0', offset)
    if end < 0:
        raise EvidenceRejected('unterminated_elf_string')
    try:
        return data[offset:end].decode('ascii')
    except UnicodeError:
        raise EvidenceRejected('non_ascii_elf_metadata') from None


def elf_facts(binary):
    """Parse actual ELF64 structures, not caller-supplied readelf text."""
    if len(binary) < 64 or len(binary) > MAX_ARCHIVE:
        raise EvidenceRejected('invalid_elf_size')
    ident, kind, machine, version, _, phoff, shoff, _, ehsize, phsize, phnum, shsize, shnum, _ = struct.unpack('<16sHHIQQQIHHHHHH', binary[:64])
    if ident[:7] != b'\x7fELF\x02\x01\x01' or kind != 3 or machine != 62 or version != 1 or ehsize != 64:
        raise EvidenceRejected('elf64_little_endian_amd64_shared_library_required')
    if phsize != 56 or not 0 < phnum <= 256 or shsize != 64 or not 0 < shnum <= 4096:
        raise EvidenceRejected('complete_elf_tables_required')
    programs = [struct.unpack('<IIQQQQQQ', bounded(binary, phoff + i * phsize, phsize)) for i in range(phnum)]
    sections = [struct.unpack('<IIQQQQIIQQ', bounded(binary, shoff + i * shsize, shsize)) for i in range(shnum)]
    dynamic = [section for section in sections if section[1] == 6]
    symbols = [section for section in sections if section[1] == 11]
    if len(dynamic) != 1 or len(symbols) != 1:
        raise EvidenceRejected('unique_dynamic_and_dynsym_sections_required')
    dynamic, symbols = dynamic[0], symbols[0]
    if (dynamic[9] != 16 or dynamic[5] % 16 or symbols[9] != 24 or symbols[5] % 24 or
            not 0 <= dynamic[6] < shnum or dynamic[6] != symbols[6] or sections[dynamic[6]][1] != 3):
        raise EvidenceRejected('invalid_dynamic_symbol_links')
    segments = [p for p in programs if p[0] == 2]
    if len(segments) != 1 or segments[0][2] != dynamic[4] or segments[0][5] != dynamic[5]:
        raise EvidenceRejected('dynamic_section_not_bound_to_runtime_segment')
    strings_section = sections[dynamic[6]]
    strings = bounded(binary, strings_section[4], strings_section[5])
    loads = [p for p in programs if p[0] == 1]
    if not loads:
        raise EvidenceRejected('loadable_elf_segments_required')
    for segment in loads:
        bounded(binary, segment[2], segment[5])

    def runtime_offset(address, size):
        matches = [p[2] + address - p[3] for p in loads if p[3] <= address and address + size <= p[3] + p[5]]
        if len(matches) != 1:
            raise EvidenceRejected('ambiguous_or_unmapped_dynamic_address')
        return matches[0]

    sonames, dependencies, tags, terminated = [], [], {}, False
    for offset in range(dynamic[4], dynamic[4] + dynamic[5], 16):
        tag, value = struct.unpack('<qQ', bounded(binary, offset, 16))
        if tag == 0:
            terminated = True
            break
        if tag == 14:
            sonames.append(cstring(strings, value))
        elif tag == 1:
            dependencies.append(cstring(strings, value))
        elif tag in (5, 6, 10, 11):
            if tag in tags:
                raise EvidenceRejected('ambiguous_dynamic_table_binding')
            tags[tag] = value
    if (set(tags) != {5, 6, 10, 11} or tags[10] != len(strings) or tags[11] != 24 or
            runtime_offset(tags[5], len(strings)) != strings_section[4] or
            runtime_offset(tags[6], symbols[5]) != symbols[4]):
        raise EvidenceRejected('dynamic_tables_not_bound_to_runtime_addresses')
    if not terminated or sonames != ['libz.so.1'] or dependencies != ['libc.so.6']:
        raise EvidenceRejected('exact_runtime_soname_and_dependencies_required')
    if any('minizip' in name.lower() for name in dependencies):
        raise EvidenceRejected('minizip_dependency_not_covered')
    defined, all_names = set(), set()
    for offset in range(symbols[4], symbols[4] + symbols[5], 24):
        name, info, _, section_index, symbol_value, symbol_size = struct.unpack('<IBBHQQ', bounded(binary, offset, 24))
        text = cstring(strings, name)
        all_names.add(text)
        if section_index != 0 and info >> 4 in (1, 2) and info & 15 in (2, 10):
            if not 0 < section_index < shnum or not sections[section_index][2] & 4:
                raise EvidenceRejected('defined_function_not_in_executable_section')
            code = sections[section_index]
            if not code[3] <= symbol_value < code[3] + code[5] or symbol_value + symbol_size > code[3] + code[5]:
                raise EvidenceRejected('defined_function_not_bound_to_executable_bytes')
            defined.add(text)
    if any(name.startswith(('zipOpen', 'unzOpen')) for name in all_names):
        raise EvidenceRejected('minizip_symbols_not_covered')
    if not {'adler32', 'compress', 'crc32', 'deflate', 'inflate', 'zlibVersion'} <= defined:
        raise EvidenceRejected('defined_zlib_dynamic_api_required')
    return {'elfClass': 64, 'endianness': 'little', 'machine': 'amd64', 'soname': sonames[0],
            'neededLibraries': sorted(dependencies), 'definedSymbolNamesSHA256': sha('\n'.join(sorted(defined)).encode())}


def ar_members(data):
    if len(data) > MAX_ARCHIVE or not data.startswith(b'!<arch>\n'):
        raise EvidenceRejected('bounded_debian_ar_archive_required')
    position, result = 8, {}
    while position < len(data):
        header = bounded(data, position, 60)
        try:
            name = header[:16].decode('ascii').strip().removesuffix('/')
            size_text = header[48:58].decode('ascii').strip()
        except UnicodeError:
            raise EvidenceRejected('invalid_ar_header') from None
        if header[58:] != b'`\n' or not re.fullmatch(r'[0-9]+', size_text) or name in result:
            raise EvidenceRejected('invalid_or_duplicate_ar_member')
        if name != 'debian-binary' and not re.fullmatch(r'(?:control|data)\.tar(?:\.xz|\.gz)?', name):
            raise EvidenceRejected('unsupported_ar_member_or_compression')
        size = int(size_text)
        result[name] = bounded(data, position + 60, size)
        position += 60 + size
        if size % 2:
            if bounded(data, position, 1) != b'\n':
                raise EvidenceRejected('invalid_ar_padding')
            position += 1
    if result.get('debian-binary') != b'2.0\n' or len(result) != 3:
        raise EvidenceRejected('exact_debian_package_structure_required')
    if sum(name.startswith('control.tar') for name in result) != 1 or sum(name.startswith('data.tar') for name in result) != 1:
        raise EvidenceRejected('unique_control_and_data_archives_required')
    return result


def safe_tar_path(name):
    if not isinstance(name, str) or '\0' in name or '\\' in name or name.startswith('/'):
        raise EvidenceRejected('unsafe_archive_path')
    while name.startswith('./'):
        name = name[2:]
    name = name.rstrip('/')
    if name in ('', '.'):
        return '.'
    if any(part in ('', '.', '..') for part in name.split('/')):
        raise EvidenceRejected('unsafe_archive_path')
    return name


def tar_members(data):
    result, total = {}, 0
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
            for item in archive:
                name = safe_tar_path(item.name)
                total += item.size
                if name in result or len(result) >= 4096 or not 0 <= item.size <= MAX_ARCHIVE or total > 32 * 1024 * 1024:
                    raise EvidenceRejected('duplicate_or_oversized_tar_member')
                if item.isdir():
                    result[name] = ('directory', b'')
                elif item.isreg():
                    with archive.extractfile(item) as stream:
                        contents = stream.read(item.size + 1)
                    if len(contents) != item.size:
                        raise EvidenceRejected('truncated_tar_member')
                    result[name] = ('file', contents)
                elif item.issym():
                    target = item.linkname
                    if not target or target.startswith('/') or '\0' in target or '\\' in target:
                        raise EvidenceRejected('unsafe_archive_symlink')
                    resolved = posixpath.normpath(str(PurePosixPath(name).parent / target))
                    if resolved == '..' or resolved.startswith('../'):
                        raise EvidenceRejected('unsafe_archive_symlink')
                    result[name] = ('symlink', resolved)
                else:
                    raise EvidenceRejected('hardlinks_devices_or_special_members_refused')
    except (tarfile.TarError, OSError, EOFError):
        raise EvidenceRejected('invalid_compressed_tar_archive') from None
    return result


def control_fields(contents):
    try:
        text = contents.decode('utf-8')
    except UnicodeError:
        raise EvidenceRejected('invalid_debian_control') from None
    result, previous = {}, None
    for line in text.splitlines():
        if line.startswith((' ', '\t')) and previous:
            result[previous] += '\n' + line
            continue
        if not line:
            continue
        key, separator, value = line.partition(':')
        if not separator or not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*', key) or key in result:
            raise EvidenceRejected('ambiguous_debian_control')
        result[key], previous = value.strip(), key
    return result


def package_library(deb_bytes, reviewed_deb_sha256):
    if reviewed_deb_sha256 != OFFICIAL_DEB_SHA256 or sha(deb_bytes) != reviewed_deb_sha256:
        raise EvidenceRejected('deb_differs_from_exact_reviewed_official_digest')
    members = ar_members(deb_bytes)
    control = tar_members(next(value for name, value in members.items() if name.startswith('control.tar')))
    payload = tar_members(next(value for name, value in members.items() if name.startswith('data.tar')))
    if control.get('control', (None,))[0] != 'file':
        raise EvidenceRejected('debian_control_file_required')
    fields = control_fields(control['control'][1])
    if (fields.get('Package') != 'zlib1g' or fields.get('Version') != VERSION or fields.get('Architecture') != 'amd64' or
            fields.get('Source') != 'zlib'):
        raise EvidenceRejected('debian_package_identity_differs')
    if (payload.get(LIBRARY, (None,))[0] != 'file' or payload.get(SONAME_PATH) != ('symlink', LIBRARY) or
            any('minizip' in name.lower() for name in payload)):
        raise EvidenceRejected('exact_package_owned_library_and_soname_link_required')
    return payload[LIBRARY][1], set(payload) - {'.'}


def installed_packages(text):
    result = {}
    for line in text.splitlines():
        fields = line.split('\t')
        if len(fields) != 4:
            raise EvidenceRejected('invalid_package_inventory_row')
        name, version, architecture, status = fields
        if (not re.fullmatch(r'[a-z0-9][a-z0-9+.-]*', name) or name in result or status != 'ii ' or
                not version or not re.fullmatch(r'[a-z0-9][a-z0-9-]*', architecture)):
            raise EvidenceRejected('unique_healthy_installed_package_inventory_required')
        result[name] = (version, architecture)
    if result.get('zlib1g') != (VERSION, 'amd64') or any('minizip' in name for name in result):
        raise EvidenceRejected('package_scope_or_minizip_presence_not_covered')
    return result


def scan_finding(raw_scan, image_id, os_release):
    if not isinstance(os_release, dict) or any(os_release.get(key) != value for key, value in
            {'ID': 'debian', 'VERSION_ID': '12', 'VERSION_CODENAME': 'bookworm'}.items()):
        raise EvidenceRejected('observed_debian_bookworm_os_required')
    try:
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise EvidenceRejected('duplicate_raw_scan_json_key')
                result[key] = value
            return result
        scan = json.loads(raw_scan, object_pairs_hook=unique_object)
        metadata = scan['Metadata']
        if scan['SchemaVersion'] != 2 or metadata['ImageID'] != image_id or metadata['OS']['Family'] != 'debian':
            raise EvidenceRejected('raw_scan_image_or_os_binding_differs')
        release = metadata['OS']['Name']
        if not isinstance(release, str) or not re.fullmatch(r'12(?:\.[0-9]+)?', release):
            raise EvidenceRejected('raw_scan_not_bookworm')
        matches = [(result, finding) for result in scan['Results'] for finding in result.get('Vulnerabilities', [])
                   if finding.get('VulnerabilityID') == CVE and finding.get('PkgName') == 'zlib1g']
        if len(matches) != 1:
            raise EvidenceRejected('one_exact_package_finding_required')
        result, finding = matches[0]
        if result['Class'] != 'os-pkgs' or result['Type'] != 'debian' or finding['InstalledVersion'] != VERSION:
            raise EvidenceRejected('raw_finding_package_identity_differs')
        purl = finding['PkgIdentifier']['PURL']
        prefix, separator, query = purl.partition('?')
        pairs = parse_qsl(query, strict_parsing=True)
        qualifiers = dict(pairs)
        if (not separator or prefix != 'pkg:deb/debian/zlib1g@1.2.13.dfsg-1' or len(pairs) != len(qualifiers) or
                qualifiers != {'arch': 'amd64', 'distro': 'debian-' + release, 'epoch': '1'}):
            raise EvidenceRejected('raw_finding_purl_scope_differs')
        if finding['Severity'] not in {'UNKNOWN', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'}:
            raise EvidenceRejected('known_raw_scan_severity_required')
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        if isinstance(error, EvidenceRejected):
            raise
        raise EvidenceRejected('incomplete_or_invalid_raw_scan') from None
    return finding, purl


def review_facts(*, image_id, raw_scan_bytes, os_release, package_inventory, package_files,
                 installed_library_bytes, deb_bytes, reviewed_deb_sha256):
    if (not isinstance(image_id, str) or not re.fullmatch(r'sha256:[a-f0-9]{64}', image_id) or
            not isinstance(raw_scan_bytes, bytes) or len(raw_scan_bytes) > 64 * 1024 * 1024 or
            not isinstance(installed_library_bytes, bytes) or not isinstance(deb_bytes, bytes) or
            not isinstance(package_inventory, str) or not isinstance(package_files, str)):
        raise EvidenceRejected('immutable_current_image_id_required')
    installed_packages(package_inventory)
    finding, purl = scan_finding(raw_scan_bytes, image_id, os_release)
    packaged_library, paths = package_library(deb_bytes, reviewed_deb_sha256)
    listed = set()
    for line in package_files.splitlines():
        if not line.startswith('/'):
            raise EvidenceRejected('absolute_package_owned_paths_required')
        name = safe_tar_path(line[1:])
        if name in listed:
            raise EvidenceRejected('duplicate_package_owned_path')
        listed.add(name)
    if listed - {'.'} != paths:
        raise EvidenceRejected('installed_package_paths_differ_from_reviewed_deb')
    if installed_library_bytes != packaged_library:
        raise EvidenceRejected('installed_library_differs_from_reviewed_deb')
    facts = elf_facts(installed_library_bytes)
    return {'schemaVersion': 1, 'kind': 'package-scoped-vex-evidence-review',
            'status': 'pending_technical_review', 'candidateStatus': 'not_affected',
            'candidateJustification': 'vulnerable_code_not_present', 'vulnerability': CVE,
            'packageScopeOnly': True, 'wholeImageNotAffected': False, 'imageId': image_id,
            'packagePURL': purl, 'packageVersion': VERSION, 'packageArchitecture': 'amd64',
            'sourceAdvisory': ADVISORY, 'reviewedDebSHA256': reviewed_deb_sha256,
            'reviewedDebFilename': DEB_FILENAME, 'digestSource': DIGEST_SOURCE,
            'installedLibrarySHA256': sha(installed_library_bytes), 'elf': facts,
            'rawScanSHA256': sha(raw_scan_bytes), 'rawFindingSHA256': sha(json.dumps(finding, sort_keys=True).encode()),
            'rawFindingSeverity': finding['Severity'], 'rawScanModified': False,
            'packageInventorySHA256': sha(package_inventory.encode()), 'packageFilesSHA256': sha(package_files.encode()),
            'osReleaseSHA256': sha(json.dumps(os_release, sort_keys=True).encode()),
            'miniZipNotInReviewedDebianPackage': True, 'factChecksPassed': True,
            'debianRepositorySignatureVerified': False, 'ciCollectorProvenanceVerified': False,
            'reviewRequired': True, 'gateOverrideApplied': False, 'riskAccepted': False,
            'severityDowngraded': False, 'realRestoreApproved': False}
