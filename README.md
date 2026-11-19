# 工作留声 · WorkRecorder

[English](README.en.md) · [使用指南](docs/使用指南.md) · [开发指南](docs/开发指南.md) · [参与贡献](CONTRIBUTING.md)

原生 macOS 录音整理应用。QS668 / CB08 通过 USB 同步原件，B3085（FW925）通过 Wi-Fi 同步原件。两类卡都支持蓝牙实时字幕，录音可在同一份 Mac 资料库中回听、转写和整理。云端转写与整理按需开启。

当前开发版本为 **0.7.0（20260006）**，开发基线标签为 `baseline-2026-11-17`。`main` 继续演进；功能和验证范围见[项目基线](docs/项目基线.md)与[更新记录](CHANGELOG.md)。项目仍在开发中，实体录音卡、不同系统版本和真实会议需要各自验收。

## 能做什么

- **保存原件。** 设备页显示 USB 或 Wi-Fi 传输进度与速度。FW925 空闲时还可通过蓝牙查看录音总数和待同步段数。两种传输方式均支持在校验归档后按设置清理卡内副本。
- **实时字幕。** 桌面气泡按稳定短语追加文字，未知发言人也会显示。默认使用 Apple 本机识别，可选 ESP 实时识别或逐句复核。最近 24 小时的字幕历史支持查看最新转写、来源和逐句回听。
- **桌面陪伴。** 可开启 Mac 内置麦克风，在桌面按来源对照麦克风与录音卡的本机字幕。Dock 图标显示录音卡状态与待同步段数。
- **本地声纹。** 用 CAM++ 和 Silero 随发言更新本人识别，支持「是我 / 不是我」反馈、样本库清空和归档发言人更正。
- **全天事项。** 以日期、当天概述和上午／下午／晚上的记录回顾一天，保留原话与人工归属，底栏统一按钟点查找、回听和原始录音入口。

## 环境要求

| 用途 | 要求 |
| --- | --- |
| 运行 App | macOS 14 或更新；当前交付与实测以 Apple Silicon 为主 |
| 构建完整 App | Xcode 27.2 或更新，包含 macOS SDK；工程采用 `project.xcproj` 格式 |
| SwiftPM 测试 | Xcode 26.2 或更新的工具链与 macOS SDK；`Package.swift` 使用 Swift tools 6.0、Swift 5 语言模式 |
| 录音卡功能 | QS668 / CB08 使用蓝牙和 USB。B3085（FW925）使用蓝牙及 Wi-Fi 热点 |
| 云端功能（可选） | 自行配置 ESP API Key、网络及服务权限；调用可能产生服务商费用 |

没有录音卡也可以构建、运行普通测试、导入本地音频和浏览已有资料库。首次解析 SwiftPM 依赖需要网络，系统本地听写还依赖可用的 Apple 语音模型。SwiftPM 可编译模块与测试，完整 App 的图标、权限和许可资源由 Xcode 工程打包。

## 从源码开始

```sh
git clone https://github.com/timiswq/WorkRecorder.git
cd WorkRecorder

# 只构建，不启动或替换正在运行的 App。
./script/build_and_run.sh --build-only

# 普通测试无需 API Key、录音卡或外部音频。
./script/test.sh
```

打开 `WorkRecorder.xcodeproj`，选择 **WorkRecorder → My Mac** 也可开发。构建脚本使用本地临时签名，无需维护者的 Apple 开发者团队；自行分发时需配置自己的签名与公证。当前打包脚本生成 Apple Silicon 的本地签名测试版，尚未进行 Developer ID 签名或 Apple 公证。

构建完成后，运行 `./script/build_and_run.sh` 启动 App。可在侧栏「录音卡」中选择设备，在「设置 → 语音识别」选择是否开启云端功能。首次使用和自动同步清理行为见[使用指南](docs/使用指南.md)。

构建、测试和下载输出默认位于仓库外 `~/Documents/CodexArtifacts/WorkRecorder/开发构建/`，可用 `WORKDAY_ARTIFACTS` 覆盖。直接运行 `swift build` / `swift test` 时也应提供仓库外的 `--scratch-path`。

```sh
# 需额外准备外部样本及系统语音模型；不属于普通 CI。
./script/test.sh --full

# 使用已经构建的 App 生成 DMG。
./script/package_dmg.sh
```

完整验收的样本列表、后台测试及构建方法见[开发指南](docs/开发指南.md)。GitHub Actions 使用 SwiftPM 执行普通测试与 Release 编译；它不替代实体硬件、云端服务或完整 App 的验收。

## 源码与文档

| 目录 | 内容 |
| --- | --- |
| `WorkRecorder/` | App 启动入口 |
| `Sources/WorkdayMac/` | SwiftUI / AppKit 界面与应用协调 |
| `Sources/WorkdayCore/` | 归档、音频、字幕、处理流水线、时间线与声纹 |
| `Sources/WiFiRecorderCore/`、`Sources/CRecorderOpus/` | Wi-Fi 卡协议、实时蓝牙音频适配、断点下载与本地 Opus 文件解码 |
| `Sources/QS668Core/` | 录音卡协议、蓝牙会话、封包与写入队列 |
| `Tests/` | 协议、业务与 macOS 界面的测试 |
| `Resources/` | App 图标、权限与第三方许可 |
| `script/` | 构建、测试、打包、合成样本和协议对照工具 |
| `docs/` | 使用、开发、架构、隐私与设备文档 |

- [使用指南](docs/使用指南.md)：归档、字幕、声纹、事项整理、备份。
- [开发指南](docs/开发指南.md)与[架构说明](docs/架构说明.md)：目录职责、数据流、调试和测试。
- [隐私与数据](docs/隐私与数据.md)：本地资料、云端发送内容与分享日志前的处理。
- QS668 / CB08 的接入、按键和通信契约见[录音卡使用指南](docs/录音卡使用指南.md)与[录音卡协议](docs/录音卡协议.md)。
- B3085 / FW925 的蓝牙实时传声、Wi-Fi 原件同步和真机联调步骤见 [Wi-Fi 录音卡开发指南](docs/Wi-Fi录音卡开发指南.md)。
- [贡献指南](CONTRIBUTING.md)与[安全问题报告](SECURITY.md)：提交 Issue、Pull Request 和漏洞报告。

## 许可与致谢

本项目原创源码和文档采用 [MIT 许可证](LICENSE)。录音卡协议源码、Opus、sherpa-onnx、ONNX Runtime、CAM++ 和 Silero VAD 分别遵循其上游许可证；模型权重和第三方代码不因本仓库的 MIT 许可而改变许可。来源、版本和模型 SHA-256 见[第三方依赖](docs/第三方依赖.md)、[随包声明](Resources/ThirdPartyNotices.txt)和[完整许可文本](Resources/VoiceLicenses)。

感谢 [NextProto 录音卡开放协议](https://github.com/nextproto1024/ai-recorder-card-open-protocol)、[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)、[3D-Speaker](https://github.com/modelscope/3D-Speaker)、[ONNX Runtime](https://github.com/microsoft/onnxruntime)和[Silero VAD](https://github.com/snakers4/silero-vad)。
