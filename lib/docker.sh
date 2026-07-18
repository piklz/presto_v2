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

  # Detect distro. VERSION_CODENAME on a derivative distro (e.g. Linux Mint,
  # Pop!_OS) is that distro's OWN codename ("vera", "jammy-derived", etc.),
  # not a real Debian/Ubuntu apt suite — using it verbatim gives Docker's
  # repo a 404. Ubuntu-based derivatives publish the real underlying suite
  # in UBUNTU_CODENAME, so prefer that whenever ID_LIKE says "ubuntu".
  local distro id_like codename ubuntu_codename
  distro=$(grep "^ID="            /etc/os-release | cut -d= -f2 | tr -d '"')
  id_like=$(grep "^ID_LIKE="      /etc/os-release | cut -d= -f2 | tr -d '"')
  codename=$(grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
  ubuntu_codename=$(grep "^UBUNTU_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')

  local repo_distro repo_codename
  case "$distro" in
    ubuntu)
      repo_distro="ubuntu"; repo_codename="$codename"
      ;;
    debian|raspbian)
      repo_distro="debian"; repo_codename="$codename"
      ;;
    *)
      if [[ "$id_like" == *ubuntu* ]]; then
        repo_distro="ubuntu"
        repo_codename="${ubuntu_codename:-$codename}"
        log_warn "Distro '$distro' is Ubuntu-based — using ubuntu/${repo_codename} Docker repo"
      elif [[ "$id_like" == *debian* ]]; then
        repo_distro="debian"
        repo_codename="$codename"
        log_warn "Distro '$distro' is Debian-based — using debian/${repo_codename} Docker repo"
      else
        repo_distro="debian"
        repo_codename="$codename"
        log_warn "Unknown distro '$distro' — defaulting to debian/${repo_codename} repo (may fail)"
      fi
      ;;
  esac

  if [[ -z "$repo_codename" ]]; then
    log_error "Could not determine an apt codename (VERSION_CODENAME/UBUNTU_CODENAME missing)"
    ui_error "Could not determine your distro's codename from /etc/os-release.\n\nDocker's apt repo needs this to know which package set to use.\nCheck /etc/os-release manually and, if needed, open an issue."
    return 1
  fi

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
https://download.docker.com/linux/${repo_distro} ${repo_codename} stable" \
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
# Verify docker is installed AND actually reachable before any stack/docker
# operation. Without this, a user who was just added to the docker group but
# hasn't run `newgrp docker` / re-logged in gets a bare "permission denied"
# or "cannot connect to the Docker daemon" buried inside a docker compose
# call, with no indication of what to actually do about it.
# ---------------------------------------------------------------------------
docker_check() {
  command -v docker &>/dev/null || {
    ui_error "Docker is not installed.\n\nUse '🔧  Install Docker + Compose' from the main menu first."
    return 1
  }

  docker info &>/dev/null && return 0

  if ! groups "$REAL_USER" 2>/dev/null | grep -qw docker; then
    ui_error "User '${REAL_USER}' is not in the 'docker' group yet.\n\nRun '🔧  Install Docker + Compose' → 'Add current user to docker group',\nthen either run:\n  newgrp docker\nor log out and back in (reboot on Raspberry Pi OS) before trying again."
  else
    ui_error "Docker is installed and '${REAL_USER}' is in the docker group,\nbut the Docker daemon isn't reachable right now.\n\nIs the service running?\n  sudo systemctl status docker\n\nIf you were just added to the docker group, this session still needs:\n  newgrp docker\n(or a full log out / log in) before group membership takes effect."
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Docker commands menu
# ---------------------------------------------------------------------------
docker_commands_menu() {
  docker_check || return 0
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
# Docker image update (pulls latest images, rebuilds if needed, restarts)
# ---------------------------------------------------------------------------
docker_compose_update() {
  docker_check || return 0
  check_disk_space 500 || return 1
  _run_script "update.sh" "Docker images updated"
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