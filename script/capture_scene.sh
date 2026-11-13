#!/bin/bash
set -euo pipefail
WORKDAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKDAY_OUTPUT="${WORKDAY_ARTIFACTS:-$HOME/Documents/CodexArtifacts/WorkRecorder/开发构建}"
WORKDAY_OUTPUT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$WORKDAY_OUTPUT")"
case "$WORKDAY_OUTPUT/" in "$WORKDAY_ROOT/"*) echo 'Scene captures must be outside the repository.' >&2; exit 2;; esac
mkdir -p "$WORKDAY_OUTPUT/validation"
if [[ "${1:-}" != "--no-build" ]]; then
  WORKDAY_ARTIFACTS="$WORKDAY_OUTPUT" "$WORKDAY_ROOT/script/build_and_run.sh" --build-only \
    > "$WORKDAY_OUTPUT/validation/scene-build.log" 2>&1
fi
WORKDAY_FIXTURE="${WORKDAY_FIXTURES:-$HOME/Documents/CodexArtifacts/WorkRecorder/fixtures}/workspace"
WORKDAY_STAGE="$(mktemp -d "$WORKDAY_OUTPUT/validation/scene-fixture.XXXXXX")"
WORKDAY_CAPTURE_CLOSED=1
trap 'if [[ "$WORKDAY_CAPTURE_CLOSED" == 1 ]]; then /bin/rm -rf "$WORKDAY_STAGE"; fi' EXIT
/usr/bin/ditto "$WORKDAY_OUTPUT/build/工作留声.app" "$WORKDAY_STAGE/ScenePreview.app"
/usr/bin/ditto "$WORKDAY_FIXTURE" "$WORKDAY_STAGE/Library"
python3 - "$WORKDAY_STAGE/ScenePreview.app/Contents/Info.plist" <<'PY'
import plistlib, sys, uuid
from pathlib import Path
path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info["CFBundleIdentifier"] = "com.workday.layoutpreview." + uuid.uuid4().hex
info["CFBundleName"] = "工作留声布局验证"
info["LSUIElement"] = True
path.write_bytes(plistlib.dumps(info))
PY
/usr/bin/codesign --force --sign - "$WORKDAY_STAGE/ScenePreview.app" \
  > "$WORKDAY_OUTPUT/validation/scene-launch.log" 2>&1
WORKDAY_CAPTURE_CLOSED=0
/usr/bin/open -W -g -j -n --env "WORKDAY_LIBRARY=$WORKDAY_STAGE/Library" \
  --env "WORKDAY_SCENE_CAPTURE=$WORKDAY_STAGE/captures" "$WORKDAY_STAGE/ScenePreview.app"
WORKDAY_CAPTURE_CLOSED=1
if python3 - "$WORKDAY_STAGE/captures/scene-validation.json" <<'PY'
import json, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
if not result.get("passed"):
    raise SystemExit(result.get("error", "Native scene capture failed."))
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
then
  /usr/bin/ditto "$WORKDAY_STAGE/captures" "$WORKDAY_OUTPUT/validation/scene"
else
  /usr/bin/ditto "$WORKDAY_STAGE/captures" "$WORKDAY_OUTPUT/validation/scene-failed-$(date +%s)"
  exit 1
fi
