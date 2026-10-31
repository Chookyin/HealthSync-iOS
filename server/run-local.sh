#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "Missing server/.env" >&2
  exit 1
fi

set -a
source .env
set +a

: "${HEALTH_API_TOKEN:?HEALTH_API_TOKEN is required}"
: "${OBSIDIAN_VAULT:?OBSIDIAN_VAULT is required}"

mkdir -p "$OBSIDIAN_VAULT"

exec .venv/bin/uvicorn health_api_server:app \
  --host "${HEALTH_API_HOST:-0.0.0.0}" \
  --port "${HEALTH_API_PORT:-8765}"
