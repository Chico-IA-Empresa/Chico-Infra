# Source/base are immutable. APT packages are inventoried, not claimed hermetic.
FROM postgres:16.13-bookworm@sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d AS build
USER root
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/* \
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
    && sha256sum /tmp/source.tar.gz > /build-provenance/source.sha256

FROM postgres:16.13-bookworm@sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d
USER root
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/* \
    && apt-get update \
    && apt-get install -y --no-install-recommends libbz2-1.0 liblz4-1 libxml2 libzstd1 python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/pgbackrest /usr/local/bin/pgbackrest
COPY --from=build /build-provenance /opt/chico-toolchain/build
RUN mkdir /opt/chico-toolchain \
    && test "$(pgbackrest version)" = 'pgBackRest 2.57.0' \
    && postgres --version | grep -E '^postgres \(PostgreSQL\) 16\.13([ .]|$)' \
    && dpkg-query -W -f='${Package}\t${Version}\n' | LC_ALL=C sort > /opt/chico-toolchain/packages.tsv \
    && sha256sum /usr/local/bin/pgbackrest /usr/lib/postgresql/16/bin/postgres \
       /usr/lib/postgresql/16/bin/pg_controldata /usr/lib/postgresql/16/bin/pg_waldump \
       > /opt/chico-toolchain/binaries.sha256 \
    && ldd /usr/local/bin/pgbackrest > /opt/chico-toolchain/pgbackrest-ldd.txt \
    && ! grep -q 'not found' /opt/chico-toolchain/pgbackrest-ldd.txt
LABEL org.opencontainers.image.title="Chico isolated PostgreSQL16 restore toolchain" \
      org.opencontainers.image.source="https://github.com/pgbackrest/pgbackrest" \
      org.opencontainers.image.revision="d9773a31c97077761ee8e7d06e073b0b0734e26f"
# Override the upstream auto-initdb entrypoint. Every run must cover its inherited VOLUME.
USER postgres
ENTRYPOINT ["/usr/local/bin/pgbackrest"]
CMD ["version"]
