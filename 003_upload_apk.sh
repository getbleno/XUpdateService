#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-http://127.0.0.1:1111}"
APK_DIR="${1:-}"
DEFAULT_UPDATE_STATUS="${DEFAULT_UPDATE_STATUS:-1}"
DEFAULT_MODIFY_CONTENT="${DEFAULT_MODIFY_CONTENT:-update}"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

need_cmd curl
need_cmd python3

if [[ -z "$APK_DIR" ]]; then
    echo "Usage: $0 <apk-folder>" >&2
    exit 1
fi

if [[ "$APK_DIR" != /* ]]; then
    APK_DIR="$ROOT_DIR/$APK_DIR"
fi

if [[ ! -d "$APK_DIR" ]]; then
    echo "APK directory not found: $APK_DIR" >&2
    exit 1
fi

PLAN_JSONL="$(mktemp)"
cleanup() {
    rm -f "$PLAN_JSONL"
}
trap cleanup EXIT

python3 <<PY > "$PLAN_JSONL"
import json
import re
from pathlib import Path

apk_dir = Path(r"$APK_DIR")
default_update_status = int(r"$DEFAULT_UPDATE_STATUS")
default_modify_content = r"$DEFAULT_MODIFY_CONTENT"

app_key_map = {
    "BibleReading": "com.bleno.bible",
    "BlenoDrawer": "com.bleno.blenodrawer",
    "BlenoNotice": "com.bleno.blenonotice",
    "BookShelf": "com.bleno.bookshelf",
    "Calendar": "com.bleno.calendar",
    "Launcher": "cn.bythemoon.jackie.myviewlauncher",
    "MReader": "com.bleno.reader",
    "NoteShelf": "com.bleno.noteshelf",
    "Notes": "com.bleno.note",
    "Player": "com.bleno.player",
    "Prayer": "com.bleno.prayer",
    "Reflection": "com.bleno.reflection",
}

pattern = re.compile(r"^(?P<name>[A-Za-z][A-Za-z0-9]*?)-(?P<version>\d+(?:\.\d+)+)-(?P<stamp>\d{12})\.apk$")

for apk in sorted(apk_dir.glob("*.apk")):
    match = pattern.match(apk.name)
    if not match:
        print(json.dumps({
            "file": str(apk),
            "skip": True,
            "reason": "unrecognized_filename"
        }, ensure_ascii=False))
        continue

    app_name = match.group("name")
    version_name = match.group("version")
    version_code = int(version_name.replace(".", ""))
    app_key = app_key_map.get(app_name)

    if not app_key:
        print(json.dumps({
            "file": str(apk),
            "skip": True,
            "reason": "unknown_app_key",
            "appName": app_name
        }, ensure_ascii=False))
        continue

    print(json.dumps({
        "file": str(apk),
        "skip": False,
        "appName": app_name,
        "appKey": app_key,
        "versionName": version_name,
        "versionCode": version_code,
        "updateStatus": default_update_status,
        "modifyContent": default_modify_content,
    }, ensure_ascii=False))
PY

echo "Upload plan from $APK_DIR:"
python3 <<PY
import json
from pathlib import Path
for line in Path(r"$PLAN_JSONL").read_text().splitlines():
    item = json.loads(line)
    if item["skip"]:
        print(f'- SKIP {Path(item["file"]).name}: {item["reason"]}')
    else:
        print(f'- {Path(item["file"]).name}: {item["appKey"]} {item["versionName"]} ({item["versionCode"]})')
PY

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    SKIP="$(python3 -c 'import json,sys; print("true" if json.loads(sys.argv[1])["skip"] else "false")' "$line")"
    if [[ "$SKIP" == "true" ]]; then
        continue
    fi

    FILE_PATH="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["file"])' "$line")"
    APP_KEY="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["appKey"])' "$line")"
    VERSION_NAME="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["versionName"])' "$line")"
    VERSION_CODE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["versionCode"])' "$line")"
    UPDATE_STATUS="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["updateStatus"])' "$line")"
    MODIFY_CONTENT="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["modifyContent"])' "$line")"

    echo "Creating version for $(basename "$FILE_PATH"): $APP_KEY $VERSION_NAME ($VERSION_CODE)"
    CREATE_RESPONSE="$(curl -fsS \
        -X POST "$BASE_URL/update/addVersionInfo" \
        --data-urlencode "appKey=$APP_KEY" \
        --data-urlencode "versionName=$VERSION_NAME" \
        --data-urlencode "versionCode=$VERSION_CODE" \
        --data-urlencode "updateStatus=$UPDATE_STATUS" \
        --data-urlencode "modifyContent=$MODIFY_CONTENT")"

    VERSION_ID="$(printf '%s' "$CREATE_RESPONSE" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
code = obj.get("Code", obj.get("code"))
msg = obj.get("Msg", obj.get("msg"))
data = obj.get("Data", obj.get("data")) or {}
if code != 0 and "已存在" not in (msg or ""):
    raise SystemExit(msg or "addVersionInfo failed")
print(data.get("versionId") or "")
')"

    if [[ -z "$VERSION_ID" ]]; then
        LOOKUP_RESPONSE="$(curl -fsS "$BASE_URL/update/versions")"
        VERSION_ID="$(printf '%s' "$LOOKUP_RESPONSE" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
items = obj.get("data") or obj.get("Data") or []
app_key = sys.argv[1]
version_code = int(sys.argv[2])
for item in items:
    if item.get("appKey") == app_key and int(item.get("versionCode")) == version_code:
        print(item.get("versionId") or "")
        break
' "$APP_KEY" "$VERSION_CODE")"
    fi

    if [[ -z "$VERSION_ID" ]]; then
        echo "Failed to resolve versionId for $(basename "$FILE_PATH")" >&2
        exit 1
    fi

    echo "Uploading $(basename "$FILE_PATH") -> versionId=$VERSION_ID"
    UPLOAD_RESPONSE="$(curl -fsS \
        -X POST "$BASE_URL/update/uploadApk" \
        -F "versionId=$VERSION_ID" \
        -F "file=@$FILE_PATH")"

    printf '%s' "$UPLOAD_RESPONSE" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
code = obj.get("Code", obj.get("code"))
msg = obj.get("Msg", obj.get("msg"))
if code != 0:
    raise SystemExit(msg or "uploadApk failed")
'
done < "$PLAN_JSONL"

echo "Done."
