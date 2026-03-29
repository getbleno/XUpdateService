#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_NAME="${CONTAINER_NAME:-xupdateservice-mysql}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_DATABASE="${MYSQL_DATABASE:-xupdate}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-123456}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-$SCRIPT_DIR/data}"
SQL_FILE="${SQL_FILE:-$SCRIPT_DIR/sql/xupdate.sql}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

container_exists() {
    docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"
}

container_running() {
    docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"
}

current_mount_source() {
    docker inspect "$CONTAINER_NAME" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Source}}{{end}}{{end}}'
}

wait_for_mysql() {
    local retries=60
    local i
    for ((i=1; i<=retries; i++)); do
        if docker exec "$CONTAINER_NAME" mysqladmin ping -h"$MYSQL_HOST" -uroot "-p$MYSQL_ROOT_PASSWORD" --silent >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    echo "MySQL did not become ready in time." >&2
    exit 1
}

require_cmd docker

if [[ ! -f "$SQL_FILE" ]]; then
    echo "SQL init file not found: $SQL_FILE" >&2
    exit 1
fi

mkdir -p "$MYSQL_DATA_DIR"

if container_exists; then
    CURRENT_MOUNT="$(current_mount_source)"
    if [[ "$CURRENT_MOUNT" != "$MYSQL_DATA_DIR" ]]; then
        echo "Recreating container to use data dir: $MYSQL_DATA_DIR"
        docker rm -f "$CONTAINER_NAME" >/dev/null
    fi
fi

if container_exists; then
    if ! container_running; then
        echo "Starting existing container: $CONTAINER_NAME"
        docker start "$CONTAINER_NAME" >/dev/null
    else
        echo "Container already running: $CONTAINER_NAME"
    fi
else
    echo "Creating MySQL container: $CONTAINER_NAME"
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p "$MYSQL_PORT:3306" \
        -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
        -e MYSQL_DATABASE="$MYSQL_DATABASE" \
        -v "$MYSQL_DATA_DIR:/var/lib/mysql" \
        "$MYSQL_IMAGE" \
        --default-authentication-plugin=mysql_native_password \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_general_ci >/dev/null
fi

echo "Waiting for MySQL to become ready..."
wait_for_mysql

cat <<EOF
MySQL is ready.

Container: $CONTAINER_NAME
Image: $MYSQL_IMAGE
Host: localhost
Port: $MYSQL_PORT
Database: $MYSQL_DATABASE
Username: root
Password: $MYSQL_ROOT_PASSWORD
Data dir: $MYSQL_DATA_DIR

JDBC URL:
jdbc:mysql://localhost:$MYSQL_PORT/$MYSQL_DATABASE?useUnicode=true&characterEncoding=UTF-8&allowMultiQueries=true

Next step:
./003_docker_mysql_import.sh
EOF
