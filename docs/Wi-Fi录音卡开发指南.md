# Wi-Fi 录音卡开发指南

本文适用于工作留声接入的 B3085 / FW925。实时传声走低功耗蓝牙（BLE），完整录音在机身保存后通过 Wi-Fi 热点下载。使用者的设置和操作见[使用指南](使用指南.md)。

## 证据到哪一步

| 项目 | 已有证据 | 下一步要确认的事 |
| --- | --- | --- |
| 真机实时通道 | 2026-11-17 通过蓝牙控制 FW925 开录和保存。5.22 秒样本收到 134 条 B0B3 通知，共 22,968 字节，按原始通知边界回放成功，261 个音频包均通过 final range 校验。 | 中途连接、暂停恢复，以及长录音连续性。 |
| 真机录音文件 | 检查过的设备文件采用大端包长、Opus final range 和音频载荷。样本中有 80 字节 / 20 ms 的单声道包。7 份历史设备原件转出的 WAV 与独立参考文件逐份一致。 | 把同一次机身录音的蓝牙片段与完整原件对齐，核对开头、末尾、暂停和中途接入。文件包长不能直接推定为实时通知包长。 |
| 工作留声识别 | 11 月 17 日用机身按键录制三句真人口述。断句调整后的 22.68 秒样本得到三条独立定稿，每条都有回听音频，文字仍有误识。 | 用长录音检查缺口，与同次 Wi-Fi 原件核对。真实会议的文字与声纹准确率仍需独立评估。 |

## 按问题定位源码

| 从哪里开始 | 负责什么 |
| --- | --- |
| [CardObserver](../Sources/WorkdayMac/Device/CardObserver.swift)、[WiFiCardSession](../Sources/WorkdayMac/Device/WiFi/WiFiCardSession.swift) | 根据实际 GATT 服务选驱动。B0B1 写命令，B0B2 收控制帧，B0B3 收实时音频，B0B4 是文件通知。工作留声的原件同步走 Wi-Fi TCP。 |
| [CardState](../Sources/WorkdayCore/Device/CardState.swift) | 处理成功的开始、结束、暂停、恢复应答及 key 5 状态查询。初次连上已经在录音的卡会初始化音频处理；从空闲进入录音或收到明确开录事件才触发页面跳转。 |
| [WiFiLiveAudio](../Sources/WiFiRecorderCore/WiFiLiveAudio.swift)、[RecorderOpusDecoder](../Sources/WiFiRecorderCore/RecorderOpusDecoder.swift) | 识别候选封装，校验单声道和包时长，维护连续解码状态。暂停、结束、断连或坏包形成音频边界，避免把两段声音接到同一个解码状态。 |
| [AppModel](../Sources/WorkdayMac/App/AppModel.swift) | 两类卡通过同一个 `card.onAudio` 把音频交给电平、本机和可选云端字幕、实时声纹。字幕回听使用收到的实时片段。 |
| [WiFiRecordingSync](../Sources/WorkdayMac/Device/WiFi/WiFiRecordingSync.swift)、[WiFiArchive](../Sources/WorkdayCore/Archive/WiFiArchive.swift) | 确认卡空闲后申请热点。下载收到结束标记且长度吻合才提交完整文件，归档保留 `device.bin` 与 `original.wav`。当前缺少可信录制日期，归入「日期未知」。 |

**FW925 真机样本。** 本次通知长度为 253、6 或 187 字节。连续拼接后，每个记录由 8 字节包头和 80 字节单声道 Opus 载荷组成，每包 20 ms，音频净码率为 32 kbit/s。保存应答报告的文件大小与收到的总字节数相同；同次卡内原件的内容仍待独立下载比对。调试时应保留通知边界，并按长度字段解析，避免把一次回调当成一个 Opus 包。

**实时包的判断。** 裸包候选要求单个通知恰好承载一个 40 或 80 字节 Opus 包，并通过包头、采样数与解码检查。本次真机样本使用 4 字节大端包长和 4 字节大端 final range，可跨多个通知拼包，也可从一次通知中拆出多包。final range 用于比对编解码器的区间终值。B0B2 的控制帧 CRC 单独在控制通道校验。

**与旧卡共用的时间轴。** 字幕和声纹入口以 40 字节代表 20 ms。兼容包可原样传递，其他已识别的包先解码为 16 kHz 单声道 PCM，再重编码为 16 kbit/s Opus。为保持预测状态，开始重编码后，同一连续片段余下的数据使用同一个编码器。录后 WAV 直接从设备文件解码，不经过这次实时转换。[旧卡协议](录音卡协议.md)

## 下一次真机联调

1. **先观察一段机身录音。** 在 Mac 保持原网络的情况下订阅蓝牙，确认 B0B3 已开启。用机身按键开始，说一段可辨认的短句，然后保存。保留逐条通知的边界、数量和长度，同时记下开始和保存的控制回复。尚未收到音频时，先区分通道订阅、机身录音状态与真实数据到达。
2. **再判断包格式。** 按原始通知边界回放样本。检查每次通知是否恰好是一包、是否含长度头、能否跨通知还原包，以及每包可解出多少采样。若格式与两种候选均不符，保存样本和第一个无法解释的偏移，从适配层补回归用例。采样工具自己添加的长度前缀不能当作设备协议头。
3. **让工作留声跑完整流程。** 用可辨认的短句再录一段，记录首次收音及字幕出现的时间，核对句子与回听。依次检查暂停、恢复、结束，以及机身先录音再连接 Mac。关注是否误开新录音、误跳页或把上段声音带到下一段。
4. **用原件对照。** 结束录音后通过 Wi-Fi 同步同次原件，用解码后的波形和语音内容核对蓝牙片段起止与缺口。走过重编码的片段不应以 Opus 字节逐字节相等作为验收条件。分别记录设备连接、持续传声、字幕、原件保存与恢复网络的结果。

## 离线回归

在仓库根目录运行以下命令。脚本默认将结果写入仓库外，可用 `WORKDAY_ARTIFACTS` 指定这次运行的输出目录。

```sh
./script/test.sh --filter WiFiLiveAudioTests
./script/test.sh --filter WiFiDecoderTests
./script/test.sh --full
./script/build_and_run.sh --build-only
```

普通定向运行覆盖坏包、分片、暂停恢复和归档解码。中文端到端用例在 `--full` 下读取 `fixtures/apple/card.opusraw`；单独运行时可设置 `WORKDAY_APPLE_SPEECH`。将 `WORKDAY_WIFI_SAMPLES` 指向同时含有 `Recordings/` 和 `Decoded/` 的历史样本根目录，可在完整验收时复核 7 份参考 WAV。真机采样、原音频和日志留在仓库外的本次验证目录。测试入口见[实时链路回归](../Tests/WiFiRecorderCoreTests/WiFiLiveAudioTests.swift)与[归档对照回归](../Tests/WiFiRecorderCoreTests/WiFiArchiveTests.swift)。
