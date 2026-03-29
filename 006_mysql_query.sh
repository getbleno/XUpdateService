#!/usr/bin/env bash

set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_DATABASE="${MYSQL_DATABASE:-xupdate}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-123456}"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 \"<sql>\"" >&2
    exit 1
fi

if ! command -v mysql >/dev/null 2>&1; then
    echo "Missing required command: mysql" >&2
    exit 1
fi

SQL="$1"

exec mysql \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    -u "$MYSQL_USER" \
    "-p$MYSQL_PASSWORD" \
    "$MYSQL_DATABASE" \
    -e "$SQL"
