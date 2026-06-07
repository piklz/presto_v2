#!/usr/bin/env bash
# =============================================================================
#  lib/backup.sh — rclone Google Drive backup / restore
#  Uses RCLONE_REMOTE and RCLONE_DEST from presto.conf
# =============================================================================

backup_menu() {
  local choice
  choice=$(gum choose \
    --header "💾  Backup & Restore" \
    "Install / configure rclone" \
    "Backup to Google Drive" \
    "Restore from Google Drive" \
    "← Back" \
  ) || return 0

  case "$choice" in
    *"Install"*) _rclone_install ;;
    *"Backup"*)  _backup_gdrive ;;
    *"Restore"*) _restore_gdrive ;;
  esac
}

_rclone_remote() { echo "${RCLONE_REMOTE:-gdrive}"; }
_rclone_dest()   { echo "${RCLONE_DEST:-presto-backup}"; }

_rclone_ready() {
  local remote; remote=$(_rclone_remote)
  command -v rclone &>/dev/null \
    && rclone listremotes 2>/dev/null | grep -q "^${remote}:"
}

_rclone_install() {
  if _rclone_ready; then
    ui_notify "rclone ready ✓" \
      "rclone is installed and '$(_rclone_remote):' remote is configured."
    return 0
  fi

  if ! command -v rclone &>/dev/null; then
    ui_confirm "Install rclone? (requires sudo)" || return 0
    local tmp; tmp=$(mktemp /tmp/rclone-XXXXXX.sh)
    run_cmd "Downloading rclone installer..." curl -fsSL https://rclone.org/install.sh -o "$tmp"
    ui_confirm "Review rclone installer?" && gum pager < "$tmp"
    run_cmd "Installing rclone..." bash "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    log_info "rclone installed"
  fi

  local remote; remote=$(_rclone_remote)
  gum style \
    --border rounded --border-foreground 214 --padding "1 2" \
    "$(gum style --bold "rclone remote setup  (remote name: '${remote}')")" \
    "" \
    "Run:  rclone config" \
    "" \
    "Steps:" \
    "  n  → new remote" \
    "  Name: ${remote}" \
    "  Storage: Google Drive  (choose 'drive')" \
    "  Client ID / Secret: leave blank" \
    "  Scope: 1  (full access)" \
    "  Root folder: leave blank" \
    "  Advanced config: n" \
    "  Auto config: y  (or n on headless — paste auth token)" \
    "  Team drive: n" \
    "  Confirm: y → q" \
    "" \
    "To change the remote name, edit RCLONE_REMOTE in presto.conf"

  ui_confirm "Open rclone config now?" && rclone config
}

_backup_gdrive() {
  if ! command -v rclone &>/dev/null; then
    ui_error "rclone not installed.\nUse 'Install / configure rclone' first."
    return 1
  fi

  local remote; remote=$(_rclone_remote)
  local dest_root; dest_root=$(_rclone_dest)

  if ! rclone listremotes 2>/dev/null | grep -q "^${remote}:"; then
    ui_error "rclone remote '${remote}:' not found.\nRun 'Install / configure rclone', or set RCLONE_REMOTE in presto.conf."
    return 1
  fi

  local script="$SCRIPTS_DIR/rclone_backup.sh"
  if [[ -f "$script" ]]; then
    run_cmd "Backing up to ${remote}:..." bash "$script" || {
      ui_error "Backup failed.\nCheck: journalctl -t ${JOURNAL_TAG}"
      return 1
    }
  else
    # Built-in fallback using presto.conf vars
    local dest="${remote}:${dest_root}/$(date +%Y%m%d_%H%M%S)"
    run_cmd "Syncing services/ to ${dest}..." \
      rclone copy "$SERVICES_DIR" "$dest" \
        --exclude "**/.git/**" --progress || {
      ui_error "Backup failed."
      return 1
    }
  fi

  ui_notify "Backup Complete ✓" "services/ synced to ${remote}:${dest_root}"
}

_restore_gdrive() {
  if ! command -v rclone &>/dev/null; then
    ui_error "rclone not installed.\nUse 'Install / configure rclone' first."
    return 1
  fi

  local script="$SCRIPTS_DIR/rclone_restore.sh"
  if [[ -f "$script" ]]; then
    run_cmd "Restoring from $(_rclone_remote):..." bash "$script" || {
      ui_error "Restore failed.\nCheck: journalctl -t ${JOURNAL_TAG}"
      return 1
    }
    ui_notify "Restore Complete ✓" "Data restored from $(_rclone_remote):$(_rclone_dest)"
  else
    ui_error "rclone_restore.sh not found in scripts/.\nRun '⬆️  Update Presto' to sync scripts."
    return 1
  fi
}
