ARG FIXTURE_BASE
FROM ${FIXTURE_BASE}
LABEL org.chico.fixture="synthetic-dev-infra"
USER 65534:65534
ENTRYPOINT ["/bin/sh", "-c", "test $(uname -m) = aarch64 && printf 'chico-dev-arm64-fixture-v1\\n'"]
