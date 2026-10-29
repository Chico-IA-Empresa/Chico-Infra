# Fragment appended to the hash-checked 45909f8 baseline by prepare_context.py.
# Build the generated Dockerfile.combined, never this fragment by itself.
FROM baseline AS libxmlcompiler
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY runner-ca.crt /etc/ssl/certs/ca-certificates.crt
RUN test "$(pgbackrest version)" = 'pgBackRest 2.57.0' \
    && postgres --version | grep -E '^postgres \(PostgreSQL\) 16\.13([ .]|$)' \
    && mkdir /baseline \
    && cp -L /usr/lib/x86_64-linux-gnu/libxml2.so.2 /baseline/libxml2.so.2 \
    && cp -L /lib/x86_64-linux-gnu/libc.so.6 /baseline/libc.so.6 \
    && sha256sum /lib/x86_64-linux-gnu/libc.so.6 /usr/lib/postgresql/16/bin/postgres > /baseline/runtime.sha256 \
    && dpkg-query -W -f='${Version}' libxml2 > /baseline/package-version \
    && apt-get update \
    && apt-get install -y --no-install-recommends build-essential dpkg-dev binutils pkg-config \
       libicu-dev liblzma-dev zlib1g-dev libreadline-dev "libxml2-dev=$(cat /baseline/package-version)" \
    && cmp /baseline/libxml2.so.2 /usr/lib/x86_64-linux-gnu/libxml2.so.2 \
    && rm -rf /var/lib/apt/lists/*
COPY source-pins.json build.sh layout.c xml-normal.c /candidate-input/
COPY verified-sources/ /sources/
RUN bash /candidate-input/build.sh

FROM baseline
USER root
COPY --from=libxmlcompiler /opt/chico-libxml-candidate /opt/chico-libxml-candidate
# No ldconfig/LD_LIBRARY_PATH, package installation, version relabel or replacement
# of the baseline library. Only explicitly selected benign tests load the candidate.
RUN sha256sum /lib/x86_64-linux-gnu/libc.so.6 /usr/lib/postgresql/16/bin/postgres > /tmp/runtime.sha256 \
    && cmp /tmp/runtime.sha256 /opt/chico-libxml-candidate/evidence/runtime.sha256 \
    && rm /tmp/runtime.sha256
USER postgres
ENTRYPOINT ["/usr/local/bin/pgbackrest"]
CMD ["version"]
