# PRIVATE CANDIDATE: native Noble packages; no mixed Bookworm/Ubuntu libraries.
# Source/base pins are immutable; remaining signed APT dependencies are inventoried.
FROM ubuntu:24.04@sha256:78d4744ead1f5b19b04d0df558ab182a5300903900755e515b2ca4d10eb2044d AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root
COPY runner-ca.crt /etc/ssl/certs/ca-certificates.crt
RUN set -eux \
    && sha256sum /etc/ssl/certs/ca-certificates.crt > /opt/chico-apt-bootstrap-ca.sha256 \
    && sed -i 's|http://|https://|g' /etc/apt/sources.list.d/* \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates curl gcc libc6-dev meson ninja-build pkg-config \
       libbz2-dev liblz4-dev libpq-dev=16.15-0ubuntu0.24.04.1 libssl-dev \
       libxml2-dev=2.9.14+dfsg-1.3ubuntu3.10 libpcre2-8-0=10.42-4ubuntu2.2 libyaml-dev libzstd-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux \
    && curl --fail --location --proto '=https' --tlsv1.2 \
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

FROM ubuntu:24.04@sha256:78d4744ead1f5b19b04d0df558ab182a5300903900755e515b2ca4d10eb2044d
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
USER root
ENV PATH="/usr/lib/postgresql/16/bin:${PATH}" LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=Etc/UTC
COPY runner-ca.crt /etc/ssl/certs/ca-certificates.crt
RUN set -eux \
    && sha256sum /etc/ssl/certs/ca-certificates.crt > /opt/chico-apt-bootstrap-ca.sha256 \
    && sed -i 's|http://|https://|g' /etc/apt/sources.list.d/* \
    && printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 0755 /usr/sbin/policy-rc.d \
    && groupadd --system --gid 999 postgres \
    && useradd --system --uid 999 --gid 999 --home-dir /var/lib/postgresql --create-home --shell /bin/bash postgres \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates postgresql-common \
    && printf 'create_main_cluster = false\n' > /etc/postgresql-common/createcluster.conf \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       postgresql-16=16.15-0ubuntu0.24.04.1 postgresql-client-16=16.15-0ubuntu0.24.04.1 \
       libpq5=16.15-0ubuntu0.24.04.1 libxml2=2.9.14+dfsg-1.3ubuntu3.10 libpcre2-8-0=10.42-4ubuntu2.2 \
       libbz2-1.0 liblz4-1 libzstd1 libyaml-0-2 locales-all \
    && test ! -e /var/lib/postgresql/16/main/PG_VERSION \
    && test ! -e /etc/postgresql/16/main/postgresql.conf \
    && test "$(id -u postgres)" = 999 \
    && test "$(id -g postgres)" = 999 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/pgbackrest /usr/local/bin/pgbackrest
COPY --from=build /build-provenance /opt/chico-toolchain/build
RUN set -eux \
    && mkdir -p /opt/chico-toolchain \
    && test "$(pgbackrest version)" = 'pgBackRest 2.57.0' \
    && postgres --version | grep -E '^postgres \(PostgreSQL\) 16\.15([ .]|$)' \
    && dpkg-query -W -f='${Package}\t${Version}\n' | LC_ALL=C sort > /opt/chico-toolchain/packages.tsv \
    && sha256sum /usr/local/bin/pgbackrest /usr/lib/postgresql/16/bin/postgres \
       /usr/lib/postgresql/16/bin/pg_controldata /usr/lib/postgresql/16/bin/pg_waldump \
       > /opt/chico-toolchain/binaries.sha256 \
    && ldd /usr/local/bin/pgbackrest > /opt/chico-toolchain/pgbackrest-ldd.txt \
    && ldd /usr/lib/postgresql/16/bin/postgres > /opt/chico-toolchain/postgres-ldd.txt \
    && cp /opt/chico-apt-bootstrap-ca.sha256 /opt/chico-toolchain/runner-ca.sha256 \
    && ! grep -q 'not found' /opt/chico-toolchain/pgbackrest-ldd.txt \
    && ! grep -q 'not found' /opt/chico-toolchain/postgres-ldd.txt
LABEL org.opencontainers.image.title="Chico isolated PostgreSQL16 restore toolchain candidate" \
      org.opencontainers.image.source="https://github.com/pgbackrest/pgbackrest" \
      org.opencontainers.image.revision="d9773a31c97077761ee8e7d06e073b0b0734e26f"
# No auto-initdb entrypoint or VOLUME. Runtime isolation still covers the data path.
USER postgres
ENTRYPOINT ["/usr/local/bin/pgbackrest"]
CMD ["version"]
