# Source/base are immutable. APT packages are inventoried, not claimed hermetic.
FROM postgres:16.13-bookworm@sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root
COPY runner-ca.crt /etc/ssl/certs/ca-certificates.crt
RUN sha256sum /etc/ssl/certs/ca-certificates.crt > /opt/chico-apt-bootstrap-ca.sha256 \
    && sed -i 's|http://|https://|g' /etc/apt/sources.list.d/* \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl gcc libc6-dev meson ninja-build pkg-config \
       libbz2-dev liblz4-dev libpq-dev libssl-dev libxml2-dev libyaml-dev libzstd-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
RUN curl --fail --location --proto '=https' --tlsv1.2 \
      https://codeload.github.com/pgbackrest/pgbackrest/tar.gz/d9773a31c97077761ee8e7d06e073b0b0734e26f \
      -o /tmp/source.tar.gz \
    && echo '61d3183877da9a809a889e61d3c0bd0dc9b3498e0777aeba1d34aa1c16a16b74  /tmp/source.tar.gz' | sha256sum -c - \
    && mkdir /source \
    && tar -xzf /tmp/source.tar.gz -C /source --strip-components=1 \
    && meson setup /build /source --buildtype=release -Dlibssh2=disabled -Dlibzstd=enabled \
    && ninja -C /build \
    && install -m 0755 /build/src/pgbackrest /usr/local/bin/pgbackrest \
    && mkdir /build-provenance \
    && dpkg-query -W -f='${Package}\t${Version}\n' | LC_ALL=C sort > /build-provenance/packages.tsv \
    && gcc --version > /build-provenance/compiler.txt \
    && meson configure /build > /build-provenance/meson.txt \
    && cp /opt/chico-apt-bootstrap-ca.sha256 /build-provenance/runner-ca.sha256 \
    && sha256sum /tmp/source.tar.gz > /build-provenance/source.sha256

FROM postgres:16.13-bookworm@sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root
COPY runner-ca.crt /etc/ssl/certs/ca-certificates.crt
RUN sha256sum /etc/ssl/certs/ca-certificates.crt > /opt/chico-apt-bootstrap-ca.sha256 \
    && sed -i 's|http://|https://|g' /etc/apt/sources.list.d/* \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libbz2-1.0 liblz4-1 libxml2 libzstd1 \
       libgnutls30=3.7.9-2+deb12u7 libperl5.36=5.36.0-7+deb12u4 \
       perl=5.36.0-7+deb12u4 perl-base=5.36.0-7+deb12u4 perl-modules-5.36=5.36.0-7+deb12u4 \
    && apt-cache rdepends --installed libsqlite3-0 > /opt/chico-sqlite-reverse-dependencies.txt \
    && apt-get -s purge libsqlite3-0 > /opt/chico-sqlite-purge-simulation.txt \
    && awk '$1 == "Remv" || $1 == "Purg" { sub(/:amd64$/, "", $2); print $2 }' /opt/chico-sqlite-purge-simulation.txt | LC_ALL=C sort -u > /opt/chico-sqlite-purge-removals.txt \
    && cat /opt/chico-sqlite-reverse-dependencies.txt /opt/chico-sqlite-purge-simulation.txt /opt/chico-sqlite-purge-removals.txt \
    && test "$(cat /opt/chico-sqlite-purge-removals.txt)" = 'libsqlite3-0' \
    && apt-get purge -y libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/local/bin/gosu
COPY --from=build /usr/local/bin/pgbackrest /usr/local/bin/pgbackrest
COPY --from=build /build-provenance /opt/chico-toolchain/build
RUN set -eux \
    && mkdir -p /opt/chico-toolchain \
    && test ! -e /usr/local/bin/gosu \
    && ! command -v python3 \
    && ! test -e /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 \
    && test "$(pgbackrest version)" = 'pgBackRest 2.57.0' \
    && postgres --version | grep -E '^postgres \(PostgreSQL\) 16\.13([ .]|$)' \
    && dpkg-query -W -f='${Package}\t${Version}\n' | LC_ALL=C sort > /opt/chico-toolchain/packages.tsv \
    && sha256sum /usr/local/bin/pgbackrest /usr/lib/postgresql/16/bin/postgres \
       /usr/lib/postgresql/16/bin/pg_controldata /usr/lib/postgresql/16/bin/pg_waldump \
       > /opt/chico-toolchain/binaries.sha256 \
    && ldd /usr/local/bin/pgbackrest > /opt/chico-toolchain/pgbackrest-ldd.txt \
    && ldd /usr/lib/postgresql/16/bin/postgres > /opt/chico-toolchain/postgres-ldd.txt \
    && cp /opt/chico-sqlite-*.txt /opt/chico-toolchain/ \
    && cp /opt/chico-apt-bootstrap-ca.sha256 /opt/chico-toolchain/runner-ca.sha256 \
    && ! grep -q 'not found' /opt/chico-toolchain/pgbackrest-ldd.txt \
    && ! grep -q 'not found' /opt/chico-toolchain/postgres-ldd.txt
LABEL org.opencontainers.image.title="Chico isolated PostgreSQL16 restore toolchain" \
      org.opencontainers.image.source="https://github.com/pgbackrest/pgbackrest" \
      org.opencontainers.image.revision="d9773a31c97077761ee8e7d06e073b0b0734e26f"
# Override the upstream auto-initdb entrypoint. Every run must cover its inherited VOLUME.
USER postgres
ENTRYPOINT ["/usr/local/bin/pgbackrest"]
CMD ["version"]
