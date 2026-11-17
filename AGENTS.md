# 工作留声

本仓库是工作留声 App 的正式开发目录。源码修改、构建、测试和打包从这里执行。

- 默认直接在当前仓库开发，不使用 worktree 或 subagent；已有未提交改动须保留。
- 当前基线为 `baseline-2026-11-17`（0.7.0 / 20260006），后续从 `main` 继续。旧基线仅作历史追溯。
- Xcode 入口为 `WorkRecorder.xcodeproj`，scheme 为 `WorkRecorder`；工程配置文件为 `project.xcproj`。
- 启动入口在 `WorkRecorder/`；界面与协调在 `Sources/WorkdayMac/`，业务处理在 `Sources/WorkdayCore/`，二者按职责分目录；QS668 / CB08 协议在 `Sources/QS668Core/`，B3085 协议与音频适配在 `Sources/WiFiRecorderCore/`。
- 构建：`./script/build_and_run.sh --build-only`。测试：`./script/test.sh`；完整验收：`./script/test.sh --full`。
- 原型、截图、日志、下载、模型转换缓存与构建验证产物必须放在仓库外 `~/Documents/CodexArtifacts/WorkRecorder/`；设置 `WORKDAY_ARTIFACTS` 可覆盖输出目录。
- 完整验收样本默认为同级 `fixtures/`；设置 `WORKDAY_FIXTURES` 可覆盖。测试使用隔离资料库、后台窗口，不抢占前台焦点。
- 清理前确认文件归属与运行依赖；保留发布物、有效证据、必要样本、用户资料库与钥匙串。
- 当前使用方式见 README.md 和 `docs/使用指南.md`；目录、开发经验、验证方法见 `docs/开发指南.md`；能力与验收边界见 `docs/项目基线.md`。
- 以当前源码和正式文档为准，客观区分自动化验证、历史实验和真实硬件验收。
