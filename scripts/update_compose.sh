#!/usr/bin/env bash
# scripts/update_compose.sh — Pull latest images and recreate containers
set -euo pipefail
cd "$PRESTO_DIR"
echo "[presto] Pulling latest images..."
docker compose pull
echo "[presto] Recreating updated containers..."
docker compose up -d --remove-orphans
echo "[presto] Update complete"
docker compose ps
