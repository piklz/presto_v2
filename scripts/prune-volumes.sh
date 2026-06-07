#!/usr/bin/env bash
# scripts/prune-volumes.sh — Remove unused docker volumes
set -euo pipefail
echo "[presto] Pruning unused volumes..."
docker volume prune -f
echo "[presto] Volume prune complete"
