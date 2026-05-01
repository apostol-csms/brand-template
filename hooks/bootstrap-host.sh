#!/usr/bin/env bash
#
# hooks/bootstrap-host.sh — cross-distro host preparation. Installs the
# minimum base packages and the Docker engine in a way that works on any
# major Linux brand operators are likely to deploy on:
#
#   - Debian / Ubuntu                 (apt)
#   - RHEL / CentOS / Rocky / Alma    (dnf, yum fallback)
#   - Fedora                          (dnf)
#   - openSUSE / SLES                 (zypper)
#
# Docker itself is installed via the upstream convenience script
# get.docker.com — Docker Inc. maintains it across all of these distros,
# so we don't reinvent the wheel per package manager.
#
# This script is intended to be invoked by csms/install.sh on a fresh
# host. It can also be run standalone:
#
#   sudo ./hooks/bootstrap-host.sh           # full setup (--all)
#   sudo ./hooks/bootstrap-host.sh --docker  # only Docker engine + sysconfig
#   sudo ./hooks/bootstrap-host.sh --minimal # only curl / git / jq

set -Eeuo pipefail

MODE="${1:---all}"

# ─── Privilege ───────────────────────────────────────────────────────
# This script does sysadmin-level work: package install, /etc/docker
# config, systemd unit enable. Re-exec under sudo if not root.
if [[ "$EUID" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "[bootstrap] ERROR: not root and sudo not found" >&2
    exit 1
  fi
else
  SUDO=""
fi

# Real user that needs to be added to the `docker` group. Survives `sudo`.
# Falls back through SUDO_USER → USER → LOGNAME → `id -un` so the
# variable is always defined under `set -u`, even in stripped-down
# container environments where $USER is unset.
REAL_USER="${SUDO_USER:-${USER:-${LOGNAME:-$(id -un 2>/dev/null || echo root)}}}"

# ─── Distro detection ────────────────────────────────────────────────

detect_pm() {
  if   command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf     >/dev/null 2>&1; then echo dnf
  elif command -v yum     >/dev/null 2>&1; then echo yum
  elif command -v zypper  >/dev/null 2>&1; then echo zypper
  else echo unknown
  fi
}

PM=$(detect_pm)

pm_install() {
  case "$PM" in
    apt)
      $SUDO apt-get update -qq
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
      ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    zypper) $SUDO zypper --non-interactive install --no-recommends "$@" ;;
    *)
      echo "[bootstrap] ERROR: unsupported package manager (apt/dnf/yum/zypper expected)" >&2
      exit 1
      ;;
  esac
}

OS_NAME="unknown"
[[ -r /etc/os-release ]] && OS_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")"
echo "[bootstrap] host: $OS_NAME (pm=$PM)"

# ─── Mode: minimal — base tools install.sh itself depends on ────────

bootstrap_minimal() {
  echo "[bootstrap] ensure base packages: ca-certificates curl git jq gettext"
  # gettext provides envsubst, used by csms compose-env / nginx render.
  pm_install ca-certificates curl git jq gettext
}

# ─── Mode: docker — Docker engine + Apostol-stack defaults ──────────

bootstrap_docker() {
  local has_docker=0 has_compose=0
  command -v docker >/dev/null 2>&1 && has_docker=1
  docker compose version >/dev/null 2>&1 && has_compose=1

  if [[ $has_docker -eq 1 && $has_compose -eq 1 ]]; then
    echo "[bootstrap] docker + compose v2 already present: $(docker --version)"
  elif [[ $has_docker -eq 1 && $has_compose -eq 0 ]]; then
    # Frequent case on Ubuntu 24.04: docker.io from the distro repo (apt)
    # ships engine + cli but NO compose v2 plugin. Reinstalling Docker
    # via get.docker.com would clobber the working engine — we only
    # need the plugin. Drop the standalone binary into the per-user
    # cli-plugins dir; works with any docker engine version.
    echo "[bootstrap] docker present ($(docker --version)), compose v2 plugin missing — installing it"
    if ! command -v curl >/dev/null 2>&1; then
      pm_install ca-certificates curl
    fi
    local plugin_dir=/usr/local/lib/docker/cli-plugins
    $SUDO mkdir -p "$plugin_dir"
    $SUDO curl -fsSL \
      https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
      -o "$plugin_dir/docker-compose"
    $SUDO chmod +x "$plugin_dir/docker-compose"
    echo "[bootstrap] compose plugin: $(docker compose version)"
  else
    # No docker at all — fresh host. Use the upstream installer.
    if ! command -v curl >/dev/null 2>&1; then
      echo "[bootstrap] curl missing — pulling base packages first"
      pm_install ca-certificates curl
    fi
    echo "[bootstrap] installing Docker via https://get.docker.com"
    curl -fsSL https://get.docker.com | $SUDO sh
  fi

  # Logging limits — without these json-file driver fills the disk in
  # weeks. Required for any deployment kept beyond a quick smoke.
  echo "[bootstrap] writing /etc/docker/daemon.json (log limits)"
  $SUDO mkdir -p /etc/docker
  $SUDO tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
JSON

  # systemd is present on every realistic deployment target (Debian 12+,
  # Ubuntu 20.04+, RHEL 7+, etc.) but not inside a default container —
  # gate the systemd-touching block so this script can be smoke-tested
  # in `docker run debian:trixie ...` without false failures.
  if [[ -d /run/systemd/system ]]; then
    echo "[bootstrap] enabling docker.service"
    $SUDO systemctl enable --now docker
    # Restart so the new daemon.json takes effect; safe even on a fresh install.
    $SUDO systemctl restart docker

    # Time sync — manifest envelope verification rejects clocks that drift
    # past CLOCK_SKEW_TOLERANCE (300s). systemd-timesyncd is default on
    # Debian/Ubuntu; chrony on Debian (chronyd is a back-compat symlink
    # there, which systemctl refuses to enable); chronyd on
    # RHEL/CentOS/Rocky/Fedora.
    #
    # Try canonical names in order. Wrap in `|| true` — NTP enable is
    # best-effort: an offline / restricted host that can't reach time
    # servers shouldn't block the deploy. Operator can run `timedatectl`
    # afterwards to verify.
    if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes; then
      echo "[bootstrap] enabling time synchronisation (best-effort)"
      ntp_enable() {
        for unit in systemd-timesyncd chrony chronyd; do
          if $SUDO systemctl enable --now "$unit" 2>/dev/null; then
            echo "[bootstrap]   enabled $unit"
            return 0
          fi
        done
        return 1
      }
      if ! ntp_enable; then
        pm_install chrony 2>/dev/null || true
        ntp_enable || echo "[bootstrap]   WARN: no time-sync daemon enabled — verify host clock drift manually (timedatectl status)"
      fi
    fi
  else
    echo "[bootstrap] WARN: systemd not running (likely a container) —"
    echo "[bootstrap]   skipping 'systemctl enable --now docker' and time-sync."
    echo "[bootstrap]   On a real host this branch enables docker.service +"
    echo "[bootstrap]   time sync after writing daemon.json."
  fi

  # Docker group for the real (non-root) user. Without this `docker ps`
  # under that user requires sudo every time.
  if [[ "$REAL_USER" != "root" ]]; then
    if ! id -nG "$REAL_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      echo "[bootstrap] adding $REAL_USER to the docker group"
      $SUDO usermod -aG docker "$REAL_USER"
      cat <<EOF

═══════════════════════════════════════════════════════════════════════
  Docker group membership added for user '$REAL_USER'.

  The current shell will NOT see the new group until you re-login
  (or run 'newgrp docker' in a sub-shell). Until then, 'docker' must
  be invoked via sudo.

  Re-login and re-run install.sh to continue.
═══════════════════════════════════════════════════════════════════════
EOF
      # Exit 0 — bootstrap succeeded; install.sh will be re-run by the
      # operator after re-login.
      exit 0
    fi
  fi

  echo "[bootstrap] docker ready: $(docker --version)"
}

# ─── Dispatch ────────────────────────────────────────────────────────

case "$MODE" in
  --minimal) bootstrap_minimal ;;
  --docker)  bootstrap_docker ;;
  --all)     bootstrap_minimal; bootstrap_docker ;;
  -h|--help)
    cat <<EOF
Usage: $0 [--minimal | --docker | --all]

  --minimal   Install ca-certificates, curl, git, jq, gettext.
  --docker    Install Docker engine + compose v2 (via get.docker.com),
              write /etc/docker/daemon.json with log-rotation limits,
              enable systemd time sync, add the real user to the
              'docker' group, restart docker.
  --all       --minimal then --docker (default).

The script auto-detects the package manager (apt / dnf / yum / zypper)
and re-execs itself under sudo if not run as root.
EOF
    exit 0
    ;;
  *)
    echo "[bootstrap] ERROR: unknown mode '$MODE' (use --minimal / --docker / --all / --help)" >&2
    exit 1
    ;;
esac

echo "[bootstrap] done"
