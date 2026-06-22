#!/usr/bin/env bash
# =============================================================================
#  lib/log.sh — Logging + run_cmd with gum spinner
# =============================================================================

log_message() {
  local level="$1" message="$2"
  local colour priority icon

  case "$level" in
    INFO)    colour='\033[1;32m'; priority="info";    icon="✓" ;;
    WARNING) colour='\033[1;33m'; priority="warning"; icon="⚠" ;;
    ERROR)   colour='\033[1;31m'; priority="err";     icon="✗" ;;
    DEBUG)   colour='\033[0;36m'; priority="debug";   icon="·" ;;
    *)       colour='\033[1;34m'; priority="notice";  icon="i" ;;
  esac

  [[ "$level" == "DEBUG" && "${VERBOSE:-0}" -eq 0 ]] && return 0

  if command -v systemd-cat &>/dev/null; then
    echo "[$icon] $message" | systemd-cat -t "${JOURNAL_TAG:-presto}" -p "$priority" 2>/dev/null || true
  fi

  printf "${colour}[%s]\033[0m %s\n" "$icon" "$message" >&2
}

log_info()  { log_message "INFO"    "$*"; }
log_warn()  { log_message "WARNING" "$*"; }
log_error() { log_message "ERROR"   "$*"; }
log_debug() { log_message "DEBUG"   "$*"; }

# run_cmd "Label shown in spinner" cmd [args...]
#
# Output is hidden behind the spinner by default. Pass --show-install (-s)
# on the presto CLI to reveal full command output for every run_cmd call
# in the session — handy for debugging or just watching what's happening.
run_cmd() {
  local label="$1"; shift
  log_debug "run_cmd: $*"

  if ! command -v gum &>/dev/null; then
    echo "→ $label"
    "$@"
    return $?
  fi

  if [[ "${SHOW_INSTALL:-0}" -eq 1 ]]; then
    gum spin --spinner dot --title "$label" --show-output -- "$@"
  else
    gum spin --spinner dot --title "$label" -- "$@"
  fi
}
