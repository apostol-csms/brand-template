# Плавающий тег upstream'а — см. комментарий в .docker/pgbouncer/Dockerfile.
ARG PGWEB_IMAGE=sosedoff/pgweb:latest
FROM ${PGWEB_IMAGE}

ENTRYPOINT /usr/bin/pgweb --bind=0.0.0.0 --listen=8081 --skip-open --lock-session
