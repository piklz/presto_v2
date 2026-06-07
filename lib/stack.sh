#!/usr/bin/env bash
# =============================================================================
#  lib/stack.sh — Service discovery + docker-compose.yml builder
#
#  Services are discovered from .templates/<name>/meta.sh
#  Each meta.sh must export:
#    SERVICE_DESC="Human readable description"
#    SERVICE_ICON="🎬"
#    SERVICE_ARCH="all"   # all | arm64 | amd64 | armv7 (space-separated)
#    SERVICE_TAGS="media" # optional, space-separated
# =============================================================================

# COMPOSE_FILE resolves from presto.conf via PRESTO_COMPOSE_FILE (exported by presto_launch.sh)
readonly COMPOSE_FILE="${PRESTO_COMPOSE_FILE:-$PRESTO_DIR/docker-compose.yml}"
readonly SELECTION_FILE="$SERVICES_DIR/selection.txt"

# ---------------------------------------------------------------------------
# Discover services from .templates/*/meta.sh filtered by current arch
# ---------------------------------------------------------------------------
_discover_services() {
  local current_arch; current_arch=$(sys_arch)
  local svc_name svc_dir

  while IFS= read -r -d '' meta; do
    svc_dir=$(dirname "$meta")
    svc_name=$(basename "$svc_dir")

    [[ -f "$svc_dir/service.yml" ]] || continue

    local SERVICE_ARCH="all"
    # shellcheck source=/dev/null
    source "$meta" 2>/dev/null || continue

    if [[ "$SERVICE_ARCH" != "all" ]]; then
      local ok=0
      for a in $SERVICE_ARCH; do
        [[ "$a" == "$current_arch" ]] && ok=1 && break
      done
      (( ok )) || continue
    fi

    echo "$svc_name"
  done < <(find "$TEMPLATES_DIR" -name "meta.sh" -print0 2>/dev/null | sort -z)
}

# Read one field from a service's meta.sh
_meta() {
  local svc="$1" field="$2"
  local meta="$TEMPLATES_DIR/$svc/meta.sh"
  [[ -f "$meta" ]] || { echo ""; return; }
  local SERVICE_DESC="" SERVICE_ICON="📦" SERVICE_TAGS="" SERVICE_ARCH="all"
  # shellcheck source=/dev/null
  source "$meta" 2>/dev/null || true
  case "$field" in
    desc) echo "$SERVICE_DESC" ;;
    icon) echo "$SERVICE_ICON" ;;
    tags) echo "$SERVICE_TAGS" ;;
  esac
}

# ---------------------------------------------------------------------------
# Stack menu
# ---------------------------------------------------------------------------
stack_menu() {
  local choice
  choice=$(gum choose \
    --header "📦  Stack Management" \
    "Build / Rebuild Stack" \
    "View current selection" \
    "View generated compose file" \
    "← Back" \
  ) || return 0

  case "$choice" in
    *"Build"*)      _build_stack ;;
    *"selection"*)  _view_file "$SELECTION_FILE" "No selection yet — run Build first." ;;
    *"compose"*)    _view_file "$COMPOSE_FILE"    "No compose file yet — run Build first." ;;
  esac
}

_view_file() {
  local file="$1" empty_msg="$2"
  if [[ -f "$file" ]]; then
    gum pager < "$file"
  else
    ui_notify "Not found" "$empty_msg"
  fi
}

# ---------------------------------------------------------------------------
# Build stack — service picker → compose generator
# ---------------------------------------------------------------------------
_build_stack() {
  check_disk_space 200 || return 1
  ui_header "Build Docker Stack"

  [[ -d "$TEMPLATES_DIR" ]] || {
    ui_error "Templates directory not found: $TEMPLATES_DIR\n\nRun '⬆️  Update Presto' to sync templates."
    return 1
  }

  local -a services
  mapfile -t services < <(_discover_services)

  if (( ${#services[@]} == 0 )); then
    ui_error "No services found in $TEMPLATES_DIR\n\nEnsure each template folder has meta.sh + service.yml"
    return 1
  fi

  # Build display list: "ICON  name  —  desc"
  local -a items=()
  for svc in "${services[@]}"; do
    local icon desc
    icon=$(_meta "$svc" icon)
    desc=$(_meta "$svc" desc)
    items+=("${icon}  ${svc}  —  ${desc}")
  done

  # Pre-select previously chosen services
  local -a sel_flags=()
  if [[ -f "$SELECTION_FILE" ]]; then
    while IFS= read -r prev; do
      for item in "${items[@]}"; do
        [[ "$item" == *"  ${prev}  "*  ]] && sel_flags+=("--selected=${item}") && break
      done
    done < "$SELECTION_FILE"
  fi

  gum style --bold --foreground 212 \
    "↑↓ navigate   /  fuzzy search   space  toggle   enter  confirm"

  local raw
  # shellcheck disable=SC2068
  raw=$(printf '%s\n' "${items[@]}" \
    | gum choose \
        --no-limit \
        --height=20 \
        --header="Select services for your stack:" \
        ${sel_flags[@]+"${sel_flags[@]}"} \
  ) || { log_info "Cancelled"; return 0; }

  local -a chosen=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    chosen+=("$(echo "$line" | awk '{print $2}')")
  done <<< "$raw"

  (( ${#chosen[@]} == 0 )) && { ui_warn "Nothing selected — cancelled."; return 0; }

  gum style --bold "Selected ${#chosen[@]} service(s):"
  printf '  • %s\n' "${chosen[@]}"
  echo ""
  ui_confirm "Build compose stack with these services?" || return 0

  _generate_compose "${chosen[@]}"
}

# ---------------------------------------------------------------------------
# Write docker-compose.yml
# ---------------------------------------------------------------------------
_generate_compose() {
  local -a services=("$@")
  mkdir -p "$SERVICES_DIR"

  cat > "$COMPOSE_FILE" <<HEADER
# Generated by Presto — do not edit manually.
# Re-run presto_launch.sh > Build Stack to regenerate.
# Edit per-service config in services/<name>/<name>.env
#
# Network : ${PRESTO_NETWORK_NAME}
# Subnet  : ${PRESTO_SUBNET}

networks:
  presto_net:
    name: "${PRESTO_NETWORK_NAME}"
    driver: bridge
    ipam:
      config:
        - subnet: ${PRESTO_SUBNET}

services:
HEADER

  rm -f "$SELECTION_FILE"
  touch "$SELECTION_FILE"

  local -a env_files=()

  for svc in "${services[@]}"; do
    if _deploy_service "$svc"; then
      echo "$svc" >> "$SELECTION_FILE"
      local yml="$SERVICES_DIR/$svc/service.yml"
      if [[ -f "$yml" ]]; then
        { echo ""; cat "$yml"; } >> "$COMPOSE_FILE"
        log_info "[$svc] appended to compose"
      else
        log_warn "[$svc] service.yml missing — skipped from compose"
      fi
      local envf="$SERVICES_DIR/$svc/${svc}.env"
      [[ -f "$envf" ]] && env_files+=("$envf")
    fi
  done

  local env_list=""
  for f in "${env_files[@]}"; do env_list+="  • $f\n"; done

  ui_notify "Stack Built ✓" \
    "${#services[@]} service(s) added to docker-compose.yml.\
$(  [[ -n "$env_list" ]] && printf '\n\nEdit .env files before starting:\n%s' "$env_list")\

Then run:
  docker compose up -d
  (or 'presto_up' if presto-tools is installed)"
}

# ---------------------------------------------------------------------------
# Deploy a single service (rsync template → services/)
# ---------------------------------------------------------------------------
_deploy_service() {
  local svc="$1"
  local tmpl="$TEMPLATES_DIR/$svc"
  local dest="$SERVICES_DIR/$svc"

  [[ -d "$tmpl" ]] || { log_error "Template missing: $tmpl"; return 1; }

  local mode="full"
  [[ -d "$dest" ]] && mode=$(ui_pick_overwrite_mode "$svc")

  case "$mode" in
    full)
      log_info "[$svc] full sync"
      rsync -a --exclude 'build.sh' --exclude 'meta.sh' "$tmpl/" "$dest/" || return 1
      ;;
    env)
      log_info "[$svc] sync, preserving .env + .conf"
      rsync -a --exclude 'build.sh' --exclude 'meta.sh' \
            --exclude '*.env' --exclude '*.conf' \
            "$tmpl/" "$dest/" || return 1
      ;;
    none)
      log_info "[$svc] keeping existing files"
      ;;
    *)
      log_warn "[$svc] unknown mode '$mode' — skipping"
      return 0
      ;;
  esac

  # First deploy: copy .env.example → .env (never overwrite)
  local example="$dest/${svc}.env.example"
  local envf="$dest/${svc}.env"
  if [[ -f "$example" && ! -f "$envf" ]]; then
    cp "$example" "$envf"
    log_info "[$svc] created ${svc}.env from example — edit before starting"
  fi

  [[ -f "$envf" ]] && apply_timezone "$envf"
  return 0
}
