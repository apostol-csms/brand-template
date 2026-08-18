#!/bin/bash

set -e

# Render default.conf from template using $DOMAIN.
export DOMAIN="${DOMAIN:-localhost}"
envsubst '$DOMAIN' \
  < /etc/nginx/conf.d/default.conf.template \
  > /etc/nginx/conf.d/default.conf

# Start nginx
/usr/sbin/nginx -g 'daemon off;' &

# Certificate renewal over webroot. Plain-HTTP /.well-known/acme-
# challenge/ is served by the ACME-safe :80 server block — no standalone
# conflict with the running nginx, no downtime.
#
# --webroot + --webroot-path force webroot regardless of how the
# certificate was originally obtained (--standalone, --nginx, --webroot —
# any of them).
# --non-interactive — never hang on a prompt.
# --deploy-hook — reload nginx ONLY when a certificate actually renewed,
#   not every 12 hours for nothing.
# --no-random-sleep-on-renew — deterministic timing, easier to spot in
#   the logs.
while true; do
  certbot renew \
    --webroot --webroot-path /var/www/certbot \
    --non-interactive \
    --deploy-hook "nginx -s reload" \
    --no-random-sleep-on-renew
  sleep 12h & wait $!
done
