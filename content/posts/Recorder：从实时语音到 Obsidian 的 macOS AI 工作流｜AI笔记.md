---
title: "Recorder：从实时语音到 Obsidian 的 macOS AI 工作流｜AI笔记"
date: '2026-07-13T12:00:00+08:00'
tags: ["AI", "macOS", "SwiftUI", "ASR", "DeepSeek", "Obsidian"]
author: "Me"
showToc: true
TocOpen: false
draft: false
hidemeta: false
comments: false
disableHLJS: false
disableShare: false
hideSummary: true
searchHidden: true
ShowReadingTime: true
ShowBreadCrumbs: true
ShowPostNavLinks: true
ShowWordCount: true
ShowRssButtonInSectionTermList: true
UseHugoToc: true
cover:
    image: https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/2026/07/recorder-quiet-intelligence-cover-v2.png
    alt: "暖白纸张上的六根炭黑信号柱、杏橙光晕与水平细线"
    caption: ''
    hidden: false
---
一段语音真正变成“可用的知识”，中间并不只是调用两次 API。

麦克风产生的是连续、高频、格式不固定的音频缓冲；实时语音识别返回的是会反复修正的临时字幕；大模型输出是一段可能被网络切成任意大小的字节流；桌面应用则要求所有这些异步状态始终能被用户理解、暂停、重试和恢复。

Recorder 是我为这条链路开发的一款 macOS 原生应用。它把麦克风音频实时发送到阿里云 DashScope 完成 ASR，再由用户主动调用 DeepSeek，把口语转录整理成更适合阅读的讲稿，最后保存历史或导出到 Obsidian。

这篇文章不按源码文件逐个讲解，而是沿着一段声音的旅程，拆解 Recorder 最关键的工程选择：为什么音频以约 100ms 为一块发送，怎样同时处理 partial 与 final，SSE 为什么不能“按行读一次就算完”，以及 Swift Concurrency 如何把音频、WebSocket、LLM 和 UI 收进同一个可控状态机。

> 本文以 2026 年 7 月 13 日的实际代码为准。当前项目约 5,263 行 Swift，23 项自动测试全部通过。

## 为什么要做 Recorder

很多语音转写工具解决的是“把声音变成字”，但我的真实需求更接近一条个人知识工作流：

1. 说话时能立即看到识别结果，及时发现麦克风或网络问题；
2. 结束后保留原始转录，不让大模型覆盖第一手材料；
3. 需要时再调用大模型，把口语、重复和断句整理成书面文本；
4. 结果能进入 Obsidian，而不是困在某个云端产品里；
5. API Key、历史和目录权限遵循 macOS 原生的安全边界。

因此，Recorder 没有把“录音结束”设计成一个黑盒按钮。用户能看到准备、连接、转录、暂停、结束、润色和导出的每一个阶段；原文与润色稿也始终是两份独立数据。大模型失败不会损坏原文，导出失败也不会影响本地历史。

## 从用户视角看完整流程

![Recorder 实际应用界面](https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/2026/07/recorder-main-window-actual.png)

上图是 Recorder 当前 SwiftUI 界面的实际渲染结果。截图来自使用独立 Bundle ID 启动的干净实例，没有读取真实历史、API Key 或个人目录。

主窗口使用 `NavigationSplitView`：左侧管理历史会话，右侧显示当前转录或历史详情。当前会话区域分成状态操作、实时转录和润色结果三部分。应用还提供 `MenuBarExtra` 菜单栏入口，因此主窗口关闭后，录音控制仍然可用。

一次典型使用过程如下：

```text
填写 API Key 与 Obsidian 目录
        ↓
点击开始，授权麦克风
        ↓
实时显示识别中的句子和已定稿句子
        ↓
暂停 / 继续 / 结束
        ↓
检查原始转录
        ↓
手动调用 DeepSeek 润色
        ↓
复制、保存历史或导出 Obsidian
```

这里有一个有意保留的动作：**结束录音后不会自动润色**。用户可以先检查转录质量，再决定是否产生模型费用、是否把完整文本发送给 DeepSeek。这个小小的交互选择，让识别与生成的错误边界变得非常清晰。

## 整体架构：让 UI 不理解协议细节

![Recorder 总体架构](https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/2026/07/recorder-architecture.png)

Recorder 采用“视图—编排器—状态—服务”的分层方式。

| 层级 | 主要职责 |
| --- | --- |
| SwiftUI 视图 | 展示状态、接收点击、提供复制和导出反馈 |
| Coordinator | 串联密钥读取、权限、网络、采集、停止和重试 |
| TranscriptStore | 保存当前业务状态、定稿段落、临时句与润色稿 |
| Service / actor | 处理音频、WebSocket、SSE、历史与文件写入 |
| macOS 系统服务 | Keychain、Sandbox、Application Support、目录授权 |

视图层不会直接建立 WebSocket，也不解析 DashScope JSON；网络服务不知道某个按钮长什么样，更不会 import SwiftUI。四个对象构成主要编排层：

- `TranscriptStore` 是页面的单一事实来源；
- `RecordingCoordinator` 组织录音、识别、暂停与结束；
- `PolishCoordinator` 组织 DeepSeek 请求、重试和 Obsidian 导出；
- `SessionHistoryCoordinator` 管理会话 ID、历史列表和本地文件。

底层能力都通过协议暴露，例如 `AudioCapturing`、`ASRSession`、`PolishServing` 和 `PolishHTTPTransport`。这样做的价值不只在“代码整洁”：测试可以注入假的音频块、WebSocket 消息和 SSE 数据，不必真的上传音频或消耗模型额度；未来更换服务商时，也不需要重写整套界面。

## 第一段旅程：把麦克风变成稳定的 100ms 音频块

Mac 的输入设备并不保证统一格式。不同麦克风可能提供 44.1kHz 或 48kHz、浮点或整数、单声道或多声道音频。如果客户端把某一种硬件格式写死，换一台机器就可能出现失真、速度异常甚至完全没有声音。

Recorder 先从 `AVAudioEngine.inputNode` 读取设备的真实输出格式，再交给 `AVAudioConverter`，统一转换成识别服务需要的格式：

```text
采样率：16,000 Hz
声道：1（单声道）
样本：Int16
每块：1,600 帧
每帧：2 字节
每块：3,200 字节 ≈ 100ms
```

计算很直接：

```text
1,600 frames × 2 bytes/frame = 3,200 bytes
1,600 frames ÷ 16,000 frames/s = 0.1s
```

为什么是约 100ms？块太大，用户要等更久才能看到字幕；块太小，网络消息数量、调度开销和状态切换都会增加。100ms 是实时感和工程成本之间相对稳妥的折中。

转换后的字节不会立刻零散发送，而是先进入 `pendingData`。只要累计到 3,200 字节，就形成一个完整块，通过 `AsyncStream<Data>` 交给识别链路。

停止录音时还有一个容易被忽略的细节：转换器内部可能仍缓存着句尾音频。Recorder 会给 converter 发送 end-of-stream，有限次冲刷尾部数据，最后把不足 3,200 字节的残块也发出去，然后才结束音频流。少了这一步，最常见的问题不是崩溃，而是最后几个字悄悄消失。

## 第二段旅程：WebSocket 不只是“连上后发音频”

当前版本使用 DashScope `paraformer-realtime-v2`，通过双向 WebSocket 一边上传 PCM，一边接收识别事件。真正可靠的实现必须管理一套协议生命周期：

```text
idle
  → connecting
  → awaitingTaskStart
  → streaming
  → finishing
  → finished
            ↘ failed
```

启动时，`RecordingCoordinator` 会先建立 ASR 会话、发送 `run-task`，并等待服务端返回 `task-started`。只有任务确认就绪后，应用才启动麦克风采集。

这个顺序是刻意的。如果先打开麦克风，再等待网络任务，开头那段音频就需要额外缓存；缓存策略稍有疏忽，用户说出的第一句话便可能没有去处。

结束时也不是简单关闭 socket。应用先停止采集并发送完尾部音频，再发送 `finish-task`；此后仍保持接收，因为云端可能还会返回最后几条定稿结果。直到收到 `task-finished`，这轮会话才真正结束。

## partial 与 final：实时字幕为什么会“改口”

流式 ASR 常见两类结果：

- `partial` 是模型当前最可能的临时句子，后续可能变化；
- `final` 是服务端确认完成的句子，应当稳定保留。

假设用户说“我想做一个语音记录工具”，识别过程可能依次返回：

```text
我想
我想做一个
我想做一个语音记录
我想做一个语音记录工具。
```

如果把每条 partial 都追加到正文，页面会出现大量重复内容。Recorder 的策略是：partial 始终整句替换；final 到达时，将其追加到 `finalSegments`，同时清空当前 partial。界面因此只有一行正在变化的临时文字，以及一组已经稳定的段落。

事件解析器还会检查 `task_id`，忽略空心跳，对 `task-failed` 产生明确错误；遇到未知事件名则记录事件类型后跳过。这种处理既避免其他任务的消息污染当前会话，也为供应商增加新事件保留一定向前兼容性。

暂停同样值得说明。Recorder 的“暂停”不是让一个 WebSocket 永久悬挂：它会停止音频、完成当前 ASR 任务并进入 `paused`；继续时新建识别任务，但保留之前的定稿段落。这样资源生命周期更可控，代价是恢复时需要一次短暂重连。

## 第三段旅程：用 SSE 接收 DeepSeek 正式输出

识别结束后，用户可以手动开始润色。当前请求允许模型启用 thinking，但界面、历史和日志只消费正式的 `content`，不会展示或保存 `reasoning_content`。

大模型的流式响应使用 SSE。它看起来像一行行 `data:`，但底层网络读取并不承诺“一次回调正好是一行”。一个 JSON 可能被切成三段，也可能一次读到多条事件。如果直接把每次收到的数据当成完整 JSON 解码，网络状况一变化就会随机失败。

`DeepSeekSSEParser` 因此维护自己的字节缓冲区：

1. 将新到的数据追加到缓冲区；
2. 只取出已经出现换行符的完整 SSE 行；
3. 忽略空行、注释和非 `data:` 行；
4. 解码 `choices[0].delta.content` 并逐段输出；
5. 收到 `[DONE]` 后确认流正常结束；
6. 若 JSON 损坏、没有正式内容或缺失 `[DONE]`，报告协议错误。

润色时采用“完整结果才算成功”的数据策略。新请求开始会清空旧结果；如果中途断网，半截润色稿也会被清空，但原始转录不受影响，用户可以修改 Key、Prompt 或网络环境后重试。

这看起来比保留部分输出更保守，却更适合一份准备导出的文稿：用户不需要猜测屏幕上的文字究竟是完整答案，还是因为请求中断而停在半句话。

## 状态机：业务阶段与短期操作分开

![Recorder 状态机](https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/2026/07/recorder-state-machine.png)

`TranscriptState` 只描述用户可理解的业务阶段：

```swift
idle
recording
paused
polishing
done
error(String)
```

但点击“开始”后，应用还要读 Key、请求麦克风权限、连接 ASR，这些步骤完成前不能立刻宣称已经在录音。为此，Coordinator 还维护 `starting`、`pausing`、`resuming`、`stopping`、`polishing`、`exporting` 等短期 operation。

状态回答“用户现在处于哪个阶段”，operation 回答“是否有一个不可重复的异步动作正在途中”。按钮禁用、进度指示和菜单栏命令都同时参考这两类信息，于是可以避免双击开始、重复结束或导出过程中再次导出。

这个拆分是项目中最值得复用的设计之一。很多异步 UI 的复杂度，并不是状态太多，而是把稳定业务状态和短暂执行状态混在了一起。

## Swift Concurrency 如何把不同节奏接起来

Recorder 同时面对三种完全不同的数据节奏：麦克风每隔很短时间产生缓冲；WebSocket 双向交换音频和识别事件；HTTP 连接单向返回模型文本。项目用 `AsyncStream` 把回调式 API 转为可顺序阅读的异步代码：

```text
麦克风 → AsyncStream<Data> → RecordingCoordinator → ASRClient
ASRClient → AsyncStream<ASREvent> → RecordingCoordinator → TranscriptStore
DeepSeek → AsyncThrowingStream<String> → PolishCoordinator → TranscriptStore
```

所有直接驱动 UI 的对象都运行在 `@MainActor` 上，确保状态变化与 SwiftUI 刷新一致。音频引擎、WebSocket、HTTP 传输、历史存储和 Obsidian 导出则分别使用 actor 隔离内部可变状态。

当消费任务取消时，stream 的 `onTermination` 会继续取消底层网络或采集任务。这样“用户关闭窗口”“请求失败”和“主动取消”不会轻易留下仍在后台运行的孤儿任务。

## 历史、Keychain 与 Obsidian：数据应该待在哪里

Recorder 没有使用数据库。每个成功结束的会话都是 Application Support 下的一个独立 JSON 文件，包含 UUID、时间、原始定稿段落和可选润色稿。文件使用原子写入，单个文件损坏时会被跳过，不阻塞其他历史。

选择 JSON 的理由很朴素：当前数据结构小、关系简单、按会话独立读写，不需要查询引擎。它也让迁移和故障排查更直观。代价是历史正文没有额外加密，因此高敏感场景仍需增加“不保存历史”、自动清理或本地加密能力。

API Key 不进入 JSON、UserDefaults 或日志，而是存入 macOS Keychain。App Sandbox 只申请四类能力：音频输入、网络客户端、用户选定目录读写，以及沙箱本身。没有辅助功能、输入监听或全磁盘访问。

Obsidian 目录由用户通过系统文件选择器授权，应用保存 security-scoped bookmark。每次导出时临时访问该目录，写完立即释放授权。生成的 Markdown 同时保留润色稿和原始转录，让知识库中的结果仍然可以追溯。

需要明确的数据边界是：麦克风 PCM 会发送给 DashScope；只有用户点击润色后，完整原文与 Prompt 才会发送给 DeepSeek；本地历史不会由 Recorder 主动同步，但用户自己的 iCloud、Git 或其他 Vault 同步方案仍可能同步导出内容。

## 23 项测试主要在证明什么

流式应用不能只靠“点几次看起来能用”。Recorder 的自动测试不连接真实云服务，而是用 fake transport、协议 fixture 和任意分块数据覆盖关键边界：

| 测试方向 | 主要验证内容 |
| --- | --- |
| 实时 ASR | endpoint、run/finish 消息、partial/final、任务生命周期、暂停保留文本 |
| DeepSeek | 请求结构、SSE 任意分块、忽略 reasoning、HTTP 错误、重试 |
| Obsidian | Markdown 生成、重名文件处理、目录授权失败 |
| 本地历史 | JSON 创建更新、排序、损坏隔离、删除、空会话不保存 |
| 应用集成 | 主窗口与菜单栏命令在各种 state/operation 下是否一致 |

自动测试的价值是稳定、快速、无费用，也不会上传真实音频。但它不能证明麦克风声音是否清晰、云服务字段是否临时变化、真实网络延迟是否可接受。因此项目仍保留人工验收：真实识别、错误 Key、断网、流式润色、历史恢复、菜单栏和 Obsidian 导出都需要在发布前走一遍。

截至本文对应版本，测试结果为：

```text
Executed 23 tests, with 0 failures
** TEST SUCCEEDED **
```

## 这次开发留下的几条工程经验

第一，**先让服务就绪，再打开数据源**。不论是音频、摄像头还是传感器，只要上游数据会持续产生，就应先确定下游能够接收，否则必须承担缓存、丢弃和背压的额外复杂度。

第二，**流式协议永远按字节流设计，不按“回调次数”设计**。WebSocket 的业务消息有边界，但 SSE 所依赖的 HTTP 字节读取未必有。解析器必须显式维护缓冲区，并测试一条事件被任意切分的情况。

第三，**把 partial 当临时状态，不当历史数据**。临时结果的意义是改善实时感，不应污染最终文本或持久化记录。

第四，**状态机与操作锁是两回事**。业务状态保持少而稳定，operation 处理按钮防重入，UI 才不会被“正在连接”“正在停止”这类瞬态塞满。

第五，**AI 失败必须可回退到非 AI 结果**。Recorder 的原始转录是一等数据，大模型润色只是可选增强。即使 DeepSeek 不可用，录音与识别成果仍然完整存在。

第六，**隐私不是一句“数据保存在本地”**。音频发给谁、文本何时发出、Key 放在哪里、日志记录什么、目录如何授权，都应该逐项说明，并让用户在关键动作上拥有主动选择。

## 当前限制与下一步

Recorder 已经走通完整主链路，但它仍是一款面向个人使用的 1.0 工具。当前主要边界包括：

- 离线时无法识别或润色；
- ASR 断线后不会自动重连并补传音频；
- 暂停后继续需要新建识别任务；
- 长文本还没有分段润色与失败续跑；
- 历史正文没有额外加密或自动清理；
- 多人会议没有说话人分离；
- 为减少高权限能力，没有实现全局快捷键；
- 主视图继续扩展前，适合拆成更小的 SwiftUI 组件。

下一步最有价值的方向不是堆更多模型，而是提高工作流的韧性：长文本分段、ASR 重连、本地隐私模式、历史保留策略，以及可替换的 ASR/LLM Provider。现有协议边界已经为这些演进留下了空间。

## 结语

Recorder 表面上是一条“语音识别 + 大模型润色”的 AI 链路，真正的工程核心却是协调四种节奏：高频音频缓冲、双向 WebSocket、单向 SSE，以及必须保持一致的 UI 与本地历史。

项目最终采用 `AsyncStream` 连接数据流，用 actor 隔离底层状态，用 Coordinator 编排业务步骤，用 `TranscriptStore` 为界面提供单一事实来源，再以 Keychain、Sandbox、最小日志和用户主动润色明确数据边界。

如果要把这套设计压缩成三条维护原则，就是：**让状态机驱动 UI，用协议隔离外部服务，任何时候都不要把密钥或正文写进日志。**
