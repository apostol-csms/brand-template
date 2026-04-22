#!/usr/bin/env bash
#
# check.sh — deployment health verification.
#
# Usage:
#   ./check.sh              # colored text, exit 0/1/2 = green/warn/fail
#   ./check.sh --json       # machine-readable JSON for Datadog/Prometheus
#
# Checks:
#   [containers]  all compose services running + healthy
#   [postgres]    pg_isready from inside the container
#   [api]         GET https://${DOMAIN}/api/v1/ping → 200
#   [openid]      GET https://auth.${DOMAIN}/.well-known/openid-configuration
#   [ocpp]        TCP connect :9220
#   [frontend]    GET https://${DOMAIN}/ → 200 (landing)
#   [tls]         cert expiry ≥ 7 days for a sample of subdomains
#   [disk]        filesystem < 85% (warn) / < 90% (fail)
#   [memory]      MemAvailable ≥ 1 GB
#   [version]     workdir/.installed-version matches docker image tag
#
# Exit codes: 0 = all ok, 1 = at least one warn, 2 = at least one fail.

set -uo pipefail

# ─── Globals ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$SCRIPT_DIR/workdir"
JSON=0
MIN_TLS_DAYS=7
DISK_WARN_PCT=85
DISK_FAIL_PCT=90
MIN_RAM_MB=1024

# RESULTS[name]="status|details"
declare -A RESULTS
ORDER=()
OVERALL=0   # 0=ok, 1=warn, 2=fail

# ─── Logging ─────────────────────────────────────────────────────────

if [[ -t 1 && $JSON -eq 0 ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_GREEN=; C_RED=; C_YELLOW=; C_RESET=
fi

for ARG in "$@"; do
  case "$ARG" in
    --json)   JSON=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./check.sh [--json]
  --json   Emit JSON (one-line, per-check status) instead of colored text.
  Exit:  0 = all ok, 1 = warn, 2 = fail.
EOF
      exit 0 ;;
    *) echo "Unknown arg: $ARG" >&2; exit 2 ;;
  esac
done

# ─── Tracking ────────────────────────────────────────────────────────

record() {
  local NAME="$1" STATUS="$2" DETAILS="${3:-}"
  RESULTS["$NAME"]="$STATUS|$DETAILS"
  ORDER+=("$NAME")
  case "$STATUS" in
    ok)   ;;
    warn) [[ $OVERALL -lt 1 ]] && OVERALL=1 ;;
    fail) OVERALL=2 ;;
  esac
}

# ─── Load env ────────────────────────────────────────────────────────

if [[ ! -f "$WORKDIR/.env" ]]; then
  record bootstrap fail "workdir/.env missing — has install.sh run?"
  OVERALL=2
else
  # shellcheck disable=SC1091
  set -a; source "$WORKDIR/.env"; set +a
fi

DOMAIN="${DOMAIN:-localhost}"
INSTALLED_VERSION="$(cat "$WORKDIR/.installed-version" 2>/dev/null || echo "")"
compose_cmd() { docker compose --env-file "$WORKDIR/.env" "$@"; }

# ─── Checks ──────────────────────────────────────────────────────────

check_containers() {
  if ! command -v docker >/dev/null 2>&1; then
    record containers fail "docker not found"; return
  fi
  local OUT UNHEALTHY=""
  if ! OUT="$(compose_cmd ps --format json 2>/dev/null)"; then
    record containers fail "docker compose ps failed"; return
  fi
  if [[ -z "$OUT" ]]; then
    record containers fail "no services running"; return
  fi
  # Each line is one service in recent compose versions. `jq -s .` normalises.
  local BAD
  BAD="$(printf '%s\n' "$OUT" | jq -rs '
    .[]
    | select(.State != "running" or (.Health? and .Health != "healthy" and .Health != ""))
    | "\(.Service)=\(.State)\(if .Health then "/"+.Health else "" end)"
  ' 2>/dev/null)"
  if [[ -n "$BAD" ]]; then
    record containers fail "not running/healthy: $(echo "$BAD" | tr '\n' ' ')"
  else
    local COUNT
    COUNT="$(printf '%s\n' "$OUT" | jq -rs 'length')"
    record containers ok "$COUNT services up"
  fi
}

check_postgres() {
  if compose_cmd exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
    record postgres ok
  else
    record postgres fail "pg_isready failed"
  fi
}

check_api_ping() {
  # Bare DOMAIN serves the landing SPA; the API lives on the cloud/cpo/
  # cs/admin subdomains. cloud is the canonical one for health probes.
  local HOST="cloud.${DOMAIN}"
  [[ "$DOMAIN" == "localhost" ]] && HOST="$DOMAIN"
  local URL="https://${HOST}/api/v1/ping"
  local CODE
  CODE="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null)"
  if [[ "$CODE" == "200" ]]; then
    record api ok "$URL → 200"
  elif [[ "$DOMAIN" == "localhost" ]]; then
    record api warn "$URL → $CODE (expected for dev without DNS)"
  else
    record api fail "$URL → $CODE"
  fi
}

check_openid() {
  local URL="https://auth.${DOMAIN}/.well-known/openid-configuration"
  local CODE
  CODE="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null)"
  if [[ "$CODE" == "200" ]]; then
    record openid ok
  elif [[ "$DOMAIN" == "localhost" ]]; then
    record openid warn "$URL → $CODE"
  else
    record openid fail "$URL → $CODE"
  fi
}

check_ocpp_tcp() {
  if timeout 3 bash -c '</dev/tcp/localhost/9220' 2>/dev/null; then
    record ocpp ok ":9220 reachable"
  else
    record ocpp fail ":9220 unreachable"
  fi
}

check_frontend_landing() {
  local URL="https://${DOMAIN}/"
  local CODE
  CODE="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null)"
  if [[ "$CODE" == "200" || "$CODE" == "301" || "$CODE" == "302" ]]; then
    record frontend ok "landing $URL → $CODE"
  elif [[ "$DOMAIN" == "localhost" ]]; then
    record frontend warn "$URL → $CODE"
  else
    record frontend fail "$URL → $CODE"
  fi
}

check_tls() {
  if [[ "$DOMAIN" == "localhost" ]]; then
    record tls warn "DOMAIN=localhost — TLS check skipped"
    return
  fi
  local HOSTS=("$DOMAIN" "cloud.$DOMAIN" "api.$DOMAIN")
  local MIN_DAYS=999999 HOST_MIN=""
  for H in "${HOSTS[@]}"; do
    local END
    END="$(echo | openssl s_client -servername "$H" -connect "$H:443" 2>/dev/null \
           | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    [[ -z "$END" ]] && continue
    local END_EPOCH NOW_EPOCH DAYS
    END_EPOCH="$(date -d "$END" +%s 2>/dev/null || echo 0)"
    NOW_EPOCH="$(date +%s)"
    DAYS=$(( (END_EPOCH - NOW_EPOCH) / 86400 ))
    if (( DAYS < MIN_DAYS )); then
      MIN_DAYS=$DAYS; HOST_MIN="$H"
    fi
  done
  if [[ "$MIN_DAYS" == "999999" ]]; then
    record tls fail "could not read any certificate"
  elif (( MIN_DAYS < MIN_TLS_DAYS )); then
    record tls fail "$HOST_MIN expires in ${MIN_DAYS}d"
  elif (( MIN_DAYS < 30 )); then
    record tls warn "$HOST_MIN expires in ${MIN_DAYS}d"
  else
    record tls ok "min expiry ${MIN_DAYS}d ($HOST_MIN)"
  fi
}

check_disk() {
  local PCT
  PCT="$(df --output=pcent "$SCRIPT_DIR" | tail -1 | tr -d ' %')"
  if [[ "$PCT" -ge $DISK_FAIL_PCT ]]; then
    record disk fail "${PCT}% used"
  elif [[ "$PCT" -ge $DISK_WARN_PCT ]]; then
    record disk warn "${PCT}% used"
  else
    record disk ok "${PCT}% used"
  fi
}

check_memory() {
  local MB
  MB="$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "$MB" -lt "$MIN_RAM_MB" ]]; then
    record memory warn "MemAvailable ${MB} MB < ${MIN_RAM_MB} MB"
  else
    record memory ok "${MB} MB available"
  fi
}

check_version_match() {
  [[ -z "$INSTALLED_VERSION" ]] && { record version warn "workdir/.installed-version unset"; return; }
  # Inspect running backend image tag.
  local TAG
  TAG="$(compose_cmd ps backend --format json 2>/dev/null | jq -r '.Image' 2>/dev/null | awk -F: '{print $NF}')"
  if [[ -z "$TAG" || "$TAG" == "null" ]]; then
    record version warn "could not read backend image tag"
  elif [[ "$TAG" == "$INSTALLED_VERSION" ]]; then
    record version ok "$TAG"
  else
    record version warn "backend image :$TAG != .installed-version $INSTALLED_VERSION"
  fi
}

# ─── Run all ─────────────────────────────────────────────────────────

if [[ -f "$WORKDIR/.env" ]]; then
  check_containers
  check_postgres
  check_api_ping
  check_openid
  check_ocpp_tcp
  check_frontend_landing
  check_tls
  check_disk
  check_memory
  check_version_match
fi

# ─── Render ──────────────────────────────────────────────────────────

if [[ $JSON -eq 1 ]]; then
  printf '{"overall":"%s","checks":{' \
    "$(case $OVERALL in 0) echo ok;; 1) echo warn;; 2) echo fail;; esac)"
  local_sep=""
  for NAME in "${ORDER[@]}"; do
    IFS='|' read -r STATUS DETAILS <<<"${RESULTS[$NAME]}"
    # shellcheck disable=SC2001
    DETAILS_ESC="$(printf '%s' "$DETAILS" | sed 's/"/\\"/g')"
    printf '%s"%s":{"status":"%s","details":"%s"}' \
      "$local_sep" "$NAME" "$STATUS" "$DETAILS_ESC"
    local_sep=","
  done
  printf '}}\n'
else
  printf '%s\n' "─── Apostol CSMS health check ───────────────────────"
  for NAME in "${ORDER[@]}"; do
    IFS='|' read -r STATUS DETAILS <<<"${RESULTS[$NAME]}"
    case "$STATUS" in
      ok)   COLOR=$C_GREEN ; BADGE="✓" ;;
      warn) COLOR=$C_YELLOW; BADGE="!" ;;
      fail) COLOR=$C_RED   ; BADGE="✗" ;;
    esac
    printf '  %s%s%s %-12s %s\n' "$COLOR" "$BADGE" "$C_RESET" "$NAME" "$DETAILS"
  done
  printf '─────────────────────────────────────────────────────\n'
  case $OVERALL in
    0) printf '%sall green%s (exit 0)\n' "$C_GREEN" "$C_RESET" ;;
    1) printf '%swarnings present%s (exit 1)\n' "$C_YELLOW" "$C_RESET" ;;
    2) printf '%sfailures present%s (exit 2)\n' "$C_RED" "$C_RESET" ;;
  esac
fi

exit $OVERALL
