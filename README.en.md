# WorkRecorder · 工作留声

[简体中文](README.md) · [Contributing](CONTRIBUTING.md) · [License](LICENSE)

A native macOS app for QS668 / CB08 and B3085 (FW925) recorder cards. Keep original recordings on your Mac, follow live captions, replay individual sentences, identify familiar speakers locally, and organize conversations into a daily timeline. Cloud transcription and summaries are optional.

Current development version: **0.7.0 (20260006)**. The baseline is tagged `baseline-2026-11-16`; development continues on `main`. This is an actively developed project. Automated tests do not establish real-device reliability, cloud availability, or speaker recognition accuracy in real meetings.

Select the B3085 in device settings. After recording, choose **Sync recordings** to download files over the card’s Wi-Fi hotspot. The library keeps the device original and a playable WAV. Bluetooth audio in a supported format feeds the same captions and speaker recognition as the QS668 / CB08. Continuous live audio and the full sync flow still need verification on the FW925.

## Features

- USB archival with file-size and SHA-256 verification before configured cleanup of card copies.
- Apple on-device captions, optional Alibaba Cloud Bailian transcription, 24-hour caption history, and sentence replay.
- Dismissible desktop captions, a menu bar status panel, and a Dock icon that changes with recorder state and shows the pending-sync count.
- Live speaker matching with local CAM++ and Silero models. Confirm or correct a speaker, review samples, or reset the sample library in Settings.
- Daily overviews and transcripts grouped by morning, afternoon, and evening. Follow processing progress or replay recordings from the time-of-day scrubber.

## Requirements

- Runtime: macOS 14 or later. Current delivery and local validation focus on Apple Silicon.
- Full app build: **Xcode 27.2 or later**. The Xcode project uses the `project.xcproj` format.
- SwiftPM tests: **Xcode 26.2 or later** and its macOS SDK. The package uses Swift tools 6.0 and Swift 5 language mode.
- Recorder features: Bluetooth and USB for the QS668 / CB08, or Bluetooth and Wi-Fi for the B3085 (FW925).
- Optional cloud features: your own Bailian API key for the Beijing region, service access, and network connectivity. Provider charges may apply.

You can build, run ordinary tests, and import local audio without a recorder card. Initial dependency resolution needs internet access. Apple speech recognition needs an available on-device language model. SwiftPM compiles modules and tests; the Xcode project packages the full app's permissions, icons, and license resources.

## Build and test

```sh
git clone https://github.com/timiswq/WorkRecorder.git
cd WorkRecorder

# Build without launching the app.
./script/build_and_run.sh --build-only

# No API key, recorder hardware, or external audio fixtures required.
./script/test.sh
```

Open `WorkRecorder.xcodeproj` and select **WorkRecorder → My Mac** for app development. The build script uses ad hoc signing and does not require the maintainer's developer team. Configure your own signing and notarization for distribution. Current DMG packaging targets Apple Silicon and is not Developer ID signed or notarized.

Run `./script/build_and_run.sh` to build and launch. Bind a recorder in Settings and explicitly enable cloud features if desired. USB sync can remove matching card copies after verified archival; review the [user guide](docs/使用指南.md) before use.

Artifacts go outside the checkout, by default to `~/Documents/CodexArtifacts/WorkRecorder/开发构建/`. Override this with `WORKDAY_ARTIFACTS`. Direct `swift build` / `swift test` commands should also use an external `--scratch-path`.

```sh
# Requires additional external fixtures and Apple speech models.
./script/test.sh --full

# Package an already built app.
./script/package_dmg.sh
```

GitHub Actions runs ordinary SwiftPM tests and Release compilation. Hardware, paid cloud requests, and fixture-dependent acceptance are separate. See the [development guide](docs/开发指南.md) for details.

## Project layout

| Path | Responsibility |
| --- | --- |
| `WorkRecorder/` | App entry point |
| `Sources/WorkdayMac/` | SwiftUI / AppKit UI and application coordination |
| `Sources/WorkdayCore/` | Archival, audio, captions, processing, timeline, and speaker inference |
| `Sources/QS668Core/` | QS668 / CB08 BLE protocol, session, framing, and write queue |
| `Sources/WiFiRecorderCore/`, `Sources/CRecorderOpus/` | FW925 protocol, live audio adaptation and device-file decoding. See the [Wi-Fi recorder development guide](docs/Wi-Fi录音卡开发指南.md). |
| `Tests/` | Protocol, core, and macOS tests |
| `Resources/` | Icons, permissions, and third-party notices |
| `script/` | Build, test, packaging, and validation tools |
| `docs/` | User, development, architecture, privacy, and protocol documentation |

Detailed project documentation and the app interface are currently in Simplified Chinese. Start with the [architecture](docs/架构说明.md), [privacy and data](docs/隐私与数据.md), [recorder protocol](docs/录音卡协议.md), and [baseline and acceptance boundaries](docs/项目基线.md).

## Privacy

The default library is `~/Documents/工作留声/`. Audio, transcripts, summaries, and speaker samples are stored locally; API keys are stored in macOS Keychain. Local storage does not imply application-level encryption. Cloud features are disabled by default. Once enabled, selected audio and text are sent to the configured Bailian services; FileTrans also uploads caption audio to provider-managed temporary storage. Review the provider's data terms before enabling it. See [privacy and data](docs/隐私与数据.md).

## Contributing and license

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request and [SECURITY.md](SECURITY.md) for private vulnerability reporting. Do not attach real recordings, credentials, voice samples, or a personal library to public issues.

Original project code and documentation are under the [MIT License](LICENSE). Third-party code and models retain their own licenses, including BSD-3-Clause, Apache-2.0 and MIT. See [dependency provenance](docs/第三方依赖.md), [bundled notices](Resources/ThirdPartyNotices.txt), and [license texts](Resources/VoiceLicenses).
