#!/usr/bin/env bash
# .templates/homeassistant/meta.sh
#
# ─── Presto template metadata ───────────────────────────────────────────────
# Sourced by presto during discovery and build.  NEVER deployed to services/. 
#
SERVICE_DESC="Home automation platform"
SERVICE_ICON="🏠"
SERVICE_ARCH="all"
SERVICE_TAGS="home-automation" 
SERVICE_DEPS=""                 # Leave empty if none
SERVICE_CONFIGS="config.yaml" # Example config file to be seeded
