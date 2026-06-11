---
title: "给 Claude Code 装上自我进化与长期记忆系统｜AI笔记"
date: '2026-06-12T00:12:55+08:00'
tags: ["AI", "Claude Code", "技术"]
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
    image: https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/2026/06/image0612.png
    alt: ''
    caption: ''
    hidden: false
---
> 本文是一份**技术设计文档**,记录如何为 Claude Code 构建一套**跨会话的自我进化 + 长期记忆系统**:用 Hook 确定性地观测行为,会话结束后自动提炼行为规律与项目知识,下一次对话通过向量召回主动注入,使其逐步演化为更贴合个人习惯的编程伙伴。
>
> 文中所有路径、依赖均为示例,可按自己环境替换。系统面向**单用户、纯本地**场景。

---

## 一、背景与动机

每次新开一个 Claude Code 会话,它都是一张白纸:昨天解释过的项目架构、反复纠正的代码风格、约定好的开发规范,全部归零。每个新会话都要花若干轮对话、约十分钟把模型"带入状态"。

我们想要的不只是**被动记忆**,而是**主动学习**:观测自己的真实行为,提炼出规律与项目知识,下次自动应用。本文介绍的系统就是为此设计的。

整个系统是一个**自学习闭环**,由三个子系统构成:

- **行为观测层(Observation)** —— Hook 100% 捕获工具调用,落盘为观测流。
- **模式提炼层(Instinct)** —— 会话结束时分析观测流,提炼为带动态置信度的原子规则。
- **记忆注入层(Memory)** —— 把知识性记忆向量化,会话开始时按相关性召回并注入上下文。

---

## 二、系统总览

```
会话进行中
  └─ 每次工具调用 ─→ observe ─→ observations.jsonl

会话结束(Stop hook)
  └─ stop_runner
       ├─ 非阻塞锁(拿不到就跳过,不拖会话)
       ├─ rotate(归档,防膨胀)
       └─ 后台 detached 拉起 analyze
            ├─ 路径 A:统计检测器 ─→ instincts/*.md
            ├─ 路径 B:语义分析(LLM,带闸门)─→ instincts + 候选记忆
            └─ evolve ─→ 去重 + 聚合 ─→ rules/auto-evolved.md(覆盖重写)

下次会话开始(SessionStart hook)
  └─ inject_memory_context
       ├─ 构造查询(项目名 + 最近 commit)
       ├─ 双层召回(全局偏好 + 当前项目记忆)→ Top-K
       └─ stdout 注入(规则 + 记忆)→ 进入 Claude 上下文
```

两条互补的记忆维度:

| 维度 | 记什么 | 怎么产生 |
|---|---|---|
| **Instinct** | 行为规律、犯过的错 | 程序从观测流提炼,置信度动态演化 |
| **Memory** | 知识性事实、决策、项目上下文 | 显式沉淀 / 自动抽取,语义检索召回 |

---

## 三、行为观测层

### 3.1 用 Hook,而非 Skill

提炼学习的前提是**高质量、无遗漏**的行为数据。一个关键取舍是:**用确定性触发的 Hook,而不是依赖模型主动调用的 Skill**。Skill 触发率不稳定,会让数据出现盲区;Hook 是系统级回调,能保证 100% 采集率。

Claude Code 的 Hook 在工具调用生命周期的固定点触发,从 **stdin 读取 JSON**、通过退出码与 stdout 反馈。我们用到四个事件,注册在 `~/.claude/settings.json`(命令使用**绝对路径**,详见 §六):

```json
{
  "hooks": {
    "PreToolUse":   [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "<abs>/observe.py pre" }] }],
    "PostToolUse":  [{ "matcher": "*",    "hooks": [{ "type": "command", "command": "<abs>/observe.py post" }] }],
    "Stop":         [{ "hooks": [{ "type": "command", "command": "<abs>/stop_runner.py" }] }],
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "<abs>/inject_memory_context.py" }] }]
  }
}
```

- `PostToolUse` 匹配所有工具(`*`),确保后置全采集;`PreToolUse` 覆盖 Bash,用于在命令执行前记录意图。
- `Stop` 驱动分析与提炼。
- `SessionStart` 的 **stdout 会成为 Claude 的上下文**,这正是记忆注入的依据。

### 3.2 观测记录格式

每条观测是一行 JSONL。**字段以真实 stdin 为准**(实测含 `session_id` / `hook_event_name` / `tool_name` / `tool_input` / `cwd`,工具结果字段为 `tool_response`):

```json
{"session_id":"…","ts":"2026-06-11T10:30:00Z","phase":"post",
 "tool":"Edit","cwd":"/path/proj",
 "input":{"file_path":"…","old":"…(截断)","new":"…(截断)"},
 "ok":true,"duration_ms":42,"bash_desc":null}
```

观测层必须**极轻**:只做"读 stdin → 截断大字段 → 追加一行",任何异常都静默退出、绝不阻断工具。重活全部留到会话结束。

### 3.3 生命周期管理

主文件超过 5MB 或 8000 行时,自动把 30 天外的数据按月归档到 `archive/YYYY-MM.jsonl`,主文件只保留近期数据,防止无限膨胀。

---

## 四、模式提炼层

会话结束时,`stop_runner` 在后台拉起分析。这是系统最核心的部分,通过**两条并行路径**提炼行为模式。

### 4.1 路径 A:统计检测

基于规则的硬编码检测器,识别高频出现的工具调用序列(例如:编辑文件前是否总先读取、改完是否倾向于等确认再提交、调用某 CLI 前是否先做前置检查)。每命中一个模式,生成或更新一条 Instinct,**置信度动态演化**:

- 首次发现:`confidence = 0.5`
- 重复验证:`confidence += 0.05`(上限 0.9)
- 长期未触发:`confidence -= 0.05`,低于 `0.55` 标记为 `deprecated`

这让系统具备"遗忘"能力:反复观测的规则被强化,过时的规则自然淘汰。

### 4.2 路径 B:语义分析

把观测摘要交给一个 LLM 做语义理解,捕获统计无法识别的深层规律。这里有一个**重要的工程决策**:

> **语义分析直接调 HTTP API(OpenAI 兼容接口,本文用 DeepSeek),而不是 spawn `claude` CLI。**
>
> 若 spawn 内层 `claude`,它本身又是一个 Claude Code 会话,会再次触发所有 Hook → 再次拉起分析 → **无限递归、成本失控**。改为直连 API 后,**不创建任何内层会话,递归在结构上就不可能发生**——比"靠环境变量守卫兜住"稳得多。

路径 B 带**预算闸门**:仅当"新增观测 ≥ 阈值"且"每日调用 ≤ 上限"时才触发,用便宜模型,控制成本。统计路径快速可靠、语义路径捕获复杂模式,两者互补。

### 4.3 Instinct 数据模型

每条 Instinct 是独立的 Markdown,原子化(一个 trigger 对应一个 action):

```markdown
---
id: read-before-edit
trigger: "about to edit a file not yet read this session"
confidence: 0.78
domain: workflow
deprecated: false
---
## Action
编辑文件前先读取当前内容,避免基于过时内容做出错误修改。
## Evidence
过去多次 Edit 之前都伴随对应的 Read 调用。
```

### 4.4 去重与聚合

单条 Instinct 是原子的;`evolve` 负责把同域高置信度规则聚合成可注入的规则文件。核心是 **Jaccard 相似度 + Union-Find** 去重:

```python
def dedupe(items, th=0.5):                 # items: 含 trigger/action/confidence
    toks = [tokenize_en(i["trigger"] + " " + i["action"]) for i in items]
    parent = list(range(len(items)))
    find = lambda x: x if parent[x] == x else find(parent[x])
    for a in range(len(toks)):
        for b in range(a + 1, len(toks)):
            if jaccard(toks[a], toks[b]) >= th:
                parent[find(a)] = find(b)          # 合并相似项
    groups = {}
    for i in range(len(items)):
        groups.setdefault(find(i), []).append(items[i])
    return [max(g, key=lambda x: x["confidence"]) for g in groups.values()]
```

**只提取英文关键词**是个巧妙的细节:同一习惯可能被中文或英文描述,基于英文技术词汇的 Jaccard 能跨语言识别同一意图。

去重后按 `domain` 分组,每组 ≥ 2 条才生成聚合条目;最终合并、精简后**整体覆盖重写** `rules/auto-evolved.md`,始终保持最新。

---

## 五、记忆注入层

Instinct 处理"行为模式",Memory 则处理"知识性记忆"——解决过的 Bug、技术决策、项目上下文、用户偏好。

### 5.1 记忆格式

每条记忆是独立 Markdown,带 YAML frontmatter:

```markdown
---
name: no-auto-commit
description: 改完代码不主动提交,等用户验证确认后再 commit/push
metadata: { type: feedback }
---
改完代码后不要自动 commit/push,等本地验证 OK 再由用户确认。
**Why:** 自动提交会打断验证节奏,push 到远端回滚成本高。
**How:** 改完明确告知改动内容,等 confirm 再执行 git 操作。
```

### 5.2 召回链路

召回由 **SessionStart Hook** 驱动——在第一条消息之前就把上下文备好,而非等用户开口:

1. **构造查询**:以当前项目名 + 最近 3 条 commit message 作为语义输入,贴近当前任务语境。非 git 目录降级为仅用项目名。
2. **向量检索**:查询向量与记忆库做余弦相似度,取 **Top-5**。
3. **上下文注入**:以结构化 Markdown 注入,每条带类型标签让模型感知来源权重,并提示"勿逐字复述"。

```
## 🧠 项目记忆(自动注入,请优先参考)
[feedback] 改完代码不主动提交,等用户验证确认后再 commit/push
> Why: 自动提交打断验证节奏,回滚成本高
[project] 本项目用 Vitest 做单测,TDD 优先
> How: 新功能先在 tests/ 写用例再实现
```

### 5.3 Embedding:本地优先 + 任务前缀

语义检索依赖向量嵌入。我们**选用本地模型**(`nomic-embed-text-v2-moe`,768 维、多语言,经 Ollama 本地推理),以保护代码隐私——记忆内容可能含项目路径、函数名等敏感信息,不宜上传第三方。当本地模型不可用且为全新空库时,降级到一个零依赖的字符哈希回退(仅关键词级匹配)。

一个**容易被忽略的细节**:nomic 系列**必须带任务前缀**——文档用 `search_document:`、查询用 `search_query:`。不带前缀,召回质量会明显下降。

### 5.4 双层作用域

记忆分两层存储,召回时合并:

```
memory/
├── global/store/                 ← feedback / user 类型,全项目生效
└── projects/<encoded>/store/     ← project / bugfix 类型,按项目隔离
```

这样**全局偏好**(如"不要自动提交")在任何项目都生效,而**项目记忆**互不泄漏。实测:在无关项目中只会召回全局偏好,不会拿到其他项目的上下文。

为防"建库时本地模型在、查询时掉线回退哈希"导致的**混维**(768 维 vs 384 维),索引带 `backend/dim` 标签;查询向量与库维度不一致时**优雅跳过**注入,绝不用错误维度做比较。

---

## 六、关键工程决策汇总

对一套长期运行的系统,这些决策决定了它能不能稳。

1. **直连 API 而非 spawn CLI** —— 让语义分析的递归在结构上不可能(见 §4.2)。
2. **再入守卫只放 Hook 入口** —— `should_skip()`(读环境变量)只用于 3 个 Hook 入口;被 spawn 的后台 worker 不带守卫,否则会静默跳过自己、导致整条链无产出。
3. **Hook 命令用绝对路径** —— Hook 的 PATH 受限,相对 `python3`/`~` 会**静默失效**;脚本用绝对解释器路径,worker 用 `sys.executable` spawn。
4. **游标用时间戳而非行号** —— rotation 会截断/重排主文件,行号游标会错位,时间戳免疫。
5. **后台分析 detached + 非阻塞锁** —— 会话结束不被分析拖慢;并发会话拿不到锁就跳过。
6. **维度安全** —— 索引打 backend/dim 标签,不匹配静默跳过。
7. **注入只走单通道** —— 规则 + 记忆统一由 SessionStart 注入,避免与其它导入机制双注入。

---

## 七、防膨胀与隐私

**防膨胀(多层次):**

- 数据层:observations 超阈归档;低置信度 Instinct deprecate + 衰减遗忘;记忆按类型 TTL(如 feedback 90 天 / project 180 天 / bugfix 365 天)。
- 索引层:`auto-evolved.md` 每会话覆盖重写;Jaccard 去重合并重复规则。

**隐私边界:**

- 观测数据与向量嵌入**全本地**。
- **仅语义分析这一步会把摘要发往云端 LLM**——这是知情的取舍:它能捕获深层模式,但摘要可能含路径/函数名。在意者可在发送前脱敏,或改用本地模型做这步判断。

---

## 八、自动记忆写入与"影子模式"上线

为了让记忆库随使用自然生长,我们增加了**自动记忆写入**:复用语义分析那一次 LLM 调用,同时产出候选记忆(一次 API 往返、两类输出)。输入是一份会话摘要(用过的工具、改过的文件、踩过的错与解决)。

自动写入器最容易堆垃圾,因此配了**五道护栏**:

| # | 护栏 | 作用 |
|---|---|---|
| 1 | 写前去重 | 候选与现有记忆 cosine ≥ 0.85 则跳过/更新,防重复 |
| 2 | 质量门槛 | confidence ≥ 0.7 才写,丢弃模糊/一次性内容 |
| 3 | 限流 | 每会话 ≤2、每天 ≤5,状态落盘 |
| 4 | 作用域路由 | 按类型入 global / project 库 |
| 5 | 隐私 | 同语义分析,内容发往云端 |

更重要的是**上线方式**:默认**影子模式**——候选只写入一份日志、**不真正建文件**。运行几天后人工审查候选质量(对不对、重不重、该不该记),满意后再翻开关让其真写。这是一道**人类在环**的安全闸:一个能自我授权写持久记忆的系统是危险的,这个开关应当始终保持手动。

---

## 九、设计目标与预期收益

> 说明:以下是系统的**设计目标与作用机制**,而非长期实测数字。真正的量化收益需要数月真实数据积累后才能给出,本文不提供伪造的指标。

- **缩短上下文冷启动**:SessionStart 自动注入项目记忆与高置信度规则,使模型第一条响应即具备项目感知,省去多轮人工解释。
- **降低重复性 token 开销**:精确召回 Top-K 相关记忆,而非每次把完整背景塞进 prompt。
- **减少重复犯错**:Instinct 记录的不只是"做过什么",更是"犯过什么错、为什么犯";前置检查类规则一旦提炼,可显著减少同类中断。
- **知识复利**:价值随时间累积——规则与项目记忆越攒越多,行为越贴合个人习惯。这是一条**随使用增长**的曲线,而非线性。

---

## 十、当前限制与权衡

- **价值需要时间**:系统刚建成时规则稀少,主要消除低级错误;真正的复利效应要数月才显现。
- **语义分析的隐私取舍**:这一步依赖云端 LLM,与"嵌入全本地"的初衷存在对冲,需按敏感度自行权衡。
- **召回质量取决于 embedding**:本地模型的区分度有限,短语级匹配的边界要靠前缀与调参改善。
- **单用户、本地**:不含团队共享与远程同步。

---

## 十一、总结

这套系统让 AI 编程助手能够跨越会话边界:用 Hook 确定性地观测行为,会话结束后自动提炼行为规律与项目知识,通过向量检索快速召回,下一次对话主动应用,逐步进化为更懂你的伙伴。

相比"每次粘贴完整规范文件"的笨办法,它的核心价值在于**确定性采集 + 自动提炼 + 语义召回**这条闭环,以及一系列让系统**长期可稳定运行**的工程决策:直连 API 消除递归、守卫只放 Hook 入口、时间戳游标、维度安全、双层作用域、影子模式上线。这些骨架与具体模型/平台解耦,迁移到其它 Agent 时,主要替换 Hook 注册方式、embedder 与语义分析的 API 端点即可。

---

## 参考与致谢

本系统的整体思路受 **得物技术《让 Claude Code 拥有自我进化和记忆系统》** 启发(原文:`https://mp.weixin.qq.com/s/PGT49KORSVZYpJxykWnwOw`)。本文为在其架构思想上**独立实现**的版本,并在递归防护、作用域隔离、嵌入选型、上线纪律等方面做了若干工程化改造;文中未转载原文内容。

Claude Code Hook 机制以官方文档为准(`https://docs.claude.com/en/docs/claude-code/hooks`)。
