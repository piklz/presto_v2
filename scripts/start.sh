#!/usr/bin/env bash
# scripts/start.sh — Start the presto docker stack
set -euo pipefail
PRESTO_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
PRESTO_DIR="$(dirname "$PRESTO_DIR")"
cd "$PRESTO_DIR"
docker compose up -d
echo "[presto] Stack started"
docker compose ps
