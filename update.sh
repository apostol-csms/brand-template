#!/usr/bin/env bash
#
# update.sh — update an existing brand deployment.
#
# Usage:
#   ./update.sh                       # use envs/<current>/platform.lock.json
#   ./update.sh --platform=X.Y.Z      # override the pinned version
#   ./update.sh --frontend-only       # rebuild + restart only frontend apps
#   ./update.sh --diff-compose        # show diff vs reference compose, exit
#   ./update.sh --rollback            # revert to previous installed version
#   ./update.sh --dry-run
#
# Pipeline — mirrors main() at the bottom of this file. Keep the two in step:
# this header is read far more often than the code under it, and it spent
# months describing the source-clone era that Phase 10 retired.
#
#   1. git pull brand-repo (ff-only)
#   2. resolve target version (lock | --platform | --rollback)
#      — --diff-compose reports and exits here
#   3. reload secrets (they may have rotated), re-pin PLATFORM_VERSION into
#      workdir/.env, refuse to continue if any CHANGE_ME survives
#   4. docker compose pull --ignore-buildable — EVERY platform image named in
#      compose (db, backend, ocpp, webapp, driver, pay, auth, ai-service), not
#      a fixed pair. A tag published for only some of them fails the whole run
#      right here — which is what makes --platform=<pre-release> unusable
#      unless every image carries that tag.
#   5. (nothing to git-pull: Phase 10 ships every platform component as an
#      image. landing is the only brand-built frontend and lives in ../landing)
#   6. render per-app env via envs/<env>/render.sh, when the brand has one
#   7. hooks/pre-update.sh
#   8. docker compose build — landing + local infra (nginx, pgbouncer);
#      with --frontend-only, landing alone
#   9. docker compose run --rm --no-deps db-migrate   ← blocking gate
#      (postgres is started if down but never recreated here — T711)
#      (on failure: exit 2, stack keeps running at old version)
#  10. rolling restart, TWO-PHASE: upstreams → wait until SPAs report healthy
#      → only then nginx (see the comment at rolling_restart for why). Inside
#      phase 1 ocpp waits for backend: it is recreated only once the new
#      backend is subscribed to LISTEN (see wait_backend_listening, T578)
#  11. hooks/post-update.sh
#  12. record version (and prev, for --rollback)
#  13. ./check.sh — note it exits 1 on a mere warning, and this step turns
#      that into exit 2 for the whole update
#  14. remove platform images of versions other than current and previous
#      (T710), then docker image prune -f

set -euo pipefail

# ─── Globals ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$SCRIPT_DIR/workdir"

OVERRIDE_VERSION=""
FRONTEND_ONLY=0
DIFF_COMPOSE=0
ROLLBACK=0
DRY_RUN=0

# ─── Logging ─────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_GREEN=; C_RED=; C_YELLOW=; C_RESET=
fi

log()  { printf '%s[update]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[update] WARN:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[update] ERROR:%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

compose_cmd() { docker compose --env-file "$WORKDIR/.env" "$@"; }

# ─── Help ────────────────────────────────────────────────────────────

display_help() {
  cat <<EOF
Apostol CSMS brand updater.

Usage:
  ./update.sh [options]

Options:
  --platform=<ver>   Override version (normally read from
                     envs/<env>/platform.lock.json)
  --frontend-only    Rebuild + restart only frontend apps
  --diff-compose     Show diff against reference compose and exit
  --rollback         Revert to previous installed version (reads
                     workdir/.installed-version.prev)
  --dry-run          Print planned commands without executing
  -h, --help         This message
EOF
}

# ─── Arg parsing ─────────────────────────────────────────────────────

for ARG in "$@"; do
  case "$ARG" in
    --platform=*)     OVERRIDE_VERSION="${ARG#*=}" ;;
    --frontend-only)  FRONTEND_ONLY=1 ;;
    --diff-compose)   DIFF_COMPOSE=1 ;;
    --rollback)       ROLLBACK=1 ;;
    --dry-run)        DRY_RUN=1 ;;
    -h|--help)        display_help; exit 0 ;;
    *)                err "Unknown argument: $ARG"; display_help >&2; exit 1 ;;
  esac
done

# ─── Preconditions ───────────────────────────────────────────────────

require_installed() {
  if [[ ! -f "$WORKDIR/.current-env" ]]; then
    err "No existing install found (workdir/.current-env missing). Run ./install.sh first."
    exit 1
  fi
  BRAND_ENV="$(cat "$WORKDIR/.current-env")"
  INSTALLED_VERSION="$(cat "$WORKDIR/.installed-version" 2>/dev/null || echo "")"
}

# ─── Step 1: git pull brand-repo ─────────────────────────────────────

pull_brand_repo() {
  log "pull brand-repo"
  if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
    warn "brand-repo is not a git checkout — skipping git pull"
    return 0
  fi
  run git -C "$SCRIPT_DIR" pull --ff-only
}

# ─── Step 2: Resolve target version ──────────────────────────────────

resolve_target() {
  if [[ $ROLLBACK -eq 1 ]]; then
    local PREV="$WORKDIR/.installed-version.prev"
    [[ -f "$PREV" ]] || { err "No previous version recorded (workdir/.installed-version.prev missing)"; exit 1; }
    PLATFORM_VERSION="$(cat "$PREV")"
    # For rollback, git refs must match the PREV version's platform.lock.
    # If the operator already reverted envs/$BRAND_ENV/platform.lock.json in
    # brand-repo before running --rollback, read that; otherwise derive refs
    # from PLATFORM_VERSION tag itself (fall-back assumption).
    if jq -e '.platform_version' "$SCRIPT_DIR/envs/$BRAND_ENV/platform.lock.json" \
         | grep -qw "\"$PLATFORM_VERSION\""; then
      DB_REF="$(jq -r '.sources["apostol-csms/db"].ref' \
        "$SCRIPT_DIR/envs/$BRAND_ENV/platform.lock.json")"
      FRONTEND_REF="$(jq -r '.sources["apostol-csms/frontend"].ref' \
        "$SCRIPT_DIR/envs/$BRAND_ENV/platform.lock.json")"
    else
      DB_REF="v$PLATFORM_VERSION"
      FRONTEND_REF="v$PLATFORM_VERSION"
      warn "rollback: platform.lock.json current != $PLATFORM_VERSION; "\
"using default refs v$PLATFORM_VERSION. Commit lock.json revert in brand-repo to make this explicit."
    fi
    log "rollback target: $PLATFORM_VERSION (was $INSTALLED_VERSION)"
    return 0
  fi

  local LOCK="$SCRIPT_DIR/envs/$BRAND_ENV/platform.lock.json"
  [[ -f "$LOCK" ]] || { err "$LOCK not found"; exit 1; }

  if [[ -n "$OVERRIDE_VERSION" ]]; then
    PLATFORM_VERSION="$OVERRIDE_VERSION"
    DB_REF="v$PLATFORM_VERSION"
    FRONTEND_REF="v$PLATFORM_VERSION"
    log "override: --platform=$PLATFORM_VERSION (refs default to tag name)"
  else
    PLATFORM_VERSION="$(jq -r '.platform_version' "$LOCK")"
    # v2 platform.lock.json (Phase 10) drops the `sources` block — every
    # platform component is a GHCR image now.  Older v1 locks still have
    # it; honour both.
    DB_REF="$(jq -r '.sources["apostol-csms/db"].ref // empty' "$LOCK")"
    FRONTEND_REF="$(jq -r '.sources["apostol-csms/frontend"].ref // empty' "$LOCK")"
    AUTH_REF="$(jq -r '.sources["apostol-csms/auth"].ref // empty' "$LOCK")"
    [[ -z "$DB_REF"       ]] && DB_REF="v${PLATFORM_VERSION}"
    [[ -z "$FRONTEND_REF" ]] && FRONTEND_REF="v${PLATFORM_VERSION}"
    [[ -z "$AUTH_REF"     ]] && AUTH_REF="v${PLATFORM_VERSION}"
  fi

  for V in PLATFORM_VERSION DB_REF FRONTEND_REF; do
    if [[ "${!V}" == "null" || -z "${!V}" ]]; then
      err "could not resolve $V"; exit 1
    fi
  done

  log "target: $PLATFORM_VERSION${INSTALLED_VERSION:+ (was $INSTALLED_VERSION)}"
  export PLATFORM_VERSION
}

# ─── Step 3: Diff compose (standalone) ───────────────────────────────

diff_compose_and_exit() {
  [[ $DIFF_COMPOSE -eq 1 ]] || return 0
  local REF_URL="https://raw.githubusercontent.com/apostol-csms/backend/v$PLATFORM_VERSION/docker-compose.reference.yaml"
  log "diff compose vs $REF_URL"
  local TMP; TMP="$(mktemp)"
  if ! curl -fsSL "$REF_URL" -o "$TMP" 2>/dev/null; then
    warn "reference compose not found at $REF_URL — check if release assets were published for v$PLATFORM_VERSION"
    rm -f "$TMP"; exit 0
  fi
  diff -u "$TMP" "$SCRIPT_DIR/docker-compose.yaml" || true
  rm -f "$TMP"
  exit 0
}

# ─── Step 4: Reload secrets ──────────────────────────────────────────

reload_secrets() {
  log "reload secrets"
  local VAULT="$SCRIPT_DIR/envs/$BRAND_ENV/secrets/load-from-vault.sh"
  [[ -x "$VAULT" ]] || { err "$VAULT missing or not executable"; exit 1; }
  run env WORKDIR="$WORKDIR" SCRIPT_DIR="$SCRIPT_DIR" BRAND_ENV="$BRAND_ENV" "$VAULT"
  if [[ $DRY_RUN -eq 0 ]]; then
    if grep -qE '^[A-Z_][A-Z_0-9]*=("?)CHANGE_ME\1$' "$WORKDIR/.env"; then
      err "workdir/.env still contains CHANGE_ME:"
      grep -nE '^[A-Z_][A-Z_0-9]*=("?)CHANGE_ME\1$' "$WORKDIR/.env" | head -5 >&2
      exit 1
    fi
    # Re-pin PLATFORM_VERSION in case lock changed.
    sed -i -E "s/^PLATFORM_VERSION=.*/PLATFORM_VERSION=$PLATFORM_VERSION/" "$WORKDIR/.env"
  fi
}

# ─── Step 5: Registry login + pull platform images ───────────────────

# ─── Image registry login ────────────────────────────────────────────
#
# Needed when REGISTRY points at a private registry — a brand's own
# mirror, typically. For the public ghcr.io the step is skipped: with the
# variables unset there is no login and nothing changes.
#
# Values are read from workdir/.env rather than the script environment:
# envs/<env>/secrets/load-from-vault.sh puts them there via the REGISTRY_
# prefix, and credentials must never sit in a committed template.
env_get() {
  [[ -r "$WORKDIR/.env" ]] || return 0
  sed -n "s/^$1=//p" "$WORKDIR/.env" | tail -1 | sed -e 's/^"//' -e 's/"$//'
}

registry_login() {
  local RU RP HOST
  RU="$(env_get REGISTRY_USER)"; RP="$(env_get REGISTRY_PASS)"
  if [[ -z "$RU" || -z "$RP" ]]; then
    log "registry login: skipped (REGISTRY_USER/REGISTRY_PASS not set)"
    return 0
  fi
  HOST="$(env_get REGISTRY)"; HOST="${HOST:-ghcr.io}"
  HOST="${HOST%%/*}"          # registry.example.ru/base → registry.example.ru
  log "registry login: $HOST as $RU"
  printf '%s' "$RP" | docker login "$HOST" -u "$RU" --password-stdin
}

pull_images() {
  registry_login
  log "pull all platform images for $PLATFORM_VERSION (Phase 10)"
  # `compose pull` reads images from compose itself — picks up
  # PLATFORM_VERSION from workdir/.env automatically and skips the
  # remaining build: contexts (landing + infra).
  run compose_cmd pull --ignore-buildable
}

# ─── Step 6: Update brand-specific sources (landing only) ────────────
#
# Phase 10 — db, frontend, auth are all GHCR images.  Only landing is
# still source-built per <brand>/landing repo.

update_sources() {
  log "  (no platform repos to update in pure-image mode)"
}

# ─── Step 7: Build infra + landing ───────────────────────────────────

rebuild_local() {
  local SERVICES
  if [[ $FRONTEND_ONLY -eq 1 ]]; then
    # Pure-image SPAs — recreate-only via restart_services; nothing to
    # build.  Landing is the sole brand-built frontend.
    SERVICES="landing"
  else
    SERVICES="landing nginx pgbouncer"
  fi
  # Drop services not declared in this brand's compose (e.g. plugme has
  # no landing). Skip build entirely if nothing remains buildable.
  SERVICES="$(filter_present_services "$SERVICES")"
  if [[ -z "$SERVICES" ]]; then
    log "docker compose build: (no buildable services declared — skipping)"
    return 0
  fi
  log "docker compose build: $SERVICES"
  # shellcheck disable=SC2086
  run compose_cmd build $SERVICES
}

# ─── Step 8: DB migrate (blocking gate) ──────────────────────────────

run_db_migrate() {
  if [[ $FRONTEND_ONLY -eq 1 ]]; then
    log "skip db-migrate (--frontend-only)"
    return 0
  fi
  # T711 — `compose run` without --no-deps walks depends_on (db-migrate →
  # db-init → postgres) and RECREATES postgres whenever its config-hash
  # label disagrees with the current render — measured 30.09 on all four
  # sites: postgres was recreated on every update, image unchanged, while
  # backend and ocpp were still running on the old version (they lost the
  # database under them), and postgres' json log — its only log,
  # logging_collector=off — went with the old container. So: make sure
  # postgres is up WITHOUT recreating it, then run the gate alone. db-init is
  # first-install only (install.sh) and is not re-run here any more.
  # Consequence: a postgres image or `-c` tuning change in compose no longer
  # reaches a running stack through update.sh — recreating the database is a
  # deliberate step of its own (stop backend/ocpp first, save `docker logs`).
  local PG_SVC
  PG_SVC="$(filter_present_services postgres)"   # empty with an external database
  if [[ -n "$PG_SVC" ]]; then
    # --wait: db-init used to wait for service_healthy on our behalf. Without
    # it a postgres still starting makes migrate.sh print "does not exist" and
    # exit 0 — the gate would pass with no patches applied.
    run compose_cmd up -d --wait --wait-timeout 120 --no-deps --no-recreate "$PG_SVC"
  fi
  log "run db-migrate (one-shot)"
  if ! run compose_cmd run --rm --no-deps db-migrate; then
    err "db-migrate FAILED. The stack is still on the previous version. "\
"Investigate logs, fix, and re-run update.sh. DO NOT force-restart services."
    exit 2
  fi
}

# ─── Step 9: Rolling restart ─────────────────────────────────────────
#
# TWO-PHASE. nginx must NOT be recreated in the same compose batch as
# its upstreams — docker embedded DNS can reassign freed IPs across
# siblings, and an nginx that came up too early will cache a resolve
# that now points at the wrong container (bare ${DOMAIN} serving the
# auth SPA is the canonical symptom). Sequence:
#
#   Phase 1: --force-recreate upstreams (backend, SPAs, pg*), then —
#            once backend listens — ocpp (the LISTEN gate below, T578).
#            Wait until every SPA reports healthy (from its
#            `x-spa-healthcheck` in docker-compose.yaml).
#   Phase 2: --force-recreate nginx. Its resolver cache starts fresh
#            and DNS is already settled.
#
# If any SPA fails to become healthy within WAIT_HEALTHY_MAX_S, we
# exit 2 WITHOUT recreating nginx. The old nginx keeps serving from
# the previous (still-running) upstreams, so the stack never enters
# a half-broken state. Operator investigates, reruns update.sh.

SPA_SERVICES="landing frontend driver pay auth"
WAIT_HEALTHY_MAX_S=120

# Filter SPA_SERVICES + UPSTREAM lists down to services actually present
# in the brand's docker-compose.yaml. Brands that omit `landing` (e.g.
# plugme) would otherwise hard-fail rolling_restart with "no such service".
filter_present_services() {
  local LIST="$1" PRESENT="" ALL
  ALL="$(compose_cmd config --services 2>/dev/null)"
  for svc in $LIST; do
    if echo "$ALL" | grep -qx "$svc"; then
      PRESENT="$PRESENT $svc"
    fi
  done
  echo "${PRESENT# }"
}

wait_spas_healthy() {
  [[ $DRY_RUN -eq 1 ]] && { log "[dry-run] skip wait_spas_healthy"; return 0; }
  log "  wait SPAs healthy (max ${WAIT_HEALTHY_MAX_S}s)…"
  local SPAS_PRESENT
  SPAS_PRESENT="$(filter_present_services "$SPA_SERVICES")"
  local t=0 pending
  while (( t < WAIT_HEALTHY_MAX_S )); do
    pending=""
    for svc in $SPAS_PRESENT; do
      local status
      status="$(compose_cmd ps --format json "$svc" 2>/dev/null \
                | jq -rs '.[0].Health // "unknown"' 2>/dev/null || echo unknown)"
      [[ "$status" == "healthy" ]] || pending="$pending $svc=$status"
    done
    if [[ -z "$pending" ]]; then
      log "  all SPAs healthy after ${t}s"
      return 0
    fi
    sleep 3; t=$((t+3))
  done
  err "SPAs did not reach healthy within ${WAIT_HEALTHY_MAX_S}s:$pending"
  err "  nginx phase SKIPPED — old nginx keeps routing. Investigate:"
  err "  docker compose --env-file workdir/.env logs $SPA_SERVICES --tail=80"
  exit 2
}

# ─── Backend LISTEN gate (T578) ──────────────────────────────────────
#
# ocpp goes up only after the new backend has subscribed. A fresh ocpp
# takes every station's reconnect at once, and each one runs OCPP logic in
# the database. Whatever that logic queues for sending — a payment capture,
# a Get* command to a station — is an http.request row announced by NOTIFY
# on channel "http" and picked up by backend's PGFetch. With nobody
# listening the NOTIFY is simply gone and the row stays in state 1 for good
# (cpms 28.09: stations were back 2–3 s before backend listened, 27 rows
# stranded, two of them captures; T577 is the fix on the backend side, this
# gate is the second line). Hence, inside phase 1:
#
#   1a. recreate every upstream except ocpp — backend together with
#       pgbouncer, as brands/CLAUDE.md requires;
#   1b. wait until the NEW backend listens: a listener connection opened
#       after 1a carries channel "http", and every database user holds at
#       least as many listener connections as it did before 1a;
#   1c. only then recreate ocpp. Until then the old ocpp keeps the stations.
#
# What the gate does NOT close: while backend itself restarts in 1a, the old
# ocpp keeps working, and an http.request it queues in those seconds (a
# StopTransaction's capture) still loses its NOTIFY. That window is ordinary
# traffic, not the reconnect burst — only T577 (PGFetch rescans the queue at
# start) closes it. Also, the old ocpp goes through pgbouncer, which is
# recreated in 1a under it: idle connections reconnect, an in-flight query
# fails once and the station repeats its message.
#
# Readiness is read from pg_stat_activity, not waited out with a sleep: a
# listener connection shows its LISTEN batch as its last query (libapostol
# ships a process's channels as one batch — `LISTEN "file";LISTEN "http";`)
# and runs nothing else on it; `state = 'idle'` means the batch has committed.
# Both queries skip their own session: the pattern '%LISTEN "http";%' is
# itself text of the query and would otherwise find the check it runs in.
# No "http" listener within WAIT_LISTEN_MAX_S → exit 2 with ocpp and nginx
# untouched. Fewer listener connections than before → a warning only: that
# is the deaf-worker case of the pgbouncer rule, not a reason to hold ocpp.

LISTEN_CHANNEL="http"
WAIT_LISTEN_MAX_S=60

# Rows as "<col> <col>", one per line; empty on any failure — no postgres
# service in compose (an external database) or the database not answering.
pg_query() {
  local PGDB
  PGDB="$(sed -n 's/^PGDATABASE=//p' "$WORKDIR/.env" | tail -1 | sed -e 's/^"//' -e 's/"$//')"
  compose_cmd exec -T postgres psql -X -U postgres -d "${PGDB:-csms}" -tA -F ' ' -c "$1" 2>/dev/null || true
}

# "<user> <count>" of listener connections opened at or after $1.
listeners_since() {
  pg_query "SELECT usename, count(*) FROM pg_stat_activity
             WHERE datname = current_database() AND pid <> pg_backend_pid()
               AND state = 'idle' AND query ILIKE 'LISTEN%' AND backend_start >= '$1'
             GROUP BY 1 ORDER BY 1"
}

wait_backend_listening() {
  local T0="$1" BASE="$2"
  [[ $DRY_RUN -eq 1 ]] && { log "[dry-run] skip wait_backend_listening"; return 0; }
  if [[ -z "$T0" ]]; then
    warn "LISTEN gate skipped: postgres does not answer through compose (external database?)"
    warn "  ocpp follows backend unchecked"
    return 0
  fi
  log "  wait backend LISTEN \"$LISTEN_CHANNEL\" (max ${WAIT_LISTEN_MAX_S}s; before: $(echo $BASE))…"
  local t=0 http now short user want have
  while (( t < WAIT_LISTEN_MAX_S )); do
    http="$(pg_query "SELECT count(*) FROM pg_stat_activity
                       WHERE datname = current_database() AND pid <> pg_backend_pid()
                         AND state = 'idle' AND query LIKE '%LISTEN \"$LISTEN_CHANNEL\";%'
                         AND backend_start >= '$T0'" | tr -dc '0-9')"
    now="$(listeners_since "$T0")"
    short=""
    while read -r user want; do
      [[ -n "$user" ]] || continue
      have="$(awk -v u="$user" '$1 == u { print $2 }' <<<"$now")"
      (( ${have:-0} >= want )) || short="$short $user=${have:-0}/$want"
    done <<<"$BASE"
    if (( ${http:-0} >= 1 )) && [[ -z "$short" ]]; then
      log "  backend listening after ${t}s: $(echo $now)"
      return 0
    fi
    sleep 2; t=$((t+2))
  done
  if (( ${http:-0} < 1 )); then
    err "backend did not LISTEN \"$LISTEN_CHANNEL\" within ${WAIT_LISTEN_MAX_S}s"
    err "  ocpp and nginx NOT recreated — the old ocpp keeps the stations. Investigate:"
    err "  docker compose --env-file workdir/.env logs backend pgbouncer --tail=80"
    exit 2
  fi
  warn "backend listens on \"$LISTEN_CHANNEL\", but holds fewer listener connections than before:$short"
  warn "  proceeding with ocpp; check the subscriptions as brands/CLAUDE.md describes (pgbouncer rule)"
}

rolling_restart() {
  local UPSTREAM LATE=""
  if [[ $FRONTEND_ONLY -eq 1 ]]; then
    UPSTREAM="$SPA_SERVICES"
  else
    UPSTREAM="backend ai-service $SPA_SERVICES pgbouncer"
    LATE="ocpp"
  fi
  # Drop services not declared in the brand's docker-compose.yaml.
  UPSTREAM="$(filter_present_services "$UPSTREAM")"
  [[ -n "$LATE" ]] && LATE="$(filter_present_services "$LATE")"
  if [[ -n "$LATE" ]]; then
    local T0="" BASE=""
    if [[ $DRY_RUN -eq 0 ]]; then
      T0="$(pg_query 'SELECT now()')"
      # Anything but a timestamp would fail both gate queries and end in a
      # false exit 2 — treat it as "postgres does not answer" instead.
      [[ $T0 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\  ]] || T0=""
      BASE="$(listeners_since '-infinity')"
    fi
    log "rolling restart (phase 1a — upstreams, $LATE held back): $UPSTREAM"
    # shellcheck disable=SC2086
    run compose_cmd up -d --no-deps --force-recreate $UPSTREAM
    wait_backend_listening "$T0" "$BASE"
    log "rolling restart (phase 1b — $LATE, backend is listening)"
    # shellcheck disable=SC2086
    run compose_cmd up -d --no-deps --force-recreate $LATE
  else
    log "rolling restart (phase 1 — upstreams): $UPSTREAM"
    # shellcheck disable=SC2086
    run compose_cmd up -d --no-deps --force-recreate $UPSTREAM
  fi
  wait_spas_healthy
  log "rolling restart (phase 2 — nginx)"
  run compose_cmd up -d --no-deps --force-recreate nginx
}

# ─── Step 9b: Patch baseline ─────────────────────────────────────────
#
# Отметка «столько патчей числилось сразу после штатной миграции». check.sh
# сравнивает с ней и объявляет всё, что появилось позже, применённым в обход
# конвейера. Снимается только когда db-migrate реально отработал.

record_patch_baseline() {
  [[ $DRY_RUN -eq 1 || $FRONTEND_ONLY -eq 1 ]] && return 0
  local PGDB CNT
  PGDB="$(sed -n 's/^PGDATABASE=//p' "$WORKDIR/.env" | tail -1 | sed -e 's/^"//' -e 's/"$//')"
  CNT="$(compose_cmd exec -T postgres psql -U postgres -d "${PGDB:-csms}" \
           -tAc 'SELECT count(*) FROM db.patch_log' 2>/dev/null | tr -dc '0-9')"
  if [[ -n "$CNT" ]]; then
    echo "$CNT" > "$WORKDIR/.patch-count"
    log "patch baseline: $CNT"
  else
    warn "patch baseline: could not read db.patch_log — skipped"
  fi
}

# ─── Step 10: Hooks ──────────────────────────────────────────────────

run_hook() {
  local NAME="$1"
  for CAND in "$SCRIPT_DIR/hooks/$NAME" "$SCRIPT_DIR/envs/$BRAND_ENV/hooks/$NAME"; do
    if [[ -x "$CAND" ]]; then
      log "hook: ${CAND#$SCRIPT_DIR/}"
      run env WORKDIR="$WORKDIR" BRAND_ENV="$BRAND_ENV" PLATFORM_VERSION="$PLATFORM_VERSION" "$CAND"
    fi
  done
}

# ─── Step 11: Record version (prev + current) ────────────────────────

record_version() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  # Save current as prev, then overwrite current — enables --rollback.
  if [[ -n "$INSTALLED_VERSION" && "$INSTALLED_VERSION" != "$PLATFORM_VERSION" ]]; then
    echo "$INSTALLED_VERSION" > "$WORKDIR/.installed-version.prev"
  fi
  echo "$PLATFORM_VERSION" > "$WORKDIR/.installed-version"
}

# ─── Step 6b: Render app env files ───────────────────────────────────
#
# After workdir/{db,frontend} are updated to the new refs, brands may
# need to re-render per-app env files (see install.sh for the contract).
# Typically a no-op on updates unless secrets rotated or a template
# gained new variables.

render_app_env() {
  local RENDER="$SCRIPT_DIR/envs/$BRAND_ENV/render.sh"
  if [[ -x "$RENDER" ]]; then
    log "render app env via envs/$BRAND_ENV/render.sh"
    run env WORKDIR="$WORKDIR" SCRIPT_DIR="$SCRIPT_DIR" BRAND_ENV="$BRAND_ENV" "$RENDER"
  else
    log "no envs/$BRAND_ENV/render.sh — skipping"
  fi
}

# ─── Step 12: Verify ─────────────────────────────────────────────────

verify_update() {
  if [[ -x "$SCRIPT_DIR/check.sh" ]]; then
    log "verify via ./check.sh"
    if ! run "$SCRIPT_DIR/check.sh"; then
      warn "check.sh reported issues — review output above"
      exit 2
    fi
  else
    warn "check.sh not found — skipping verification"
  fi
}

# ─── Step 13: Cleanup ────────────────────────────────────────────────

prune_images() {
  # T710 — `image prune -f` removes only dangling layers; every release left
  # a full set of tagged platform images behind (30.09: 257 images, 23.4 GB
  # reclaimable on prod ocpp-css, 280 on chargemecar, 232 on cpms). Keep the
  # version just installed and the previous one (--rollback brings it back
  # without a pull); remove the platform images of every other version.
  # No -f on rmi: an image a container (even a stopped one) still uses
  # refuses and stays. Brand-built images (nginx, pgbouncer, landing) and
  # tools (loadgen) are not matched.
  local PREV_VER PLATFORM_RE OLD REPOS KEPT=0 REMOVED=0 IMG
  local PRUNE_OLD
  PRUNE_OLD="${PRUNE_OLD_PLATFORM_IMAGES:-$(env_get PRUNE_OLD_PLATFORM_IMAGES)}"
  if [[ "${PRUNE_OLD:-1}" != "1" ]]; then
    log "skip old platform images (PRUNE_OLD_PLATFORM_IMAGES=$PRUNE_OLD)"
  else
    PREV_VER="$(cat "$WORKDIR/.installed-version.prev" 2>/dev/null || true)"
    # dry-run does not record the version, so .prev is still one step behind
    if [[ $DRY_RUN -eq 1 && "$INSTALLED_VERSION" != "$PLATFORM_VERSION" ]]; then
      PREV_VER="$INSTALLED_VERSION"
    fi
    PLATFORM_RE='/csms-(backend|ocpp|db|webapp|driver|pay|auth|ai-service):[0-9]+\.[0-9]+\.[0-9]+'
    # only the repositories THIS stack pulls — another stack on the same host
    # (graftio on the owner's workstation) keeps its images
    REPOS="$(compose_cmd config --images 2>/dev/null | sed 's/@.*//; s/:[^:/]*$//' | sort -u)"
    OLD="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "$PLATFORM_RE" \
      | awk -F: -v cur="$PLATFORM_VERSION" -v prev="$PREV_VER" '$NF != cur && $NF != prev' \
      | while read -r IMG; do grep -qxF "${IMG%:*}" <<<"$REPOS" && echo "$IMG"; done || true)"
    if [[ -n "$OLD" ]]; then
      log "remove platform images other than $PLATFORM_VERSION / ${PREV_VER:-—}: $(wc -l <<<"$OLD") candidate(s)"
      while read -r IMG; do
        if [[ $DRY_RUN -eq 1 ]]; then
          echo "[dry-run] docker rmi $IMG"
        elif docker rmi "$IMG" >/dev/null 2>&1; then
          REMOVED=$((REMOVED + 1))
        else
          KEPT=$((KEPT + 1))   # still used by a container (e.g. the exited db-init)
        fi
      done <<<"$OLD"
      [[ $DRY_RUN -eq 1 ]] || log "  removed $REMOVED, kept $KEPT (in use)"
    fi
  fi
  log "docker image prune -f"
  run docker image prune -f
}

# ─── Main ────────────────────────────────────────────────────────────

require_installed

log "Apostol CSMS update — env=$BRAND_ENV installed=$INSTALLED_VERSION\
$([[ $DRY_RUN -eq 1 ]] && echo ' [dry-run]')\
$([[ $ROLLBACK -eq 1 ]] && echo ' [rollback]')\
$([[ $FRONTEND_ONLY -eq 1 ]] && echo ' [frontend-only]')"

pull_brand_repo
resolve_target
diff_compose_and_exit        # exits if --diff-compose
reload_secrets
pull_images
update_sources
render_app_env
run_hook pre-update.sh
rebuild_local
run_db_migrate
record_patch_baseline
rolling_restart
run_hook post-update.sh
record_version
verify_update
prune_images

log "update complete: $PLATFORM_VERSION"
