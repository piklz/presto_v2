#!/usr/bin/env bash
# =============================================================================
#  lib/docker.sh — Docker install, stack commands, presto-tools
# =============================================================================

# ---------------------------------------------------------------------------
# Install menu
# ---------------------------------------------------------------------------
docker_install_menu() {
  local choice
  choice=$(gum choose \
    --header "🐳  Docker Installation" \
    "Install Docker + Compose plugin" \
    "Add current user to docker group" \
    "← Back" \
  ) || return 0

  case "$choice" in
    *"Install Docker"*) _docker_full_install ;;
    *"docker group"*)   _docker_add_group ;;
  esac
}

_docker_full_install() {
  ui_confirm "Install Docker CE + Compose plugin? (requires sudo)" || return 0
  check_disk_space 500 || return 1

  # Detect distro
  local distro codename
  distro=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
  codename=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')

  local repo_distro
  case "$distro" in
    ubuntu)          repo_distro="ubuntu" ;;
    debian|raspbian) repo_distro="debian" ;;
    *)
      log_warn "Unknown distro '$distro' — defaulting to debian repo"
      repo_distro="debian"
      ;;
  esac

  run_cmd "Updating apt..."            sudo apt-get update -y
  run_cmd "Installing prerequisites..." sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings

  run_cmd "Adding Docker GPG key..." bash -c "
    curl -fsSL https://download.docker.com/linux/${repo_distro}/gpg \
      | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod 644 /etc/apt/keyrings/docker.gpg
  "

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${repo_distro} ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  run_cmd "Updating apt with Docker repo..." sudo apt-get update -y
  run_cmd "Installing Docker CE..." \
    sudo apt-get install -y \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin

  _docker_add_group

  log_info "Docker installed"
  ui_notify "Docker Installed ✓" \
    "Docker + Compose plugin ready.\n\nRun 'newgrp docker' or reboot before using docker without sudo."

  ui_confirm "Reboot now?" && sudo reboot now
}

_docker_add_group() {
  sudo groupadd docker 2>/dev/null || true
  sudo usermod -aG docker "$REAL_USER" && log_info "$REAL_USER added to docker group"
}

# ---------------------------------------------------------------------------
# Docker commands menu
# ---------------------------------------------------------------------------
docker_commands_menu() {
  local choice
  choice=$(gum choose \
    --header "🐳  Docker Commands" \
    "▶  Start stack" \
    "⏹  Stop stack" \
    "🔄  Restart stack" \
    "🗑  Prune unused volumes  (safe)" \
    "🗑  Prune unused images   (frees space)" \
    "← Back" \
  ) || return 0

  case "$choice" in
    *"Start"*)   _run_script "start.sh"        "Stack started" ;;
    *"Stop"*)    _run_script "stop.sh"         "Stack stopped" ;;
    *"Restart"*) _run_script "restart.sh"      "Stack restarted" ;;
    *"volumes"*) _run_script "prune-volumes.sh" "Volume prune complete" ;;
    *"images"*)  _run_script "prune-images.sh"  "Image prune complete" ;;
  esac
}

# Run a script from $SCRIPTS_DIR via bash (never source)
_run_script() {
  local script="$1" ok_msg="$2"
  local path="$SCRIPTS_DIR/$script"

  if [[ ! -f "$path" ]]; then
    ui_error "Script not found: $path\n\nRun '⬆️  Update Presto' to sync scripts."
    return 1
  fi

  run_cmd "Running ${script}..." bash "$path" || {
    log_error "$script failed"
    ui_error "$script failed.\nCheck: journalctl -t ${JOURNAL_TAG}"
    return 1
  }
  ui_notify "Done ✓" "$ok_msg"
}

# ---------------------------------------------------------------------------
# Docker image update (pulls latest images for running stack)
# ---------------------------------------------------------------------------
docker_compose_update() {
  check_disk_space 500 || return 1
  _run_script "update_compose.sh" "Docker images updated"
}

# ---------------------------------------------------------------------------
# Presto-tools — download, review, run (no blind curl | bash)
# ---------------------------------------------------------------------------
presto_tools_install() {
  ui_header "Install Presto-Tools"

  local url="https://raw.githubusercontent.com/piklz/presto-tools/main/scripts/presto-tools_install.sh"
  local tmp; tmp=$(mktemp /tmp/presto-tools-XXXXXX.sh)

  run_cmd "Downloading presto-tools installer..." curl -fsSL -o "$tmp" "$url" || {
    log_error "Download failed"
    ui_error "Could not reach GitHub. Check your internet connection."
    rm -f "$tmp"
    return 1
  }

  if ui_confirm "Review installer script before running?"; then
    gum pager < "$tmp"
  fi

  ui_confirm "Run presto-tools installer?" || { rm -f "$tmp"; return 0; }

  bash "$tmp" || {
    log_error "presto-tools installer failed"
    ui_error "Installation failed. See output above."
    rm -f "$tmp"
    return 1
  }

  rm -f "$tmp"
  log_info "presto-tools installed"
  ui_notify "Presto-Tools Installed ✓" \
    "Run: source ~/.bashrc\nor reboot to activate aliases and welcome screen."
}
