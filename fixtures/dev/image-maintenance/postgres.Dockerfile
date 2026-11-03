FROM docker.io/library/postgres@sha256:7a8050e52090c5f77effbe7e0cbed4a0587306776c3f26dc99933a63c619eaf1
ENV GOSU_VERSION=1.20
COPY --chmod=0755 gosu-arm64 /usr/local/bin/gosu
