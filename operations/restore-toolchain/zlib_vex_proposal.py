"""Build a narrowly bound technical proposal, never a scan-gate override.

Debian's source advisory says contrib/minizip is not built for bookworm zlib.
The generated statement additionally binds actual image/package/library/symbols.
Raw scan findings remain unchanged; coordinator review is still required.
"""
import hashlib
import re

SOURCE = "https://security-tracker.debian.org/tracker/CVE-2023-45853"
PACKAGE_VERSION = "1:1.2.13.dfsg-1"
PURL = "pkg:deb/debian/zlib1g@1.2.13.dfsg-1?arch=amd64&distro=debian-12.13&epoch=1"


def proposal(*, image_id, package_inventory, package_files, binary, dynamic_symbols, dynamic_section):
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise ValueError("Exact image id required for technical statement")
    packages = {}
    for line in package_inventory.splitlines():
        name, version, architecture, status = line.split("\t")
        if status.startswith("ii"):
            packages[name] = (version, architecture)
    if packages.get("zlib1g") != (PACKAGE_VERSION, "amd64"):
        raise ValueError("Statement does not cover this package/version/architecture")
    if any("minizip" in name for name in packages) or "minizip" in package_files.lower():
        raise ValueError("MiniZip package/file detected; not covered by statement")
    if not binary.startswith(b"\x7fELF") or "libz.so.1" not in dynamic_section:
        raise ValueError("Actual ELF libz.so.1 evidence required")
    if not dynamic_symbols.strip() or "zipOpenNewFileInZip4_64" in dynamic_symbols or "unzOpen" in dynamic_symbols:
        raise ValueError("Missing symbols evidence or vulnerable MiniZip symbols present")
    if not re.search(r"\blibz\.so\.1\.2\.13\b", package_files):
        raise ValueError("Expected package-owned runtime library missing")
    digest = hashlib.sha256(binary).hexdigest()
    return {"schemaVersion": 1, "kind": "technical-vex-proposal", "vulnerability": "CVE-2023-45853",
            "status": "not_affected", "justification": "vulnerable_code_not_present",
            "imageId": image_id, "packagePURL": PURL, "packageVersion": PACKAGE_VERSION,
            "sourceAdvisory": SOURCE, "sourceReviewedOn": "2026-10-29",
            "sourceRationale": "Debian bookworm zlib does not build contrib/minizip; this finding concerns that component.",
            "libraryPath": "/lib/x86_64-linux-gnu/libz.so.1", "librarySHA256": digest,
            "packageInventorySHA256": hashlib.sha256(package_inventory.encode()).hexdigest(),
            "packageFilesSHA256": hashlib.sha256(package_files.encode()).hexdigest(),
            "dynamicSymbolsSHA256": hashlib.sha256(dynamic_symbols.encode()).hexdigest(),
            "sonameEvidenceSHA256": hashlib.sha256(dynamic_section.encode()).hexdigest(),
            "miniZipPackageOrSymbolsPresent": False, "reviewRequired": True,
            "rawScanModified": False, "gateOverrideApplied": False, "realRestoreApproved": False}
