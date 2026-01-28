---
title: "DeepSeek OCR 2 创新点与技术细节｜AI笔记"
date: '2026-01-27T17:22:25+08:00'
tags: ["技术", "多模态", "大模型", "DeepSeek"]
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
    image: https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/image2026127.png
    alt: ''
    caption: ''
    hidden: false
---
> DeepSeek-OCR 2 的核心升级是用 **LLM-style 视觉编码器 + 因果流（causal flow）查询 token** 在编码阶段学到更接近人类阅读顺序的表示，在 **相近/更小的视觉 token 预算**下把 OmniDocBench v1.5 的整体指标从 87.36 提升到 91.09（+3.73）。

这篇笔记聚焦 DeepSeek OCR 2 的方法动机与关键机制，尤其是“编码器端重排阅读顺序 + 解码器端保持高效自回归”的级联因果结构。

## 贡献点

1. **DeepEncoder V2：用“LLM 作为视觉编码器”替换 DeepEncoder 里的 CLIP ViT**，目的是让编码器具备更贴近人类阅读的“因果视觉流”。（引言贡献点 (1)，图 1）
2. **引入“因果流查询 token（causal flow tokens）”并用定制 attention mask**：视觉 token 仍是双向全局注意力，但查询 token 走因果注意力，可逐步吸收视觉信息并形成“新阅读顺序”。（引言贡献点 (2)，方法 3.2.2 + 图 5 + 式 (1)）
3. **保持查询 token 与视觉 token 等势（等数量）**，并且 **只把查询 token（编码器输出后半段）喂给解码器**，形成“编码器先重排、解码器再自回归推理”的级联因果结构。（引言贡献点 (3)(4)）
4. **在不牺牲 token 压缩比/解码效率的前提下提高性能**：把喂给 LLM 的视觉 token 预算约束在 **256–1120**（下限对齐 DeepSeek-OCR 的 1024^2 tokenization，上限对齐 Gemini-3 Pro token budget）。
5. **实证：OmniDocBench v1.5 上整体 +3.73，阅读顺序 ED 从 0.085 降到 0.057**，并在生产环境用 repetition rate 观测到质量提升。

---

## 问题定义与假设

- 输入：文档图像（多分辨率、多布局；方法中明确有 1024×1024 global view + 768×768 local crops）
- 输出：面向“文档阅读/解析”的文本与结构化内容（论文用 OmniDocBench 的多指标来衡量文本、公式、表格、阅读顺序）
- 关键约束：
  - **token 预算**：喂给解码器的（重排后）视觉 token 总数在 [256, 1120]，通过 0–6 个 local crops 控制
  - **可比性假设**：训练数据源“基本一致”，仅做了轻量数据采样/标签合并，因此把 DeepSeek-OCR 视为有效 baseline
- 隐含假设（论文动机）：
  - 固定 raster-scan + 固定位置编码会引入不合理归纳偏置；文档这种强结构视觉逻辑更需要“因果阅读流”

---

## 方法细读

```txt
模块 -> 目的 -> 关键公式/伪代码 -> 复杂度/实现细节 + 逐段证据
```

### 总体架构：Encoder（DeepEncoder V2）+ Decoder（DeepSeek-MoE）

- 目标：在 encoder 端就完成 **token 压缩 + token 重排（阅读顺序建模）**，decoder 侧保持 DeepSeek-OCR 的高效 MoE 解码。
- 证据：明确“主要聚焦 encoder，不升级 decoder，保留 DeepSeek-OCR 的 3B MoE（~500M active）”。

---

### 视觉 tokenizer（图像→视觉 token）

- 做法：沿用 DeepEncoder 的 tokenizer：**80M 参数 SAM-base + 2 个卷积层**；并把最后卷积层维度从 1024 改到 **896** 以对齐后续流水，采用的方法为 **token compression 16×**。
- 目的：在进入“全局注意力的 LM-style encoder”前就把 token 数压到可控规模，降低计算/显存。

---

### LM 作为 Vision Encoder：双流注意力 + 前缀拼接（核心创新）

- **Dual-stream attention（双流注意力）**：同一 transformer 序列里，前半段视觉 token 用双向注意力；后半段查询 token 用因果注意力。
- **Causal flow queries / tokens（因果流查询 token）**：可学习的查询向量序列，用来“按因果顺序”聚合视觉 token，并隐式学出阅读顺序。

关键机制：

1. **视觉 token：bidirectional attention**，保留类似 ViT/CLIP 的全局建模能力。
2. **查询 token：causal attention**，每个查询 token 能看全部视觉 token + 之前的查询 token，从而形成“渐进式重排/蒸馏”。
3. **只输出查询 token 给 decoder**：编码器输出的后半段才进入 LLM 解码器，形成级联因果推理。

工程选择与动机：

- 实现实例：用 **Qwen2-0.5B（500M）** 初始化/实例化该 LM-style encoder，对标 CLIP ViT（300M）且避免过大开销。
- **prefix-concatenation（视觉 token 作为前缀与查询 token 拼接）**：论文提到尝试 mBART 风格 encoder-decoder + cross-attn 失败不收敛，并推测原因是视觉 token 交互不足；而前缀拼接能让视觉 token 在各层保持“活跃”，促进与查询 token 信息交换。

---

### 查询 token 数量与 multi-crop：把“阅读重排能力”塞进固定预算

- 规则：查询 token 数 **等于** 视觉 token 数（n=m），并用 multi-crop 统一不同分辨率下的 query 配置。

目的：

1. **保持信息容量不变**：每个查询 token “负责”重排一个视觉 token 的信息，避免信息丢失或冗余。
2. **控制解码器 token 预算**：由于只有查询 token 被送入解码器，n=m 意味着解码器接收的 token 数与原始视觉 token 数一致，不额外增加解码成本。
3. **简化 multi-crop 配置**：1:1 对应关系让不同分辨率的 crop 可以共享统一的查询配置逻辑，便于工程实现和超参管理。
4. **便于公平对比**：总 token 预算（256–1120）与 DeepSeek-OCR 原方案（最高 1156）基本对齐，确保性能提升来自“因果流重排”而非“更多 token”。

配置：

- global view：1024×1024 ⇒ **256 query_global**
- local view：768×768 ⇒ **144 query_local**（所有 local crops 共享同一套 144 queries）
- crops 数 k ∈ [0,6] ⇒ 总 token = **k×144 + 256 ∈ [256,1120]**

与 DeepSeek-OCR 的直接对比：最大 1120 token **低于** DeepSeek-OCR 的 1156（文中称 Gundam mode），并对齐 Gemini-3 Pro 的上限预算。

---

### Attention mask（式 (1) + 图 5）：为什么它能“重排”

- **LowerTri(n)**：n×n 下三角矩阵（对角线及以下为 1），对应标准 decoder-only 的因果掩码。
- **R-order Edit Distance**：阅读顺序的编辑距离（越低越好）。

Mask 分块（式 (1)）：

- 视觉 token 区：全 1（双向可见）
- 查询 token 区：LowerTri（因果）
- 查询 token 可以 attend 到所有视觉 token（下左块全 1），但视觉 token 不看查询 token（上右块全 0）
- 且 n=m

直觉：

- 视觉 token 先形成一个“全局可交互”的视觉场。
- 查询 token 以因果方式逐步读取这个视觉场，并把“读到的内容”编码成序列 ⇒ 更贴近人类阅读的“因果扫视流”。

---

### 复杂度（从掩码结构推出的可解释结论）

设视觉 token 数 m，查询 token 数 n=m。单层注意力的有效计算量（按可见块估算）约为：

- Visual→Visual：m^2
- Query→Visual：n·m = m^2
- Query→Query（因果三角）：~n^2/2 = m^2/2

合计 ≈ **2.5·m^2**（而如果对 2m token 全双向，会是 4m^2）。

> 这不是论文显式数字，是从式 (1) 的可见区域推出来的结构性结论；证据基础：mask 的分块定义与 n=m。

## 术语表

| 术语 | 解释 |
| --- | --- |
| **CLIP ViT** | **Contrastive Language-Image Pre-training Vision Transformer 对比式语言-图像预训练视觉 Transformer。**OpenAI 于 2021 年发布的多模态预训练模型，通过对比学习在 4 亿对图文数据上训练，使图像编码器（ViT）与文本编码器学会将匹配的图文对映射到相近的特征空间。被广泛用作多模态大模型的视觉特征提取器。 |
| **ED** | **Edit Distance 编辑距离。**用于衡量阅读顺序预测与真实顺序之间的差异，数值越低表示预测顺序越接近真实顺序。 |
| **Raster-scan** | **光栅扫描顺序。**一种固定的图像 patch 排列方式，按从左到右、从上到下的顺序将图像切块平铺成序列。传统 ViT 均采用此顺序，但对于复杂文档布局可能引入不合理的归纳偏置，不能反映真实的阅读顺序。 |
| **SAM-base** | **Segment Anything Model - Base。**Meta 发布的通用图像分割模型，Base 版本约 80M 参数。在 DeepSeek-OCR 2 中被用作视觉 tokenizer 的 backbone，配合卷积层实现图像特征提取与 token 压缩。 |
| **Token compression 16×** | **16 倍 token 压缩。**指视觉 token 数被窗口注意力/压缩模块减少到原来的 1/16 量级。在 DeepSeek-OCR 2 中，通过 SAM-base 后的 2 个卷积层实现，目的是在进入全局注意力的 LM-style encoder 前就把 token 数压到可控规模，降低计算与显存开销。 |
| **LowerTri(n)** | **n×n 下三角矩阵。**对角线及以下为 1，其余为 0。在 Transformer 中用作因果注意力掩码（causal attention mask），确保每个 token 只能 attend 到自己及之前的 token，是标准 decoder-only 模型的基础组件。 |
| **R-order Edit Distance** | **阅读顺序编辑距离。**用于衡量模型预测的阅读顺序与真实阅读顺序之间的差异，数值越低表示预测的阅读顺序越接近真实顺序。在 DeepSeek-OCR 2 中，该指标从 0.085 降到 0.057，证明因果流设计有效提升了阅读顺序建模能力。 |
