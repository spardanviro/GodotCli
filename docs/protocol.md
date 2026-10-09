# gdcli 协议（protocol 1，草案）

状态：草案，待评审。评审通过后，改动本文件必须同时改 `cli/src/protocol.ts` 和 `bridge/addons/gdcli/plugin.gd` 里的协议号，并由 `scripts/check-versions.mjs` 校验。

本文定义三件事：

1. `gd` 命令行怎样驱动 Godot（两条通道）。
2. 命令行与编辑器内桥接插件之间的线上协议（发现、传输、认证、命令、返回值）。
3. `gd` 对调用方（人、脚本、智能体）的输出约定（信封、错误码、退出码）。

术语：**桥接**指编辑器里的 `addons/gdcli` 插件；**宿主**指承载桥接的编辑器进程（带界面或无头）；**实例**指一个正在运行的宿主。

---

## 1. 两条通道

Godot 自带的命令行是"一次性进程"模型：每条命令启动一个新进程，做完就退出。它管不了已经打开的编辑器。所以 `gd` 有两条通道，按命令自动选择。

| 通道 | 做法 | 需要 | 适合 |
|---|---|---|---|
| 离线 | `gd` 启动 Godot 可执行文件，等它退出，解析输出 | 只要有 Godot 可执行文件 | 运行并收集报错、检查脚本、导入、导出、查接口文档、持续集成 |
| 在线 | `gd` 通过本机 HTTP 调用桥接 | 编辑器开着且装了桥接 | 读写场景树、节点、资源、编辑器状态，全部可撤销 |

### 1.1 离线通道与 Godot 参数的对应

来源：官方 `tutorials/editor/command_line_tutorial`。"可用性"一列是官方图例：**编辑器** = 仅编辑器构建；**扩展** = 编辑器构建，以及未禁用路径覆盖的导出模板；**全部** = 所有构建。`gd` 的离线命令一律要求编辑器构建。

| `gd` 命令 | 实际调用 | 可用性 |
|---|---|---|
| `gd doctor` | `godot --version`，外加环境检查 | 全部 |
| `gd open [场景]` | `godot --editor --path <项目> [场景]` | 编辑器 |
| `gd run [场景] [--seconds N] [--headless]` | `godot --path <项目> [场景] --debug [--headless]`，由 `gd` 计时并结束进程 | 全部（`--path` 为扩展） |
| `gd check <脚本>…` | `godot --headless --path <项目> --check-only --script <脚本>` | 扩展 |
| `gd exec <脚本> [-- 参数]` | `godot --headless --path <项目> --script <脚本> -- 参数` | 扩展 |
| `gd import` | `godot --headless --path <项目> --import` | 编辑器 |
| `gd export <预设> <输出>` | `godot --headless --path <项目> --export-release\|--export-debug\|--export-pack <预设> <绝对路径>` | 编辑器 |
| `gd api class <类名>` | 首次：在缓存目录执行 `godot --headless --dump-extension-api-with-docs`，之后读缓存 | 编辑器 |
| `gd host start` | `godot --headless --editor --path <项目> --lsp-port <空闲> --dap-port <空闲> -- --gdcli-host` | 编辑器 |

从官方文档得出的硬约束：

- **未知参数不报错**。Godot 会静默忽略不认识的参数。`gd` 必须先用 `godot --version` 确认版本，再决定能不能用某个参数；每个参数的最低版本记在命令行内的一张表里，由持续集成的版本矩阵验证。
- **导出路径相对于项目目录**，不是当前目录。`gd export` 一律把输出路径转成绝对路径再传。
- **`--script` 的脚本必须继承 `SceneTree` 或 `MainLoop`**。`gd exec` 在启动前检查并给出明确报错。
- **`--quit-after` 按帧计数**，不是按秒。`gd run --seconds` 由命令行自己计时，到时结束子进程。
- **没有显卡的环境必须加 `--headless`**。
- **`--recovery-mode` 会禁用编辑器插件**，桥接不会加载。这是唯一一种"编辑器开着但连不上"的常态情形，`gd doctor` 要能指出来。
- **`--` 之后的参数引擎不处理**，可用 `OS.get_cmdline_user_args()` 读到。`gd host start` 用它告诉桥接"你是被命令行拉起的无头宿主"，以便空闲超时后自行退出。
- Windows 上要用带 `console` 后缀的可执行文件才能拿到标准输出。

Godot 可执行文件的查找顺序：`--godot <路径>` 参数 → 环境变量 `GODOT_BIN` → `~/.gdcli/config.json` → `PATH` 里的 `godot`、`godot4`。找不到返回 `GODOT_NOT_FOUND`。

### 1.2 为什么"运行并收集报错"走离线通道

游戏进程与编辑器是两个进程，4.5 之前编辑器插件没有公开接口读取运行中游戏的报错。由 `gd` 直接启动游戏进程，就能拿到完整的标准输出和标准错误，4.3 起都能用，也不依赖桥接。编辑器内的"播放/停止"仍作为在线命令提供，给人看效果用。

### 1.3 离线通道的安全约束

**离线命令都会执行项目里的代码。** `run`、`import`、`export`、`open`、`host start` 会加载项目的 `@tool` 脚本、自动加载和插件，`exec` 直接运行脚本。这与用户自己用 Godot 打开该项目的风险相同，第 4.3 节的访问模式管不到它们。用户级配置 `~/.gdcli/config.json` 里的 `allow_offline`（默认 `true`）可以整体关闭离线通道；这个开关不从项目目录读取。

启动子进程的规则：

- 用参数数组直接启动，不经过命令解释器，不使用 `.cmd` / `.bat` 垫片。
- Godot 可执行文件由 `gd` 自己解析成绝对路径再启动，**不在当前目录里查找**。Windows 的默认查找顺序把当前目录排在 `PATH` 前面，而智能体的当前目录通常就是项目目录，项目里放一个 `godot.exe` 就会被执行。
- 场景和脚本参数必须通过第 4.4 节的路径检查，再以 `res://` 形式传给 Godot。
- 导出预设名必须与 `export_presets.cfg` 里的某个预设完全相同。
- 任何来自调用方的值，只要以 `-` 开头，就不能出现在 Godot 的选项位置上；`gd exec` 的用户参数一律放在字面量 `--` 之后。
- `gd export` 的输出路径若已存在，需要 `--yes` 才覆盖。

---

## 2. 发现

宿主启动时，桥接在用户目录写一个锁文件；退出时删除。

- 目录：环境变量 `GDCLI_HOME`，未设置时为 `~/.gdcli`。锁文件在其下的 `instances/<instance_id>.json`。
- 选用户目录而不是项目目录的原因：令牌不会被误提交到版本库；用户目录默认只有本人可读；`gd status` 在任何目录都能列出所有实例。
- 写入顺序：先开始监听端口；再创建临时文件并把权限收紧到 `0600`（目录 `0700`）；然后写入内容；最后改名成正式文件名（原子替换）。令牌不会出现在权限尚未收紧的文件里。
- Windows 上依赖用户目录继承的访问控制。`GDCLI_HOME` 指向用户目录之外时，由用户自己保证该目录只有本人可读，`gd doctor` 给出提示。

```json
{
  "schema": 1,
  "instance_id": "9f2c41d07a5be813",
  "pid": 12345,
  "host": "127.0.0.1",
  "port": 51234,
  "token": "<64 位十六进制>",
  "protocol": 1,
  "bridge_version": "0.1.0",
  "godot_version": "4.3.stable",
  "project_path": "C:/Users/me/games/platformer",
  "project_name": "Platformer",
  "headless": false,
  "started_at": "2026-10-09T12:00:00Z"
}
```

命令行选择实例的规则：

1. 确定项目：`--project <路径>` → 环境变量 `GDCLI_PROJECT` → 从当前目录向上找 `project.godot`。都没有返回 `NO_PROJECT`。
2. 取 `project_path` 与之相同的锁文件（比较前统一分隔符，Windows 上不区分大小写）。
3. 对每个候选做握手（见下）。握手不通过的一律当作不存在。
4. 没有可达实例：`NO_EDITOR`。多于一个：`MULTIPLE_EDITORS`，并在 `details` 里列出，用 `--instance <id>` 指定。

命令行对锁文件的校验，任何一条不满足就忽略该文件：

- 是普通文件，不是符号链接；类 Unix 系统上属主是当前用户，且组和其他人没有任何权限。
- `instance_id` 匹配 `^[0-9a-f]{16}$`，并与文件名一致。
- `port` 在 1024 到 65535 之间。
- **忽略 `host` 字段**，固定连接 `127.0.0.1`。这个字段只是给人看的。

### 2.1 握手

命令行在把令牌发给任何端口之前，先确认对方确实持有令牌：

1. 命令行生成 16 字节随机数 `nonce`，发 `GET /v1/ping?nonce=<十六进制>`，**不带令牌**。
2. 桥接返回 `instance_id`、`protocol`、`bridge_version`，以及 `proof = HMAC-SHA256(令牌, nonce + instance_id)`。
3. 命令行用锁文件里的令牌自己算一遍，一致才继续，之后的请求才带令牌。

这样，编辑器退出后别的进程占了同一个端口，也拿不到令牌和后续命令。

**不做心跳**，存活以握手为准。连接被拒的锁文件由命令行顺手删除（只删自己枚举到的、通过了上面文件检查的那一个）；进程号只用于给人看，不作为判断依据，因为进程号会被复用。连接成功但超时不响应，说明编辑器主线程在忙（导入、长操作），返回 `EDITOR_BUSY`，这是可重试错误。

---

## 3. 传输

- 仅监听 `127.0.0.1`，端口由系统随机分配。第 1 版没有任何让它监听其他地址的配置。
- HTTP/1.1，每个连接只处理一个请求（`Connection: close`）。正文是 UTF-8 的 JSON。
- 桥接在编辑器主线程的 `_process` 里轮询连接，读写都不阻塞。命令**逐条串行**执行，先到先做。所以调用方看到的是严格顺序语义，不存在两条命令交错修改场景。

HTTP 解析是手写的，所以把它能接受的东西限定得很窄，其余一律 `400` 并断开：

- 方法只有 `GET` 和 `POST`。请求行不超过 2 KB，请求头总共不超过 8 KB、不超过 64 个。
- 出现 `Transfer-Encoding` 或 `Expect` 即拒绝。`Host`、`Authorization`、`Content-Type`、`Content-Length` 任何一个重复即拒绝。
- `POST` 必须带 `Content-Length`，值是纯十进制数字，不超过 4 MB（超过返回 `413`）。
- 路径不做百分号解码。命令名必须匹配 `^[a-z][a-z0-9_]*$`。
- 时限按整个请求计算：连接建立后 1 秒内必须发完请求头，5 秒内必须发完正文。
- 同时最多 8 个连接。
- **先检查后读正文**：请求头读完就做第 4.2 节的检查，通过了才读正文。没有令牌的连接最多让桥接读 8 KB。
- 选 HTTP 而不是 WebSocket：`gd` 是无状态的短进程；用 `curl` 就能调试；MCP 服务器放在命令行一侧，桥接不需要长连接。

### 3.1 端点

只有三个。其余一切都是命令。

| 方法与路径 | 作用 |
|---|---|
| `GET /v1/ping?nonce=<十六进制>` | 握手（第 2.1 节）。不带令牌，只返回身份信息和 `proof` |
| `GET /v1/commands` | 返回命令注册表（见第 6 节） |
| `POST /v1/commands/<名字>` | 执行一条命令 |

后两个端点要求令牌。

请求正文：

```json
{
  "args": { "parent": ".", "type": "CharacterBody2D", "name": "Player" },
  "dry_run": false,
  "confirm": false
}
```

---

## 4. 安全

### 4.1 威胁模型

要防的：

- **同一台机器上的其他用户**：靠锁文件权限、握手和令牌。
- **浏览器里的恶意网页**向本机端口发请求（跨站请求、DNS 重绑定）：见 4.2。
- **克隆来的不可信项目**通过项目文件抬高智能体的权限：访问模式不存在项目目录里，见 4.3。
- **智能体的误操作**：靠风险分级、只读模式、破坏性操作确认、空跑。

不防的：以同一用户身份运行的恶意程序。它本来就能读写项目文件和锁文件。

必须说清楚的一点：**`standard` 模式下，智能体拥有在编辑器和游戏里执行代码的能力。** 写脚本是开发游戏的本职，脚本被编辑器或游戏加载就会运行；而且智能体通常还有自己的文件读写工具，不经过桥接也能改项目。所以风险分级是**护栏，不是沙箱**：它让常规路径不出事故，让危险动作必须显式表态，但拦不住一个存心绕过的调用方。真正有约束力的只有两样：`readonly` 模式（桥接不做任何修改），以及 `ask` 模式下由人在编辑器里点确认。

### 4.2 每个请求的检查顺序

请求头读完后依次检查，任何一步不过就直接响应并断开，不读正文：

1. 带 `Origin` 或 `Sec-Fetch-Site` 请求头的一律拒绝（`403 FORBIDDEN_ORIGIN`）。`gd` 从不发送这两个头，浏览器发起的请求一定带其中之一。
2. `Host` 必须是 `127.0.0.1:<端口>` 或 `localhost:<端口>`，否则 `403`。
3. 除 `ping` 外，必须有 `Authorization: Bearer <令牌>`，不匹配返回 `401 AUTH_FAILED`。比较方式：对收到的值和正确的值各算一次 SHA-256，再比较两个摘要，避免逐字节比较泄露时间信息。
4. `POST` 必须是 `Content-Type: application/json`，否则 `415`。
5. 任何响应都不带 `Access-Control-*` 头；`OPTIONS` 等其他方法在解析阶段就已拒绝。

令牌每次启动重新生成，32 字节随机数，来自 `Crypto.generate_random_bytes`。令牌只出现在锁文件和请求头里，不写日志，不进命令行输出，`gd status` 也不显示。

### 4.3 风险分级与访问模式

每条命令声明一个风险等级：

| 等级 | 含义 | 例子 |
|---|---|---|
| `read` | 不改变任何状态 | 场景树、节点属性、报错列表 |
| `write` | 修改，可撤销或影响有限。**包括写脚本** | 建节点、设属性、保存场景、写 `.gd` 文件 |
| `destructive` | 删除、覆盖，或改动会影响编辑器和项目如何加载的东西 | 删文件、覆盖已有文件、改项目设置、写入 4.4 节列出的敏感路径 |
| `exec` | 立即在编辑器进程里执行调用方给的代码 | `eval` |

访问模式存在**编辑器设置**里（每个用户一份，不随项目走）：`gdcli/access/mode` 和 `gdcli/access/allow_eval`。

| 模式 | `read` | `write` | `destructive` | `exec` |
|---|---|---|---|---|
| `readonly` | 允许 | `READONLY_MODE` | `READONLY_MODE` | `READONLY_MODE` |
| `standard`（默认） | 允许 | 允许 | 需要 `confirm: true` | 需 `allow_eval`，且需要 `confirm: true` |
| `ask` | 允许 | 允许 | 编辑器弹窗，由人确认 | 需 `allow_eval`，且由人确认 |
| `full` | 允许 | 允许 | 允许 | 需 `allow_eval` |

- **项目文件里的同名设置一律忽略。** `project.godot` 在磁盘上，智能体改得了，克隆来的仓库也带得进来。桥接启动时若发现项目设置里有 `gdcli/` 开头的键，在握手响应的 `warnings` 里提示。
- 这两项设置只能在编辑器的设置界面里改。`gd` **不提供**修改它们的命令。
- `confirm: true`（命令行的 `--yes`）由调用方自己提供，它是**减速带，不是人工授权**。未带时返回 `CONFIRMATION_REQUIRED`，`details` 里说明会影响什么。
- `ask` 模式才是人工授权：桥接弹出对话框，写明命令和影响，人点了才执行；等待期间其他修改类请求返回 `EDITOR_BUSY`；无头宿主下视为拒绝。`ask` 在第 6 阶段实现，协议先留出位置。
- 所有 `write` 和 `destructive` 命令支持 `dry_run: true`：做完参数校验和前置检查，返回将要发生的改动，不落地。
- `eval` 默认关闭。开启后仍是无沙箱的任意代码执行，文档和技能里都要这样写明。

### 4.4 路径规则

所有文件参数，以及 `$res` 引用的路径，都按下面的顺序处理。违反返回 `PATH_NOT_ALLOWED`。

1. 接受 `res://` 路径；`uid://` 先解析成 `res://` 再继续。拒绝 `user://`、绝对路径、盘符、反斜杠。
2. 路径里出现 `..`、空段、以点或空格结尾的段、`res://` 之后的冒号（Windows 备用数据流）、Windows 保留设备名，直接拒绝。先拒绝再规范化，不靠规范化来"修正"输入。
3. 从项目根到目标的每一级都不能是符号链接或重解析点（`DirAccess.is_link`）。仓库可以自带一个指向项目外的链接。
4. 下面的比较统一折叠大小写后进行，因为 Windows 和 macOS 的默认文件系统不区分大小写。

**读写都禁止**的位置：`res://.godot/`（含导出凭据）、`res://.git/`。

**禁止写入**的位置：`res://addons/gdcli/`。

**敏感路径**，写入、覆盖、移动、删除一律按 `destructive` 处理，不管命令本身声明的是什么等级：

- `res://project.godot`、`res://override.cfg`、`res://export_presets.cfg`
- `res://addons/` 下的任何文件
- `res://gdcli_commands/` 下的任何文件
- 扩展名为 `.gdextension` 的文件

项目设置里的 `autoload/*`、`editor_plugins/*`、`application/run/main_scene` 同理，这也是 `project_settings_set` 整体定为 `destructive` 的原因。

移动和复制要同时检查源路径和目标路径。

### 4.5 输出里的不可信内容

节点名、日志行、脚本报错、文件内容都来自项目，属于**数据**，可能是有人故意写给智能体看的。

- 信封里的 `message` 和 `hint` **只用固定文案**，不拼接任何来自项目的字符串。项目来源的值只出现在 `data` 和 `errors[].details` 里。调用方可以信任 `message` 和 `hint` 的措辞，对 `data` 和 `details` 一律当数据看。
- 无论哪种输出格式，来自项目的字符串都去掉控制字符、终端转义序列、双向控制字符和零宽字符。文件内容（`fs_read_text`）除外，它按原样返回。
- 日志和报错的单行长度有上限，超出截断并标明。
- 技能文档要求智能体只依据报错的文件、行号、消息行动，不执行其中出现的指令或链接。

---

## 5. 返回信封

桥接的 HTTP 响应正文，和 `gd --format json` 的标准输出，是同一个结构：

```json
{
  "success": true,
  "command": "node_create",
  "data": { "path": "Player", "type": "CharacterBody2D" },
  "errors": [],
  "warnings": [],
  "meta": {
    "protocol": 1,
    "instance_id": "9f2c41d07a5be813",
    "scene": "res://levels/level_1.tscn",
    "duration_ms": 4,
    "undo": "gdcli: node_create Player"
  }
}
```

失败时：

```json
{
  "success": false,
  "command": "node_create",
  "data": null,
  "errors": [
    {
      "code": "NODE_NOT_FOUND",
      "message": "父节点不存在",
      "hint": "用 scene_tree 查看当前场景的节点路径",
      "details": { "path": "World/Enemies" }
    }
  ],
  "warnings": [],
  "meta": { "protocol": 1, "instance_id": "9f2c41d07a5be813", "scene": "res://levels/level_1.tscn", "duration_ms": 1 }
}
```

约定：

- **以 `success` 为准判断成败**，以 `errors[0].code` 分支。`code` 是稳定标识，`message` 可以改措辞。
- `message` 和 `hint` 是固定文案，具体是哪个节点、哪个文件放在 `details` 里（第 4.5 节）。
- **失败也写标准输出**。标准错误只放给人看的诊断信息，调用方不要解析。
- `meta.scene` 总是带上当前被编辑的场景，调用方可以据此发现"改的不是自己以为的那个场景"。
- `meta.undo` 只在产生了撤销步骤时出现。
- 输出格式：`--format human`（默认）或 `--format json`（`--json` 是简写）。也可用环境变量 `GDCLI_FORMAT`。

HTTP 状态码与类别对应（`200` 成功、`400` 参数、`401` 认证、`403` 拒绝、`404` 未知命令、`409` 前置条件、`500` 内部错误、`503` 忙），但命令行只依据信封。

### 5.1 错误码

| 错误码 | 含义 | 退出码 |
|---|---|---|
| `USAGE` | 命令行用法错误 | 2 |
| `INVALID_ARGS` | 参数缺失、类型不对、取值非法 | 2 |
| `UNKNOWN_COMMAND` | 没有这条命令 | 2 |
| `AUTH_FAILED` | 令牌不对或缺失 | 3 |
| `FORBIDDEN_ORIGIN` | 请求来自浏览器或 `Host` 不对 | 3 |
| `NO_PROJECT` | 找不到 `project.godot` | 4 |
| `GODOT_NOT_FOUND` | 找不到 Godot 可执行文件 | 4 |
| `UNSUPPORTED_GODOT_VERSION` | Godot 版本低于该功能的最低要求 | 4 |
| `BRIDGE_NOT_INSTALLED` | 项目里没有桥接或未启用 | 4 |
| `NO_EDITOR` | 没有可达的实例 | 4 |
| `MULTIPLE_EDITORS` | 同一项目有多个实例，未指定 | 4 |
| `PROTOCOL_MISMATCH` | 命令行与桥接的协议号不兼容 | 4 |
| `READONLY_MODE` | 只读模式下调用了修改类命令 | 4 |
| `CONFIRMATION_REQUIRED` | 破坏性命令未确认 | 4 |
| `EVAL_DISABLED` | `eval` 未开启 | 4 |
| `PRECONDITION_FAILED` | 状态不满足，例如没有打开的场景 | 4 |
| `EDITOR_BUSY` | 编辑器在忙，稍后重试 | 5 |
| `TIMEOUT` | 超过 `--timeout` | 5 |
| `PATH_NOT_ALLOWED` | 路径不在允许范围内 | 6 |
| `NODE_NOT_FOUND` | 节点不存在 | 6 |
| `RESOURCE_NOT_FOUND` | 资源或文件不存在 | 6 |
| `ALREADY_EXISTS` | 目标已存在 | 6 |
| `TYPE_MISMATCH` | 值无法转换成目标类型 | 6 |
| `COMMAND_FAILED` | 命令执行失败（其余情况） | 6 |
| `INTERNAL_ERROR` | 桥接或命令行自身的缺陷 | 1 |

### 5.2 退出码

| 退出码 | 含义 | 调用方该怎么做 |
|---|---|---|
| 0 | 成功 | — |
| 1 | 内部错误 | 报告缺陷 |
| 2 | 用法或参数错误 | 改命令 |
| 3 | 认证失败 | 检查实例，重新发现 |
| 4 | 前置条件不满足 | 按 `hint` 准备环境 |
| 5 | 暂时性失败 | 等待后重试 |
| 6 | 命令执行失败 | 读 `errors`，修正后再试 |
| 130 | 被中断 | — |

0、1、2、3、4、6 的含义与 Unity 命令行一致。5 是新增的，Unity 没有使用这个值；智能体需要区分"重试就行"和"得改点什么"。

---

## 6. 命令

### 6.1 描述符

`GET /v1/commands` 的 `data.commands` 里每项：

```json
{
  "name": "node_create",
  "group": "node",
  "summary": "在当前场景里新建一个节点",
  "risk": "write",
  "undoable": true,
  "requires": ["scene_open"],
  "params": {
    "type": "object",
    "properties": {
      "parent": { "type": "string", "description": "父节点路径，相对场景根；\".\" 表示根", "default": "." },
      "type":   { "type": "string", "description": "节点类名，如 CharacterBody2D" },
      "name":   { "type": "string" },
      "properties": { "type": "object", "description": "创建后要设置的属性" }
    },
    "required": ["type"]
  },
  "returns": "新节点的路径和类型",
  "since": 1
}
```

- 命名：`<分组>_<动作>`，小写加下划线。命令行、MCP 工具名、技能文档用同一个名字，不做转换。
- `params` 是 JSON Schema 的子集，只用这些关键字：`type`、`properties`、`required`、`enum`、`default`、`description`、`items`、`minimum`、`maximum`。这样第 5 阶段可以原样作为 MCP 工具的输入结构。
- `requires` 是前置条件标识，第 1 版有 `scene_open`、`not_playing`、`playing`。不满足返回 `PRECONDITION_FAILED`。
- `undoable: false` 的修改类命令（建文件、保存场景、改项目设置）在响应的 `warnings` 里说明"此操作不进撤销栈"。

命令行把 `--键 值` 按结构转换成 `args`（数字、布尔按 `type` 转换）。复杂参数用 `--args '<JSON>'`，或 `--args-file <文件>`，`-` 表示标准输入。

### 6.2 节点与场景的寻址

- 节点路径相对当前被编辑场景的根，`.` 表示根，如 `Player/Sprite2D`。不接受绝对路径和 `..`。
- 第 1 版的修改类命令只作用于**当前被编辑的场景**。要改别的场景先 `scene_open`。响应的 `meta.scene` 会回显。
- 修改不会自动保存。`scene_save` 显式保存；`editor_status` 里有 `unsaved` 列表。

### 6.3 撤销

每条可撤销命令对应编辑器撤销栈里的一步，名字是 `gdcli: <命令> <对象>`，走 `EditorUndoRedoManager`。用户在编辑器里按 Ctrl+Z 能撤回智能体的每一步，`edit_undo` 和 `edit_redo` 命令做同样的事。

### 6.4 值的编码

JSON 能直接表示的类型原样传。其余类型：

**输出**一律带标签，保证无歧义：

```json
{ "$type": "Vector2", "value": [10, 20] }
{ "$type": "Color", "value": "#ff8800ff" }
{ "$type": "NodePath", "value": "../Target" }
{ "$res": "res://art/player.png", "class": "CompressedTexture2D" }
{ "$node": "World/Spawn" }
```

**输入**按目标属性的类型做宽松转换，带标签的写法总是接受：

| 目标类型 | 接受的写法 |
|---|---|
| `int` | 整数；整数值的浮点数 |
| `Vector2` / `Vector3` 等 | 数组 `[x, y]`；对象 `{"x":1,"y":2}`；带标签 |
| `Color` | `"#rrggbb"`、`"#rrggbbaa"`、颜色名；数组 `[r,g,b,a]` |
| `NodePath`、`StringName` | 字符串 |
| 枚举 | 整数或成员名 |
| 资源 | `{"$res":"res://…"}` 加载已有资源；`{"$new":"RectangleShape2D","properties":{…}}` 新建子资源 |
| 节点引用 | `{"$node":"相对场景根的路径"}` |

规则：

- 转换失败返回 `TYPE_MISMATCH`，`details` 里给出属性的期望类型和收到的值。
- **不使用 `str_to_var`**。它能按文本构造任意对象，等于给了一条绕过 `exec` 分级的代码执行路径。
- 为了不让 `$new` 和 `$res` 变成同样的旁路：
  - `$new` 只能构造引擎原生的 `Resource` 子类。`Script` 及其子类、`PackedScene`、`GDExtension` 不能用 `$new` 构造，也就是说**不能凭空造出一段代码**，代码只能来自项目里的文件。
  - `$res` 的路径要过第 4.4 节的检查。
  - 任何命令都不接受直接设置 `script` 属性（包括嵌套在 `properties` 里的）。挂脚本只有 `node_attach_script` 一个入口，参数是项目内脚本文件的路径。
- Godot 的 JSON 解析把所有数字读成浮点数，桥接按目标类型还原成整数。超出 ±2^53 的整数在输出里用 `{"$type":"int","value":"<十进制字符串>"}`。

完整类型表在第 1 至第 3 阶段随命令实现补全，补充不算破坏性变更。

### 6.5 第 1 版命令清单

阶段指 [roadmap.md](roadmap.md) 里的阶段。

| 分组 | 命令 | 风险 | 阶段 |
|---|---|---|---|
| editor | `editor_status`、`editor_selection`、`editor_errors` | read | 1 |
| scene | `scene_tree`、`scene_list_open` | read | 1 |
| node | `node_get`、`node_find` | read | 1 |
| fs | `fs_list`、`fs_read_text` | read | 1 |
| project | `project_settings_get`、`project_input_map` | read | 1 |
| editor | `editor_screenshot` | read | 3 |
| scene | `scene_open`、`scene_new`、`scene_save` | write | 3 |
| node | `node_create`、`node_set`、`node_rename`、`node_move`、`node_duplicate`、`node_attach_script`、`node_connect_signal`、`node_add_to_group`、`node_instantiate_scene` | write | 3 |
| node | `node_delete` | write（可撤销） | 3 |
| resource | `resource_create`、`resource_set` | write | 3 |
| fs | `fs_write_text`、`fs_scan` | write | 3 |
| fs | `fs_delete`、`fs_move` | destructive | 3 |
| project | `project_settings_set`、`project_input_map_set` | destructive | 3 |
| edit | `edit_undo`、`edit_redo` | write | 3 |
| editor | `editor_play`、`editor_stop` | write | 3 |
| exec | `eval` | exec | 3 |

表里是命令的基础等级。目标落在第 4.4 节的敏感路径上时，`fs_write_text` 等命令按 `destructive` 处理；覆盖已有文件同样如此。

类信息、脚本检查、运行并收集报错、导入、导出不在这张表里，它们走离线通道（第 1.1 节）。

### 6.6 项目自定义命令

项目可以在 `res://gdcli_commands/` 放脚本来注册自己的命令。脚本提供描述符和执行函数，接口在第 3 阶段定稿。自定义命令是项目自己的编辑器代码，信任等级与项目里任何 `@tool` 脚本相同。

约束：

- **只在桥接启动时加载**，不随文件系统变化重新扫描。否则"写一个文件"就等于"立即执行一段代码"。新增或修改自定义命令后要重启编辑器或重新启用插件。
- 自报的风险等级只能往高报：桥接把低于 `write` 的声明一律当作 `write`。脚本的实际行为桥接无法核实。
- `readonly` 模式下不加载自定义命令。
- 该目录是第 4.4 节的敏感路径，通过桥接写入需要确认。

---

## 7. 版本

- `protocol` 是整数。只在出现破坏性变更时加一：删除或改名命令、字段，改变已有字段的含义，改变认证或发现方式。
- 新增命令、新增可选参数、新增响应字段不改协议号。调用方必须忽略不认识的字段。
- 命令行声明自己支持的协议范围。握手返回的协议号不在范围内时返回 `PROTOCOL_MISMATCH`，`hint` 指明该升级哪一边（`gd bridge upgrade` 或升级命令行）。
- 桥接版本、命令行版本、Claude 插件版本保持一致，一起发布。

---

## 8. 未决问题

实现时验证，结论回填到本文：

1. `TCPServer.listen(0, "127.0.0.1")` 在 4.3 至 4.7 上是否都能拿到系统分配的端口。不行就在 49152–65535 里随机重试。
2. `--check-only` 对不继承 `SceneTree` 的普通脚本是否给出完整的解析报错。不行就改为通过编辑器的语言服务器（`--lsp-port`）取诊断。
3. 无头编辑器宿主里哪些命令不可用（已知：截图）。`editor_status` 要返回 `capabilities` 列表。
4. Flatpak 等沙箱版 Godot 能否写到 `~/.gdcli`。不能则需要 `GDCLI_HOME` 的文档说明。
5. `DirAccess.is_link` 对 Windows 的目录联接（junction）是否返回真。不是的话第 4.4 节的链接检查在 Windows 上要另找办法。
6. 4.3 上是否有可用的 HMAC-SHA256（`Crypto.hmac_digest`）。握手依赖它。
7. 同一台机器开第二个编辑器时，语言服务器和调试适配器的默认端口会冲突并报错。`gd host start` 已经显式指定端口；带界面的第二个实例是否需要处理，待定。
