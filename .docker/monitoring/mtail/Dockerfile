# Access-log parser for the edge nginx. No published image exists, so the release binary is
# fetched at build time and verified against a pinned digest; the result stays local.
ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/alpine:3.22 AS fetch
ARG MTAIL_VERSION=3.4.21
ARG MTAIL_SHA256_AMD64=1e1fafaa0d440c63776e89062bca3b53579d93b979428014d817860ddda6682a
ARG MTAIL_SHA256_ARM64=feca10316e23c97b258c98149f59cdf4cd30e5b7ccfacc433300c4246507f8e2
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) sum="$MTAIL_SHA256_AMD64" ;; \
      arm64) sum="$MTAIL_SHA256_ARM64" ;; \
      *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    f="mtail_${MTAIL_VERSION}_linux_${TARGETARCH:-amd64}.tar.gz"; \
    wget -q -O "/tmp/$f" "https://github.com/jaqx0r/mtail/releases/download/v${MTAIL_VERSION}/$f"; \
    echo "$sum  /tmp/$f" | sha256sum -c -; \
    tar -xzf "/tmp/$f" -C /tmp mtail

FROM ${BASE_REGISTRY}/alpine:3.22
COPY --from=fetch /tmp/mtail /usr/local/bin/mtail
COPY nginx.mtail /etc/mtail/nginx.mtail
USER 65534:65534
EXPOSE 3903
ENTRYPOINT ["/usr/local/bin/mtail"]
CMD ["--progs", "/etc/mtail", "--logs", "/var/log/nginx/main_access.text.log", "--port", "3903"]
