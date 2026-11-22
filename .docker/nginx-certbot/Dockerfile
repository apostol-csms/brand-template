# Базовый образ Nginx
# Реестр базового образа параметризован: по умолчанию Docker Hub,
# бренд с собственным зеркалом подставляет своё через BASE_REGISTRY.
ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/nginx:stable-bookworm

# Установка необходимых пакетов
RUN apt-get update && apt-get install -y \
    certbot \
    python3-certbot-nginx \
    gettext-base \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Создание необходимых директорий
RUN mkdir /var/nginx; \
    mkdir /var/nginx/client_body_temp; \
    mkdir /var/nginx/proxy_temp; \
    mkdir /var/www; \
    mkdir /var/www/certbot; \
    mkdir /var/www/frontend; \
    mkdir /var/www/oauth; #legacy, kept for directory structure

# Копирование SSL сертификатов
COPY ./certbot/letsencrypt /etc/letsencrypt

# Копирование конфигурации Nginx
COPY ./nginx.conf /etc/nginx/nginx.conf
COPY ./default.conf.template /etc/nginx/conf.d/default.conf.template
COPY ./includes/ /etc/nginx/includes/

# Копирование Swagger UI / API docs
COPY ./frontend/docs /var/www/docs
# Templates of the Swagger UI documents and its OAuth2 settings (brands/_lib/mk-openapi.py writes the
# two documents); the entrypoint renders them into /var/www/docs per deployment. An image without a
# usable document is refused here instead of serving a Swagger UI that cannot load its file.
COPY ./docs-templates /etc/nginx/docs.d
RUN set -e; \
    for t in api.yaml api-v2.yaml oauth-config.js; do \
      test -s "/etc/nginx/docs.d/$t.template" || { echo "docs: $t.template is missing or empty; run brands/_lib/mk-openapi.py" >&2; exit 1; }; \
    done; \
    for t in api.yaml api-v2.yaml; do \
      grep -q '^openapi: ' "/etc/nginx/docs.d/$t.template" || { echo "docs: $t.template is not an OpenAPI document" >&2; exit 1; }; \
      grep -q '${OAUTH_SCOPE}' "/etc/nginx/docs.d/$t.template" || { echo "docs: $t.template has no OAUTH_SCOPE placeholder" >&2; exit 1; }; \
    done; \
    [ "$(grep -c '^  /' /etc/nginx/docs.d/api.yaml.template)" -ge 900 ] || { echo "docs: api.yaml.template has fewer than 900 paths" >&2; exit 1; }; \
    [ "$(grep -c '^  /' /etc/nginx/docs.d/api-v2.yaml.template)" -ge 130 ] || { echo "docs: api-v2.yaml.template has fewer than 130 paths" >&2; exit 1; }

# Копирование сайтов
COPY ./frontend /var/www/frontend
# Auth frontend is now a separate container (auth service)
# COPY ./oauth /var/www/oauth

RUN chown root:www-data -R /var/www

COPY ./tls-rsa.sh /usr/local/bin/tls-rsa
RUN chmod +x /usr/local/bin/tls-rsa
COPY ./renew-status.sh /usr/local/bin/renew-status
RUN chmod +x /usr/local/bin/renew-status
COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
