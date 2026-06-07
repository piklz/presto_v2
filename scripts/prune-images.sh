#!/usr/bin/env bash
# scripts/prune-images.sh — Remove unused docker images
set -euo pipefail
echo "[presto] Pruning unused images..."
docker image prune -af
echo "[presto] Image prune complete"
