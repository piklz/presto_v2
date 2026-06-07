#!/usr/bin/env bash
# =============================================================================
#  lib/ui.sh — gum UI helpers + auto-install
# =============================================================================

# ---------------------------------------------------------------------------
# Install gum if missing (runs once, silently thereafter)
# ---------------------------------------------------------------------------
ui_check_gum() {
  command -v gum &>/dev/null && return 0

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  presto needs 'gum' for its UI (one-time install)"
  echo "  https://github.com/charmbracelet/gum"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -r -p "  Install gum now? [Y/n]: " _ans
  [[ "${_ans,,}" == "n" ]] && { echo "gum is required. Exiting."; exit 1; }

  if grep -qiE "debian|ubuntu|raspbian" /etc/os-release 2>/dev/null; then
    log_info "Installing gum via apt (Charm repo)..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
      | sudo gpg --yes --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
      | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
    sudo apt-get update -q && sudo apt-get install -y gum
  else
    log_info "Installing gum binary..."
    local arch tmp
    arch=$(uname -m)
    tmp=$(mktemp -d)
    case "$arch" in
      aarch64|arm64) gum_arch="arm64" ;;
      armv7l)        gum_arch="armv7" ;;
      x86_64)        gum_arch="amd64" ;;
      *)  log_error "Unsupported arch: $arch"; exit 1 ;;
    esac
    curl -fsSL \
      "https://github.com/charmbracelet/gum/releases/latest/download/gum_Linux_${gum_arch}.tar.gz" \
      | tar -xz -C "$tmp"
    sudo install -m 0755 "$tmp/gum" /usr/local/bin/gum
    rm -rf "$tmp"
  fi

  command -v gum &>/dev/null || { log_error "gum install failed"; exit 1; }
  log_info "gum installed"
}

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

ui_confirm() {
  gum confirm --affirmative="Yes" --negative="No" --prompt.foreground="212" "$1"
}

ui_notify() {
  # ui_notify "Title" "body text..."
  local title="$1"; shift
  gum style \
    --border rounded --border-foreground 212 \
    --padding "0 1" --margin "1 0" \
    "$(gum style --bold --foreground 212 "$title")" "" "$*"
  gum input --placeholder "  Press Enter to continue..." --char-limit 0 >/dev/null 2>&1 || true
}

ui_error() {
  gum style \
    --border rounded --border-foreground 9 \
    --padding "0 1" --margin "1 0" \
    "$(gum style --bold --foreground 9 "✗  Error")" "" "$*"
  gum input --placeholder "  Press Enter to continue..." --char-limit 0 >/dev/null 2>&1 || true
}

ui_warn() {
  gum style \
    --border rounded --border-foreground 214 \
    --padding "0 1" --margin "1 0" \
    "$(gum style --bold --foreground 214 "⚠  Warning")" "" "$*"
}

ui_header() {
  gum style \
    --bold --foreground 212 --border-foreground 212 \
    --border double --align center --width 58 --margin "1 0" \
    "$1"
}

ui_about() {
  gum style \
    --border rounded --border-foreground 212 \
    --padding "1 3" --margin "1 2" \
    "$(gum style --bold --foreground 212 "🚀  PRESTO  v${VERSION}")" \
    "" \
    "$(gum style --foreground 245 "Author  : piklz")" \
    "$(gum style --foreground 245 "GitHub  : https://github.com/piklz/presto")" \
    "$(gum style --foreground 245 "License : GPL-3.0")" \
    "" \
    "Docker stack manager for Raspberry Pi" \
    "and Debian-based systems." \
    "" \
    "$(gum style --foreground 245 "Logs: journalctl -t presto [-f]")"
  gum input --placeholder "  Press Enter to continue..." --char-limit 0 >/dev/null 2>&1 || true
}

# Returns: none | env | full
ui_pick_overwrite_mode() {
  local name="$1"
  gum choose \
    --header "'${name}' already exists — pick mode:" \
    "none — Keep everything as-is" \
    "env  — Re-sync template, preserve .env + .conf files" \
    "full — Full fresh template (overwrites all)" \
  | awk '{print $1}'
}
