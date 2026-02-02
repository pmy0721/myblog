---
title: "smart_trans：多模态交通事故分析｜AI之路"
date: '2026-01-29T17:10:47+08:00'
tags: ["多模态", "LLM", "RAG", "FastAPI", "React", "SQLite", "ECharts", "Leaflet", "可视化"]
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
lastmod: '2026-02-02T00:00:00+08:00'
---
smart_trans 是一个“从交通照片到事故结构化数据，再到可视化看板”的最小闭环项目：用多模态 LLM 识别事故信息，FastAPI + SQLite 落库并提供统计接口，React 仪表盘展示。

项目地址：

- https://github.com/pmy0721/smart_trans

## 目标与范围

这个项目实现三件事：

1. 输入：一张交通现场照片（jpg/png/webp 都可）。
2. 推理：调用多模态模型，得到“是否事故 / 类型 / 严重度 / 描述 / 置信度”的严格 JSON。
3. 归档与展示：把记录存入 SQLite，前端展示列表与统计图。

它不是一个“万能交通理解系统”，而是一个可跑通、可扩展、便于做产品化迭代的骨架。

## 总体架构

三段式：

- 离线/命令行：`traffic_issue_analyzer.py`
- 服务端：`backend/`（FastAPI + SQLAlchemy + SQLite）
- 前端：`frontend/`（React + Vite + ECharts）

![smart_trans 总体架构图](https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/smart_trans%E6%80%BB%E4%BD%93%E6%9E%B6%E6%9E%84.png)

_图：smart_trans 总体架构（脚本 → 后端 API/DB → 前端可视化）_

其中一个很实用的设计是“单端口部署”：前端打包产物输出到 `backend/static/`，最终只需要启动一个后端端口即可同时提供页面与 API。

## 脚本：从图片到严格 JSON

核心入口在 `traffic_issue_analyzer.py`。

- 通过 `data:image/...;base64,...` 把图片嵌入到请求里。
- 使用固定提示词，要求模型“只输出一个 JSON 对象，且字段必须严格匹配”。
- 对输出做容错：如果模型输出夹杂了说明文字，会尝试截取第一个 `{...}` JSON 片段解析。
- 统一归一化：`severity` 限定为 `轻微/中等/严重`，`confidence` clamp 到 `[0,1]`。

脚本默认走 `--task accident`（严格 JSON）；也保留了 `--task label` 的“单标签分类”模式，便于做更轻量的分桶。

最常用的调用方式：

```bash
python3 -m pip install -r requirements.txt

python3 traffic_issue_analyzer.py \
  -i input_image/image1.jpg \
  --upload http://localhost:8000/api/uploads \
  --post http://localhost:8000/api/accidents
```

脚本依赖的关键环境变量：

- `SILICONFLOW_API_KEY`：必填
- `SILICONFLOW_BASE_URL`：默认 `https://api.siliconflow.cn/v1`
- `SILICONFLOW_MODEL`：默认 `Qwen/Qwen3-VL-32B-Instruct`

## 脚本进阶：RAG 模式（确定性输出 + 可追溯证据链）

默认的 `--task accident` 依赖模型“直接给结论”，优点是简单，缺点是口径容易随模型输出波动。为了解决“稳定性 + 可解释性”这两个工程痛点，项目加入了 `--task rag`：

1) 先让模型只做“事实抽取”（不输出事故结论），多次运行后聚合为一份 `observations`。

2) 再用本地规则 `rag/rules.json` 根据 `observations` 以确定性方式产出 `accident_type/severity`（优先级命中）。

3) 最后从 `rag/knowledge.md` 做轻量检索，连同命中规则、抽取结果一起写入 `raw_model_output`，便于回放与排障。

![smart_trans RAG 结构图](https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/smart_transRAG%E7%BB%93%E6%9E%84%E5%9B%BE.jpeg)

_图：RAG 流程（事实抽取 → 聚合 observations → rules.json 决策 → knowledge.md 检索 → trace 写入 raw_model_output）_

示例：

```bash
python3 traffic_issue_analyzer.py \
  -i input_image/image1.jpg \
  --task rag \
  --extract-runs 3 \
  --upload http://localhost:8000/api/uploads \
  --post http://localhost:8000/api/accidents
```

成本控制：RAG 模式默认启用本地缓存（`.cache/smart_trans/accident_rag/`），可用 `--no-cache` 关闭，或用 `--refresh-cache` 强制重算。

### observations：事实抽取后的“可见事实”结构

在 `--task rag` 下，模型不会直接输出事故结论，而是输出一份“事实抽取 JSON”，脚本会做归一化并多次运行后聚合，最终形成 `observations`（写入 `raw_model_output` 的 trace 中）。

`observations` 字段包含：

- 碰撞/现场证据
  - `collision_evidence`：是否有明确碰撞/事故证据（受损、接触、翻车、撞护栏等）
  - `vehicles_involved`：0-10，涉及车辆数量估计
  - `collision_mode`：`rear_end/side/head_on/single_vehicle/unknown`
  - `rollover`：是否翻车/侧翻
  - `guardrail_collision`：是否撞护栏/隔离设施
  - `damage_level`：`minor/moderate/severe/unknown`

- 弱势交通参与者与危险线索
  - `pedestrian_involved`：是否涉及行人
  - `non_motor_involved`：是否涉及非机动车（自行车/电动车/摩托车等）
  - `fire_or_smoke`：是否有明显火焰或浓烟
  - `wrong_way`：是否有明确逆行线索
  - `scene_context_confidence`：0-1，仅用于需要场景上下文的判断（如逆行）

- 通行影响
  - `lane_blockage`：`none/partial/full/unknown`

- 可读描述（只写事实）
  - `description_facts`：1-3 句中文，只描述可见事实，不输出“事故类型/严重度”等结论

- 位置信息（可选）
  - `location_text`：地点/道路/地标文字线索或 null
  - `lat/lng`：坐标或 null（优先从右上角水印 `Lat:..., Lng:...` 抄写）
  - `location_source`：`exif/watermark/model/hint/unknown` 或 null
  - `location_confidence`：0-1 或 null

聚合方式（多次抽取 -> 一份 observations）：

- bool：多数投票
- 数值/车辆数：中位数
- 枚举：众数（并按偏好顺序打破平局）
- 坐标：中位数 + 合法范围校验；来源偏向 `watermark > exif > hint > model`

### rag/rules.json：确定性口径的规则配置

`rag/rules.json` 的作用是把“模型输出的不稳定事实”收敛为“稳定可回归的结论”。它包含三块：

1) `accident_type`

- `allowed`：允许输出的事故类型集合
- `rules`：规则列表（按 `priority` 从高到低命中第一条），每条规则形如：
  - `id`：规则标识
  - `priority`：优先级（越大越先命中）
  - `when`：条件（支持等值、范围 `>=/<=`、集合 `in`）
  - `set`：命中的输出值（例如 `追尾/侧面碰撞/...`）
  - `note`：说明
- `default`：默认值（通常为 `其他`）

典型规则（按优先级大致从高到低）：

- 行人/非机动车优先归类（弱势交通参与者优先级最高）
- 翻车/多车连环/对向相撞/撞护栏/追尾/侧面碰撞/单车事故等
- 逆行需要 `scene_context_confidence` 达到阈值才会判定
- 如果只是占道但没有碰撞证据，会判为 `占道`

2) `severity`

- `allowed`：`轻微/中等/严重`
- `rules`：同样的优先级命中机制
- 常见严重指标：行人、翻车、火烟、多车连环、严重变形、完全堵塞
- 无碰撞证据时会落到 `轻微`

3) `confidence`

- `base_if_accident/base_if_no_accident`：基础置信度
- `weights`：各特征加权（如翻车/火烟/行人/对向相撞/占道程度/损伤程度等）
- 还有保守上限：例如“无事故证据”时置信度上限会被压低，避免过度自信

这套设计的关键收益：结论稳定（规则决定口径），同时保留证据链（`observations + matched_rules + retrieved_notes`），方便排障与做离线评测。

## 后端：FastAPI + SQLite 的数据与接口

### FastAPI + SQLite：为什么这对组合适合做最小闭环

- FastAPI：基于 ASGI 的 Python Web 框架，天然适合做“API + 数据校验 + 文档”这一套工程闭环。
  - 类型标注 + Pydantic 模型：请求/响应结构天然可约束（本项目的 `AccidentCreate/AccidentRead` 就是这种模式）。
  - 自动 OpenAPI：接口文档与调试（Swagger / ReDoc）几乎零成本，适合快速迭代和对接前端。
  - 依赖注入（Depends）：数据库 session、鉴权、参数校验等横切逻辑更容易组织（本项目用 `get_db` 管理 session 生命周期）。

- SQLite：单文件数据库，零运维、可复制、可随项目一起跑起来，特别适合 demo/内网工具/原型验证。
  - 优点：启动成本极低（一个 `.db` 文件）、读多写少场景很顺手。
  - 局限：高并发写入能力有限；如果后续要上生产或多实例部署，一般会迁移到 Postgres/MySQL，并配合 Alembic 做迁移管理。

在本项目里，SQLite 由 SQLAlchemy 2.x 管理，默认库文件在 `backend/data/accidents.db`（可用 `SMART_TRANS_DB` 覆盖）。

后端主入口：`backend/app/main.py`。

- CORS：默认允许 `http://localhost:5173`（可用 `SMART_TRANS_CORS_ORIGIN` 覆盖）。
- 启动自动建表：`Base.metadata.create_all(bind=engine)`。
- 静态托管：
  - `/uploads`：上传图片目录
  - `/assets`：前端 build 产物
  - `/` + SPA fallback：让 React Router 在单端口下可用

### 数据模型

`backend/app/models.py` 里 `Accident` 表字段覆盖了“结果 + 证据 + 位置信息”的最小集合：

- 结果：`has_accident / accident_type / severity / description / confidence`
- 证据：`image_path`（相对路径 `uploads/<filename>`）+ `raw_model_output`（可选）
- 补充：`hint`、`source`
- 位置：`lat/lng/location_source/location_confidence/location_text`

时间字段 `created_at` 使用“北京时间的 naive datetime”存 SQLite（配合 `backend/app/utils.py` 里的 `now_bjt_naive()` / `as_bjt_aware()` 做转换）。

### Schema 演进兜底：ensure_sqlite_schema

Demo 阶段最常见的变化就是“加字段”。项目在 `backend/app/db.py` 里提供了 `ensure_sqlite_schema()`：如果 `accidents` 表已存在但缺少新列，会在启动时自动执行 `ALTER TABLE ... ADD COLUMN` 补齐（例如 `lat/lng/location_text/location_confidence/raw_model_output` 等）。

这让你可以先把闭环跑通，再逐步扩充字段；但如果要走长期演进，还是建议引入 Alembic 管理迁移。

### 上传接口：带 EXIF GPS 提取

`POST /api/uploads`（`backend/app/routes/uploads.py`）：

- 保存原始图片到 `backend/uploads/`。
- 返回 `image_path` 和可直接访问的 `image_url`。
- 尝试从 EXIF GPS 解析经纬度（`backend/app/utils.py:try_extract_exif_gps`），如果拿到就一并返回。

这个设计让“图片证据”和“结构化记录”能解耦：前端展示时只需要 `image_url`。

### 事故记录接口

`backend/app/routes/accidents.py`：

- `POST /api/accidents`：入库，会对严重度做一次兜底归一化。
- `GET /api/accidents`：支持分页和过滤（是否事故、严重度、类型、时间范围）。
- `GET /api/accidents/{id}`：详情。

### 统计接口

`backend/app/routes/stats.py`：

- `GET /api/stats/summary`：总数、近 7 天、严重数、严重占比
- `GET /api/stats/by_type`：按类型计数
- `GET /api/stats/by_severity`：按严重度计数（轻微/中等/严重顺序固定）
- `GET /api/stats/timeline?days=30`：按天的趋势点
- `GET /api/stats/geo?precision=2&limit=300`：按经纬度分桶聚合（用于地图散点/热力）

## 位置信息：从图片到可视化

位置字段在这个项目里是“可选但很关键”的一环：一旦有了可用的 `lat/lng`，统计和展示的表达力会立刻上一个台阶。

### 位置来源优先级（实践里的四条路）

从本次代码实现来看，位置大致有四种来源：

1. EXIF（优先且可靠）：`POST /api/uploads` 会尝试从图片 EXIF GPS 解析经纬度（如果图片本身带定位）。
2. 水印（可控且可造数据）：脚本提示词明确要求“如果右上角有 `Lat:..., Lng:...` 字样水印，则优先抄写”，并标记 `location_source=watermark`。
3. 模型推断（弱证据）：若图片出现明确路牌/地标，模型可在 `location_text` 给出文本线索，坐标可信度通常不高。
4. hint（人为补充）：脚本支持 `--hint` 作为辅助，但建议只当提示，不要当真值。

落库字段对应为：`location_text / lat / lng / location_source / location_confidence`。

### 工具：tools/stamp_coords.py 给图片“打坐标水印”

为了快速做 demo 数据集（尤其是地图统计），项目提供了 `tools/stamp_coords.py`：它会在图片右上角盖一个半透明水印，例如 `Lat: 23.162414, Lng: 113.241440`。

几个常用用法：

```bash
# 单张图片：默认原地覆盖（可加 --backup 先备份）
python3 tools/stamp_coords.py input_image/image4.jpg --backup

# 批量处理目录：生成 *_stamped 副本，不覆盖原图
python3 tools/stamp_coords.py --dir input_image --write-map
```

配合 `--write-map` 会生成一份坐标映射 JSON（例如 `coords_stamped.json`），方便做回放、对账、或后续评测。

### 统计补充：/api/stats/geo 的“分桶聚合”

`/api/stats/geo` 的实现方式非常“工程化”：不是返回每一条事故记录，而是先把经纬度按精度 round 成 bucket，再聚合计数。

- `precision`：保留小数位数（越大越细，bucket 越多）
- `limit`：最多返回多少个 bucket

```bash
curl "http://localhost:8000/api/stats/geo?precision=2&limit=300"
```

前端 Dashboard 地图展示的圆点，本质就是这些 bucket（点越大代表该区域聚合计数越高），非常适合“看分布”，而不是“看单条”。

## 前端：仪表盘 + 列表 + 详情

前端位于 `frontend/`：React Router 做路由，ECharts 做图。

另外，地图使用 Leaflet（React-Leaflet）。在 Vite 环境下，Leaflet 默认 marker 的图片路径经常会丢失，因此项目加了 `frontend/src/map/leafletFix.ts`，把 `marker-icon.png` 等资源显式注入到默认 icon 配置里，避免“地图有点但图标不显示”的常见坑。

- Dashboard：KPI 卡片 + Top10 类型条形图 + 严重度环形图 + 30 天游走趋势。
- Accidents：分页列表 + 筛选（严重度/是否事故/每页数量），点击行进入详情。
- Detail：展示图片 + 记录字段，支持一键 Copy JSON。

开发时通过 `frontend/vite.config.ts` 代理：

- `/api` -> `http://localhost:8000`
- `/uploads` -> `http://localhost:8000`

构建时输出到 `../backend/static`，配合后端的静态挂载实现单端口。

## 本地运行

后端：

```bash
python3 -m pip install -r requirements.txt
PYTHONPATH=backend uvicorn app.main:app --reload --port 8000
```

前端（开发模式）：

```bash
cd frontend
npm install
npm run dev
```

单端口构建（生产形态）：

```bash
cd frontend
npm run build

PYTHONPATH=backend uvicorn app.main:app --port 8000
```

## 上线前的几个现实问题

这个项目目前非常适合本地/内网 demo，但如果要对公网开放，建议优先补齐：

1. 鉴权与限流：上传与写入接口需要保护（API key / OAuth / 反代鉴权 + rate limit）。
2. 上传安全：`/api/uploads` 需要做文件类型白名单、大小限制、内容嗅探防护；同时注意 `/uploads` 是静态可访问的公开目录。
3. 数据演进：现在是 `create_all` 自动建表，后续字段变化建议引入 Alembic 做迁移。
4. 可观测性：记录 `raw_model_output`（或截断/哈希）能显著提升排障与评测能力。

## 可以继续扩展的方向

- 结构化增强：更多字段（车道占用、是否拥堵、涉及车辆数、是否有行人、建议处置等）。
- 地理可视化：如果 EXIF GPS 命中率高，可在前端加地图热力图（并明确隐私策略）。
- 质量评测：引入一批标注样例，做离线评测与 prompt/模型版本对比。
- 任务队列：把“推理”变成异步任务（Celery/RQ/Redis），提升吞吐并避免阻塞请求。
- 版本可追溯：把 `model/base_url/prompt_version` 等写入库（或写入 `raw_model_output` 的外层 envelope），方便回归与对比。
