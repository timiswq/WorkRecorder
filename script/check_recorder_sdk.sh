#!/bin/bash
# Check the independently buildable app and SDK against the same demo contract.
set -euo pipefail
if [[ $# != 1 || ! -f "$1/Package.swift" ]]; then
  echo "Usage: $0 /path/to/recorder-sdk/native" >&2
  exit 2
fi
app_root="$(cd "$(dirname "$0")/.." && pwd)"
native_root="$(cd "$1" && pwd)"
for name in Protocol.swift RecorderProtocol.swift RecorderGATTSession.swift RecorderWriter.swift RealtimeSession.swift; do
  diff -u "$app_root/Sources/QS668Core/$name" "$native_root/Sources/QS668Core/$name"
done
for name in Tests/QS668CoreTests/WebDemoTests.swift docs/录音卡协议.md docs/录音卡使用指南.md script/verify_recorder_demo.mjs; do
  diff -u "$app_root/$name" "$native_root/$name"
done
echo "录音卡协议、Demo 回放、回归样例和指南一致。"
