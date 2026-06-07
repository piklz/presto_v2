#!/usr/bin/env bash
# scripts/stop.sh — Stop the presto docker stack
set -euo pipefail
cd "$PRESTO_DIR"
docker compose down
echo "[presto] Stack stopped"
