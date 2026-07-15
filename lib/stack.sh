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
  # Match short-form port mappings under a `ports:` list:
  #   - "8080:80"                (HOST:CONTAINER)
  #   - 8080:80/tcp              (with protocol suffix)
  #   - "192.168.1.5:8080:80"    (IP:HOST:CONTAINER)
  #   - "8080-8090:8080-8090"    (ranges)
  #
  # The host port is always the SECOND-TO-LAST colon-separated field — the
  # last field is always the container port, and an optional bind IP always
  # comes before the host port, never after. Splitting naively on the first
  # colon (the old approach) mis-extracts the last IP octet as the "port"
  # for any IP-bound mapping, e.g. reading "5" out of "192.168.1.5:8080:80".
  #
  # A bare "- 80" (single number, no colon at all) is container-port-only —
  # Docker assigns a random ephemeral host port for it, so it can never be a
  # real conflict and is intentionally skipped by the grep below.
  grep -E '^\s+-\s+"?[0-9.]*[0-9]+(-[0-9]+)?:[0-9]+(-[0-9]+)?' "$yml" 2>/dev/null \
    | sed -E 's/^\s+-\s+//; s/^"//; s/"$//; s#/(tcp|udp)$##' \
    | awk -F: '{ print $(NF-1) }'
}

_port_in_use() {
  # ss column 5 is local address:port; grep for exact port boundary
  ss -tulpn 2>/dev/null | awk 'NR>1{print $5}' | grep -qE "(^|:)$1$"
}

_check_port_conflicts() {
  local -a services=("$@")
  local -a conflicts=()

  # Build a lookup of container names for the selected services so we can
  # skip ports that are already held by a container we are about to replace.
  # Container name defaults to service name but may be overridden in service.yml.
  declare -A owned_containers=()
  for svc in "${services[@]}"; do
    local yml="$TEMPLATES_DIR/$svc/service.yml"
    [[ -f "$yml" ]] || continue
    # Extract explicit container_name if set, otherwise fall back to service name
    local cname
    cname=$(grep -oP "(?<=container_name:\s{0,10})\S+" "$yml" 2>/dev/null | head -1)
    owned_containers["${cname:-$svc}"]=1
  done

  for svc in "${services[@]}"; do
    local yml="$TEMPLATES_DIR/$svc/service.yml"
    [[ -f "$yml" ]] || continue

    local host_port
    while IFS= read -r host_port; do
      [[ -z "$host_port" ]] && continue

      _check_single_port() {
        local p="$1" s="$2"
        _port_in_use "$p" || return 0
        # Port is in use — find out which container holds it
        local holder
        holder=$(docker ps --format "{{.Names}} {{.Ports}}" 2>/dev/null           | awk -v pat=":${p}->" '$0 ~ pat {print $1}' | head -1)
        # If the holder is one of our selected services, it will be replaced —
        # not a real conflict, skip silently
        if [[ -n "$holder" && -v "owned_containers[$holder]" ]]; then
          log_debug "[$s] port $p held by own container ($holder) — will be replaced, skipping"
          return 0
        fi
        conflicts+=("${s}: port ${p}${holder:+ (held by: $holder)}")
      }

      if [[ "$host_port" == *-* ]]; then
        local start="${host_port%-*}" end="${host_port#*-}"
        local p
        for (( p=start; p<=end; p++ )); do _check_single_port "$p" "$svc"; done
      else
        _check_single_port "$host_port" "$svc"
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
  docker_check || return 0
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

  if ! mkdir -p "$SERVICES_DIR" 2>/dev/null || [[ ! -w "$SERVICES_DIR" ]]; then
    local owner; owner=$(stat -c '%U:%G' "$SERVICES_DIR" 2>/dev/null || stat -c '%U:%G' "$PRESTO_DIR" 2>/dev/null || echo "unknown")
    ui_error "Cannot write to:\n  ${SERVICES_DIR}\n\nCurrent owner: ${owner}\n\nThis usually means it (or ${PRESTO_DIR}) got created as root at some\npoint — most often Docker auto-creating a bind-mount host path before\nthe directory existed, or an earlier command run under sudo by mistake.\n\nFix ownership, then retry:\n  sudo chown -R \$(id -un):\$(id -gn) \"${PRESTO_DIR}\""
    return 1
  fi

  # Build into temp files first — nothing below touches the LIVE
  # docker-compose.yml or selection.txt until validation has passed.
  # This is what makes a rebuild safe to run against a stack that's
  # currently up: a broken template can never leave the live compose file
  # half-written for the next `docker compose up`/`restart` to trip over.
  #
  # NOTE: deliberately no `trap ... RETURN` here. In bash, a RETURN trap set
  # inside a function is NOT scoped to that function — it stays armed for
  # every subsequent function return anywhere else in the script for the
  # rest of the run, long after tmp_compose/tmp_selection have gone out of
  # scope, which trips `set -u` ("unbound variable") on the next unrelated
  # function return. Clean up explicitly on the one path that needs it below.
  local tmp_compose; tmp_compose=$(mktemp "${COMPOSE_FILE}.XXXXXX")
  local tmp_selection; tmp_selection=$(mktemp "${SELECTION_FILE}.XXXXXX")

  # Write header + network block
  cat > "$tmp_compose" <<HEADER
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

  local -a env_files=()
  local -a failed=()

  for svc in "${services[@]}"; do
    if _deploy_service "$svc"; then
      echo "$svc" >> "$tmp_selection"
      local yml="$SERVICES_DIR/$svc/service.yml"
      if [[ -f "$yml" ]]; then
        printf '\n' >> "$tmp_compose"
        cat "$yml" >> "$tmp_compose"
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

  # ── Validate the generated file BEFORE it goes live ────────────────────────
  # docker compose config parses the full file; catches YAML syntax errors,
  # missing env_file references, and invalid keys before anything tries to
  # run. tmp_compose sits in the same directory as COMPOSE_FILE (mktemp
  # preserves the path prefix), so any env_file: ./services/... paths inside
  # it still resolve exactly as they will once it's the real file.
  if command -v docker &>/dev/null; then
    local validate_err; validate_err=$(mktemp)
    if ! docker compose -f "$tmp_compose" config --quiet 2>"$validate_err"; then
      local err_msg; err_msg=$(cat "$validate_err")
      rm -f "$validate_err" "$tmp_compose" "$tmp_selection"
      ui_error "Generated compose file failed validation:\n\n${err_msg}\n\nFix the template(s) above and rebuild.\n\nYour existing docker-compose.yml was left untouched — nothing\nrunning has been affected."
      return 1
    fi
    rm -f "$validate_err"
    log_info "Compose file validated OK"
  fi

  # ── Validation passed — atomically swap the drafts into place ─────────────
  # mv within the same filesystem is atomic, so there's no window where
  # docker-compose.yml or selection.txt is partially written.
  mv -f "$tmp_compose" "$COMPOSE_FILE"
  mv -f "$tmp_selection" "$SELECTION_FILE"

  # ── Summary ────────────────────────────────────────────────────────────────
  # Relative paths keep this readable once more than a handful of services
  # are selected — repeating the full /home/pi/presto/services/... prefix
  # on every line was the main reason a 9-service build turned into an
  # unreadable wrapped wall of text.
  local env_list=""
  for f in "${env_files[@]}"; do env_list+="  • ${f#"$PRESTO_DIR"/}\n"; done

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