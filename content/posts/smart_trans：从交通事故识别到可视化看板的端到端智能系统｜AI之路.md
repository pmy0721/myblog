---
title: "smart_trans：从交通事故识别到可视化看板的端到端智能系统｜AI之路"
date: '2026-02-04T20:04:05+08:00'
tags: ["smart_trans", "多模态", "LLM", "RAG", "YOLO", "MCP", "FastAPI", "React", "SQLite", "可视化"]
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
    image: https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/image129.png
    alt: ''
    caption: ''
    hidden: false
---
# smart_trans：从交通事故识别到可视化看板的端到端智能系统

`smart_trans` 是一个交通事故智能分析系统：输入事故现场图片，输出结构化事故记录（JSON）。系统支持 YOLO 标注增强视觉线索，使用多模态 LLM 进行事实抽取，并通过本地规则与轻量 RAG 实现确定性归类。数据可入库至 FastAPI + SQLite 后端，并通过 React 仪表盘进行可视化展示，基于MCP实现远程收图触发pipeline和蜂鸣器告警。

本文档基于完整代码走读，详细说明系统的端到端数据流、关键模块设计，以及后续工程化改进方向。

**项目地址：** [smart_trans](https://github.com/pmy0721/smart_trans)

## 1. 设计亮点

### 亮点一：端到端闭环 + MCP 联动物联网告警

`smart_trans` **不只是一个分析脚本，而是完整的产品形态**：

- **输入侧**：MCP SSE 接收图片，支持局域网内任意设备发图
- **处理侧**：YOLO 标注 → LLM 抽取 → 规则决策 → 数据入库
- **输出侧**：React 大屏可视化 + 蜂鸣器实时告警

使用MCP 把"收图触发流水线"和"外设告警"都封装成远程可调用的工具接口，实现了 **从图片到告警到大屏的全链路自动化**。

### 亮点二：LLM 只做事实抽取，规则引擎做最终决策

**传统方案的痛点**：让 LLM 直接输出"事故类型"和"严重程度"，结果不稳定、不可解释、难复现。

本项目创新：

- LLM 只负责输出"可见事实"（碰撞证据、车辆数、是否翻车等 17 个结构化字段）
- 最终的 `accident_type` 和 `severity` 由基于RAG构建的**本地规则引擎**根据可见事实确定
- 规则可版本化、可追溯、可调试

通过 **"关注点分离"** 设计，把模型擅长的**视觉理解**和规则擅长的**确定性决策**分开，各司其职。

## 2. 系统架构

### 2.1 数据流总览

| 阶段 | 输入 | 处理 | 输出 |
| --- | --- | --- | --- |
| **① 图片接收** | 事故现场图片 | MCP SSE 接收
`mcp_image_server.py` | 落盘至 `incoming/` |
| **② 视觉增强** | 原始图片 | YOLOv11 标注
`pipeline_yolo_rag.py` | 标注图 `output/*.jpg` |
| **③ 事实抽取** | 图片（原始/标注） | LLM 多次运行 + 结果聚合
`traffic_issue_analyzer.py` | 可见事实 JSON |
| **④ 规则决策** | 可见事实 JSON | 本地规则引擎 + 知识检索
`rag/rules.json`  • `knowledge.md` | `accident_type`  • `severity`  • trace |
| **⑤ 数据入库** | 结构化记录 | FastAPI 后端
`POST /api/uploads`  • `/api/accidents` | SQLite 持久化 |
| **⑥ 告警触发** | `has_accident=true` | MCP 蜂鸣器服务 `beep_mcp_server.py` | 根据事故严重程度响铃 1-3 次 |
| **⑦ 可视化** | SQLite 数据 | React + ECharts + Leaflet
`frontend/` | Dashboard 大屏 |

<aside>
📡

**端到端流程：**

图片 → MCP 接收 → YOLO 标注 → LLM 事实抽取 → 规则决策 → 入库 + 告警 → 大屏展示

</aside>

### 2.2 组件启动方式

根据需求选择启动相应组件：

| 需求场景 | 启动组件 |
| --- | --- |
| 仅获取 JSON 输出 | `traffic_issue_analyzer.py` |
| 入库 + 前端展示 | backend，frontend |
| 局域网图片接收 | `mcp_image_server.py` |
| 报警蜂鸣器 | `beep_mcp_server.py`（可由 pipeline 自动拉起） |

## 3. 核心模块说明

### 3.1 traffic_issue_analyzer.py

该模块是系统的智能核心，提供三种运行模式：

| 模式 | 说明 |
| --- | --- |
| `-task accident` | 直接让模型输出严格 JSON，本地做字段归一化 |
| `-task rag`（推荐） | 先抽取可见事实，多次运行聚合后由规则决策 |
| `-task label` | 旧版单标签输出，适用于简单演示场景 |

**RAG 模式工作流程：**

1. 使用 `_build_observation_prompt()` 让模型仅输出“可见事实”JSON
2. 多次运行（`-extract-runs`，默认 3 次，最多 7 次），聚合结果以降低抖动
3. 根据 `rag/rules.json` 的优先级规则做确定性决策（类型/严重程度）
4. 从 `rag/knowledge.md` 检索相关片段作为判定依据

**可见事实 JSON Schema（`_build_observation_prompt()`）：**

模型输出必须是一个且仅一个 JSON 对象，包含且仅包含以下字段（缺失也不能省略，要用默认值补齐）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `collision_evidence` | bool | 是否有明确碰撞/事故现场证据（明显受损、相互接触、翻车、撞护栏等）；不确定填 `false` |
| `vehicles_involved` | int (0-10) | 估计涉及车辆数量；看不清填 `0` |
| `collision_mode` | string | `rear_end` / `side` / `head_on` / `single_vehicle` / `unknown` |
| `rollover` | bool | 是否翻车/侧翻/四轮朝天 |
| `guardrail_collision` | bool | 是否撞护栏/隔离墩/路侧设施 |
| `pedestrian_involved` | bool | 是否涉及行人 |
| `non_motor_involved` | bool | 是否涉及非机动车（自行车/电动车/摩托车等） |
| `fire_or_smoke` | bool | 是否有明显火焰或浓烟 |
| `wrong_way` | bool | 是否有明确逆行线索；不确定填 `false` |
| `lane_blockage` | string | `none` / `partial` / `full` / `unknown`（占道/堵塞情况） |
| `damage_level` | string | `minor` / `moderate` / `severe` / `unknown`（基于可见变形/碎片/受损程度） |
| `scene_context_confidence` | number (0-1) | 仅用于“场景上下文判断”的置信度（例如逆行）；不确定填 `0` |
| `description_facts` | string | 1-3 句中文，只描述可见事实；不确定就说明不确定 |
| `location_text` | string|null | 地点/道路/地标简短描述；无法判断为 `null` |
| `lat` | number|null | 纬度 (-90 到 90)；无法判断为 `null`（若右上角有 Lat/Lng 水印要优先抄写） |
| `lng` | number|null | 经度 (-180 到 180)；无法判断为 `null`（同上） |
| `location_source` | string|null | `exif` / `watermark` / `model` / `hint` / `unknown`；无法判断为 `null`（若来自水印要用 `watermark`） |
| `location_confidence` | number (0-1)|null | 坐标/位置的置信度；无法判断为 `null` |

<aside>
⚠️

**重要约束：** 模型不应输出最终结论字段（如 `has_accident`、`accident_type`、`severity` 等），这些由本地规则引擎决定。

</aside>

**工程化特性：**

| 特性 | 说明 |
| --- | --- |
| 结果缓存 | 缓存目录：`.cache/smart_trans/accident_rag/`
Key 由 `sha256(image_bytes) + rules_version + extractor_version` 构成
图片与规则版本不变时可复用结果 |
| Trace 落库 | RAG 模式将 trace（observations、命中规则、检索片段、原始抽取输出）存入 `raw_model_output` 字段
后端允许最长 20000 字符，脚本做 18000 字符截断 |

### 3.2 规则引擎

`rag/rules.json` 本质上是两套可排序的规则表（事故类型、严重程度），用于对上游“可见事实”做确定性落地。

#### 3.2.1 规则结构

每条规则包含以下字段：

| 字段 | 说明 |
| --- | --- |
| `id` | 规则唯一标识（便于追踪/调试/回放解释） |
| `priority` | 优先级数值（越大越先匹配；按降序评估，命中第一条即确定结果） |
| `when` | 匹配条件（对“可见事实”字段做判定） |
| `set` | 命中后要设置的确定性输出值 |
| `note` | 规则说明/理由（作为可解释性证据文本，不参与计算） |

#### 3.2.2 `when` 条件表达式

| 表达形式 | 示例 |
| --- | --- |
| **直接等值/布尔** | `"rollover": true`、`"collision_mode": "rear_end"` |
| **数值比较** | `"vehicles_involved": {">=": 3}`、`"scene_context_confidence": {">=": 0.6}` |
| **集合包含** | `"lane_blockage": {"in": ["partial", "full"]}`、`"damage_level": {"in": ["moderate", "unknown"]}` |

**规则示例：**

```json
{ "id": "type_rollover", "when": { "rollover": true }, "set": "翻车", "priority": 104, "note": "翻车/侧翻事故" }
{ "id": "type_multi_vehicle", "when": { "vehicles_involved": { ">=": 3 }, "collision_evidence": true }, "set": "多车连环", "priority": 103 }
```

#### 3.2.3 决策域配置

每个决策域（`accident_type` / `severity`）还包含以下约束/兆底信息：

| 配置项 | 说明 | 示例 |
| --- | --- | --- |
| `allowed` | 允许输出的枚举集合 | `["rear_end", "追尾", "翻车", "多车连环", "其他"]` |
| `default` | 无规则命中时的兆底输出 | 类型默认 `"其他"`，严重程度默认 `"中等"` |
| `confidence` | 置信度计算用的 `base_*` 与 `weights`
（不是优先级匹配，但同属确定性产物） | `{"base_type": 0.7, "weights": {...}}` |

#### 3.2.4 规则知识

`rag/knowledge.md` 是给 RAG 模式用的“事故知识笔记”，检索采用 substring 计数的轻量实现（适用于中文短词），返回 top-k 片段作为 trace 的一部分。

**用途与设计目标：**

强调“最终 `accident_type` / `severity` 由本地规则确定（`rules.json`）”，RAG 只负责检索相关笔记/规则作为证据，提升可追溯性与解释性。

**事故类型知识（视觉线索/判别要点）：**

| 事故类型 | 可见线索 | 备注 |
| --- | --- | --- |
| 追尾 | 车辆同向、前车尾部/后车头部受损、接触位置在后方 |  |
| 侧面碰撞 | 车辆垂直/斜交、侧面受损、T 形或 L 形接触 |  |
| 对向相撞 | 车辆对向、双方头部严重变形 |  |
| 单车事故 | 仅一辆车、冲出路面/撞固定物 |  |
| 翻车 | 车辆侧翻/四轮朝天 |  |
| 撞护栏 | 车辆与护栏/隔离墩接触、护栏变形 |  |
| 行人事故 | 行人倒地/与车辆接触 | 优先级：行人 > 非机动车 |
| 非机动车事故 | 自行车/电动车/摩托车与机动车接触 |  |
| 多车连环 | ≥ 3 辆车、多个接触点 |  |
| 占道 | 车辆占据车道、导致拥堵 |  |
| 逆行 | 车辆行驶方向与车道方向相反 | 需要强场景上下文 |

**严重程度启发式：**

| 严重程度 | 强指标 |
| --- | --- |
| **严重** | 翻车、火烟、行人涉及、多车连环、严重变形、全幅封路 |
| **中等** | 明确碰撞但无强严重指标、两车事故、部分占道 |
| **轻微** | 轻微剐蹭、车辆可移动、无弱势交通参与者、无翻车/火烟 |

**置信度指导原则：**

| 方向 | 证据 |
| --- | --- |
| **提高置信度** | 强视觉线索（明显变形、翻车、火烟、接触点清晰） |
| **降低置信度** | 低清晰度、遮挡严重、仅拥堵无碰撞证据、场景模糊 |

### 3.3 pipeline_yolo_rag.py

该脚本将分析能力集成为完整流水线：

| 步骤 | 说明 |
| --- | --- |
| YOLO 标注 | vendored Ultralytics：`yolov11/ultralytics`
默认权重：`yolov11/best.pt`
输出目录：`output/` |
| 分析 | 调用 `analyze_accident_rag()` 或 `analyze_accident()` |
| 入库 | 通过 `_try_upload_image()`、`_try_post_accident()` 写入后端 |
| 蜂鸣器 | 触发条件：`-beep` 参数 + `-post` 参数 + POST 成功 + `has_accident=true`
严重程度映射为 1/2/3 次蜂鸣 |

### 3.4 后端服务（backend/）

基于 FastAPI + SQLite 构建，提供以下接口：

| 类型 | 接口 |
| --- | --- |
| 上传 | `POST /api/uploads`（落盘至 `backend/uploads/`，解析 EXIF GPS） |
| 记录 | `POST /api/accidents`、`GET /api/accidents`、`GET /api/accidents/{id}` |
| 统计 | `GET /api/stats/*`（summary、by_type、by_severity、timeline、geo） |

**关键数据字段：**

- 位置信息：`location_text`、`lat`、`lng`、`location_source`、`location_confidence`
- 追溯信息：`raw_model_output`（trace / provenance）

**Schema 迁移机制：**

`ensure_sqlite_schema()` 在启动时检查表结构，缺失列时自动执行 `ALTER TABLE` 补充。

### 3.5 前端应用（frontend/）

基于 React + Vite 构建，包含以下页面：

| 页面 | 功能 |
| --- | --- |
| Dashboard | ECharts 图表（类型分布/时间线/严重程度饼图）+ Leaflet 地图热区 |
| Accidents | 筛选（severity、has_accident）+ 分页表格 |
| Detail | 图片展示、字段详情、Copy JSON、单点地图 |

**部署方式：**

- 开发模式：`vite` 代理 `/api` 和 `/uploads` 至后端
- 生产模式：构建输出至 `backend/static/`，后端提供 SPA fallback，实现单端口部署

### 3.6 MCP 服务（跨进程/跨机器工具调用）

MCP（Model Context Protocol）在本项目中主要承担**跨进程/跨机器的工具调用与事件触发**作用，核心场景包括：

#### 3.6.1 图片上报/接收与自动触发流水线

`mcp_image_server.py` 使用 FastMCP 以 SSE 方式暴露以下工具：

| 工具 | 说明 |
| --- | --- |
| `upload_image` | 接收 base64 图片，落盘至 `incoming/<timestamp>/`，触发子进程执行 `pipeline_yolo_rag.py` |
| `get_job` | 查询指定 job 的状态与结果 |
| `list_jobs` | 列出所有 job |

任意设备可通过客户端 `send_images_mcp.py` 调用 `upload_image` 把图片发送到接收机，每张图对应一个 job，并发数通过 semaphore 控制（`SMART_TRANS_PIPELINE_MAX_CONCURRENCY`）。

#### 3.6.2 任务编排与可观测性

MCP 接收端将 job 相关信息持久化，便于轮询查询与排障：

| 存储位置 | 内容 |
| --- | --- |
| `incoming/jobs/<job_id>.json` | Job 元数据、状态、解析到的 result |
| `incoming/job_artifacts/<job_id>/` | `pipeline.stdout.txt`、`pipeline.stderr.txt` 日志文件 |

客户端 `send_images_mcp.py` 支持批量发送与 `--wait` 轮询 job 状态。

#### 3.6.3 蜂鸣器/物联网告警的工具化接口

`beep_mcp_server.py` 将华为云 IoTDA 的蜂鸣器控制封装为 MCP 工具 `set_beep`（SSE）。

**触发流程：**

1. `pipeline_yolo_rag.py` 在入库成功且 `has_accident=true` 时
2. 通过 `llm_mcp_client.py` 的 `beep_n()` 连接蜂鸣器 MCP 服务
3. 根据严重程度响铃（轻微 1 次 / 中等 2 次 / 严重 3 次）

#### 3.6.4 LLM 调用 MCP 工具

`llm_mcp_client.py` 中的 `AlarmAssistant` 演示了 **LLM function calling + MCP tool** 的模式：

- 通过 `list_tools` 获取可用工具列表
- 通过 `call_tool` 执行工具调用
- 让模型自主决定何时调用 `set_beep`

目前主流程仍以脚本规则触发 beep 为主，LLM 调用模式作为扩展演示。

#### 3.6.5 小结

MCP 在本项目中将**收图触发 pipeline** 和**外设告警（蜂鸣器）**都封装为可通过 SSE 远程调用的工具接口，从而实现：

- 局域网自动化联动
- 可追踪的异步任务执行
- 统一的工具调用协议

## 4. 快速开始

### 4.1 安装依赖

```bash
python3 -m pip install -r requirements.txt
```

### 4.2 配置环境变量

创建 `.env` 文件：

```bash
SILICONFLOW_API_KEY=your_key
SILICONFLOW_BASE_URL=https://api.siliconflow.cn/v1
SILICONFLOW_MODEL=Qwen/Qwen3-VL-235B-A22B-Instruct
```

### 4.3 单图分析

```bash
python3 traffic_issue_analyzer.py -i input_image/image1.jpg --task rag
```

### 4.4 启动服务

启动后端：

```bash
PYTHONPATH=backend uvicorn app.main:app --reload --port 8000
```

启动前端（开发模式）：

```bash
cd frontend
npm install
npm run dev
```

启动MCP服务（收图服务、告警设备）

```bash
python3 mcp_image_server.py --host 0.0.0.0 --port 9010

python beep_mcp_server.py
```

### 4.5 完整流水线

```bash
python3 send_images_mcp.py \
  --server http://<your ip>/sse \
  --pipeline-cli=--upload --pipeline-cli=http://localhost:8000/api/uploads \
  --pipeline-cli=--post --pipeline-cli=http://localhost:8000/api/accidents \
  --pipeline-cli=--beep \
  input_image/image1.jpg --wait

```