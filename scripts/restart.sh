#!/usr/bin/env bash
# scripts/restart.sh — Restart the presto docker stack
set -euo pipefail
cd "$PRESTO_DIR"
docker compose restart
echo "[presto] Stack restarted"
docker compose ps
