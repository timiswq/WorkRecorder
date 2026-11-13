# 工作留声

配合 QS668 / CB08 录音卡使用的原生 macOS 应用：接收实时字幕、归档完整录音、逐句回听、识别熟人，并按日期整理事项。

当前开发基线为 **0.6.0（20260005）**，Git 标签为 `baseline-2026-11-13`。后续版本从本仓库 `main` 继续，现有资料库格式和 App 标识保持兼容。[基线范围与验收边界](docs/项目基线.md)

## 使用与维护

- [使用指南](docs/使用指南.md)：归档、字幕、声纹、事项整理、资料库备份。
- [开发指南](docs/开发指南.md)：目录职责、构建测试、调试方法和维护约定。
- [录音卡使用指南](docs/录音卡使用指南.md)：连接、按键、USB 和实机对照。
- [录音卡协议与 SDK](docs/录音卡协议.md)：帧格式、命令表和接入边界。

## 开发入口

打开 `WorkRecorder.xcodeproj`，选择 **WorkRecorder → My Mac**。部署目标为 macOS 14，当前打包脚本交付 Apple Silicon 本地签名测试版。

```sh
./script/build_and_run.sh --build-only
./script/test.sh
./script/test.sh --full
./script/package_dmg.sh
```

默认构建输出位于仓库外的 `~/Documents/CodexArtifacts/WorkRecorder/开发构建/`，验收样本位于同级 `fixtures/`。可分别用 `WORKDAY_ARTIFACTS` 和 `WORKDAY_FIXTURES` 覆盖。完整验收所需样本、系统语音模型和限制见[开发指南](docs/开发指南.md)。

用户资料库默认为 `~/Documents/工作留声/`。清理开发产物时保留真实资料库、钥匙串和账号设置。
