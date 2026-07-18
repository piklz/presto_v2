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
readonly VERSION="2.1.0"
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
for _lib in log ui system docker stack; do
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
: "${PRESTO_VOLUMES_DIR:=$PRESTO_DIR/volumes}"

# Resolve PRESTO_VOLUMES_DIR to an absolute path.
# presto.conf may set a bare relative value ("volumes") for brevity — bash
# file ops need absolute paths, so we anchor relative values to $PRESTO_DIR.
# Absolute paths (starting with /) are left unchanged.
if [[ "${PRESTO_VOLUMES_DIR}" != /* ]]; then
  PRESTO_VOLUMES_DIR="$PRESTO_DIR/${PRESTO_VOLUMES_DIR}"
fi
# Canonicalise away any ./ or double-slashes without requiring the dir to exist yet.
PRESTO_VOLUMES_DIR="$(realpath -m "$PRESTO_VOLUMES_DIR")"

export PRESTO_NETWORK_NAME PRESTO_SUBNET PRESTO_COMPOSE_FILE PRESTO_VOLUMES_DIR

# ---------------------------------------------------------------------------
# Breadcrumb for external tools (presto-tools aliases/cron scripts, etc).
# They need to find THIS install's paths without hardcoding "~/presto" —
# PRESTO_DIR is user-configurable and may live anywhere. Written fresh on
# every launch, so if the install ever moves, the next run self-heals it.
# Deliberately best-effort: a failure here must never block presto itself.
# ---------------------------------------------------------------------------
cat > "$USER_HOME/.presto_env" <<EOF 2>/dev/null || true
PRESTO_DIR=$PRESTO_DIR
PRESTO_COMPOSE_FILE=$PRESTO_COMPOSE_FILE
PRESTO_VOLUMES_DIR=$PRESTO_VOLUMES_DIR
EOF

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
VERBOSE=0
SHOW_INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v)      VERBOSE=1 ;;
    --show-install|-s) SHOW_INSTALL=1 ;;
    --help|-h)
      cat <<EOF
presto v${VERSION}
Usage: ./presto_launch.sh [--verbose] [--show-install] [--help]

  --verbose, -v        Verbose internal logging (DEBUG level)
  --show-install, -s   Show full output of background installs
                        (gum, Docker, log2ram, etc.) instead of a
                        quiet spinner. Output is always shown on
                        failure regardless of this flag.

Logs:  journalctl -t ${JOURNAL_TAG} [-f]
EOF
      exit 0 ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
  shift
done
export VERBOSE SHOW_INSTALL

# ---------------------------------------------------------------------------
# gum visual theme — set ONCE here, inherited by every `gum choose` call
# across every lib/*.sh file (they're all `source`d into this same shell,
# and gum reads these as its own env vars — no per-call-site flags needed).
# Change the look everywhere at once by editing these values only.
# ---------------------------------------------------------------------------
export GUM_CHOOSE_CURSOR="❯ "
export GUM_CHOOSE_CURSOR_FOREGROUND="212"
export GUM_CHOOSE_CURSOR_BACKGROUND="53"
export GUM_CHOOSE_SELECTED_FOREGROUND="255"
export GUM_CHOOSE_SELECTED_BACKGROUND="57"
export GUM_CHOOSE_SELECTED_PREFIX="✅ "
export GUM_CHOOSE_UNSELECTED_PREFIX="⬜ "
export GUM_CHOOSE_HEADER_FOREGROUND="212"

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
ui_check_gum
git_check_and_sync

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
while true; do
  menu_items=(
    "📦  Build / Manage Stack"
    "🐳  Docker Commands"
  )
  # Only show the update item when we actually know we're behind origin/main.
  [[ "${PRESTO_UPDATE_AVAILABLE:-0}" -eq 1 ]] && \
    menu_items+=("⬆️   Update Presto  (update available)")
  menu_items+=(
    "⬆️   Update Docker Images"
    "🔧  Install Docker + Compose"
    "🛠   System Tools"
    "🧩  Install Presto-Tools"
    "ℹ️   About"
    "❌  Exit"
  )

  choice=$(gum choose \
    --header "🚀  PRESTO  v${VERSION}  —  Docker Stack Manager" \
    "${menu_items[@]}" \
  ) || { log_info "Bye!"; exit 0; }

  case "$choice" in
    *"Build"*)            stack_menu ;;
    *"Docker Commands"*)  docker_commands_menu ;;
    *"Update Presto"*)    git_do_update ;;
    *"Docker Images"*)    docker_compose_update ;;
    *"Install Docker"*)   docker_install_menu ;;
    *"System Tools"*)     system_tools_menu ;;
    *"Presto-Tools"*)     presto_tools_install ;;
    *"About"*)            ui_about ;;
    *"Exit"*)             log_info "Bye!"; exit 0 ;;
  esac
done