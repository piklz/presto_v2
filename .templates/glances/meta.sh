#!/usr/bin/env bash
# .templates/glances/meta.sh
#
# ─── Presto template metadata ───────────────────────────────────────────────
# Sourced by presto during discovery and build.  NEVER deployed to services/. 
#
SERVICE_DESC="System monitoring dashboard"
SERVICE_ICON="📊"
SERVICE_ARCH="all"
SERVICE_TAGS="monitoring" 
SERVICE_DEPS=""                 # Leave empty if none
SERVICE_CONFIGS="config.yaml" # Example config file to be seeded
