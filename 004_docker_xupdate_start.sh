#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

BUILD_IMAGE="${BUILD_IMAGE:-eclipse-temurin:8-jdk}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-eclipse-temurin:8-jre}"
IMAGE_TAG="${IMAGE_TAG:-xupdateservice:local}"
CONTAINER_NAME="${CONTAINER_NAME:-xupdateservice-app}"

PORT="${PORT:-1111}"
HOST_BIND="${HOST_BIND:-0.0.0.0}"
APP_FILES_PATH="${APP_FILES_PATH:-$ROOT_DIR/apps}"

DB_NAME="${DB_NAME:-XUpdateService}"
DB_URL="${DB_URL:-jdbc:mysql://host.docker.internal:3306/xupdate?useUnicode=true&characterEncoding=UTF-8&allowMultiQueries=true}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-123456}"
JAVA_OPTS="${JAVA_OPTS:-}"
MAX_FILE_SIZE="${MAX_FILE_SIZE:-500MB}"
MAX_REQUEST_SIZE="${MAX_REQUEST_SIZE:-500MB}"

TMP_SRC=""
TMP_IMG=""

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

cleanup() {
    [[ -n "$TMP_SRC" && -d "$TMP_SRC" ]] && rm -rf "$TMP_SRC"
    [[ -n "$TMP_IMG" && -d "$TMP_IMG" ]] && rm -rf "$TMP_IMG"
}

copy_repo() {
    mkdir -p "$TMP_SRC"
    tar \
        --exclude='.git' \
        --exclude='build' \
        --exclude='.gradle' \
        --exclude='.gradle-user-home' \
        --exclude='data' \
        --exclude='uploads' \
        -cf - . | (cd "$TMP_SRC" && tar -xf -)
}

need_cmd docker
need_cmd tar
need_cmd python3

mkdir -p "$APP_FILES_PATH"
if [[ ! -d "$APP_FILES_PATH" ]]; then
    echo "Failed to create app files directory: $APP_FILES_PATH" >&2
    exit 1
fi
TMP_SRC="$(mktemp -d)"
TMP_IMG="$(mktemp -d)"
trap cleanup EXIT

echo "Preparing temporary build workspace..."
(cd "$ROOT_DIR" && copy_repo)

python3 <<PY
from pathlib import Path

root = Path(r"$TMP_SRC")

generator_gradle = """def getDbProperties = {
    def properties = new Properties()
    file("src/main/resources/db-mysql.properties").withInputStream { inputStream ->
        properties.load(inputStream)
    }
    properties;
}
task mybatisGenerate {
    doLast {
        def properties = getDbProperties()
        ant.properties['targetProject'] = projectDir.path
        ant.properties['classPath'] = properties.getProperty("classPath")
        ant.properties['driverClass'] = properties.getProperty("jdbc.driverClassName")
        ant.properties['connectionURL'] = properties.getProperty("jdbc.url")
        ant.properties['userId'] = properties.getProperty("jdbc.user")
        ant.properties['password'] = properties.getProperty("jdbc.pass")
        ant.properties['src_main_java'] = sourceSets.main.java.srcDirs[0].path
        ant.properties['src_main_resources'] = sourceSets.main.resources.srcDirs[0].path
        ant.properties['modelPackage'] = this.modelPackage
        ant.properties['mapperPackage'] = this.mapperPackage
        ant.properties['sqlMapperPackage'] = this.sqlMapperPackage
        ant.taskdef(
                name: 'mbgenerator',
                classname: 'org.mybatis.generator.ant.GeneratorAntTask',
                classpath: configurations.mybatisGenerator.asPath
        )
        ant.mbgenerator(overwrite: true,
                configfile: project.file('db/generatorConfig.xml').path, verbose: true) {
            propertyset {
                propertyref(name: 'targetProject')
                propertyref(name: 'classPath')
                propertyref(name: 'driverClass')
                propertyref(name: 'connectionURL')
                propertyref(name: 'userId')
                propertyref(name: 'password')
                propertyref(name: 'src_main_java')
                propertyref(name: 'src_main_resources')
                propertyref(name: 'modelPackage')
                propertyref(name: 'mapperPackage')
                propertyref(name: 'sqlMapperPackage')
            }
        }
    }
}
"""

(root / "generator.gradle").write_text(generator_gradle)

files = {
    "src/main/resources/db-mysql.properties": [
        ("classPath=/Users/xuexiang/Documents/MyGitHub/XUpdateService/libs/mysql-connector-java-5.1.35.jar", "classPath=libs/mysql-connector-java-5.1.35.jar"),
    ],
    "src/main/resources/application.yml": [
        ("classpath:mapping/*.xml", "classpath:mybatis_mapper/*.xml"),
    ],
    "src/main/resources/templates/index.html": [
        ("../static/css/main.css", "/css/main.css"),
        ("../static/js/upload.js", "/js/upload.js"),
    ],
}

for name, replacements in files.items():
    path = root / name
    text = path.read_text()
    for old, new in replacements:
        text = text.replace(old, new)
    path.write_text(text)
PY

echo "Building jar inside Docker with JDK 8..."
docker run --rm \
    --user "${HOST_UID}:${HOST_GID}" \
    -v "$TMP_SRC:/workspace" \
    -w /workspace \
    "$BUILD_IMAGE" \
    bash -lc '
        set -euo pipefail
        chmod +x ./gradlew
        mkdir -p /workspace/.gradle-user-home
        export GRADLE_USER_HOME=/workspace/.gradle-user-home
        ./gradlew --no-daemon clean bootJar
    '

JAR_PATH="$(ls -t "$TMP_SRC"/build/libs/*.jar | head -n 1)"
if [[ -z "$JAR_PATH" ]]; then
    echo "Build succeeded but no jar was found." >&2
    exit 1
fi

cp "$JAR_PATH" "$TMP_IMG/app.jar"
cat > "$TMP_IMG/entrypoint.sh" <<'EOF'
#!/bin/sh
set -eu

exec java ${JAVA_OPTS:-} -jar /opt/xupdateservice/app.jar \
  --server.port="${PORT:-1111}" \
  --spring.datasource.name="${DB_NAME:-XUpdateService}" \
  --spring.datasource.url="${DB_URL}" \
  --spring.datasource.username="${DB_USER:-root}" \
  --spring.datasource.password="${DB_PASSWORD:-123456}" \
  --spring.servlet.multipart.max-file-size="${MAX_FILE_SIZE:-500MB}" \
  --spring.servlet.multipart.max-request-size="${MAX_REQUEST_SIZE:-500MB}" \
  --upload.file-directory=/opt/xupdateservice/apps
EOF

cat > "$TMP_IMG/Dockerfile" <<EOF
FROM ${RUNTIME_IMAGE}
WORKDIR /opt/xupdateservice
COPY app.jar /opt/xupdateservice/app.jar
COPY entrypoint.sh /opt/xupdateservice/entrypoint.sh
RUN chmod +x /opt/xupdateservice/entrypoint.sh
EXPOSE ${PORT}
ENTRYPOINT ["/opt/xupdateservice/entrypoint.sh"]
EOF

echo "Building runtime image ${IMAGE_TAG}..."
docker build -t "$IMAGE_TAG" "$TMP_IMG" >/dev/null

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
fi

echo "Starting ${CONTAINER_NAME}..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${HOST_BIND}:${PORT}:${PORT}" \
    -e JAVA_OPTS="$JAVA_OPTS" \
    -e PORT="$PORT" \
    -e DB_NAME="$DB_NAME" \
    -e DB_URL="$DB_URL" \
    -e DB_USER="$DB_USER" \
    -e DB_PASSWORD="$DB_PASSWORD" \
    -e MAX_FILE_SIZE="$MAX_FILE_SIZE" \
    -e MAX_REQUEST_SIZE="$MAX_REQUEST_SIZE" \
    -v "$APP_FILES_PATH:/opt/xupdateservice/apps" \
    "$IMAGE_TAG" >/dev/null

echo
echo "Container started."
echo "Image: $IMAGE_TAG"
echo "Container: $CONTAINER_NAME"
echo "Port: $HOST_BIND:$PORT"
echo "Datasource: $DB_URL"
echo "App files dir: $APP_FILES_PATH"
echo
echo "Access:"
echo "http://127.0.0.1:$PORT/"
echo "http://127.0.0.1:$PORT/index"
echo
echo "Logs:"
echo "docker logs -f $CONTAINER_NAME"
