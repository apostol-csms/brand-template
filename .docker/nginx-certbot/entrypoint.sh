#!/bin/bash

set -e

# Trusted edge in front of the node (customer load balancer that SNATs
# inbound traffic): restore the real client IP for the two-layer
# /yookassa/callback YooKassa-IP allowlist (nginx allow/deny + the DB-layer
# re-check via X-Real-IP). Two modes, both opt-in, EMPTY BY DEFAULT —
# directly attached brands keep $remote_addr as the client IP:
#   NGINX_PROXY_PROTOCOL=on   L4 edge with PROXY protocol (TLS passthrough):
#                             the public 443 listener requires the PROXY
#                             header (real_ip_header proxy_protocol).
#   NGINX_REAL_IP_TRUSTED     Space-separated CIDRs of the edge whose header
#                             is trusted — and nothing else.
# For an XFF (L7) edge: the edge must OVERWRITE X-Forwarded-For — an
# appending edge leaves the allowlist spoofable via a client-supplied XFF.

export NGINX_PROXY_PROTO_OPTS=""
REAL_IP_RECURSIVE="real_ip_recursive on;"
REAL_IP_HEADER="X-Forwarded-For"
if [ "${NGINX_PROXY_PROTOCOL:-}" = "on" ]; then
  # PROXY protocol edge (e.g. cloud.ru L4 LB with TLS passthrough): the
  # public 443 listener requires the PROXY header and nginx restores the
  # real client IP from it, preferring it over any client-supplied
  # X-Forwarded-For value. Cutover is one action on the LB side; the gap
  # until then is a short, accepted outage (testing stands).
  NGINX_PROXY_PROTO_OPTS=" proxy_protocol"
  REAL_IP_RECURSIVE=""
  REAL_IP_HEADER="proxy_protocol"
fi
# workdir/.env is also bash-sourced in places: the value may arrive quoted.
NGINX_REAL_IP_TRUSTED="${NGINX_REAL_IP_TRUSTED//[\"\']}"
REAL_IP_CONF=/etc/nginx/conf.d/real-ip.conf
if [ -n "$NGINX_REAL_IP_TRUSTED" ]; then
  {
    echo "real_ip_header $REAL_IP_HEADER;"
    [ -n "$REAL_IP_RECURSIVE" ] && echo "$REAL_IP_RECURSIVE"
    for cidr in $NGINX_REAL_IP_TRUSTED; do
      echo "set_real_ip_from $cidr;"
    done
  } > "$REAL_IP_CONF"
else
  : > "$REAL_IP_CONF"
fi

# Render default.conf from template. envsubst whitelists $DOMAIN, $ALT_DOMAIN (where present) and $NGINX_PROXY_PROTO_OPTS so unrelated `$variable` strings survive untouched.
export DOMAIN="${DOMAIN:-localhost}"
envsubst '$DOMAIN $NGINX_PROXY_PROTO_OPTS' \
  < /etc/nginx/conf.d/default.conf.template \
  > /etc/nginx/conf.d/default.conf

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
#
# One failed line must not take the edge down. `certbot renew` exits
# 1 when any lineage fails (ACME unreachable, a name whose DNS left this
# host), and under `set -e` that ended this script — PID 1 — and with it
# nginx and the stations' wss, in a restart loop. The failure is now one
# plain log line, nginx keeps serving the certificates it has, and the
# outcome of every pass lands in $RENEW_STATUS for `renew-status` and
# check.sh [renew].
RENEW_STATUS=/run/certbot-renew.status
rm -f "$RENEW_STATUS"   # /run survives `docker restart`: no stale outcome
while true; do
  rc=0
  certbot renew \
    --webroot --webroot-path /var/www/certbot \
    --installer null \
    --non-interactive \
    --deploy-hook "nginx -s reload" \
    --no-random-sleep-on-renew || rc=$?
  echo "$rc $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RENEW_STATUS"
  if [ "$rc" -ne 0 ]; then
    echo "certbot-renew: FAILED rc=$rc — at least one certificate line did not renew; nginx keeps serving the current certificates. Lines and days left: docker exec nginx renew-status; details (incl. \"Another instance of Certbot\" when a manual certbot ran at the same time): /var/log/letsencrypt/letsencrypt.log" >&2
  fi
  sleep 12h & wait $!
done
