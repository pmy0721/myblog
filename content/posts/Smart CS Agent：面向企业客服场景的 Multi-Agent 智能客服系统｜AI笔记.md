---
title: "Smart CS Agent：面向企业客服场景的 Multi-Agent 智能客服系统｜AI笔记"
date: '2026-04-03T14:34:07+08:00'
tags: ["智能客服", "Multi-Agent", "FastAPI", "LangGraph", "RAG", "开源项目"]
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
    image: /uploads/2026/04/Gemini_Generated_Image_o7yf60o7yf60o7yf.png
    alt: ''
    caption: ''
    hidden: false
---
# Smart CS Agent：面向企业客服场景的 Multi-Agent 智能客服系统

## 1. 项目概述

`Smart CS Agent` 是一个面向企业客服场景的多 Agent 智能客服系统，目标不是做“能聊天”的通用助手，而是把 FAQ 检索、订单查询、退款预检、审批门控、人工升级、记忆与审计这些客服核心链路，串成一个可以真实运行的闭环。当前实现对外提供 FastAPI API、WebSocket 事件流和一个浏览器调试台，适合做开源演示、个人归档和后续二次开发。

和常见的单 Agent 客服 demo 相比，这个项目的差异化不在于“多放几个 prompt”，而在于把客服流程拆成了显式的状态机和职责清晰的专家 Agent：`Supervisor` 负责路由与意图编排，`FAQ Agent` 负责知识检索问答，`Order Agent` 负责订单与退款事务，`Complaint Agent` 负责投诉与人工接管，`Chitchat Agent` 负责兜底闲聊；同时通过审批、记忆、Guardrails、审计和工作流持久化，把系统从“回答问题”推进到“处理流程”。整个项目也很适合作为一次 Vibe Coding 实践样本：代码明显是围绕架构文档逐步补齐，从可运行骨架一路扩展到评估、可观测和交付层。

## 2. 业务场景与用户旅程

### 用户故事 1：用户问 FAQ，系统返回带来源的答案

例如用户输入“你们支持开电子发票吗？”。请求会先经过输入安全检查，然后由 `Supervisor` 路由到 `FAQ Agent`，后者通过本地 RAG 链路完成查询拆解、检索和 rerank，最终返回答案并在响应中附带来源文件名。

- 涉及节点与 Agent：
  - `memory_inject` → `guardrail_in` → `supervisor` → `faq` → `finalize` → `guardrail_out` → `memory_update`
- 对应实现：
  - `src/smart_cs_agent/agents/faq_agent.py`
  - `src/smart_cs_agent/rag/service.py`
  - `src/smart_cs_agent/rag/retriever.py`

### 用户故事 2：用户申请退款，系统先做 dry-run 风险评估，再决定自动完成、进入审批或升级人工

例如用户输入“我要退款订单 20260318001”。系统会路由到 `Order Agent`，由退款工具先做一次 `dry-run` 预检，而不是直接执行事务。根据订单状态，流程会分成三种路径：

- 低风险：可自动进入执行阶段；
- 中风险：进入 `approval_gate`，再转 `wait_for_approval`，生成审批单；
- 高风险：直接进入 `human_escalation`，创建人工工单。

这一套路径把“能回答退款问题”升级成了“能表达事务边界、风险和下一步动作”的客服流程。

- 涉及节点与 Agent：
  - `memory_inject` → `guardrail_in` → `supervisor` → `order` → `approval_gate`
  - 中风险：`wait_for_approval` → `guardrail_out` → `memory_update`
  - 高风险：`human_escalation` → `guardrail_out` → `memory_update`
- 对应实现：
  - `src/smart_cs_agent/agents/order_agent.py`
  - `src/smart_cs_agent/tools/refund_tools.py`
  - `src/smart_cs_agent/graph/nodes.py`

### 用户故事 3：用户情绪激动或流程多次失败，系统转入投诉/人工处理路径

如果用户直接表达投诉诉求，或者流程累计失败次数达到阈值，状态机会把请求转给 `Complaint Agent`。在图里，这个能力既支持显式投诉，也支持“熔断后转投诉”的保护逻辑，避免用户被困在反复失败的自动流程里。

- 涉及节点与 Agent：
  - 显式投诉：`supervisor` → `complaint_agent`
  - 熔断投诉：`supervisor` 检测 `error_count >= 2` 后强制路由到 `complaint_agent`
- 对应实现：
  - `src/smart_cs_agent/agents/complaint_agent.py`
  - `src/smart_cs_agent/graph/nodes.py`
  - `src/smart_cs_agent/graph/edges.py`

## 3. 系统架构总览

![Smart CS Agent 系统架构图](/uploads/2026/04/smart-cs-agent/architecture-overview.svg)

之所以是三层，而不是“编排层 + Agent 层”两层，是因为这个项目里有一批能力天然应该被多个 Agent 共享，而不应该复制到每个 Agent 内部，比如记忆注入、审批持久化、Guardrails、审计日志、FAQ 检索服务和工作流状态持久化。把这些能力抽成共享服务层，带来的价值是：一方面让 Agent 保持职责单一，另一方面让审批、记忆、安全、追踪这些横切能力可以被统一治理。

当前核心 Agent 包括：

- `Supervisor`
- `FAQ Agent`
- `Order Agent`
- `Complaint Agent`
- `Chitchat Agent`

## 4. Multi-Agent 协作机制

### 4.1 LangGraph 状态机设计

项目的状态定义位于 `src/smart_cs_agent/graph/state.py`。它不是只保存一条“最终回答”，而是显式维护了多 Agent 协作需要的上下文，包括：

- 会话上下文：`messages`、`user_input`、`user_id`、`session_id`、`turn_count`
- 路由上下文：`intent`、`primary_intent`、`candidate_intents`、`pending_intents`、`confidence`、`route_source`
- 执行上下文：`current_agent`、`visited_agents`、`handled_intents`、`response_segments`
- 事务上下文：`pending_actions`、`requires_approval`、`approval_status`、`approval_id`、`handoff_target`
- 安全与恢复上下文：`guardrail_hits`、`error`、`error_detail`、`circuit_open`
- 记忆与可观测上下文：`session_summary`、`user_profile`、`memory_snapshot`、`workflow_id`、`workflow_status`

在 `src/smart_cs_agent/graph/builder.py` 里，状态机节点被组织为一条完整客服处理链：

- 入口链路：`memory_inject` → `guardrail_in` → `supervisor`
- 专家 Agent：`faq`、`order`、`complaint_agent`、`chitchat`
- 控制节点：`clarify`、`reject`、`approval_gate`、`wait_for_approval`、`human_escalation`
- 收尾链路：`finalize` → `guardrail_out` → `memory_update`

条件边的设计集中在 `src/smart_cs_agent/graph/edges.py`：

- `supervisor_decision` 决定路由到哪个专家 Agent，或者进入 `clarify` / `reject` / `finalize`
- `agent_decision` 决定专家 Agent 执行后是回到 `supervisor` 继续处理剩余意图，还是进入审批、澄清、拒绝或最终输出
- `approval_gate_decision` 决定中风险订单进入审批等待，高风险订单进入人工升级，低风险则直接响应

这个设计的关键点在于：状态机不是“一轮只跑一个 Agent”，而是支持多意图串行处理。比如“帮我查订单，另外退款政策是什么？”这类请求，会先执行 `order`，再基于 `pending_intents` 回到 `supervisor`，继续分发到 `faq`，最后由 `finalize` 聚合多段回复。

### 4.2 Supervisor 路由策略

`Supervisor` 的实现位于 `src/smart_cs_agent/agents/supervisor.py`，它采用的是一个很典型但非常实用的混合路由策略：

1. `L1_rule_engine`
   - 由 `src/smart_cs_agent/router/rule_engine.py` 提供。
   - 对投诉、订单、FAQ、闲聊分别维护正则规则和分值。
   - 既能命中主意图，也能保留多意图排序结果。
   - 对“退款”做了 FAQ / 订单语义拆分，避免把“退款政策”误判成退款事务。

2. 关键词分类器
   - 由 `src/smart_cs_agent/router/classifier.py` 提供。
   - 目前是轻量的关键词计数分类器，返回 `intent + confidence`。
   - 在当前实现中主要作为辅助 hint 写入 `RoutePlan.classifier_hint`，不是最终决策者。

3. `L3_llm_router`
   - 由 `src/smart_cs_agent/router/llm_router.py` 提供。
   - 当前还不是调用真实 LLM，而是一个简化的启发式 fallback。
   - 当规则层没有命中时，系统用它兜底，并且在低置信度场景触发澄清。

这种“规则优先 + 分类器辅助 + LLM fallback”的好处是非常适合客服域：

- 高频、强结构化意图尽量走可控规则；
- 模糊输入保留兜底能力；
- 路由结果既有 `primary_intent`，也保留 `candidate_intents` 和 `pending_intents`，方便状态机继续协作。

### 4.3 Agent 间协作模式

这个项目里的 Agent 协作模式是“Supervisor 编排 + 共享状态驱动”。

- Agent 不直接互相调用，而是都通过 LangGraph 节点被调度。
- 每个 Agent 返回统一的 `AgentResult`，再由 `graph/nodes.py` 转成状态字段。
- 多 Agent 响应通过 `response_segments` 聚合，最终由 `finalize_node` 拼成面向用户的最终回答。
- `visited_agents` 和 `handled_intents` 用来记录真实执行轨迹。
- `pending_intents` 用来处理多意图串行消费。
- `pending_actions`、`approval_status`、`handoff_target` 用来承接事务型后续动作。

这意味着 Agent 之间的“协作”不是靠 prompt 里互相提及，而是靠显式状态字段和条件边完成，代码可读性和可测性都更强。

### 4.4 意图切换与状态共享

意图切换主要发生在两个地方：

- `supervisor_node`
  - 如果前一个 Agent 已完成且还有 `pending_intents`，就切到下一个意图；
  - 如果没有剩余意图且已经积累了 `response_segments`，则进入 `finalize`。
- `agent_decision`
  - 如果当前 Agent 产生了 `pending_actions`，则进入审批门控；
  - 如果还有 `pending_intents`，则回到 `supervisor`；
  - 如果已经形成响应段，则进入 `finalize`。

共享状态则由三个公共节点持续维护：

- `memory_inject_node`：注入轮次记忆、会话摘要、用户画像
- `guardrail_in_node` / `guardrail_out_node`：统一做输入输出防护
- `memory_update_node`：更新消息历史、会话摘要、用户画像、工作流状态和审计事件

### 4.5 完整状态流转图

![Smart CS Agent 状态流转图](/uploads/2026/04/smart-cs-agent/state-flow.svg)

## 5. 核心能力模块

### RAG 检索增强

RAG 相关实现位于 `src/smart_cs_agent/rag/`。当前链路是一个轻量但结构完整的本地检索系统：`query_decomposer.py` 先把问题拆成 `structured` / `faq` 子查询，`retriever.py` 基于本地索引做启发式打分检索，`reranker.py` 再把 FAQ 结果和文档结果重新排序，最后在 `service.py` 中去重输出。它还不是向量库实现，但接口边界已经留好，后续可以替换为 ChromaDB 或其他向量检索方案。

### 工具调用层

工具层位于 `src/smart_cs_agent/tools/`。`order_tools.py` 负责订单查询与权限校验，`refund_tools.py` 负责退款 `dry-run` 预检，`base.py` 提供统一的 `ToolResult` 和结构化错误封装。当前事务设计很克制：代码里明确只做 `dry-run` 和状态决策，不直接执行真实退款；同时错误统一带 `error_code`、`error_detail` 和 `retry_suggestion`，适合后续接入更正式的工具编排和权限隔离策略。

### 审批与人工升级

审批和人工升级是这个项目最像“业务系统”而不只是“聊天 demo”的部分。退款预检目前实际形成了四级风险结果：`low` 可继续执行、`medium` 进入审批、`high` 转人工、`blocked` 直接拒绝。`approval_gate_node` 负责统一判定，`wait_for_approval_node` 会落库审批记录，`human_escalation_node` 会创建人工工单，审批还支持通过 `/approvals/{approval_id}/decision` 回调恢复执行。

### 三级记忆系统

记忆相关代码位于 `src/smart_cs_agent/memory/`。系统把记忆拆成三层：`turn_memory.py` 保留最近几轮对话，`session_memory.py` 维护会话级摘要，`user_memory.py` 维护用户画像和交互偏好。`memory_inject_node` 会在编排开始时注入这些上下文，`memory_update_node` 会在输出后统一更新，当前持久化已经落到 SQLite repository。

### 安全护栏

Guardrails 位于 `src/smart_cs_agent/guardrails/`。输入侧会检测 prompt injection、PII 和内部探测；输出侧会检测空响应、内部信息泄露、无依据回答和缺失引用。这里的设计亮点是“双侧防护 + 可重写”，不是一味阻断：比如手机号会先脱敏再继续路由，FAQ 缺少来源时会自动补充引用。

### 可观测性

可观测性实现位于 `src/smart_cs_agent/observability/tracing.py`。项目通过 OpenTelemetry OTLP exporter 预留了到 Phoenix 的 trace 输出，并在 `api/main.py`、`graph/builder.py` 和部分 Agent 中打了 spans。同时，审批、记忆更新、Guardrail 命中、工作流流转还会写入 SQLite 审计表，形成“trace + audit + workflow state”三条并行的排障线索。

## 6. 技术栈一览

| 模块 | 技术选型 | 简要说明 |
| --- | --- | --- |
| 语言与运行时 | Python 3.12 | `pyproject.toml` 要求 `>=3.12` |
| API 层 | FastAPI | 提供 HTTP、WebSocket、审批与 workflow 查询接口 |
| 工作流编排 | LangGraph | 用显式状态机组织 Supervisor、Agent、审批、升级与记忆更新 |
| 路由层 | 规则引擎 + 关键词分类 + fallback 路由 | 当前不是重 LLM Router，而是更适合 demo 和回归测试的混合路由 |
| 知识检索 | 本地 JSON 索引 + 启发式检索 | 当前实现未接 ChromaDB，后续可替换为向量库 |
| 事务与持久化 | SQLite | 审批、审计、会话记忆、用户画像、workflow 状态统一落库 |
| Mock 业务数据 | 本地 JSON 文件 | 订单、商品、用户数据来自 `data/mock_data/` |
| 可观测性 | OpenTelemetry + Phoenix | 已预留 OTLP 输出，`docker-compose.yml` 可一键启动 Phoenix |
| 容器化 | Docker Compose | 同时启动 App 与 Phoenix |
| 开发工具 | uv、pytest、ruff | 负责依赖管理、测试和静态检查 |

## 7. 项目结构

项目目录树基于仓库中的 `project_tree.txt`：

```text
.
├── api/                         # FastAPI 入口与前端调试台
│   ├── main.py
│   └── static/index.html
├── data/
│   ├── knowledge_base/          # FAQ、政策文档与本地检索索引
│   ├── mock_data/               # 订单、商品、用户 mock 数据
│   └── runtime/                 # SQLite 运行时库与生成数据
├── docs/                        # Quick Start 与 Demo Guide
├── eval/                        # Router / RAG / E2E 评估脚本与报告
│   └── reports/
├── scripts/                     # build_index、demo runner、smoke test
├── src/smart_cs_agent/
│   ├── agents/                  # FAQ / Order / Complaint / Chitchat / Supervisor
│   ├── config/                  # settings、策略占位与 prompt 占位
│   ├── graph/                   # LangGraph state、nodes、edges、builder
│   ├── guardrails/              # 输入输出安全护栏
│   ├── memory/                  # turn / session / user 三级记忆
│   ├── observability/           # OpenTelemetry tracing
│   ├── rag/                     # 本地 RAG 检索链路
│   ├── repositories/            # SQLite repository 抽象
│   ├── router/                  # 规则引擎、分类器、fallback router
│   └── tools/                   # 订单、退款、工单工具
├── tests/                       # API、路由、Guardrails、评估等回归测试
├── Makefile
├── Dockerfile
├── docker-compose.yml
└── pyproject.toml
```

关键目录说明：

- `src/smart_cs_agent/graph/` 是系统的编排中枢。
- `src/smart_cs_agent/repositories/` 负责把审批、记忆、审计和 workflow 状态统一持久化。
- `eval/` 和 `tests/` 一起构成“回归测试 + 量化评估”的双层验证体系。
- `api/static/index.html` 不是正式产品 UI，而是一个偏工程调试向的工作台。

## 8. 快速开始（Quick Start）

### 环境要求

- Python `3.12+`
- `uv`
- Docker / Docker Compose（如果要一键启动 Phoenix）

### 安装依赖

```bash
uv sync
uv sync --extra observability
```

依赖定义见 `pyproject.toml`，其中可观测性相关依赖放在 `observability` extra 中。

### 构建知识索引

```bash
uv run python scripts/build_index.py
```

或者直接使用 Makefile：

```bash
make build-index
```

### 本地启动服务

```bash
uv run uvicorn api.main:app --reload
```

或者：

```bash
make api
```

启动后可访问：

- App: `http://127.0.0.1:8000`
- Health Check: `http://127.0.0.1:8000/health`
- Workflow 列表: `http://127.0.0.1:8000/workflows`
- 评估摘要: `http://127.0.0.1:8000/reports/summary`

### 运行 Demo

```bash
uv run python scripts/run_demo.py --scenario simple
uv run python scripts/run_demo.py --scenario complex
uv run python scripts/run_demo.py --scenario escalation
```

### Docker Compose 启动

```bash
docker compose up --build
```

Compose 会同时启动：

- App: `http://127.0.0.1:8000`
- Phoenix: `http://127.0.0.1:6006`

### 基本验证命令

```bash
uv run ruff check .
uv run pytest
uv run python eval/run_eval.py
make smoke
```

## 9. 评估与测试

评估脚本位于 `eval/`，测试用例位于 `tests/`。

### 评估体系覆盖维度

- `eval/router_eval.py`
  - 评估路由准确率、澄清命中率、多意图命中率、拒绝命中率
- `eval/rag_eval.py`
  - 评估来源命中率、引用覆盖率、resolved 匹配率、无依据回答比例
- `eval/e2e_eval.py`
  - 评估端到端任务完成率、审批路径覆盖率、人工升级比例
- `eval/run_eval.py`
  - 汇总生成 `eval/reports/*.json` 与 `summary.md`

测试用例覆盖的主要模块包括：

- 路由与多意图切换：`tests/test_routing.py`
- FAQ 检索与来源返回：`tests/test_faq_agent.py`
- 订单查询、退款 dry-run 与权限控制：`tests/test_order_tools.py`
- 输入输出 Guardrails：`tests/test_guardrails.py`
- API、审批恢复、workflow/debug 接口、WebSocket：`tests/test_api.py`
- 评估脚本本身：`tests/test_eval.py`

### 当前测试结果

基于本地实际运行结果：

- `uv run pytest -q`：`48 passed in 0.58s`
- `uv run python eval/run_eval.py`：成功生成评估报告
- `eval/reports/summary.md` 当前结果：
  - Router accuracy：`100.00%`
  - Router clarify hit rate：`100.00%`
  - RAG source hit rate：`100.00%`
  - RAG citation coverage：`100.00%`
  - E2E task completion rate：`100.00%`
  - E2E escalation rate：`16.67%`
- 当前三类评估报告均为 `PASS`
  - `router_report.json`：`10` 条样本
  - `rag_report.json`：`5` 条样本
  - `e2e_report.json`：`6` 条样本

## 10. 未来规划 / 已知局限

这个项目已经具备完整演示闭环，但仍然是一个偏“工程化原型”的开源项目，而不是生产级客服平台。代码里比较明确的局限主要有：

- 路由层的 `llm_router.py` 目前仍是启发式 fallback，不是真实 LLM Router。
- `config/models.py` 和 `config/prompts.py` 还是明显的占位实现，说明系统还没有进入真实模型编排阶段。
- FAQ 检索当前是本地 JSON 索引 + 启发式检索，不是向量库或混合检索方案。
- 订单、用户、商品数据仍来自 `data/mock_data/`，不是外部业务系统。
- 退款链路目前只做到 `dry-run` 和审批/升级决策，审批通过后的“执行退款”在 `api/main.py` 中仍是模拟完成。
- `ticket_tools.py` 当前返回的是固定 demo 工单号，不是真实工单系统集成。
- Guardrails 目前主要是规则型实现，适合演示和回归测试，但还没有更强的模型级 faithful / policy 检测。
- SQLite 持久化很适合单机开发和开源 demo，但还不具备生产环境需要的并发、容灾和运维能力。
- 前端页更像调试台，而不是最终用户产品界面。

结合 `NEXT_STEPS.md` 和现有代码，比较自然的后续方向是：

- 把本地检索替换为向量库或混合检索；
- 把审批、退款、工单能力接到真实外部系统；
- 把 Guardrails 从规则检测升级为更强的组合策略；
- 扩大 golden dataset 和自动评测样本规模；
- 继续加强 WebSocket 调试台和 Phoenix trace 展示，把它从演示工具升级为更实用的开发工作台。

## 代码参考

- 状态机定义：`src/smart_cs_agent/graph/state.py`
- 图构建与节点编排：`src/smart_cs_agent/graph/builder.py`
- 节点实现：`src/smart_cs_agent/graph/nodes.py`
- 条件边：`src/smart_cs_agent/graph/edges.py`
- Supervisor 路由：`src/smart_cs_agent/agents/supervisor.py`
- FAQ Agent：`src/smart_cs_agent/agents/faq_agent.py`
- Order Agent：`src/smart_cs_agent/agents/order_agent.py`
- Complaint Agent：`src/smart_cs_agent/agents/complaint_agent.py`
- RAG 服务：`src/smart_cs_agent/rag/service.py`
- 工具层：`src/smart_cs_agent/tools/`
- 记忆系统：`src/smart_cs_agent/memory/`
- Guardrails：`src/smart_cs_agent/guardrails/`
- 可观测性：`src/smart_cs_agent/observability/tracing.py`
- API 入口：`api/main.py`
