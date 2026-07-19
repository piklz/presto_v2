#!/usr/bin/env bash
# =============================================================================
#  lib/system.sh — Arch detection, disk, git, swappiness, system tools
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
    if [[ -d "$PRESTO_DIR" && -n "$(ls -A "$PRESTO_DIR" 2>/dev/null)" ]]; then
      # PRESTO_DIR exists, has content, but isn't a git checkout — this can
      # happen from a zip download, a corrupted .git, or simply pointing
      # PRESTO_DIR at the wrong path. It may contain volumes/ (real container
      # data) or a hand-edited .env. NEVER auto-delete it.
      log_error "PRESTO_DIR ($PRESTO_DIR) exists and is non-empty, but is not a git repository."
      ui_error "PRESTO_DIR:\n  ${PRESTO_DIR}\n\nexists and contains files, but isn't a git checkout of presto.\nRefusing to touch it automatically — presto will never delete an\nexisting directory that might hold your data (volumes/, .env, etc).\n\nTo fix this, either:\n  • cd into an EMPTY directory and re-run presto_launch.sh, or\n  • turn this into a git repo yourself:\n      cd \"${PRESTO_DIR}\"\n      git init\n      git remote add origin ${PRESTO_REPO}\n      git fetch origin main\n      git reset --hard origin/main   # ⚠ only if no local edits matter"
      exit 1
    fi

    log_info "Cloning presto..."
    [[ "$PWD" == "$PRESTO_DIR"* ]] && cd "$USER_HOME"
    # Only reached when PRESTO_DIR is absent or empty — rmdir is a safety
    # net here too, since it refuses to remove a non-empty directory.
    [[ -d "$PRESTO_DIR" ]] && { rmdir "$PRESTO_DIR" 2>/dev/null || true; }
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
    apply_puid_pgid "$PRESTO_DIR/.env"
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
    if (( stash_created )); then
      local restore_out
      if ! restore_out=$(git stash pop 2>&1); then
        log_error "git pull failed AND restoring your stashed local changes also hit a conflict"
        ui_error "The pull itself failed, and re-applying your local changes afterward\nalso conflicted:\n\n$(printf '%s' "$restore_out" | tail -15)\n\nYour local edits are still safe in the stash (not lost), but the\nworking tree needs manual attention before anything else will work:\n\n  cd \"${PRESTO_DIR}\"\n  git status\n  git stash list\n\nResolve the conflict shown, or run 'git reset --hard HEAD' to discard\nthe partial pop and then 'git stash pop' again once clean."
      fi
    fi
    return 1
  }

  if (( stash_created )); then
    local pop_out
    if ! pop_out=$(git stash pop 2>&1); then
      log_error "git stash pop conflicted — update NOT marked complete"
      ui_error "The pull from GitHub succeeded, but re-applying your local changes\nafterward hit a conflict:\n\n$(printf '%s' "$pop_out" | tail -15)\n\nPresto has deliberately NOT marked this update as complete — your\nrepo is now sitting mid-conflict and needs manual resolution before\nanything else (including future updates) will work cleanly:\n\n  cd \"${PRESTO_DIR}\"\n  git status\n\nFor each file listed as unmerged, either:\n  git checkout --ours  -- <file>   # keep YOUR local version\n  git checkout --theirs -- <file>  # keep the pulled/upstream version\nthen:\n  git add <file>\n  git commit\n\nOr, to discard ALL of your local changes and just match GitHub exactly:\n  git reset --hard origin/main\n\nRe-run 'Check for Presto updates' once 'git status' shows a clean tree."
      return 1
    fi
  fi

  # NOTE: deployed services/<svc>/*.env.example is intentionally NOT refreshed
  # here. .templates/ is already current (git pull just updated it directly —
  # it's a tracked path). Pushing that into an already-deployed service is a
  # user decision, made explicitly via Build/Manage Stack → Rebuild →
  # 'service' or 'env' mode, which already does this (plus service.yml) with
  # the user's consent. Doing it silently here duplicated that logic and was
  # the one place the update flow wrote into services/ outside the menu.

  find "$SCRIPTS_DIR" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

  export PRESTO_UPDATE_AVAILABLE=0
  rm -f "$PRESTO_DIR/.update_notified"

  log_info "Updated to $(git rev-parse --short HEAD)"
  ui_notify "Update Complete ✓" \
    "Presto is up to date.\n\nTemplate changes (service.yml, .env.example, configs) are now in\n.templates/ but NOT yet applied to your deployed services.\n\nRun 'Build / Manage Stack → Rebuild' and pick 'service' or 'env'\nmode per app to pull them in, or 'none' to leave a service untouched."
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
    "🔌  Update Docker Compose plugin (apt)" \
    "🎚   Set swappiness to 0  (favour RAM over swap)" \
    "🎨  Change theme" \
    "← Back" \
  ) || return 0

  case "$choice" in
    *"Presto updates"*)   _check_for_updates_manual ;;
    *"snapshot"*)          _resource_snapshot ;;
    *"OS updates"*)        _check_apt_updates ;;
    *"Compose plugin"*)    _docker_engine_update ;;
    *"swappiness"*)        _set_swappiness ;;
    *"theme"*)             ui_theme_menu ;;
  esac
}

# Lower vm.swappiness = kernel favours keeping things in RAM and only
# swaps as a last resort, vs the Debian default of 60 which swaps fairly
# eagerly. Worth doing on a Pi regardless of which swap backend is in use
# (dphys-swapfile, rpi-swap/zram, or a plain fstab swapfile) — this is a
# kernel-level tunable underneath all of them, not tied to any one of them.
_set_swappiness() {
  if grep -q "vm.swappiness" /etc/sysctl.conf; then
    sudo sed -i "/vm.swappiness/c\\vm.swappiness=0" /etc/sysctl.conf
  else
    echo "vm.swappiness=0" | sudo tee -a /etc/sysctl.conf >/dev/null
  fi
  sudo sysctl vm.swappiness=0
  ui_notify "Done ✓" "Swappiness set to 0.\n\nThe kernel will now avoid swapping to disk unless RAM is genuinely\nfull, instead of doing it fairly eagerly (Debian's default is 60).\nHelps responsiveness and reduces disk/SD-card writes."
}

# Check apt's upgradable package list and let the user choose to apply it.
_check_apt_updates() {
  ui_confirm "Check for OS package updates? (sudo apt update)" || return 0

  # Captured directly (not via run_cmd's spinner) so we can actually inspect
  # the output. Deliberately NOT gated on apt's own exit code below — a
  # corrupted/unparseable keyring file for one repo is a soft failure apt
  # recovers from by falling back to cached index data, and still exits 0
  # overall (only a rotated/missing key is a hard, nonzero-exit failure) —
  # so the charm-repo check has to scan the output text unconditionally,
  # not just when apt_rc is nonzero.
  local apt_out apt_rc=0
  apt_out=$(sudo apt-get update -qq 2>&1) || apt_rc=$?

  # Any line that mentions the charm repo AND carries a trouble marker —
  # covers both observed failure shapes ("Missing key"/"is not signed" for
  # a rotated/absent key, "Failed to parse keyring"/EOF for a corrupted
  # file) without hardcoding either phrasing specifically, since apt's
  # exact wording varies by version and by which of the two problems it is.
  local charm_trouble
  charm_trouble=$(printf '%s\n' "$apt_out" \
    | grep -i "charm\.sh" \
    | grep -iE "err:|warning:|sqv returned|failed to (parse|fetch)|not signed|missing key|no_pubkey|expkeysig" \
    || true)

  if [[ -n "$charm_trouble" ]]; then
    log_warn "Charm (gum) apt repo signature check failed: $charm_trouble"
    if ui_confirm "The Charm (gum) apt repo's key can't be verified right now\n(rotated, missing, or the local keyring file is corrupted) —\nthis only affects future 'gum' updates via apt, nothing else on\nyour system is broken.\n\nRefresh the key now?"; then
      if _refresh_charm_gpg_key; then
        log_info "Charm apt key refreshed — retrying apt update"
        apt_rc=0
        apt_out=$(sudo apt-get update -qq 2>&1) || apt_rc=$?
        charm_trouble=$(printf '%s\n' "$apt_out" \
          | grep -i "charm\.sh" \
          | grep -iE "err:|warning:|sqv returned|failed to (parse|fetch)|not signed|missing key|no_pubkey|expkeysig" \
          || true)
        if [[ -z "$charm_trouble" ]]; then
          ui_notify "Fixed ✓" "Charm apt key refreshed — apt update now succeeds cleanly."
        else
          ui_error "Key refreshed, but the charm repo is still reporting trouble:\n\n${charm_trouble}"
        fi
      else
        ui_error "Failed to refresh the Charm apt key — check your internet connection.\n\nTo do it manually:\n  curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --yes --dearmor -o /etc/apt/keyrings/charm.gpg"
      fi
    fi
  elif (( apt_rc != 0 )); then
    ui_warn "apt update reported errors — the package list may be incomplete:\n\n$(printf '%s' "$apt_out" | tail -10)"
  fi

  local count
  count=$(apt list --upgradable 2>/dev/null | grep -vc "^Listing...") || true

  if (( count == 0 )); then
    ui_notify "Up to date ✓" "No package updates available."
    return 0
  fi

  ui_warn "${count} package(s) can be upgraded."
  ui_confirm "Apply updates now? (sudo apt-get dist-upgrade -y)" || return 0
  # dist-upgrade rather than plain upgrade: upgrade refuses to touch a
  # package if the new version needs a dependency added OR removed, silently
  # "keeping it back" — dist-upgrade actually resolves those, which is what
  # people usually mean by "some packages don't update unless I use X".
  # This is a genuinely different apt vs apt-get pitfall than the
  # script-stability one — dist-upgrade (apt-get) and full-upgrade (apt)
  # are equivalent in capability, so staying on apt-get here keeps the
  # stable-for-scripts interface without leaving anything held back.
  run_cmd "Upgrading packages..." sudo apt-get dist-upgrade -y
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

# ---------------------------------------------------------------------------
# PUID/PGID helper — called once when the global .env is first created.
#
# Most container images (linuxserver.io-style: sonarr, radarr, jellyfin,
# qbittorrent, etc.) chown their internal files to PUID:PGID on start so
# bind-mounted volumes stay writable by the host user. A hardcoded default
# of 1000:1000 in the example only happens to work when the installing
# user's uid/gid is actually 1000 — on a second machine, a system with
# multiple existing users, or anyone who created their account differently,
# it silently breaks file permissions on every volume. We always use the
# REAL invoking user resolved in the sudo-aware block at the top of
# presto_launch.sh, never the root ids, even if presto itself were ever
# invoked with sudo.
# ---------------------------------------------------------------------------
apply_puid_pgid() {
  local env_file="$1"
  local puid pgid
  puid=$(id -u "$REAL_USER" 2>/dev/null) || puid=$(id -u)
  pgid=$(id -g "$REAL_USER" 2>/dev/null) || pgid=$(id -g)

  if grep -q "^PUID=" "$env_file"; then
    sed -i "s|^PUID=.*|PUID=${puid}|" "$env_file"
  else
    printf "PUID=%s\n" "$puid" >> "$env_file"
  fi

  if grep -q "^PGID=" "$env_file"; then
    sed -i "s|^PGID=.*|PGID=${pgid}|" "$env_file"
  else
    printf "PGID=%s\n" "$pgid" >> "$env_file"
  fi

  log_info "Set PUID=${puid} PGID=${pgid} in $(basename "$env_file") (matches user: ${REAL_USER})"
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