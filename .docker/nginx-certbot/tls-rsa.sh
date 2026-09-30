#!/bin/sh
# T716 — an RSA 2048 certificate next to the ECDSA one on the hosts stations
# connect to (ocpp./ws.; graftio: csms./ws.).
#
# OCPP-J 1.6 §6.2.1: the server certificate SHALL be RSA, no more than 2048
# bits. OCPP 2.0.1 A00.FR.318: the CSMS serves both ECDSA and RSA cipher
# suites, i.e. two certificates. nginx takes two ssl_certificate pairs in one
# server block and picks the one the client can use.
#
# default.conf includes /etc/nginx/tls/rsa-<host>.conf in those blocks. This
# script writes every such file: the RSA pair when certbot has issued it as
# /etc/letsencrypt/live/<host>-rsa/, a comment otherwise — so nginx starts with
# or without it (ECDSA only then). entrypoint.sh runs it at start; after the
# first issue run it by hand:
#
#   docker exec nginx certbot certonly --webroot -w /var/www/certbot \
#     --non-interactive --key-type rsa --rsa-key-size 2048 \
#     --cert-name ocpp.<domain>-rsa -d ocpp.<domain>
#   docker exec nginx sh -c 'tls-rsa && nginx -t && nginx -s reload'
#
# Renewal needs nothing: `certbot renew` keeps each lineage's key type.

set -eu

CONF=/etc/nginx/conf.d/default.conf
mkdir -p /etc/nginx/tls

for inc in $(grep -o '/etc/nginx/tls/rsa-[A-Za-z0-9.-]*\.conf' "$CONF" | sort -u); do
  host=${inc#/etc/nginx/tls/rsa-}
  host=${host%.conf}
  live="/etc/letsencrypt/live/${host}-rsa"
  if [ -s "$live/fullchain.pem" ] && [ -s "$live/privkey.pem" ]; then
    printf 'ssl_certificate %s/fullchain.pem;\nssl_certificate_key %s/privkey.pem;\n' "$live" "$live" > "$inc"
    echo "tls-rsa: $host — ECDSA + RSA"
  else
    echo "# $live is not issued — ECDSA only (T716)" > "$inc"
    echo "tls-rsa: $host — no RSA certificate, ECDSA only"
  fi
done
