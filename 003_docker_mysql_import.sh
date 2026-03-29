#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_NAME="${CONTAINER_NAME:-xupdateservice-mysql}"
MYSQL_DATABASE="${MYSQL_DATABASE:-xupdate}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-123456}"
SQL_FILE="${SQL_FILE:-$SCRIPT_DIR/sql/xupdate.sql}"

if ! command -v docker >/dev/null 2>&1; then
    echo "Missing required command: docker" >&2
    exit 1
fi

if [[ ! -f "$SQL_FILE" ]]; then
    echo "SQL file not found: $SQL_FILE" >&2
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    echo "MySQL container is not running: $CONTAINER_NAME" >&2
    echo "Start it first with ./001_docker_mysql_start.sh" >&2
    exit 1
fi

echo "Importing schema and seed data from $SQL_FILE"
docker exec -i "$CONTAINER_NAME" mysql -uroot "-p$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" < "$SQL_FILE"

cat <<EOF
Import completed.

Container: $CONTAINER_NAME
Database: $MYSQL_DATABASE
SQL file: $SQL_FILE
EOF
