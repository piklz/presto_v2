#!/usr/bin/env bash
# scripts/prune-system.sh — Remove ALL unused docker data
# (containers, images, networks, build cache, volumes)
set -euo pipefail
echo "[presto] Pruning entire docker system (containers, images, networks, build cache, volumes)..."
docker system prune -af --volumes
echo "[presto] System prune complete"
