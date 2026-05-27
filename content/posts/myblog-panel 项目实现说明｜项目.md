---
title: "myblog-panel 博客发布后台面板｜项目"
date: '2026-05-27T21:19:10+08:00'
tags: ["项目", "FastAPI", "Hugo", "博客自动化", "myblog-panel"]
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
    image: https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/2026/05/myblog-panel-cover.png
    alt: ''
    caption: ''
    hidden: false
---
# myblog-panel 博客发布后台面板

`myblog-panel` 是一个给个人博客使用的私有发布面板。它的目标不是重新实现一套博客系统，而是把原本需要在命令行里执行的博客发布流程，包装成一个可以通过浏览器访问的轻量 Web 控制台。

原本的博客发布链路：

```text
打开服务器 → 进入博客目录 → 执行 myblog-manager 命令 → 检查输出 → 部署 Hugo 站点 → git push
```

`myblog-panel` 把这些步骤收进一个网页里：

```text
打开网页 → 输入密码 → 填写动态 / 摄影 / 音乐表单 → 点击发布 → 等待命令完成 → 查看发布结果和日志
```

项目位置：

```text
/Users/mekeypan/Documents/New project/myblog-panel
```

面向的博客目录：

```text
/home/blogbot/myblog
```

## 设计思路

这个项目可以理解为"命令行发布工具的私有网页外壳"。

实际生成文章、处理图片、发布音乐、部署站点的逻辑，都交给 `myblog-manager` 完成。`myblog-panel` 自己只负责：登录认证、表单收集、文件上传、命令调度、发布前检查和日志展示。

这种设计的好处是项目本身非常薄，核心业务逻辑仍然集中在 `myblog-manager` 里。面板只做协调层，不抢博客生成器的职责。

> [!summary]
> `myblog-panel` 是一个薄 Web 层。它把浏览器里的输入转成受控的命令行调用，再把命令结果和日志反馈回页面。

没有数据库，没有后台队列，没有前端框架，也没有自己实现博客生成逻辑。这种方式很适合个人工具：开发成本低、部署简单、出问题时容易定位、可以复用已有命令行能力，不需要维护额外数据模型。

## 整体架构

![myblog-panel 发布流程图](https://picgo-mekeypan0721.oss-cn-hangzhou.aliyuncs.com/img/2026/05/myblog-panel-flow.svg)

## 技术栈

后端依赖极简，`requirements.txt` 里只有四类核心依赖：

| 依赖 | 用途 |
| --- | --- |
| FastAPI | Web 服务、路由、表单接收、文件上传 |
| Uvicorn | ASGI 服务运行器 |
| Jinja2 | 服务端 HTML 模板渲染 |
| python-multipart | 支持 `multipart/form-data`，用于上传图片 |

前端没有使用 React、Vue 或构建工具，而是采用原生 HTML、CSS 和 JavaScript。这让项目部署起来很简单，也符合它作为私人管理面板的定位。

## 目录结构

```text
myblog-panel/
  README.md
  requirements.txt
  app/
    __init__.py
    main.py
    templates/
      index.html
      login.html
    static/
      app.js
      styles.css
```

各文件职责：

| 文件 | 职责 |
| --- | --- |
| `app/main.py` | FastAPI 主程序，包含认证、发布、上传、Git 检查、日志记录等后端逻辑 |
| `app/templates/index.html` | 登录后的主界面，包含动态、摄影、音乐三个发布表单 |
| `app/templates/login.html` | 密码登录页面 |
| `app/static/app.js` | Tab 切换、图片预览、删除已选图片、发布中状态 |
| `app/static/styles.css` | 页面视觉样式 |

## 后端实现

### 配置初始化

后端主入口是 `app/main.py`。应用初始化时会读取几个环境变量：

```python
BLOG_ROOT = Path(os.getenv("MYBLOG_ROOT", "/home/blogbot/myblog")).expanduser()
SKILL_SCRIPT = Path(
    os.getenv(
        "MYBLOG_MANAGER",
        "/home/blogbot/.codex/skills/myblog-manager/scripts/myblog_manager.py",
    )
).expanduser()
UPLOAD_ROOT = Path(os.getenv("MYBLOG_PANEL_UPLOADS", str(APP_ROOT / "uploads"))).expanduser()
LOG_ROOT = Path(os.getenv("MYBLOG_PANEL_LOGS", "/home/blogbot/logs/myblog-panel")).expanduser()
SESSION_COOKIE = os.getenv("MYBLOG_PANEL_COOKIE", "myblog_panel_session")
SESSION_SECRET = os.getenv("MYBLOG_PANEL_SECRET", "")
PANEL_PASSWORD = os.getenv("MYBLOG_PANEL_PASSWORD", "")
```

这些配置决定了面板连接到哪个博客目录、调用哪个管理脚本、上传文件放在哪里、日志写到哪里，以及登录认证使用什么密码和签名密钥。

其中 `MYBLOG_PANEL_SECRET` 和 `MYBLOG_PANEL_PASSWORD` 是必需的，缺少时程序直接报错：

```python
if not SESSION_SECRET or not PANEL_PASSWORD:
    raise RuntimeError("MYBLOG_PANEL_SECRET and MYBLOG_PANEL_PASSWORD must be set")
```

### 登录与认证

用户访问 `/login` 后输入密码。后端用 `hmac.compare_digest` 比较输入密码和 `MYBLOG_PANEL_PASSWORD`，避免普通字符串比较带来的时序攻击风险。

登录成功后，后端设置一个 HTTP-only cookie：

```python
response.set_cookie(
    SESSION_COOKIE,
    _session_value(),
    httponly=True,
    samesite="strict",
    secure=False,
    max_age=60 * 60 * 24 * 30,
)
```

cookie 的值不是随机 session id，而是通过 `SESSION_SECRET` 计算出的固定 HMAC：

```python
def _session_value() -> str:
    return hmac.new(SESSION_SECRET.encode(), b"myblog-panel", "sha256").hexdigest()
```

每个需要登录的路由都依赖 `require_auth`，认证失败则 303 跳转到 `/login`。

这个方案适合放在 Tailscale 或 SSH tunnel 后面的私人面板。如果要暴露到公网，应该启用 HTTPS、设置 `secure=True`，并考虑更完整的 session 管理、速率限制和 CSRF 防护。

### 文件上传

图片上传由 FastAPI 的 `UploadFile` 接收，保存逻辑在 `save_uploads`：

```python
async def save_uploads(files: list[UploadFile]) -> list[str]:
    saved: list[str] = []
    batch = UPLOAD_ROOT / _now_stamp()
    for idx, item in enumerate(files or [], start=1):
        if not item.filename:
            continue
        data = await item.read()
        if not data:
            continue
        batch.mkdir(parents=True, exist_ok=True)
        path = batch / f"{idx}-{_safe_upload_name(item.filename)}"
        path.write_bytes(data)
        saved.append(str(path))
    return saved
```

每次上传会按时间戳创建批次目录，文件名经过 `_safe_upload_name` 清洗，只保留字母、数字、点、短横线和下划线，避免用户上传文件名影响服务器路径。保存后的图片路径会作为 `--image` 参数传给 `myblog-manager`。

### 命令执行

核心桥接函数是 `_base_cmd` 和 `run_cmd`。

`_base_cmd` 生成调用 `myblog-manager` 的基础命令：

```python
def _base_cmd() -> list[str]:
    return [
        "python3",
        str(SKILL_SCRIPT),
        "--blog-root",
        str(BLOG_ROOT),
    ]
```

`run_cmd` 负责真正执行命令：

```python
proc = subprocess.run(
    cmd,
    cwd=str(BLOG_ROOT),
    text=True,
    capture_output=True,
    timeout=timeout,
    env=env,
)
```

执行要点：

- 命令工作目录是 `BLOG_ROOT`
- 标准输出和错误都会被捕获
- 各类命令有独立超时，发布类最长可达 720 秒
- 命令结果写入日志文件
- 页面只显示最后 12000 个字符，避免输出过长撑爆页面

命令结果封装为 `CommandResult`：

```python
@dataclass
class CommandResult:
    command: str
    code: int
    output: str
    log_path: Path
    url: str = ""
```

模板根据 `code` 判断成功或失败，并展示命令输出。

### 发布前检查

在真正发布前，动态和音乐发布会调用 `preflight_publish`，做三层检查：

1. `git fetch origin main`
2. `git status --short` 确认工作区干净
3. `git rev-list --left-right --count HEAD...origin/main` 确认本地和远端同步

如果仓库有未提交变更，或本地和 `origin/main` 不同步，发布会被阻止。这是为了避免 Web 面板在服务器上直接生成新文章时，覆盖或混入未处理的 Git 状态。

### 部署与推送

命令执行完成后，`push_after_publish` 根据结果决定是否推送：

```python
def push_after_publish(result: CommandResult) -> CommandResult:
    if result.code == 0:
        push = run_git(["push", "origin", "main"], timeout=180)
        result.output = result.output + "\n\n" + push.output
        result.code = push.code
        if push.code == 0:
            result.url = "https://mekeypan.com/posts/"
    return result
```

只有 `myblog-manager` 发布命令成功后，才会执行 `git push origin main`。推送成功后，页面会显示博客文章列表链接。

### 三类发布流程

**动态发布**（`/quick-publish`）

允许只写文字、只传图片或图文混合。后端调用：

```text
publish-photo-note --text ... --no-draft --write --deploy --image ...
```

如果用户既没有输入文字也没有上传图片，后端直接返回错误：`Add text or at least one image before publishing.`

**摄影发布**（`/photo/publish`）

表单包含标题、正文和图片。同样调用 `publish-photo-note`，但会额外传入标题：

```text
publish-photo-note --title ... --text ... --no-draft --write --deploy --image ...
```

表单里默认带有：

```html
<input type="hidden" name="draft" value="false" />
<input type="hidden" name="deploy" value="true" />
```

即面向"直接发布并部署"的使用方式。

**音乐发布**（`/music/publish`）

用户只需输入网易云音乐链接，后端调用：

```text
publish-music --netease-url ... --write --deploy
```

发布成功后同样继续执行 Git push。

### 日志系统

每次命令执行都通过 `_log_result` 写入日志：

```python
path = LOG_ROOT / f"{_now_stamp()}-{name}.log"
```

日志内容包含完整命令和输出：

```text
$ python3 ... myblog_manager.py ...

命令输出...
```

主页面的"更多"区域通过 `recent_logs` 读取最近 8 个日志文件，显示每个日志最后 4000 个字符，方便发布失败时排查问题。

## 前端实现

### 主界面结构

登录后的页面由 `app/templates/index.html` 渲染，包含三个发布 Tab：

| Tab | 表单 action | 用途 |
| --- | --- | --- |
| 动态 | `/quick-publish` | 发布文字、图片或图文动态 |
| 摄影 | `/photo/publish` | 发布摄影文章 |
| 音乐 | `/music/publish` | 根据网易云链接发布音乐文章 |

页面底部还有一个"更多"区域，用于显示 Git 状态、执行仓库同步、查看最近命令日志。

主界面不是单页应用。表单提交后，后端执行命令，再重新渲染同一个 `index.html`，把结果作为 `result` 传回模板。

### Git 状态面板

页面每次渲染时都会带上 `git_summary`：

```python
return {
    "branch": git(["branch", "--show-current"]),
    "head": git(["log", "-1", "--oneline"]),
    "sync": git(["rev-list", "--left-right", "--count", "HEAD...origin/main"]),
    "status": git(["status", "--short"]) or "clean",
}
```

模板会显示当前分支、最新提交、同步状态和工作区状态，让用户随时了解博客仓库是否处于干净状态。

### 前端交互脚本

前端脚本在 `app/static/app.js`，主要做三件事：

**Tab 切换：**

```javascript
function activateTab(name) {
  tabs.forEach((tab) => {
    const isActive = tab.dataset.tabTarget === name;
    tab.classList.toggle("active", isActive);
    tab.setAttribute("aria-selected", String(isActive));
  });

  panels.forEach((panel) => {
    panel.classList.toggle("active", panel.dataset.tabPanel === name);
  });
}
```

**图片预览：** 用户选择图片后，脚本用 `URL.createObjectURL(file)` 在页面显示缩略图，并把第一张标记为"封面"。每张图右上角有删除按钮，删除后会重新同步 `<input type="file">` 的文件列表。

**发布中状态：** 表单提交后，按钮会禁用，文字变为"发布中..."，并显示三步进度提示（上传图片 → 生成文章 → 部署博客）。这个进度不是实时后端进度，而是一个前端等待状态，用于避免用户重复点击。

### 页面设计

视觉上采用简洁的 Apple 风格：浅灰背景、半透明卡片、大圆角、蓝色主按钮、原生系统字体，以移动端优先为宽度基准：

```css
.app-shell,
.login-shell {
  width: min(720px, calc(100vw - 32px));
  margin: 0 auto;
}
```

主界面宽度限制在 720px，主要面向手机或窄屏使用场景，适合随手发布动态、摄影和音乐的私人面板。

## 可以改进的方向

**增强安全性：** 当前 `secure=False` 适合内网或 SSH tunnel。如果未来通过 HTTPS 暴露访问，应改成 `secure=True`，并加上 CSRF 防护、登录失败限制和更完整的 session 机制。

**增加实时日志：** 当前发布时页面等待请求完成，前端只显示静态"发布中"状态。可以改成后台任务加 Server-Sent Events 或 WebSocket，实时显示部署步骤和命令输出。

**补齐预览流程：** 代码里已有 `/photo/preview` 和 `/music/preview`，但主界面没有暴露预览按钮。可以让用户先生成草稿、查看效果，再确认发布。

**增加文章管理能力：** 比如列出最近文章、删除草稿、重新部署、查看图片上传历史等。

**完善错误提示：** 现在页面直接展示命令输出，对懂命令行的人很友好，但对移动端快速操作来说，可以把常见错误翻译成更明确的提示。

## 总结

`myblog-panel` 是一个非常典型的个人自动化工具：不是大而全的后台系统，而是围绕一个明确工作流做的轻量控制台。

后端用 FastAPI 接收表单和图片，调用 `myblog-manager` 完成内容生成和部署；前端用原生 JS 提供必要的交互；Git 预检和日志系统保证发布过程可控、可追踪。

它最重要的价值不是技术复杂度，而是把"写博客、传图片、部署、推送"这条链路压缩成了一个网页按钮。这种小而稳定的工具，正是个人博客长期维护里最能节省心力的部分。
