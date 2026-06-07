#!/usr/bin/env bash
# scripts/update_compose.sh — Pull latest images and recreate containers
set -euo pipefail
PRESTO_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
PRESTO_DIR="$(dirname "$PRESTO_DIR")"
cd "$PRESTO_DIR"
echo "[presto] Pulling latest images..."
docker compose pull
echo "[presto] Recreating updated containers..."
docker compose up -d --remove-orphans
echo "[presto] Update complete"
docker compose ps
