#!/usr/bin/env bash
# =============================================================================
#  lib/stack.sh — Service discovery + docker-compose.yml builder
#
#  Template contract — each .templates/<name>/ folder must contain:
#
#    meta.sh      Metadata sourced by presto (never deployed to services/)
#    service.yml  A 2-space-indented YAML *fragment* — NOT a standalone
#                 compose file.  It must slot directly under the generated
#                 `services:` key with no top-level keys of its own.
#                 Paths inside (env_file, volumes) must be relative to
#                 $PRESTO_DIR, which is where docker-compose.yml lives and
#                 where `docker compose` is always invoked from.
#
#  meta.sh fields:
#    SERVICE_DESC="Human readable description"
#    SERVICE_ICON="🎬"
#    SERVICE_ARCH="all"       # all | arm64 | amd64 | armv7 (space-separated)
#    SERVICE_TAGS="media"     # optional, space-separated
#    SERVICE_DEPS=""          # optional — space-separated service names that
#                             # must be included alongside this one.
#                             # Presto auto-adds them and tells the user.
#                             # Use for hard runtime deps (e.g. a database
#                             # this service's depends_on block references).
#
#  env_file path note (Compose v2 behaviour):
#    env_file paths in service.yml resolve relative to docker-compose.yml's
#    directory ($PRESTO_DIR), not the shell's CWD.  Use:
#      ./services/<name>/<name>.env   ← correct
#    Never use absolute paths in templates — they break portability.
# =============================================================================

# COMPOSE_FILE resolves from presto.conf via PRESTO_COMPOSE_FILE
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

# Read one field from a service's meta.sh (safe: local vars shadow globals)
_meta() {
  local svc="$1" field="$2"
  local meta="$TEMPLATES_DIR/$svc/meta.sh"
  [[ -f "$meta" ]] || { echo ""; return; }
  local SERVICE_DESC="" SERVICE_ICON="📦" SERVICE_TAGS="" SERVICE_ARCH="all" SERVICE_DEPS=""
  # shellcheck source=/dev/null
  source "$meta" 2>/dev/null || true
  case "$field" in
    desc) echo "$SERVICE_DESC" ;;
    icon) echo "$SERVICE_ICON" ;;
    tags) echo "$SERVICE_TAGS" ;;
    deps) echo "$SERVICE_DEPS" ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency resolution
# Reads SERVICE_DEPS from each selected service's meta.sh and auto-adds any
# missing dependencies.  Iterates until stable (handles transitive deps).
# Outputs the final de-duped ordered list, one name per line.
# ---------------------------------------------------------------------------
_resolve_deps() {
  local -a resolved=("$@")
  local changed=1

  while (( changed )); do
    changed=0
    local -a additions=()

    for svc in "${resolved[@]}"; do
      local SERVICE_DEPS=""
      local meta="$TEMPLATES_DIR/$svc/meta.sh"
      [[ -f "$meta" ]] || continue
      # shellcheck source=/dev/null
      source "$meta" 2>/dev/null || continue
      [[ -z "$SERVICE_DEPS" ]] && continue

      for dep in $SERVICE_DEPS; do
        # Skip if already in the resolved list
        local found=0
        for existing in "${resolved[@]}"; do
          [[ "$existing" == "$dep" ]] && found=1 && break
        done
        (( found )) && continue

        if [[ -d "$TEMPLATES_DIR/$dep" ]]; then
          additions+=("$dep")
          changed=1
          log_info "[$svc] requires '$dep' — auto-adding"
        else
          log_warn "[$svc] declared dep '$dep' not found in templates — skipping"
        fi
      done
    done

    # De-dup additions before appending (two services could both require the same dep)
    for add in "${additions[@]+"${additions[@]}"}"; do
      local dup=0
      for existing in "${resolved[@]}"; do
        [[ "$existing" == "$add" ]] && dup=1 && break
      done
      (( dup )) || resolved+=("$add")
    done
  done

  printf '%s\n' "${resolved[@]}"
}

# ---------------------------------------------------------------------------
# Port conflict pre-flight
# Parses host ports from each selected service's TEMPLATE service.yml and
# checks them against currently listening ports.  Handles ranges (61208-61209).
# Warns and asks to continue rather than hard-blocking, since the user may
# intend to replace a conflicting process.
# ---------------------------------------------------------------------------
_extract_host_ports() {
  local yml="$1"
  # Match short-form port entries: - "HOST:CONTAINER" or - HOST:CONTAINER
  # Captures only the host side (left of the colon) which may be a range.
  grep -E '^\s+-\s+"?[0-9]' "$yml" \
    | grep -oE '"?[0-9]+(-[0-9]+)?:' \
    | tr -d '":'
}

_port_in_use() {
  # ss column 5 is local address:port; grep for exact port boundary
  ss -tulpn 2>/dev/null | awk 'NR>1{print $5}' | grep -qE '(^|:)'"$1"'$'
}

_check_port_conflicts() {
  local -a services=("$@")
  local -a conflicts=()

  for svc in "${services[@]}"; do
    local yml="$TEMPLATES_DIR/$svc/service.yml"
    [[ -f "$yml" ]] || continue

    local host_port
    while IFS= read -r host_port; do
      [[ -z "$host_port" ]] && continue

      if [[ "$host_port" == *-* ]]; then
        # Expand range
        local start="${host_port%-*}" end="${host_port#*-}"
        local p
        for (( p=start; p<=end; p++ )); do
          _port_in_use "$p" && conflicts+=("${svc}: port ${p}")
        done
      else
        _port_in_use "$host_port" && conflicts+=("${svc}: port ${host_port}")
      fi
    done < <(_extract_host_ports "$yml")
  done

  if (( ${#conflicts[@]} > 0 )); then
    ui_warn "Port conflicts — these host ports are already in use:\n\n$(printf '  • %s\n' "${conflicts[@]}")\n\nConflicting containers may fail to start."
    ui_confirm "Continue building anyway?" || return 1
  fi

  return 0
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
# Build stack — service picker → pre-flight → compose generator
# ---------------------------------------------------------------------------
_build_stack() {
  check_disk_space 200 || return 1
  ui_header "Build Docker Stack"

  # Warn if global .env hasn't been edited yet
  local env_file="$PRESTO_DIR/.env"
  if [[ ! -f "$env_file" ]]; then
    ui_error "No .env file found at $PRESTO_DIR/.env\n\nRun presto_launch.sh first to auto-create it, then edit it."
    return 1
  fi
  if grep -qE "192\.168\.1\.x|your-hostname|your-remote-hostname" "$env_file"; then
    ui_warn "Your .env file still has placeholder values.\nEdit it before starting your stack:\n\n  nano $env_file\n\nSet: SYSTEM_HOSTNAME, HOST_IP, REMOTE_HOSTNAME, REMOTE_IP"
    ui_confirm "Continue building stack anyway?" || return 0
  fi

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
      [[ -z "$prev" ]] && continue
      for item in "${items[@]}"; do
        [[ "$item" == *"  ${prev}  "* ]] && sel_flags+=("--selected=${item}") && break
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
    # Field 2 is the service name: "ICON  name  —  desc"
    chosen+=("$(echo "$line" | awk '{print $2}')")
  done <<< "$raw"

  (( ${#chosen[@]} == 0 )) && { ui_warn "Nothing selected — cancelled."; return 0; }

  # ── Dependency resolution ──────────────────────────────────────────────────
  local -a resolved
  mapfile -t resolved < <(_resolve_deps "${chosen[@]}")

  if (( ${#resolved[@]} > ${#chosen[@]} )); then
    local -a auto_added=()
    for svc in "${resolved[@]}"; do
      local found=0
      for c in "${chosen[@]}"; do [[ "$c" == "$svc" ]] && found=1 && break; done
      (( found )) || auto_added+=("$svc")
    done
    ui_warn "Auto-added required dependencies:\n$(printf '  • %s\n' "${auto_added[@]}")"
  fi
  chosen=("${resolved[@]}")

  # ── Port conflict pre-flight ───────────────────────────────────────────────
  _check_port_conflicts "${chosen[@]}" || return 0

  # ── Confirm and build ──────────────────────────────────────────────────────
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

  # Write header + network block
  cat > "$COMPOSE_FILE" <<HEADER
# Generated by Presto — do not edit manually.
# Re-run: presto_launch.sh > Build / Manage Stack > Build / Rebuild Stack
# Per-service config: services/<name>/<name>.env
#
# env_file paths resolve relative to this file's directory (Compose v2).
# Always run 'docker compose' from: ${PRESTO_DIR}
#
# Network : ${PRESTO_NETWORK_NAME}
# Subnet  : ${PRESTO_SUBNET}

networks:
  private_network:
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
  local -a failed=()

  for svc in "${services[@]}"; do
    if _deploy_service "$svc"; then
      echo "$svc" >> "$SELECTION_FILE"
      local yml="$SERVICES_DIR/$svc/service.yml"
      if [[ -f "$yml" ]]; then
        printf '\n' >> "$COMPOSE_FILE"
        cat "$yml" >> "$COMPOSE_FILE"
        log_info "[$svc] appended to compose"
      else
        log_warn "[$svc] service.yml missing after deploy — skipped"
        failed+=("$svc (no service.yml)")
      fi
      local envf="$SERVICES_DIR/$svc/${svc}.env"
      [[ -f "$envf" ]] && env_files+=("$envf")
    else
      failed+=("$svc (deploy failed)")
    fi
  done

  # ── Validate the generated file ────────────────────────────────────────────
  # docker compose config parses the full file; catches YAML syntax errors,
  # missing env_file references, and invalid keys before anything tries to run.
  if command -v docker &>/dev/null; then
    local validate_err; validate_err=$(mktemp)
    if ! docker compose -f "$COMPOSE_FILE" config --quiet 2>"$validate_err"; then
      local err_msg; err_msg=$(cat "$validate_err")
      rm -f "$validate_err"
      ui_error "Generated compose file failed validation:\n\n${err_msg}\n\nFix the template(s) above and rebuild.\nThe broken file is at: ${COMPOSE_FILE}"
      return 1
    fi
    rm -f "$validate_err"
    log_info "Compose file validated OK"
  fi

  # ── Summary ────────────────────────────────────────────────────────────────
  local env_list=""
  for f in "${env_files[@]}"; do env_list+="  • $f\n"; done

  local fail_note=""
  if (( ${#failed[@]} > 0 )); then
    fail_note="\n\n⚠  Failed services (check logs):\n$(printf '  • %s\n' "${failed[@]}")"
  fi

  ui_notify "Stack Built ✓" \
    "${#services[@]} service(s) processed.${fail_note}\
$(  [[ -n "$env_list" ]] && printf '\n\nEdit .env files before starting:\n%s' "$env_list")\

Then run:
  docker compose up -d
  (or 'presto_up' if presto-tools is installed)"
}

# ---------------------------------------------------------------------------
# Deploy a single service: rsync template → services/
# meta.sh and build.sh are never deployed (presto internals only).
# SERVICE_CONFIGS files are seeded to volumes/<svc>/ — never to services/.
# ---------------------------------------------------------------------------
_deploy_service() {
  local svc="$1"
  local tmpl="$TEMPLATES_DIR/$svc"
  local dest="$SERVICES_DIR/$svc"

  [[ -d "$tmpl" ]] || { log_error "[$svc] template missing: $tmpl"; return 1; }

  # Read SERVICE_CONFIGS before rsync so we can exclude those files.
  # They belong in volumes/<svc>/, not services/<svc>/ — seeded separately below.
  local SERVICE_CONFIGS=""
  local SERVICE_DESC="" SERVICE_ICON="" SERVICE_ARCH="" SERVICE_TAGS="" SERVICE_DEPS=""
  # shellcheck source=/dev/null
  source "$tmpl/meta.sh" 2>/dev/null || true

  # Always exclude: presto internals + volume-bound config files
  local -a excludes=(--exclude 'meta.sh' --exclude 'build.sh')
  for _cfg in $SERVICE_CONFIGS; do
    excludes+=(--exclude "$_cfg")
  done

  local mode="full"
  [[ -d "$dest" ]] && mode=$(ui_pick_overwrite_mode "$svc")

  case "$mode" in
    full)
      log_info "[$svc] full sync from template"
      rsync -a "${excludes[@]}" "$tmpl/" "$dest/" || return 1
      ;;
    service)
      # Most common update: upstream changed image tag, ports, or healthcheck.
      # Touches only service.yml — leaves .env and volume configs completely alone.
      log_info "[$svc] updating service.yml only"
      cp "$tmpl/service.yml" "$dest/service.yml" || return 1
      ;;
    env)
      # Refresh service.yml; leave .env and named config files untouched.
      log_info "[$svc] sync template, preserving .env"
      rsync -a "${excludes[@]}" --exclude '*.env' "$tmpl/" "$dest/" || return 1
      ;;
    none)
      log_info "[$svc] keeping existing files as-is"
      ;;
    *)
      log_warn "[$svc] unknown mode '$mode' — skipping deploy"
      return 0
      ;;
  esac

  # Seed .env from .env.example on first deploy (never overwrite user edits)
  local example="$dest/${svc}.env.example"
  local envf="$dest/${svc}.env"
  if [[ -f "$example" && ! -f "$envf" ]]; then
    cp "$example" "$envf"
    log_info "[$svc] created ${svc}.env from example — edit before starting"
  fi

  [[ -f "$envf" ]] && apply_timezone "$envf"

  # Seed SERVICE_CONFIGS to volumes/<svc>/ — first deploy only, never overwrite.
  # These are extra runtime configs (Caddyfile, glances.conf, etc.) that the
  # container mounts from volumes/ at runtime.  The user edits them there.
  _seed_volume_configs "$svc" "$SERVICE_CONFIGS"

  return 0
}

# ---------------------------------------------------------------------------
# Seed volume-bound config entries from the template into volumes/<svc>/.
# Handles both flat files (glances.conf, Caddyfile) and subdirectories
# (homepage's config/ folder).
#
# Flat file  → copied only if the destination file does not yet exist.
# Directory  → rsync --ignore-existing merges template files into the
#              destination dir, skipping any that are already present and
#              leaving all user-added files (custom.css, proxmox.yaml, logs/)
#              completely untouched.  No deletions, ever.
#
# Called on every _deploy_service run regardless of mode, so a new config
# file added to a template later is seeded automatically on next rebuild.
# ---------------------------------------------------------------------------
_seed_volume_configs() {
  local svc="$1" configs="$2"
  [[ -z "$configs" ]] && return 0

  local tmpl="$TEMPLATES_DIR/$svc"
  local vol_dir="${PRESTO_VOLUMES_DIR}/${svc}"
  local -a seeded=() skipped=()

  for cfg in $configs; do
    local src="$tmpl/$cfg"
    local dst="$vol_dir/$cfg"

    if [[ ! -e "$src" ]]; then
      log_warn "[$svc] SERVICE_CONFIGS: '$cfg' not found in template — skipping"
      continue
    fi

    mkdir -p "$vol_dir"

    if [[ -d "$src" ]]; then
      # ── Directory (e.g. homepage's config/) ──────────────────────────────
      # rsync --ignore-existing seeds template files that are absent in dst,
      # skips files already there, and never deletes user-added files.
      # Trailing slash on src = "contents of", preventing config/config/ nesting.
      mkdir -p "$dst"
      if rsync -a --ignore-existing "$src/" "$dst/" 2>/dev/null; then
        seeded+=("$cfg/")
        log_info "[$svc] seeded config dir → volumes/$svc/$cfg/ (existing files kept)"
      else
        log_warn "[$svc] rsync failed seeding $cfg/ — check permissions on volumes/$svc/"
      fi
    else
      # ── Flat file (e.g. glances.conf, Caddyfile) ─────────────────────────
      if [[ ! -f "$dst" ]]; then
        cp "$src" "$dst"
        seeded+=("$cfg")
        log_info "[$svc] seeded $cfg → volumes/$svc/$cfg"
      else
        skipped+=("$cfg")
        log_debug "[$svc] $cfg already exists in volumes/$svc/ — not overwriting"
      fi
    fi
  done

  (( ${#seeded[@]}  > 0 )) && log_info  "[$svc] volume configs seeded : ${seeded[*]}"
  (( ${#skipped[@]} > 0 )) && log_debug "[$svc] volume configs kept   : ${skipped[*]}"
  return 0
}
