#!/bin/bash
# Compile the vendor-patched LIBRARY ONLY. No check/runtest/testapi/fuzz target.
set -euo pipefail
umask 022
cd /sources
printf '%s\n' \
  '4fe913dec8b1ab89d13b489b419a8203176ea39e931eaa0d25b17eafb9c279e9  libxml2_2.9.14+dfsg.orig.tar.xz' \
  'd2d821830eb60edbcfcbe30e2827420e9e439e98c85c812352969cdda764d60b  libxml2_2.9.14+dfsg-1.3ubuntu3.10.debian.tar.xz' \
  '1e2a56b4ae292abd2715b1f411cfa30f1b31ef9013c60d2f906d4a68b165cd4c  libxml2_2.9.14+dfsg-1.3ubuntu3.10.dsc' | sha256sum -c -
# InRelease->Sources authenticates all three complete files. Uploader .dsc
# signature is not a substitute for that repository chain (nor claimed here).
mkdir /source
dpkg-source --no-check -x libxml2_2.9.14+dfsg-1.3ubuntu3.10.dsc /source/libxml2
task_out=/opt/chico-libxml-candidate
mkdir -p "$task_out/evidence"
cp /sources/provenance.json "$task_out/evidence/source-provenance.json"
cp /candidate-input/source-pins.json "$task_out/evidence/"
cp /baseline/runtime.sha256 "$task_out/evidence/"
cp /baseline/package-version "$task_out/evidence/baseline-package-version"
cc /candidate-input/layout.c $(pkg-config --cflags libxml-2.0) -o /tmp/layout-before
/tmp/layout-before > "$task_out/evidence/layout-before.txt"
(cd /usr/include/libxml2/libxml; sha256sum *.h | LC_ALL=C sort -k2) > "$task_out/evidence/headers-before.sha256"
cd /source/libxml2
./configure --prefix="$task_out" --without-python --with-icu --with-history \
  --with-lzma --with-zlib --disable-static \
  CFLAGS='-O2 -g -fPIC -fstack-protector-strong' LDFLAGS='-Wl,-z,relro,-z,now'
make -j2 libxml2.la
make install-libLTLIBRARIES
cc /candidate-input/layout.c -I/source/libxml2/include -o /tmp/layout-after
/tmp/layout-after > "$task_out/evidence/layout-after.txt"
(cd /source/libxml2/include/libxml; sha256sum *.h | LC_ALL=C sort -k2) > "$task_out/evidence/headers-after.sha256"
cc /candidate-input/xml-normal.c -I/source/libxml2/include -L"$task_out/lib" -lxml2 -ldl -o "$task_out/xml-normal-probe"
nm -D --defined-only -P /baseline/libxml2.so.2 | awk '{print $1}' | LC_ALL=C sort -u > "$task_out/evidence/symbols-before.txt"
nm -D --defined-only -P "$task_out/lib/libxml2.so.2" | awk '{print $1}' | LC_ALL=C sort -u > "$task_out/evidence/symbols-after.txt"
readelf -d /baseline/libxml2.so.2 > "$task_out/evidence/dynamic-before.txt"
readelf -d "$task_out/lib/libxml2.so.2" > "$task_out/evidence/dynamic-after.txt"
readelf --version-info /baseline/libc.so.6 > "$task_out/evidence/baseline-libc-versions.txt"
readelf --version-info "$task_out/lib/libxml2.so.2" > "$task_out/evidence/candidate-versions.txt"
sha256sum /baseline/libxml2.so.2 "$task_out/lib/libxml2.so.2" > "$task_out/evidence/library-sha256.txt"
dpkg-query -W -f='${Package}\t${Version}\n' | LC_ALL=C sort > "$task_out/evidence/compiler-packages.tsv"
cp config.log "$task_out/evidence/configure.log"
# Sources contain vendor regression files as part of the complete distribution;
# no upstream regression executable/target or XML corpus is invoked or exported.
rm -f "$task_out/lib/libxml2.la"
