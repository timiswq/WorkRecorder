#!/bin/bash
set -euo pipefail
WORKDAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKDAY_MODE="${1:-run}"
WORKDAY_OUTPUT="${WORKDAY_ARTIFACTS:-$HOME/Documents/CodexArtifacts/WorkRecorder/开发构建}"
case "${WORKDAY_CONFIGURATION:-release}" in
  [Dd]ebug) WORKDAY_CONFIG=Debug ;;
  [Rr]elease) WORKDAY_CONFIG=Release ;;
  *) echo 'WORKDAY_CONFIGURATION must be debug or release.' >&2; exit 2 ;;
esac
mkdir -p "$WORKDAY_OUTPUT"
WORKDAY_OUTPUT="$(cd "$WORKDAY_OUTPUT" && pwd -P)"
case "$WORKDAY_OUTPUT/" in "$WORKDAY_ROOT/"*) echo 'Build output must be outside the source repository.' >&2; exit 2;; esac
WORKDAY_DERIVED="$WORKDAY_OUTPUT/build/xcode"
WORKDAY_APP="$WORKDAY_OUTPUT/build/工作留声.app"
cd "$WORKDAY_ROOT"
xcodebuild -project WorkRecorder.xcodeproj -scheme WorkRecorder -configuration "$WORKDAY_CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$WORKDAY_DERIVED" \
  ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- build
WORKDAY_PRODUCT="$WORKDAY_DERIVED/Build/Products/$WORKDAY_CONFIG/工作留声.app"
codesign --verify --strict "$WORKDAY_PRODUCT"
# Copy the complete signed bundle, including the SwiftPM model resource bundle.
WORKDAY_STAGE="$(mktemp -d "$WORKDAY_OUTPUT/build/app-stage.XXXXXX")"
trap '/bin/rm -rf "$WORKDAY_STAGE"' EXIT
/usr/bin/ditto "$WORKDAY_PRODUCT" "$WORKDAY_STAGE/工作留声.app"
codesign --verify --strict "$WORKDAY_STAGE/工作留声.app"
if [[ -e "$WORKDAY_APP" ]]; then mv "$WORKDAY_APP" "$WORKDAY_STAGE/previous.app"; fi
if ! mv "$WORKDAY_STAGE/工作留声.app" "$WORKDAY_APP"; then
  if [[ -e "$WORKDAY_STAGE/previous.app" ]]; then mv "$WORKDAY_STAGE/previous.app" "$WORKDAY_APP"; fi
  exit 1
fi
if [[ "$WORKDAY_MODE" == '--build-only' ]]; then printf '%s\n' "$WORKDAY_APP"; exit 0; fi
/usr/bin/open -g "$WORKDAY_APP"
WORKDAY_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$WORKDAY_APP/Contents/Info.plist")"
if [[ "$WORKDAY_MODE" == '--verify' ]]; then sleep 1; pgrep -x "$WORKDAY_EXEC" >/dev/null; fi
if [[ "$WORKDAY_MODE" == '--logs' ]]; then /usr/bin/log stream --info --style compact --predicate "process == \"$WORKDAY_EXEC\""; fi
