#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-xupdateservice-app}"

if ! command -v docker >/dev/null 2>&1; then
    echo "Missing required command: docker" >&2
    exit 1
fi

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    docker stop "$CONTAINER_NAME"
else
    echo "Container not found: $CONTAINER_NAME" >&2
    exit 1
fi
