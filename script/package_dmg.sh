#!/bin/bash
set -euo pipefail

WORKDAY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDAY_OUTPUT="${WORKDAY_ARTIFACTS:-$HOME/Documents/CodexArtifacts/WorkRecorder/开发构建}"
mkdir -p "$WORKDAY_OUTPUT"
WORKDAY_OUTPUT="$(cd "$WORKDAY_OUTPUT" && pwd -P)"
case "$WORKDAY_OUTPUT/" in "$WORKDAY_ROOT/"*) echo 'Package output must be outside the source repository.' >&2; exit 2;; esac

WORKDAY_APP="$WORKDAY_OUTPUT/build/工作留声.app"
if [[ ! -d "$WORKDAY_APP" ]]; then
  echo 'Build the app with script/build_and_run.sh --build-only first.' >&2
  exit 2
fi
/usr/bin/codesign --verify --strict "$WORKDAY_APP"
WORKDAY_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WORKDAY_APP/Contents/Info.plist")"
[[ "$WORKDAY_ID" == 'com.markonce.WorkRecorder' ]] || { echo 'Unexpected app bundle.' >&2; exit 2; }
WORKDAY_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORKDAY_APP/Contents/Info.plist")"
[[ "$WORKDAY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Unexpected version format.' >&2; exit 2; }
WORKDAY_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$WORKDAY_APP/Contents/Info.plist")"
WORKDAY_ARCH="$(/usr/bin/lipo -archs "$WORKDAY_APP/Contents/MacOS/$WORKDAY_EXEC")"
[[ "$WORKDAY_ARCH" == 'arm64' ]] || { echo 'This package script currently targets Apple Silicon.' >&2; exit 2; }

mkdir -p "$WORKDAY_OUTPUT/build" "$WORKDAY_OUTPUT/validation"
WORKDAY_DMG="$WORKDAY_OUTPUT/build/工作留声-$WORKDAY_VERSION-macOS-arm64.dmg"
[[ ! -e "$WORKDAY_DMG" ]] || { echo "Package already exists: $WORKDAY_DMG" >&2; exit 2; }
WORKDAY_STAGE="$(mktemp -d "$WORKDAY_OUTPUT/build/dmg-stage.XXXXXX")"
trap '/bin/rm -rf "$WORKDAY_STAGE"' EXIT

/usr/bin/ditto "$WORKDAY_APP" "$WORKDAY_STAGE/工作留声.app"
/bin/ln -s /Applications "$WORKDAY_STAGE/Applications"
cat > "$WORKDAY_STAGE/安装说明.txt" <<'EOF'
工作留声 · 安装说明

1. 若旧版仍在运行，请先在设备上结束并保存正在进行的录音，再退出旧版 App。
2. 将「工作留声.app」拖入旁边的 Applications（应用程序）文件夹，替换旧版。
3. 从「应用程序」打开工作留声；已有资料库和设置会保留。首次使用请在设置中连接录音卡。
4. 安装完成后可推出此磁盘映像。

系统要求：Apple Silicon（M 系列芯片），macOS 14 或更新。
这是本地签名测试版，尚未进行 Developer ID 签名及 Apple 公证。

一天可录任意多段；每段在设备上结束并保存后，即可接入 USB 自动同步。
打开 App 后自动连接已绑定录音卡；待机显示状态与待同步数，收到音频后显示实时文字。
实时文字可使用百炼。仅有本机字幕时，实时页也可查看。桌面语音气泡可在设置中单独开关。
完整录音与剪辑默认保存在「文稿/工作留声」，每段 USB 录音校验完成后，App 自动清理卡内对应的 WAV 和配对 OPUS。
需要百炼的转写和整理功能在设置中配置。
EOF
/usr/bin/codesign --verify --strict "$WORKDAY_STAGE/工作留声.app"
/usr/bin/hdiutil create -srcfolder "$WORKDAY_STAGE" -volname "工作留声 $WORKDAY_VERSION" -fs HFS+ -format UDZO "$WORKDAY_DMG"
/usr/bin/hdiutil verify "$WORKDAY_DMG"
/usr/bin/shasum -a 256 "$WORKDAY_DMG" > "$WORKDAY_DMG.sha256"
printf '%s\n' "$WORKDAY_DMG"
