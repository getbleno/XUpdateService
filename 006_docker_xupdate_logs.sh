#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-xupdateservice-app}"
TAIL_LINES="${TAIL_LINES:-200}"

if ! command -v docker >/dev/null 2>&1; then
    echo "Missing required command: docker" >&2
    exit 1
fi

exec docker logs -f --tail "$TAIL_LINES" "$CONTAINER_NAME"
