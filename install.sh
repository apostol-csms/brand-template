#!/usr/bin/env bash
#
# install.sh — initial brand deployment on a fresh server.
#
# Usage:
#   ./install.sh --env=<dev|stage|prod> [--force] [--dry-run]
#
# Or one-liner (reads BRAND_REPO_URL from env, clones, re-execs):
#   curl -fsSL https://raw.githubusercontent.com/<brand>/csms/main/install.sh \
#     | BRAND_ENV=prod BRAND_REPO_URL=https://github.com/<brand>/csms bash
#
# Pipeline:
#   1. Self-bootstrap: in pipe-mode (curl|sh) install ca-certificates,
#                      curl, git, jq, gettext via the host package
#                      manager (apt/dnf/yum/zypper), git clone the brand
#                      repo into /opt/<brand>/, re-exec from there.
#   2. Pre-flight:     docker ≥24, compose v2, disk ≥20 GB, RAM ≥4 GB.
#                      If docker is missing, offer hooks/bootstrap-host.sh
#                      to install Docker via get.docker.com + log limits +
#                      time sync + docker group. Operator confirms y/N.
#   3. Platform pin:   read envs/<env>/platform.lock.json → PLATFORM_VERSION
#   4. Merge env:      .env.template + envs/<env>/.env.template → workdir/.env
#   5. Load secrets:   envs/<env>/secrets/load-from-vault.sh writes into workdir/
#   6. Clone sources:  apostol-csms/{db,frontend} at pinned tag → workdir/
#   7. Pull images:    csms-backend + csms-ocpp from GHCR (public, no auth)
#   8. Pre-install hook
#   9. Local build:    docker compose build (db-init + 4 frontend apps + infra)
#  10. First boot:     postgres → db-init → db-migrate → rest
#  11. Post-install hook
#  12. ./check.sh
#
# Idempotency: refuses if workdir/ exists unless --force is set.

set -euo pipefail

# ─── Globals ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$SCRIPT_DIR/workdir"
REQUIRED_DOCKER_MAJOR=24
# Disk floor: 10 GB covers a single-brand running stack with default
# log-rotation (50m × 3 files × ~9 containers ≈ 1.5 GB) plus ~3 GB of
# pulled images and ~3 GB of headroom for postgres data + Docker
# overlay layers. Bump to 20+ for prod hosts with long log retention,
# multiple brands or a TimescaleDB-backed metrics column.
# Override via MIN_DISK_GB env var if the host is constrained.
MIN_DISK_GB="${MIN_DISK_GB:-10}"
MIN_RAM_MB="${MIN_RAM_MB:-4096}"

BRAND_ENV="${BRAND_ENV:-}"
BRAND_REPO_URL="${BRAND_REPO_URL:-}"
FORCE=0
DRY_RUN=0

# ─── Logging ─────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_GREEN=; C_RED=; C_YELLOW=; C_RESET=
fi

log()  { printf '%s[install]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[install] WARN:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[install] ERROR:%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

# ─── Help ────────────────────────────────────────────────────────────

display_help() {
  cat <<EOF
Apostol CSMS brand installer.

Usage:
  ./install.sh --env=<dev|stage|prod> [options]

Options:
  --env=<name>   Target environment (required unless BRAND_ENV is set)
  --force        Bypass 'workdir/ already exists' check
  --dry-run      Print planned actions without executing
  -h, --help     This message

Env vars:
  BRAND_ENV          Alternative to --env=
  BRAND_REPO_URL     Git URL of the brand repo (for self-bootstrap).
                     HTTPS or SSH (git@host:owner/repo) form supported.
  BRAND_GIT_TOKEN    PAT with read on the brand repo (for self-bootstrap
                     of a private repo over HTTPS). Ignored for SSH URLs
                     and anonymous HTTPS clones. Use a fine-grained PAT
                     scoped to read-only on this single repository.
  BRAND_INSTALL_DIR  Clone destination when self-bootstrapping
                     (default: /opt/<repo-basename>)
EOF
}

# ─── Arg parsing ─────────────────────────────────────────────────────

for ARG in "$@"; do
  case "$ARG" in
    --env=*)   BRAND_ENV="${ARG#*=}" ;;
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) display_help; exit 0 ;;
    *) err "Unknown argument: $ARG"; display_help >&2; exit 1 ;;
  esac
done

# ─── Step 1: Self-bootstrap ──────────────────────────────────────────
#
# If the script was run via curl|bash ($0 ends in "bash" or is not a file),
# git clone the brand repo and re-exec from there.

# ensure_minimal_tools — install curl, git, jq, gettext on a fresh host
# so self-bootstrap can clone and run the rest. Inline copy of the
# bootstrap-host.sh logic because we don't have it locally yet (we are
# the curl|sh that will fetch the repo containing it).
ensure_minimal_tools() {
  local missing=()
  for t in curl git jq envsubst; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  log "minimal host setup needed: ${missing[*]}"

  local SUDO=""
  if [[ "$EUID" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || { err "not root and sudo not found — install ${missing[*]} manually"; exit 1; }
    SUDO="sudo"
  fi

  # Detect the package manager once; install whichever of (curl git jq
  # gettext) are missing. envsubst lives in 'gettext'.
  local pkgs="ca-certificates curl git jq gettext"
  if   command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgs
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y $pkgs
  elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y $pkgs
  elif command -v zypper >/dev/null 2>&1; then $SUDO zypper --non-interactive install --no-recommends $pkgs
  else
    err "Unsupported package manager (apt/dnf/yum/zypper expected). Install ${missing[*]} manually and retry."
    exit 1
  fi
}

self_bootstrap() {
  # Heuristic: BASH_SOURCE[0] is empty/non-file when run from stdin.
  if [[ -f "${BASH_SOURCE[0]:-/dev/null}" ]]; then
    return 0   # Already running from a file — skip bootstrap.
  fi
  if [[ -z "$BRAND_REPO_URL" ]]; then
    err "Pipe install detected but BRAND_REPO_URL is unset. Set BRAND_REPO_URL=https://github.com/<brand>/csms and retry."
    exit 1
  fi

  # Pipe-mode means we may be on a freshly provisioned host without git
  # / jq / envsubst yet. Plant them before doing anything that needs them.
  ensure_minimal_tools

  local BASENAME; BASENAME="$(basename "$BRAND_REPO_URL" .git)"
  local DEST="${BRAND_INSTALL_DIR:-/opt/$BASENAME}"

  # Auth path for the brand repo:
  #   - SSH URL (git@... / ssh://...): rely on a pre-provisioned key.
  #   - HTTPS URL: inject BRAND_GIT_TOKEN as the password if set.
  #     Anonymous HTTPS works only for public repos.
  local CLONE_URL="$BRAND_REPO_URL"
  if [[ "$BRAND_REPO_URL" == https://* && -n "${BRAND_GIT_TOKEN:-}" ]]; then
    # Strip the scheme, splice "oauth2:<token>@" in front of the host.
    # GitHub accepts any non-empty username with a PAT; "oauth2" is a
    # convention shared with `git credential` helpers.
    CLONE_URL="https://oauth2:${BRAND_GIT_TOKEN}@${BRAND_REPO_URL#https://}"
    log "self-bootstrap: clone $BRAND_REPO_URL (BRAND_GIT_TOKEN injected) → $DEST"
  else
    log "self-bootstrap: clone $BRAND_REPO_URL → $DEST"
  fi
  if [[ -d "$DEST" && $FORCE -eq 0 ]]; then
    err "$DEST already exists. cd there and run ./install.sh, or remove it."
    exit 1
  fi
  if ! run git clone "$CLONE_URL" "$DEST"; then
    err "git clone failed."
    if [[ "$BRAND_REPO_URL" == https://* && -z "${BRAND_GIT_TOKEN:-}" ]]; then
      err "  → if the brand repo is private, retry with BRAND_GIT_TOKEN=<PAT-with-repo:read>"
    elif [[ "$BRAND_REPO_URL" == git@* || "$BRAND_REPO_URL" == ssh://* ]]; then
      err "  → check that this host's SSH key is registered as a deploy key on the brand repo"
    fi
    exit 1
  fi
  cd "$DEST"
  exec bash "$DEST/install.sh" "$@"
}

# ─── Step 2: Pre-flight ──────────────────────────────────────────────

# offer_docker_install — interactive prompt to run hooks/bootstrap-host.sh
# when Docker is missing. Aborts the install if the operator declines.
# bootstrap-host.sh itself exit 0's after `usermod -aG docker` so the
# operator re-logins; in that case install.sh terminates here too.
offer_docker_install() {
  local reason="$1"
  local hook="$SCRIPT_DIR/hooks/bootstrap-host.sh"
  if [[ ! -x "$hook" ]]; then
    err "$reason"
    err "  → hooks/bootstrap-host.sh not found; install Docker manually and retry."
    exit 1
  fi
  warn "$reason"
  echo
  echo "  hooks/bootstrap-host.sh can install Docker via https://get.docker.com,"
  echo "  write /etc/docker/daemon.json with log-rotation limits, enable"
  echo "  systemd time-sync, and add the current user to the 'docker' group."
  echo "  It auto-detects apt / dnf / yum / zypper."
  echo
  # Non-interactive context (e.g. <brand>.sh --install over SSH heredoc):
  # /dev/tty is unavailable. install.sh reaching this point already implies
  # the operator triggered a full deploy and opted into bootstrapping —
  # auto-run instead of failing on an unreadable prompt. Interactive
  # context (operator on the host) still asks first; default no.
  local ans=""
  if [[ -r /dev/tty ]]; then
    read -r -p "  Run hooks/bootstrap-host.sh --docker now? [y/N] " ans </dev/tty || ans=""
  else
    log "non-interactive shell — auto-bootstrapping Docker via hooks/bootstrap-host.sh --docker"
    ans=y
  fi
  case "${ans,,}" in
    y|yes) ;;
    *) err "Docker required. Install it manually (see https://docs.docker.com/engine/install/) and retry."; exit 1 ;;
  esac
  run "$hook" --docker
  # If bootstrap-host.sh exit 0'd because of group membership, control
  # never reaches here. Otherwise we have a working Docker now.
  log "Docker installed; continuing install."
}

preflight() {
  log "pre-flight checks"

  # Ensure minimal tools (curl, git, jq, envsubst) — needed by every code
  # path. self_bootstrap already calls this in pipe-mode (curl|bash);
  # tarball-mode installs (e.g. <brand>.sh --install) skip self_bootstrap
  # entirely, so we'd hit "jq not found" later in the tool check below.
  # Idempotent — exits early if all tools present.
  ensure_minimal_tools

  if ! command -v docker >/dev/null 2>&1; then
    offer_docker_install "docker not found"
  fi
  local DV DMAJOR
  DV="$(docker --version | awk '{print $3}' | tr -d ,)"
  DMAJOR="${DV%%.*}"
  if [[ "$DMAJOR" -lt $REQUIRED_DOCKER_MAJOR ]]; then
    err "Docker ≥${REQUIRED_DOCKER_MAJOR} required (found $DV)"; exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    offer_docker_install "docker compose v2 plugin not found"
  fi

  local DISK_GB
  DISK_GB="$(df -BG "$SCRIPT_DIR" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
  if [[ "$DISK_GB" -lt $MIN_DISK_GB ]]; then
    err "Need ≥${MIN_DISK_GB} GB free disk, got $DISK_GB GB"; exit 1
  fi

  local RAM_MB
  RAM_MB="$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "$RAM_MB" -gt 0 && "$RAM_MB" -lt $MIN_RAM_MB ]]; then
    warn "Less than ${MIN_RAM_MB} MB RAM available (got $RAM_MB MB)"
  fi

  for tool in git jq envsubst curl; do
    command -v "$tool" >/dev/null 2>&1 || { err "$tool not found"; exit 1; }
  done

  if [[ ! -d "$SCRIPT_DIR/envs/$BRAND_ENV" ]]; then
    err "envs/$BRAND_ENV/ not found"; exit 1
  fi
  if [[ ! -f "$SCRIPT_DIR/envs/$BRAND_ENV/platform.lock.json" ]]; then
    err "envs/$BRAND_ENV/platform.lock.json not found"; exit 1
  fi
  if [[ ! -x "$SCRIPT_DIR/envs/$BRAND_ENV/secrets/load-from-vault.sh" ]]; then
    err "envs/$BRAND_ENV/secrets/load-from-vault.sh missing or not executable"; exit 1
  fi

  # ── Operator-supplied artefacts in <workspace>/.secrets/ ────────────
  # CI/CD lays these down via SCP (deploy-<env>.yml), or admin places
  # them manually for non-CI deploys. See
  # docs/operations/brand-deployment-runbook.md for the full pipeline.
  local PARENT="$(dirname "$SCRIPT_DIR")"

  # 1. SSL is mandatory — nginx-certbot Dockerfile bakes letsencrypt/
  #    into the image at build time (pre-install hook physical-copies
  #    it from .secrets/ into the build context).
  if [[ ! -d "$PARENT/.secrets/letsencrypt/live" ]]; then
    err "$PARENT/.secrets/letsencrypt/live/ not found"
    err "  → admin must place TLS tree there once (see runbook §5.5)"
    err "  → typical: 'sudo cp -a /etc/letsencrypt $PARENT/.secrets/letsencrypt'"
    exit 1
  fi

  # 2. Operator vault for the requested env.  load-from-vault.sh's
  #    auto-detect picks file:// when this is present.
  if [[ ! -f "$PARENT/.secrets/$BRAND_ENV.env" ]]; then
    err "$PARENT/.secrets/$BRAND_ENV.env not found"
    err "  → CI/CD should SCP it from BRAND_ENV_$(echo "$BRAND_ENV" | tr '[:lower:]' '[:upper:]') Secret"
    err "  → manual: copy from your secrets vault before running install.sh"
    exit 1
  fi
  local PERMS
  PERMS="$(stat -c '%a' "$PARENT/.secrets/$BRAND_ENV.env" 2>/dev/null || echo ?)"
  if [[ "$PERMS" != "600" && "$PERMS" != "400" ]]; then
    err "$PARENT/.secrets/$BRAND_ENV.env permissions are $PERMS — must be 600 or 400"
    err "  → fix: chmod 600 $PARENT/.secrets/$BRAND_ENV.env"
    exit 1
  fi

  # 3. license.json is OPTIONAL for legacy (pre-Phase-3a) brands but
  #    REQUIRED for license-aware ones.  Detect the brand intent by
  #    presence of conf/license.json.example in the repo (added by
  #    Phase-3a wiring); if present, license.json must also be in
  #    .secrets/ on first install.  This keeps backward compat for
  #    pre-license brands like the chargemecar 0.9.x cohort.
  if [[ -f "$SCRIPT_DIR/conf/license.json.example" ]]; then
    if [[ ! -f "$PARENT/.secrets/license.json" ]]; then
      err "$PARENT/.secrets/license.json not found (license-aware brand)"
      err "  → CI/CD should SCP it from LICENSE_JSON Secret"
      err "  → manual: place envelope from platform issuer, see runbook §5.2"
      exit 1
    fi
  fi

  log "  docker=$DV compose=ok disk=${DISK_GB}G ram=${RAM_MB}M tools=ok envs/$BRAND_ENV=ok"
  log "  .secrets: letsencrypt=ok ${BRAND_ENV}.env=ok$([[ -f $PARENT/.secrets/license.json ]] && echo ' license.json=ok' || echo '')"
}

# ─── Step 3: Idempotency ─────────────────────────────────────────────

idempotency_check() {
  if [[ -d "$WORKDIR" && $FORCE -eq 0 ]]; then
    err "workdir/ already exists. Re-run with --force to reinstall, or use ./update.sh to refresh."
    exit 1
  fi
  if [[ -d "$WORKDIR" && $FORCE -eq 1 ]]; then
    warn "workdir/ exists — --force given, will overwrite"
  fi
}

# ─── Step 4: Platform pin ────────────────────────────────────────────

load_platform_lock() {
  local LOCK="$SCRIPT_DIR/envs/$BRAND_ENV/platform.lock.json"
  PLATFORM_VERSION="$(jq -r '.platform_version' "$LOCK")"
  # v2 platform.lock.json (Phase 10) has no `sources` block — every
  # platform component is a GHCR image.  Older v1 locks still have it;
  # honour both, fall back to v${PLATFORM_VERSION} otherwise.
  DB_REF="$(jq -r '.sources["apostol-csms/db"].ref // empty' "$LOCK")"
  FRONTEND_REF="$(jq -r '.sources["apostol-csms/frontend"].ref // empty' "$LOCK")"
  AUTH_REF="$(jq -r '.sources["apostol-csms/auth"].ref // empty' "$LOCK")"
  [[ -z "$DB_REF"       ]] && DB_REF="v${PLATFORM_VERSION}"
  [[ -z "$FRONTEND_REF" ]] && FRONTEND_REF="v${PLATFORM_VERSION}"
  [[ -z "$AUTH_REF"     ]] && AUTH_REF="v${PLATFORM_VERSION}"
  if [[ -z "$PLATFORM_VERSION" || "$PLATFORM_VERSION" == "null" ]]; then
    err "platform.lock.json missing 'platform_version'"; exit 1
  fi
  if [[ -z "$DB_REF" || "$DB_REF" == "null" ]]; then
    err "platform.lock.json missing 'sources.apostol-csms/db.ref'"; exit 1
  fi
  if [[ -z "$FRONTEND_REF" || "$FRONTEND_REF" == "null" ]]; then
    err "platform.lock.json missing 'sources.apostol-csms/frontend.ref'"; exit 1
  fi
  export PLATFORM_VERSION
  log "pin: platform=$PLATFORM_VERSION db=$DB_REF frontend=$FRONTEND_REF auth=$AUTH_REF"
}

# ─── Step 5: Merge env templates → workdir/.env ──────────────────────

merge_env() {
  log "merge env: .env.template + envs/$BRAND_ENV/.env.template → workdir/.env"
  run mkdir -p "$WORKDIR"
  if [[ $DRY_RUN -eq 0 ]]; then
    cat "$SCRIPT_DIR/.env.template" > "$WORKDIR/.env"
    if [[ -f "$SCRIPT_DIR/envs/$BRAND_ENV/.env.template" ]]; then
      printf '\n# ─── env overrides (envs/%s/.env.template) ────────\n' "$BRAND_ENV" \
        >> "$WORKDIR/.env"
      cat "$SCRIPT_DIR/envs/$BRAND_ENV/.env.template" >> "$WORKDIR/.env"
    fi
    # Pin platform version into the rendered file (authoritative source).
    printf '\n# ─── pinned by install.sh from platform.lock.json ─\n' >> "$WORKDIR/.env"
    printf 'PLATFORM_VERSION=%s\n' "$PLATFORM_VERSION" >> "$WORKDIR/.env"

    # Compose project name — prefixes volumes/networks. If the brand
    # env didn't pin one, derive it from the brand code in license.json
    # so docker compose never falls back to a default 'csms' that would
    # silently orphan brand-named volumes if PROJECT_NAME is added later.
    if ! grep -qE '^PROJECT_NAME=' "$WORKDIR/.env"; then
      local PARENT="$(dirname "$SCRIPT_DIR")"
      local LIC="$PARENT/.secrets/license.json"
      if [[ -f "$LIC" ]] && command -v jq >/dev/null 2>&1; then
        local BRAND_CODE
        BRAND_CODE="$(jq -r '.payload.brand.code // empty' "$LIC" 2>/dev/null)"
        if [[ -n "$BRAND_CODE" ]]; then
          printf 'PROJECT_NAME=%s\n' "$BRAND_CODE" >> "$WORKDIR/.env"
          log "  PROJECT_NAME=$BRAND_CODE (derived from license.payload.brand.code)"
        fi
      fi
    fi
    chmod 600 "$WORKDIR/.env"
  fi
}

# ─── Step 6: Load secrets ────────────────────────────────────────────

load_secrets() {
  log "load secrets via envs/$BRAND_ENV/secrets/load-from-vault.sh"
  run env WORKDIR="$WORKDIR" SCRIPT_DIR="$SCRIPT_DIR" BRAND_ENV="$BRAND_ENV" \
    "$SCRIPT_DIR/envs/$BRAND_ENV/secrets/load-from-vault.sh"
  if [[ $DRY_RUN -eq 1 ]]; then return 0; fi
  [[ -s "$WORKDIR/.env" ]] || { err "workdir/.env missing or empty after secrets load"; exit 1; }
  if grep -qE '^[A-Z_][A-Z_0-9]*=("?)CHANGE_ME\1$' "$WORKDIR/.env"; then
    err "workdir/.env still contains CHANGE_ME placeholders:"
    grep -nE '^[A-Z_][A-Z_0-9]*=("?)CHANGE_ME\1$' "$WORKDIR/.env" | head -5 >&2
    err "The secrets provider did not populate every required value."
    exit 1
  fi
  chmod 600 "$WORKDIR/.env"
}

# ─── Step 7: Clone private sources (landing only) ────────────────────
#
# Phase 10 — db, frontend, auth are now pulled as public GHCR images.
# Only the brand-specific landing site is still built from source (per
# <brand>/landing repo).  If the brand has no landing repo, the operator
# comments out the landing service in docker-compose.yaml and this step
# becomes a no-op.

clone_sources() {
  log "clone brand-specific sources at $PLATFORM_VERSION"
  # shellcheck disable=SC1091
  [[ $DRY_RUN -eq 0 ]] && source "$WORKDIR/.env"

  # Landing is per-brand: <brand>/landing — sibling clone, not under
  # workdir/.  install.sh assumes it already exists if the operator has
  # uncommented the landing service.  No-op here.
  log "  (no platform repos to clone in pure-image mode)"
}

# ─── Step 8: Pull images ─────────────────────────────────────────────

pull_images() {
  log "pull all platform images from ghcr.io/apostol-csms/* (Phase 10)"
  # `compose pull` reads images from compose itself — picks up
  # PLATFORM_VERSION from workdir/.env automatically.  Brand-specific
  # `landing` (build: context) is skipped by --ignore-buildable.
  run docker compose --env-file "$WORKDIR/.env" pull --ignore-buildable
}

# ─── Step 9: Build infra + landing ───────────────────────────────────

build_local() {
  log "docker compose build (infra + landing only)"
  # Only buildable services remain: nginx, pgbouncer, pgweb, wireguard,
  # and the brand-specific landing.  Platform images are already pulled.
  run docker compose --env-file "$WORKDIR/.env" build
}

# ─── Step 10: First boot ─────────────────────────────────────────────

compose_cmd() { docker compose --env-file "$WORKDIR/.env" "$@"; }

wait_postgres_healthy() {
  local t=0
  until compose_cmd ps postgres --format json 2>/dev/null | jq -e '.Health == "healthy"' >/dev/null 2>&1; do
    sleep 2; t=$((t+2))
    if [[ $t -ge 120 ]]; then
      err "postgres did not reach healthy within 120s"
      compose_cmd logs --tail 40 postgres >&2
      exit 1
    fi
  done
}

first_boot() {
  log "first boot sequence"
  run compose_cmd up -d postgres
  log "  wait postgres healthy…"
  [[ $DRY_RUN -eq 0 ]] && wait_postgres_healthy
  log "  postgres healthy"

  log "  run db-init (creates users + schemas + seeds)"
  run compose_cmd up db-init
  # db-migrate has depends_on: db-init service_completed_successfully,
  # so it runs as part of `up -d` below.

  log "  bring up remaining services"
  run compose_cmd up -d
}

# ─── Step 11: Hooks ──────────────────────────────────────────────────

run_hook() {
  local NAME="$1"
  for CAND in "$SCRIPT_DIR/hooks/$NAME" "$SCRIPT_DIR/envs/$BRAND_ENV/hooks/$NAME"; do
    if [[ -x "$CAND" ]]; then
      log "hook: ${CAND#$SCRIPT_DIR/}"
      run env WORKDIR="$WORKDIR" BRAND_ENV="$BRAND_ENV" PLATFORM_VERSION="$PLATFORM_VERSION" \
        "$CAND"
    fi
  done
}

# ─── Step 11b: Render app env files ──────────────────────────────────
#
# After the platform sources are cloned into workdir/, brands often need
# to materialize per-app env files that containers read at runtime:
#   workdir/db/sql/.env.psql, .env.key.psql, .env.branding.psql
#   workdir/frontend/{webapp,driver,pay}/.env*
# (landing is typically a sibling repo, not under workdir/frontend/).
#
# This step delegates to `envs/<env>/render.sh` if executable. Brands
# implement it to either:
#   a) envsubst from *.template files committed in the brand-repo, or
#   b) copy pre-rendered files from a sibling .secrets/<env>/ tree.
#
# Default (no render.sh): skip; compose build will fail later if apps
# need those env files and they're absent.

render_app_env() {
  local RENDER="$SCRIPT_DIR/envs/$BRAND_ENV/render.sh"
  if [[ -x "$RENDER" ]]; then
    log "render app env via envs/$BRAND_ENV/render.sh"
    run env WORKDIR="$WORKDIR" SCRIPT_DIR="$SCRIPT_DIR" BRAND_ENV="$BRAND_ENV" "$RENDER"
  else
    log "no envs/$BRAND_ENV/render.sh — skipping app-env rendering"
  fi
}

# ─── Step 12: Verify ─────────────────────────────────────────────────

record_current_env() {
  if [[ $DRY_RUN -eq 0 ]]; then
    echo "$BRAND_ENV" > "$WORKDIR/.current-env"
    echo "$PLATFORM_VERSION" > "$WORKDIR/.installed-version"
  fi
}

verify_install() {
  if [[ -x "$SCRIPT_DIR/check.sh" ]]; then
    log "verify via ./check.sh"
    if ! run "$SCRIPT_DIR/check.sh"; then
      warn "check.sh reported issues — review output above"
    fi
  else
    warn "check.sh not found — skipping verification"
  fi
}

# ─── Main ────────────────────────────────────────────────────────────

self_bootstrap "$@"

if [[ -z "$BRAND_ENV" ]]; then
  err "--env=<name> required (or BRAND_ENV env var)"
  display_help >&2
  exit 1
fi

log "Apostol CSMS install — env=$BRAND_ENV$([[ $FORCE -eq 1 ]] && echo ' [force]')$([[ $DRY_RUN -eq 1 ]] && echo ' [dry-run]')"

preflight
idempotency_check
load_platform_lock
merge_env
load_secrets
clone_sources
render_app_env
pull_images
run_hook pre-install.sh
build_local
first_boot
run_hook post-install.sh
record_current_env
verify_install

log "install complete — https://${DOMAIN:-<DOMAIN>}"
