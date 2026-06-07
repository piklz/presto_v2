#!/usr/bin/env bash
# scripts/start.sh — Start the presto docker stack
set -euo pipefail
cd "$PRESTO_DIR"
docker compose up -d
echo "[presto] Stack started"
docker compose ps
