# 工作留声

本仓库是工作留声 App 的开发目录。后续源码修改、构建、测试和打包均从本仓库进行。

- Xcode 入口是 `WorkRecorder.xcodeproj`，App scheme 是 `WorkRecorder`。命令行使用 `./script/build_and_run.sh --build-only` 和 `./script/test.sh`。
- 业务代码位于 `Sources/WorkdayMac` 和 `Sources/WorkdayCore`，本项目使用的协议库位于 `Sources/QS668Core`。
- 原型、截图、日志和构建验证产物放在仓库外的 `~/Documents/CodexArtifacts/WorkRecorder/`。

当前正式开发基点为本仓库的 `baseline-2026-11-11`（0.5.3 / 20260004）。日常改动从 `main` 继续，完整验收使用 `./script/test.sh --full`。README.md 维护当前使用方式、源码入口和构建步骤。
