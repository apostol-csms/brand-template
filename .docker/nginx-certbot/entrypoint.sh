#!/bin/bash

set -e

# Render default.conf from template using $DOMAIN.
export DOMAIN="${DOMAIN:-localhost}"
envsubst '$DOMAIN' \
  < /etc/nginx/conf.d/default.conf.template \
  > /etc/nginx/conf.d/default.conf

# Запуск Nginx
/usr/sbin/nginx -g 'daemon off;' &

# Обновление сертификатов через webroot. Plain-HTTP /.well-known/acme-
# challenge/ обслуживается ACME-safe :80 server'ом — никаких standalone-
# конфликтов с running nginx, никакого downtime.
#
# --webroot + --webroot-path форсируют webroot независимо от того, чем
# был получен серт изначально (--standalone, --nginx, --webroot — любой).
# --non-interactive — не зависнуть на prompt'е.
# --deploy-hook — reload nginx ТОЛЬКО при реальном обновлении серта,
#   а не каждые 12 часов вхолостую.
# --no-random-sleep-on-renew — детерминированный таймер, удобнее ловить
#   в логах.
while true; do
  certbot renew \
    --webroot --webroot-path /var/www/certbot \
    --non-interactive \
    --deploy-hook "nginx -s reload" \
    --no-random-sleep-on-renew
  sleep 12h & wait $!
done
