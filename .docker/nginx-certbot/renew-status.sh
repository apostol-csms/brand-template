#!/bin/sh
# The state of certificate renewal, for check.sh [renew] and for a
# human: `docker exec nginx renew-status`.
#
# One record per line:
#   last <rc> <utc>      outcome of the last `certbot renew` pass of
#                        entrypoint.sh; `last none` before the first pass ends
#   line <name> <days>   every lineage certbot renews (renewal/<name>.conf)
#                        and the whole days left on its certificate;
#                        `line <name> unreadable` when live/<name>/ has none
#
# A lineage taken out of renewal by hand (renewal/<name>.conf renamed) is
# not listed: it is no longer renewed, so its expiry is not a renewal fault.

set -u

STATUS=/run/certbot-renew.status
if [ -s "$STATUS" ]; then
  echo "last $(cat "$STATUS")"
else
  echo "last none"
fi

now=$(date +%s)
for conf in /etc/letsencrypt/renewal/*.conf; do
  [ -e "$conf" ] || continue
  name=$(basename "$conf" .conf)
  end=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$name/cert.pem" 2>/dev/null | cut -d= -f2)
  if [ -z "$end" ]; then
    echo "line $name unreadable"
    continue
  fi
  if ! endsec=$(date -d "$end" +%s 2>/dev/null); then
    echo "line $name unreadable"
    continue
  fi
  echo "line $name $(( (endsec - now) / 86400 ))"
done
