#!/usr/bin/env bash
# .templates/plex/meta.sh
#
# ─── Presto template metadata ───────────────────────────────────────────────
# Sourced by presto during discovery and build.  NEVER deployed to services/. 
#
SERVICE_DESC="Plex Media Server"
SERVICE_ICON="🎬"
SERVICE_ARCH="all"
SERVICE_TAGS="media" 
SERVICE_DEPS=""                 # Leave empty if none
SERVICE_CONFIGS="config.yaml" # Example config file to be seeded
