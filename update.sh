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
# Pipeline:
#   1. git pull brand-repo (ff-only)
#   2. resolve target version (lock | --platform | --rollback)
#   3. reload secrets (they may have rotated)
#   4. docker pull csms-backend + csms-ocpp (new PLATFORM_VERSION)
#   5. git pull workdir/db + workdir/frontend to new refs
#   6. hooks/pre-update.sh
#   7. docker compose build (locally-built images)
#   8. docker compose run --rm db-migrate   ← blocking gate
#      (on failure: exit 2, stack keeps running at old version)
#   9. rolling restart: up -d --no-deps --force-recreate <services>
#  10. hooks/post-update.sh
#  11. record version (and prev, for --rollback)
#  12. ./check.sh
#  13. docker image prune -f

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
    DB_REF="$(jq -r '.sources["apostol-csms/db"].ref' "$LOCK")"
    FRONTEND_REF="$(jq -r '.sources["apostol-csms/frontend"].ref' "$LOCK")"
    AUTH_REF="$(jq -r '.sources["apostol-csms/auth"].ref // empty' "$LOCK")"
    [[ -z "$AUTH_REF" ]] && AUTH_REF="v${PLATFORM_VERSION}"
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

# ─── Step 5: Pull platform images ────────────────────────────────────

pull_images() {
  log "pull ghcr.io/apostol-csms/csms-backend:$PLATFORM_VERSION"
  run docker pull "ghcr.io/apostol-csms/csms-backend:$PLATFORM_VERSION"
  log "pull ghcr.io/apostol-csms/csms-ocpp:$PLATFORM_VERSION"
  run docker pull "ghcr.io/apostol-csms/csms-ocpp:$PLATFORM_VERSION"
}

# ─── Step 6: Update cloned sources ───────────────────────────────────

update_sources() {
  # GIT_TOKEN needed for fetch on private repos.
  # shellcheck disable=SC1091
  [[ $DRY_RUN -eq 0 ]] && source "$WORKDIR/.env"
  for REPO in db frontend auth; do
    local REF
    case "$REPO" in
      db)       REF="$DB_REF" ;;
      frontend) REF="$FRONTEND_REF" ;;
      auth)     REF="$AUTH_REF" ;;
    esac
    local TARGET="$WORKDIR/$REPO"
    local URL="https://${GIT_TOKEN:-TOKEN}@github.com/apostol-csms/${REPO}.git"
    if [[ -d "$TARGET/.git" ]]; then
      log "  $REPO: fetch + checkout $REF"
      run git -C "$TARGET" fetch origin --tags
      run git -C "$TARGET" checkout "$REF"
      run git -C "$TARGET" submodule update --init --recursive
    else
      # New platform component added after the initial install — clone.
      log "  $REPO: not present — cloning at $REF"
      run git clone --recurse-submodules --branch "$REF" "$URL" "$TARGET"
    fi
  done
}

# ─── Step 7: Build (locally-built images) ────────────────────────────

rebuild_local() {
  local SERVICES
  if [[ $FRONTEND_ONLY -eq 1 ]]; then
    SERVICES="landing frontend driver pay auth"
  else
    SERVICES="db-init db-migrate landing frontend driver pay auth nginx pgbouncer pgweb"
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
  log "run db-migrate (one-shot)"
  if ! run compose_cmd run --rm db-migrate; then
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
#   Phase 1: --force-recreate upstreams (backend, ocpp, SPAs, pg*).
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

wait_spas_healthy() {
  [[ $DRY_RUN -eq 1 ]] && { log "[dry-run] skip wait_spas_healthy"; return 0; }
  log "  wait SPAs healthy (max ${WAIT_HEALTHY_MAX_S}s)…"
  local t=0 pending
  while (( t < WAIT_HEALTHY_MAX_S )); do
    pending=""
    for svc in $SPA_SERVICES; do
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

rolling_restart() {
  local UPSTREAM
  if [[ $FRONTEND_ONLY -eq 1 ]]; then
    UPSTREAM="$SPA_SERVICES"
  else
    UPSTREAM="backend ocpp $SPA_SERVICES pgbouncer pgweb"
  fi
  log "rolling restart (phase 1 — upstreams): $UPSTREAM"
  # shellcheck disable=SC2086
  run compose_cmd up -d --no-deps --force-recreate $UPSTREAM
  wait_spas_healthy
  log "rolling restart (phase 2 — nginx)"
  run compose_cmd up -d --no-deps --force-recreate nginx
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
rolling_restart
run_hook post-update.sh
record_version
verify_update
prune_images

log "update complete: $PLATFORM_VERSION"
