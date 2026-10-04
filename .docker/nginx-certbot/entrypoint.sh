#!/bin/bash

set -e

# Render default.conf from template using $DOMAIN.
export DOMAIN="${DOMAIN:-localhost}"
envsubst '$DOMAIN' \
  < /etc/nginx/conf.d/default.conf.template \
  > /etc/nginx/conf.d/default.conf

# Trusted edge in front of the node (e.g. a customer L7 load balancer that
# SNATs inbound traffic): restore the real client IP from X-Forwarded-For.
# Space-separated CIDR list in NGINX_REAL_IP_TRUSTED. EMPTY BY DEFAULT —
# directly attached brands keep $remote_addr as the client IP, and the
# /yookassa/callback allowlist keeps working off it. Enable only for a brand
# whose edge OVERWRITES X-Forwarded-For: an edge that merely appends leaves
# the allowlist spoofable through a client-supplied XFF header.
REAL_IP_CONF=/etc/nginx/conf.d/real-ip.conf
if [ -n "$NGINX_REAL_IP_TRUSTED" ]; then
  {
    echo 'real_ip_header X-Forwarded-For;'
    echo 'real_ip_recursive on;'
    for cidr in $NGINX_REAL_IP_TRUSTED; do
      echo "set_real_ip_from $cidr;"
    done
  } > "$REAL_IP_CONF"
else
  : > "$REAL_IP_CONF"
fi

# T716 — the RSA pair next to ECDSA on the stations' hosts, when issued.
/usr/local/bin/tls-rsa

# Start nginx
/usr/sbin/nginx -g 'daemon off;' &

# Certificate renewal over webroot. Plain-HTTP /.well-known/acme-
# challenge/ is served by the ACME-safe :80 server block — no standalone
# conflict with the running nginx, no downtime.
#
# --webroot + --webroot-path force webroot regardless of how the
# certificate was originally obtained (--standalone, --nginx, --webroot —
# any of them).
# --installer null disables the installer step: certificates migrated
#   from the old server carry `installer = nginx` in renewal/*.conf, and
#   without this flag certbot would run the nginx plugin installer after a
#   successful renewal and clobber our hand-written default.conf. The
#   --deploy-hook "nginx -s reload" takes its place.
# --non-interactive — never hang on a prompt.
# --deploy-hook — reload nginx ONLY when a certificate actually renewed,
#   not every 12 hours for nothing.
# --no-random-sleep-on-renew — deterministic timing, easier to spot in
#   the logs.
while true; do
  certbot renew \
    --webroot --webroot-path /var/www/certbot \
    --installer null \
    --non-interactive \
    --deploy-hook "nginx -s reload" \
    --no-random-sleep-on-renew
  sleep 12h & wait $!
done
