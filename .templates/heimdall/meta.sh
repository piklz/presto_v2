#!/usr/bin/env bash
# .templates/heimdall/meta.sh
#
# ─── Presto template metadata ───────────────────────────────────────────────
# Sourced by presto during discovery and build.  NEVER deployed to services/. 
#
SERVICE_DESC="Application dashboard"
SERVICE_ICON="🏠"
SERVICE_ARCH="all"
SERVICE_TAGS="dashboard" 
SERVICE_DEPS=""                 # Leave empty if none
SERVICE_CONFIGS="config.yaml" # Example config file to be seeded
