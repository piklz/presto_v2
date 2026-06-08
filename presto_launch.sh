#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
# =============================================================================
#  PRESTO v2 — Docker Stack Manager for Debian/Raspberry Pi OS
#  https://github.com/piklz/presto
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths and real user (works with and without sudo)
# ---------------------------------------------------------------------------
if [[ -n "${SUDO_USER:-}" ]]; then
  REAL_USER="$SUDO_USER"
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  REAL_USER="$(id -un)"
  USER_HOME="$HOME"
fi

readonly REAL_USER USER_HOME
readonly VERSION="2.0.0"
readonly JOURNAL_TAG="presto"
readonly PRESTO_REPO="https://github.com/piklz/presto_v2.git"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PRESTO_DIR="${PRESTO_DIR:-$SCRIPT_DIR}"
readonly TEMPLATES_DIR="$PRESTO_DIR/.templates"
readonly SERVICES_DIR="$PRESTO_DIR/services"
readonly SCRIPTS_DIR="$PRESTO_DIR/scripts"
readonly LIB_DIR="$PRESTO_DIR/lib"

export REAL_USER USER_HOME VERSION JOURNAL_TAG PRESTO_REPO
export PRESTO_DIR TEMPLATES_DIR SERVICES_DIR SCRIPTS_DIR LIB_DIR

# ---------------------------------------------------------------------------
# Must not run as root
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
  echo "[presto] ERROR: Do not run as root. Run as your normal user."
  exit 1
fi

# ---------------------------------------------------------------------------
# Source libs
# ---------------------------------------------------------------------------
for _lib in log ui system docker stack backup; do
  # shellcheck source=/dev/null
  source "$LIB_DIR/${_lib}.sh" || { echo "ERROR: missing lib/${_lib}.sh"; exit 1; }
done

# ---------------------------------------------------------------------------
# Load user config (presto.conf) — must come after libs so log_* is available
# ---------------------------------------------------------------------------
readonly PRESTO_CONF="$PRESTO_DIR/presto.conf"
if [[ -f "$PRESTO_CONF" ]]; then
  # shellcheck source=/dev/null
  source "$PRESTO_CONF"
  log_debug "Loaded config: $PRESTO_CONF"
else
  log_warn "presto.conf not found — using built-in defaults"
fi

# Apply defaults for any vars not set in presto.conf
: "${PRESTO_NETWORK_NAME:=presto-network}"
: "${PRESTO_SUBNET:=172.19.0.0/24}"
: "${PRESTO_COMPOSE_FILE:=$PRESTO_DIR/docker-compose.yml}"
: "${RCLONE_REMOTE:=gdrive}"
: "${RCLONE_DEST:=presto-backup}"

export PRESTO_NETWORK_NAME PRESTO_SUBNET PRESTO_COMPOSE_FILE RCLONE_REMOTE RCLONE_DEST

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v) VERBOSE=1 ;;
    --help|-h)
      cat <<EOF
presto v${VERSION}
Usage: ./presto_launch.sh [--verbose] [--help]
Logs:  journalctl -t ${JOURNAL_TAG} [-f]
EOF
      exit 0 ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
  shift
done
export VERBOSE

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
ui_check_gum
git_check_and_sync

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
while true; do
  choice=$(gum choose \
    --header "🚀  PRESTO  v${VERSION}  —  Docker Stack Manager" \
    --header.foreground="212" \
    "📦  Build / Manage Stack" \
    "🐳  Docker Commands" \
    "⬆️   Update Presto" \
    "⬆️   Update Docker Images" \
    "🔧  Install Docker + Compose" \
    "🛠   System Tools" \
    "💾  Backup / Restore" \
    "🧩  Install Presto-Tools" \
    "ℹ️   About" \
    "❌  Exit" \
  ) || { log_info "Bye!"; exit 0; }

  case "$choice" in
    *"Build"*)           stack_menu ;;
    *"Docker Commands"*) docker_commands_menu ;;
    *"Update Presto"*)   git_do_update ;;
    *"Docker Images"*)   docker_compose_update ;;
    *"Install Docker"*)  docker_install_menu ;;
    *"System Tools"*)    system_tools_menu ;;
    *"Backup"*)          backup_menu ;;
    *"Presto-Tools"*)    presto_tools_install ;;
    *"About"*)           ui_about ;;
    *"Exit"*)            log_info "Bye!"; exit 0 ;;
  esac
done
