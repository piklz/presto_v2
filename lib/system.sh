#!/usr/bin/env bash
# =============================================================================
#  lib/system.sh — Arch detection, disk, git, swap, log2ram, system tools
# =============================================================================

# ---------------------------------------------------------------------------
# Architecture
# ---------------------------------------------------------------------------
sys_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo "arm64" ;;
    armv7l)        echo "armv7" ;;
    x86_64)        echo "amd64" ;;
    *)             echo "unknown" ;;
  esac
}

is_pi() {
  grep -qi "raspberrypi" /proc/device-tree/compatible 2>/dev/null
}

# ---------------------------------------------------------------------------
# Disk space guard
# check_disk_space [required_mb] [path]
# ---------------------------------------------------------------------------
check_disk_space() {
  local required="${1:-200}"
  local path="${2:-$PRESTO_DIR}"
  local free

  free=$(df -m "$path" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ -z "$free" || ! "$free" =~ ^[0-9]+$ ]]; then
    log_error "Cannot determine free space at $path"
    return 1
  fi

  if (( free < required )); then
    log_error "Low disk space: ${free}MB free, ${required}MB needed at $path"
    ui_error "Only ${free}MB free at ${path}.\nNeed at least ${required}MB — free up space and retry."
    return 1
  fi

  log_debug "Disk OK: ${free}MB free at $path"
}

# ---------------------------------------------------------------------------
# Git — clone on first run, check for updates each launch.
#
# PRESTO_UPDATE_AVAILABLE (0/1) drives whether the main menu shows
# "Update Presto". .update_notified just throttles the one-time startup
# nag so it doesn't repeat every launch while a commit is pending.
# ---------------------------------------------------------------------------
git_check_and_sync() {
  if ! command -v git &>/dev/null; then
    ui_confirm "git is not installed. Install it now?" \
      || { log_error "git required. Exiting."; exit 1; }
    run_cmd "Installing git..." sudo apt-get install -y git \
      || { log_error "git install failed"; exit 1; }
  fi

  if [[ ! -d "$PRESTO_DIR/.git" ]]; then
    log_info "Cloning presto..."
    [[ "$PWD" == "$PRESTO_DIR"* ]] && cd "$USER_HOME"
    [[ -d "$PRESTO_DIR" ]] && rm -rf "$PRESTO_DIR"
    git clone -b main "$PRESTO_REPO" "$PRESTO_DIR" \
      || { log_error "Clone failed"; exit 1; }
  fi

  cd "$PRESTO_DIR"

  # First-run: create presto.conf from example if not present
  if [[ ! -f "$PRESTO_DIR/presto.conf" && -f "$PRESTO_DIR/presto.conf.example" ]]; then
    cp "$PRESTO_DIR/presto.conf.example" "$PRESTO_DIR/presto.conf"
    log_info "Created presto.conf from example — edit to customise network settings"
  fi

  # First-run: create root .env from example if not present
  if [[ ! -f "$PRESTO_DIR/.env" && -f "$PRESTO_DIR/.env.example" ]]; then
    cp "$PRESTO_DIR/.env.example" "$PRESTO_DIR/.env"
    log_warn ".env created from example — EDIT IT NOW: nano $PRESTO_DIR/.env"
    log_warn "Set SYSTEM_HOSTNAME, HOST_IP, and REMOTE_IP before starting your stack"
  fi

  git fetch origin --quiet 2>/dev/null || true
  _update_status_refresh
}

# Compares HEAD to origin/main, sets PRESTO_UPDATE_AVAILABLE +
# PRESTO_COMMITS_BEHIND, and fires the one-time nag the first time a
# new commit is seen. Assumes the caller already did `git fetch`.
_update_status_refresh() {
  local behind
  behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
  PRESTO_COMMITS_BEHIND="$behind"

  if (( behind > 0 )); then
    export PRESTO_UPDATE_AVAILABLE=1
    if [[ ! -f "$PRESTO_DIR/.update_notified" ]]; then
      ui_warn "Presto is ${behind} commit(s) behind.\nUse '⬆️  Update Presto' from the menu, or System Tools → Check for Presto updates."
      touch "$PRESTO_DIR/.update_notified"
    fi
  else
    export PRESTO_UPDATE_AVAILABLE=0
    rm -f "$PRESTO_DIR/.update_notified"
  fi
}

# ---------------------------------------------------------------------------
# Git pull update
# ---------------------------------------------------------------------------
git_do_update() {
  check_disk_space 100 || return 1
  cd "$PRESTO_DIR"
  ui_header "Updating Presto"

  local stash_created=0
  if git stash 2>&1 | grep -q "Saved working directory"; then
    stash_created=1
    log_warn "Local changes stashed"
  fi

  run_cmd "Pulling from GitHub..." git pull origin main || {
    log_error "git pull failed"
    (( stash_created )) && git stash pop 2>/dev/null || true
    return 1
  }

  (( stash_created )) && { git stash pop 2>/dev/null || log_warn "Stash pop had conflicts — check git status"; }

  # Refresh .env.example files without touching real .envs
  while IFS= read -r -d '' ex; do
    local svc; svc=$(basename "$(dirname "$ex")")
    local dest="$SERVICES_DIR/$svc/$(basename "$ex")"
    [[ -f "$dest" ]] && cp "$ex" "$dest"
  done < <(find "$TEMPLATES_DIR" -name "*.env.example" -print0 2>/dev/null)

  find "$SCRIPTS_DIR" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

  export PRESTO_UPDATE_AVAILABLE=0
  rm -f "$PRESTO_DIR/.update_notified"

  log_info "Updated to $(git rev-parse --short HEAD)"
  ui_notify "Update Complete ✓" "Presto is up to date."
}

# Manual, always-available trigger — System Tools → Check for Presto updates.
# Re-fetches regardless of the one-time-nag state, so it always gives a
# fresh answer even if you already dismissed the startup notice.
_check_for_updates_manual() {
  check_disk_space 100 || return 1
  cd "$PRESTO_DIR"
  ui_header "Checking for Presto Updates"

  run_cmd "Fetching from GitHub..." git fetch origin --quiet || {
    ui_error "Could not reach GitHub.\nCheck your internet connection and try again."
    return 1
  }
  _update_status_refresh

  if [[ "${PRESTO_UPDATE_AVAILABLE}" -eq 1 ]]; then
    ui_confirm "Presto is ${PRESTO_COMMITS_BEHIND} commit(s) behind. Update now?" && git_do_update
  else
    ui_notify "Up to date ✓" "Presto is already on the latest version."
  fi
}

# ---------------------------------------------------------------------------
# System tools menu
# ---------------------------------------------------------------------------
system_tools_menu() {
  local choice
  choice=$(gum choose \
    --header "🛠  System Tools" \
    "🔄  Check for Presto updates" \
    "📊  Quick resource snapshot" \
    "📦  Check & apply OS updates (apt)" \
    "🧹  Docker system prune (all-in-one)" \
    "💤  Disable swap" \
    "🎚   Set swappiness to 0" \
    "📂  Install log2ram" \
    "← Back" \
  ) || return 0

  case "$choice" in
    *"Presto updates"*) _check_for_updates_manual ;;
    *"snapshot"*)        _resource_snapshot ;;
    *"OS updates"*)      _check_apt_updates ;;
    *"system prune"*)    _docker_system_prune ;;
    *"Disable swap"*)    _disable_swap ;;
    *"swappiness"*)      _set_swappiness ;;
    *"log2ram"*)         _install_log2ram ;;
  esac
}

_disable_swap() {
  ui_confirm "Disable dphys swap file? (Recommended with ≥4GB RAM)" || return 0
  run_cmd "Stopping swap..."           sudo dphys-swapfile swapoff
  run_cmd "Uninstalling swap..."       sudo dphys-swapfile uninstall
  run_cmd "Removing swap from init..." sudo update-rc.d dphys-swapfile remove
  sudo systemctl disable dphys-swapfile 2>/dev/null || true
  ui_notify "Done ✓" "Swap disabled."
}

_set_swappiness() {
  if grep -q "vm.swappiness" /etc/sysctl.conf; then
    sudo sed -i "/vm.swappiness/c\\vm.swappiness=0" /etc/sysctl.conf
  else
    echo "vm.swappiness=0" | sudo tee -a /etc/sysctl.conf >/dev/null
  fi
  sudo sysctl vm.swappiness=0
  ui_notify "Done ✓" "Swappiness set to 0."
}

_install_log2ram() {
  if [[ -f /usr/bin/log2ram ]]; then
    ui_notify "Already installed" "log2ram is already on this system."; return 0
  fi
  ui_confirm "Install log2ram? (Mounts /var/log in RAM to reduce disk writes)" || return 0

  local tmp; tmp=$(mktemp -d)
  run_cmd "Downloading log2ram..." \
    curl -fsSL https://github.com/azlux/log2ram/archive/master.tar.gz -o "$tmp/log2ram.tar.gz"
  tar -xzf "$tmp/log2ram.tar.gz" -C "$tmp"
  chmod +x "$tmp/log2ram-master/install.sh"
  (cd "$tmp/log2ram-master" && sudo ./install.sh)
  rm -rf "$tmp"
  ui_notify "log2ram installed ✓" "Reboot to activate."
}

# Check apt's upgradable package list and let the user choose to apply it.
_check_apt_updates() {
  ui_confirm "Check for OS package updates? (sudo apt update)" || return 0
  run_cmd "Checking for updates..." sudo apt-get update -qq

  local count
  count=$(apt list --upgradable 2>/dev/null | grep -vc "^Listing...")

  if (( count == 0 )); then
    ui_notify "Up to date ✓" "No package updates available."
    return 0
  fi

  ui_warn "${count} package(s) can be upgraded."
  ui_confirm "Apply updates now? (sudo apt upgrade -y)" || return 0
  run_cmd "Upgrading packages..." sudo apt-get upgrade -y
  ui_notify "Done ✓" "${count} package(s) upgraded.\n\nReboot if a kernel or firmware update was included."
}

# At-a-glance load/memory/disk/temp — no scrolling logs, just the headline numbers.
_resource_snapshot() {
  local load mem disk temp
  load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
  mem=$(free -h | awk '/^Mem:/{print $3" / "$2" used"}')
  disk=$(df -h "$PRESTO_DIR" | awk 'NR==2{print $3" / "$2" used ("$5")"}')

  if command -v vcgencmd &>/dev/null; then
    temp=$(vcgencmd measure_temp | sed 's/temp=//')
  elif [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    temp="$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))°C"
  else
    temp="n/a"
  fi

  gum style \
    --border rounded --border-foreground 212 --padding "1 2" \
    "$(gum style --bold --foreground 212 "📊  System Snapshot")" \
    "" \
    "Load avg : ${load}" \
    "Memory   : ${mem}" \
    "Disk     : ${disk}  (${PRESTO_DIR})" \
    "Temp     : ${temp}"
  gum input --placeholder "  Press Enter to continue..." --char-limit 0 >/dev/null 2>&1 || true
}

# Full docker system prune — broader than the per-resource prune scripts in
# Docker Commands, so it gets an explicit warning before running.
_docker_system_prune() {
  ui_warn "This removes ALL unused containers, images, networks, build cache,\nand volumes — not just dangling ones. Anything not attached to a\nrunning container will be deleted."
  ui_confirm "Continue with full Docker system prune?" || return 0
  _run_script "prune-system.sh" "Docker system pruned"
}

# ---------------------------------------------------------------------------
# Timezone helper — called from stack builder
# ---------------------------------------------------------------------------
apply_timezone() {
  local env_file="$1"
  local tz; tz=$(cat /etc/timezone 2>/dev/null || echo "UTC")
  if grep -q "^TZ=" "$env_file"; then
    sed -i "s|^TZ=.*|TZ=${tz}|" "$env_file"
  else
    printf "\nTZ=%s\n" "$tz" >> "$env_file"
  fi
}
