#!/bin/bash
set -euo pipefail
WORKDAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDAY_OUTPUT="${WORKDAY_ARTIFACTS:-$HOME/Documents/CodexArtifacts/WorkRecorder/开发构建}"
WORKDAY_OUTPUT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$WORKDAY_OUTPUT")"
case "$WORKDAY_OUTPUT/" in "$WORKDAY_ROOT/"*) echo 'Test output must be outside the source repository.' >&2; exit 2;; esac
mkdir -p "$WORKDAY_OUTPUT/validation"
export WORKDAY_TEST_ROOT="$WORKDAY_OUTPUT/validation"
if [[ "${1:-}" == "--full" ]]; then
  shift
  WORKDAY_INPUT="${WORKDAY_FIXTURES:-$HOME/Documents/CodexArtifacts/WorkRecorder/2026-11-11-开发基线/fixtures}"
  for fixture in apple/card.opusraw apple/edges.opusraw public-voices/fangjun-test-sr-1.wav workspace/Records workspace/Days; do
    if [[ ! -e "$WORKDAY_INPUT/$fixture" ]]; then
      echo "Missing acceptance fixture: $WORKDAY_INPUT/$fixture (see README.md)" >&2
      exit 2
    fi
  done
  export WORKDAY_APPLE_SPEECH="$WORKDAY_INPUT/apple/card.opusraw" WORKDAY_APPLE_SPEECH_EDGES="$WORKDAY_INPUT/apple/edges.opusraw"
  export WORKDAY_PUBLIC_SPEECH="$WORKDAY_INPUT/public-voices"
  export WORKDAY_LONG_AUDIO=1 WORKDAY_DESKTOP_SNAPSHOTS=1 WORKDAY_WORKSPACE_SNAPSHOTS=1
  WORKDAY_FIXTURE_LIBRARY="$(mktemp -d "$WORKDAY_TEST_ROOT/workspace-fixture.XXXXXX")"
  export WORKDAY_FIXTURE_LIBRARY
  trap '/bin/rm -rf "$WORKDAY_FIXTURE_LIBRARY"' EXIT
  /usr/bin/ditto "$WORKDAY_INPUT/workspace" "$WORKDAY_FIXTURE_LIBRARY"
fi
cd "$WORKDAY_ROOT"
swift test --scratch-path "$WORKDAY_OUTPUT/build/swift-debug" "$@"
