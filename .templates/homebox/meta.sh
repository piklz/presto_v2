#!/usr/bin/env bash
# .templates/homepage/meta.sh
#
# ─── Presto template metadata ───────────────────────────────────────────────
# Sourced by presto during discovery and build.  NEVER deployed to services/.
#
# SERVICE_ARCH    Supported architectures (space-separated) or "all".
#                 Valid: all | arm64 | amd64 | armv7
#
# SERVICE_DEPS    Space-separated template names that must be included
#                 alongside this service (hard runtime deps that your
#                 service.yml's `depends_on:` references).  Presto
#                 auto-adds them and notifies the user.  Leave empty
#                 if there are no dependencies.
#
# SERVICE_CONFIGS Space-separated extra config files in this template dir
#                 (e.g. Caddyfile, glances.conf) that belong in the
#                 container's volume mount, NOT in services/<name>/.
#                 Presto seeds these to volumes/<name>/ on first deploy
#                 and never overwrites them — same safety model as .env.
#                 They are excluded from the services/ rsync entirely.
#                 Edit them in volumes/<name>/ after first deploy.
# ────────────────────────────────────────────────────────────────────────────

SERVICE_DESC="home catalogging dashboard"
SERVICE_ICON="📋"
SERVICE_ARCH="all"
SERVICE_TAGS="dashboard"
SERVICE_DEPS=""       # e.g. "postgres redis"  — leave empty if none
SERVICE_CONFIGS=""    # seeds .templates/homepage/config/ → volumes/homepage/config/