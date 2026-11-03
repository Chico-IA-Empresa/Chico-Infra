FROM docker.io/library/caddy@sha256:cc447f149425221422153c6cdf33a123b3f458839679f950298f68a690a54a5b
RUN apk add --no-cache --upgrade 'brotli-libs=1.2.1-r0'
