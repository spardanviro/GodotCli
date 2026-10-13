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
- **`gd host start` 对同一个项目互斥。** 启动前在 `~/.gdcli/host-locks/<项目路径哈希>.lock` 独占创建一个锁文件（内容是本次 `gd` 的进程号），宿主可达或启动失败后删除。拿不到锁说明另一个 `gd` 正在启动宿主，这时不再启动第二个，只等那一个可达，返回 `started: false`。持锁的 `gd` 已经不在，或锁比最长等待时间还旧，视为过期并接管。
- Windows 上要用带 `console` 后缀的可执行文件才能拿到标准输出。

Godot 可执行文件的查找顺序：`--godot <路径>` 参数 → 环境变量 `GODOT_BIN` → `~/.gdcli/config.json` → `PATH` 里的 `godot`、`godot4`。找不到返回 `GODOT_NOT_FOUND`。

### 1.2 为什么"运行并收集报错"走离线通道

游戏进程与编辑器是两个进程，4.5 之前编辑器插件没有公开接口读取运行中游戏的报错。由 `gd` 直接启动游戏进程，就能拿到完整的标准输出和标准错误，4.3 起都能用，也不依赖桥接。编辑器内的"播放/停止"仍作为在线命令提供；用它启动的游戏可以用 `game_*` 命令查看、操作和调试（第 6.7 节）。不需要交互、只想跑一遍拿报错时，`gd run` 仍是更简单的办法。

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
  "godot_version": "4.3.0-stable",
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
2. 桥接返回 `instance_id`、`protocol`、`bridge_version`，以及 `proof`。`proof` 是 HMAC-SHA256 的十六进制摘要：密钥是令牌（锁文件里那 64 个十六进制字符的 UTF-8 字节，不做解码），消息是 `nonce` 紧接 `instance_id` 两个字符串的 UTF-8 字节。`nonce` 必须是 32 个小写十六进制字符。
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
- 同时最多 8 个连接。满了以后新连接会挤掉最早的、还没发完请求头的那个，空闲连接占不住位置。
- 在读完正文之前就给出响应的情况（认证失败、正文过大等），桥接写完响应后再丢弃约 250 毫秒的输入才关闭，避免客户端因连接被重置而收不到响应。
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

具体地说，`eval` 关着并不等于"不能立即在编辑器里执行代码"。带 `@tool` 的脚本一被加载就在编辑器进程里运行：写一个这样的脚本，再让任何东西加载它（挂到节点上、被资源文件引用、打开用到它的场景），效果就和 `eval` 一样，而且这段代码还能去改编辑器设置里的访问模式。桥接对此只做一件事：通过 `fs_write_text` 写带 `@tool` 的脚本需要确认。这同样是减速带；智能体用自己的文件工具写就绕过去了。

### 4.2 每个请求的检查顺序

请求头读完后依次检查，任何一步不过就直接响应并断开，不读正文：

1. 带 `Origin` 或 `Sec-Fetch-Site` 请求头的一律拒绝（`403 FORBIDDEN_ORIGIN`）。`gd` 从不发送这两个头，浏览器发起的请求一定带其中之一。
2. `Host` 必须是 `127.0.0.1:<端口>` 或 `localhost:<端口>`，否则 `403`。
3. 除 `GET /v1/ping` 外，必须有 `Authorization: Bearer <令牌>`，不匹配返回 `401 AUTH_FAILED`。比较方式：对收到的值和正确的值各算一次 SHA-256，再比较两个摘要，避免逐字节比较泄露时间信息。
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
| `exec` | 把调用方给的代码直接交给编辑器进程执行，不经过文件 | `eval` |

访问模式存在**编辑器设置**里（每个用户一份，不随项目走）：`gdcli/access/mode` 和 `gdcli/access/allow_eval`。

| 模式 | `read` | `write` | `destructive` | `exec` |
|---|---|---|---|---|
| `readonly` | 允许 | `READONLY_MODE` | `READONLY_MODE` | `READONLY_MODE` |
| `standard`（默认） | 允许 | 允许 | 需要 `confirm: true` | 需 `allow_eval`、`confirm: true`，并由人批准 |
| `ask` | 允许 | 允许 | 由人批准 | 需 `allow_eval`，并由人批准 |
| `full` | 允许 | 允许 | 允许 | 需 `allow_eval` |

- **项目文件里的同名设置一律忽略。** `project.godot` 在磁盘上，智能体改得了，克隆来的仓库也带得进来。桥接启动时若发现项目设置里有 `gdcli/` 开头的键，在握手响应的 `warnings` 里提示。
- 这两项设置只能在编辑器的设置界面里改。`gd` **不提供**修改它们的命令。
- `confirm: true`（命令行的 `--yes`）由调用方自己提供，它是**减速带，不是人工授权**。未带时返回 `CONFIRMATION_REQUIRED`，`details` 里说明会影响什么。
- **人工批准**是唯一不经过调用方的确认：桥接在编辑器里弹出对话框，写明命令、原因、目标和将要写入的**完整内容**，人点"Allow"才执行，默认焦点在"Deny"上。它在两种情况下出现：
  1. **会让代码进入编辑器进程、或改变编辑器和项目加载什么的改动**，在 `standard` 和 `ask` 模式下都要人批准，调用方自己带 `confirm: true` 不算数：
     - `fs_write_text` 写入的内容里出现工具注解（`@tool`）。不看扩展名也不看它在哪一行：写在别的注解后面、藏在场景或资源文件内嵌的脚本里都算；注释里提到它也算，宁可多问一次。
     - `fs_write_text` 写入第 4.4 节的敏感位置：`addons/`、`gdcli_commands/`、`project.godot`、`project.binary`、`override.cfg`、`*.gdextension`，以及 C# 构建会执行的 `*.csproj`、`*.sln`、`*.props`、`*.targets` 等。
     - `node_attach_script` 挂的脚本带工具注解。这一条不管脚本是怎么进到项目里的，在加载之前就问。
     - `resource_create`、`resource_set`、`scene_new`、`scene_save` 落在敏感位置。
     - `fs_move` 的源或目标在敏感位置，或者会改写敏感位置里的文件。
     - `project_settings_set` 改 `autoload/`、`editor_plugins/`、`dotnet/` 下的设置，或 `application/config/project_settings_override`、`application/run/main_loop_type`。
     - `eval`。
  2. **`ask` 模式下所有 `destructive` 和 `exec` 命令**，代替调用方的 `confirm`。桥接先把命令空跑一遍：本来就会失败的请求直接返回错误，不打扰人；对话框里显示参数和空跑得出的"将会发生什么"。
- 批准的规则：
  - 没被批准返回 `NOT_APPROVED`，`details.reason` 说明是被拒绝、没人应答、编辑器没有窗口，还是内容太长。
  - **人看到的就是将要写入的全部。** 内容完整显示、自动换行；会被隐藏或改变显示顺序的字符（零宽字符、双向控制符等）显示成 `<U+200B>` 这样的码点。超过 60000 字符的内容不拿去问人，直接拒绝。调用方给的内容显示在一条分隔线下面，与对话框自己的文字分开。
  - **无头编辑器里没有人可问，一律视为拒绝。** 在无头宿主或 CI 里要做这类改动，只能把访问模式设成 `full`，那是用户在自己的编辑器设置里做的决定。
  - 最多等 50 秒；调用方先断开、或桥接停止时，对话框自动撤回并视为拒绝。`gd` 的默认超时因此是 60 秒。人已经点了允许之后调用方才断开的，改动照常完成。
  - 等待期间其他修改类请求返回 `EDITOR_BUSY`，只读命令照常。
  - 空跑不问人。`full` 模式不问人。
  - `fs_write_text` 不写二进制的场景和资源文件（`.scn`、`.res`）：它们能带脚本，而人没法审。
- **这一层管得住什么、管不住什么**，要如实说：
  - 管得住：一切**经过桥接**的、会让代码进入编辑器进程的路径。只通过桥接操作的调用方（例如只接了 MCP 的客户端）拿不到在编辑器里执行代码的办法，也改不了访问模式。
  - 管不住：**调用方自己有写文件的手段时**（多数编码智能体都有），它可以不经过桥接，直接在磁盘上写一个工具脚本；编辑器扫描到文件变化、或有人打开用到它的场景时，这段代码就会运行。桥接看不到这次写入。此时这一层只是让"走桥接"这条路不成为捷径，真正的约束要靠调用方那一侧的权限设置（不让它直接写项目里的脚本），或者操作系统层面的隔离。
  - 管不住：游戏进程。写一个普通脚本再运行游戏，游戏里的代码可以做任何事，包括改编辑器设置文件。
  - 管不住：已经在项目里的代码。打开一个用了工具脚本的场景、用 `$res` 加载这样的资源，会运行那些脚本；它们是项目已有的代码。
  - 批准之后、执行之前的短暂间隙里磁盘状态可能变化（例如 `fs_move` 会重新查找引用）。
  - 离线通道（`gd run`、`gd exec` 等）不经过桥接，不受它管。
- 所有 `write` 和 `destructive` 命令支持 `dry_run: true`：做完参数校验和前置检查，返回将要发生的改动，不落地。
- `eval` 默认关闭。开启后仍是无沙箱的任意代码执行，文档和技能里都要这样写明。

### 4.4 路径规则

所有文件参数，以及 `$res` 引用的路径，都按下面的顺序处理。违反返回 `PATH_NOT_ALLOWED`。

1. 接受 `res://` 路径；`uid://` 先解析成 `res://` 再继续。拒绝 `user://`、绝对路径、盘符、反斜杠。
2. 路径里出现 `..`、空段、以点或空格结尾的段、`res://` 之后的冒号（Windows 备用数据流）、Windows 保留设备名、形如 `GODOT~1` 的短文件名（波浪号后跟数字），直接拒绝。先拒绝再规范化，不靠规范化来"修正"输入。
3. 从项目根到目标的每一级都不能是符号链接或重解析点（`DirAccess.is_link`）。仓库可以自带一个指向项目外的链接。
4. 下面的比较统一折叠大小写后进行，因为 Windows 和 macOS 的默认文件系统不区分大小写。

**读写都禁止**的位置：`res://.godot/`（含导出凭据）、`res://.git/`。

**禁止写入**任何深度的 `.git` 文件夹（嵌套仓库的钩子和配置会被 git 执行）。

**禁止写入**的位置：`res://addons/gdcli/`。

**敏感路径**，写入、覆盖、移动、删除一律按 `destructive` 处理，不管命令本身声明的是什么等级：

- `res://project.godot`、`res://override.cfg`、`res://export_presets.cfg`
- `res://addons/` 下的任何文件
- `res://gdcli_commands/` 下的任何文件
- 扩展名为 `.gdextension` 的文件
- 任何位置的 `.gitmodules`、`.gitattributes`
- 内容带 `@tool` 的 `.gd` 脚本（按内容判断，见 4.1）

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
- 失败时 `data` 通常是 `null`，但不总是：`gd run`、`gd check`、`gd exec`、`gd import`、`gd export` 在发现报错时返回失败，同时在 `data` 里带上完整报告（`diagnostics` 等）。所以只能用 `success` 判断成败，不能用 `data`。
- `meta.scene` 总是带上当前被编辑的场景，调用方可以据此发现"改的不是自己以为的那个场景"。
- `meta.undo` 只在产生了撤销步骤时出现。
- 输出格式：`--format human`（默认）或 `--format json`（`--json` 是简写）。也可用环境变量 `GDCLI_FORMAT`。

HTTP 状态码与类别对应（`200` 成功、`400` 参数、`401` 认证、`403` 拒绝、`404` 未知命令、`409` 前置条件、`422` 命令执行失败、`500` 内部错误、`503` 忙），但命令行只依据信封。

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
| `NOT_APPROVED` | 这个改动要由人在编辑器里批准，而人没有批准（拒绝、超时，或编辑器没有窗口） | 4 |
| `PRECONDITION_FAILED` | 状态不满足，例如没有打开的场景 | 4 |
| `EDITOR_BUSY` | 编辑器在忙，稍后重试 | 5 |
| `TIMEOUT` | 超过 `--timeout`；或运行中的游戏没有在时限内回答（桥接返回，HTTP 504） | 5 |
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
- 修改类命令的处理函数除参数外还会收到请求选项（`dry_run`、`confirm`、当前访问模式），只读命令只收到参数。
- 产生撤销步骤的命令在 `meta.undo` 里给出步骤名。

命令行把 `--键 值` 按结构转换成 `args`（数字、布尔按 `type` 转换）。复杂参数用 `--args '<JSON>'`，或 `--args-file <文件>`。`--<参数名>-file <文件>` 从文件读取单个参数的值（字符串参数原样读入，其余按类型解析），用来传脚本正文，不必为 shell 转义。两处的文件名写成 `-` 都表示标准输入。

### 6.2 节点与场景的寻址

- 节点路径相对当前被编辑场景的根，`.` 表示根，如 `Player/Sprite2D`。不接受绝对路径和 `..`。
- 第 1 版的修改类命令只作用于**当前被编辑的场景**。要改别的场景先 `scene_open`。响应的 `meta.scene` 会回显。
- 修改不会自动保存。`scene_save` 显式保存。

### 6.3 撤销

每条可撤销命令对应编辑器撤销栈里的一步，名字是 `gdcli: <命令> <对象>`，走 `EditorUndoRedoManager`。用户在编辑器里按 Ctrl+Z 能撤回智能体的每一步，`edit_undo` 和 `edit_redo` 命令做同样的事。

### 6.4 值的编码

JSON 能直接表示的类型原样传。其余类型：

**输出**一律带标签，保证无歧义：

```json
{ "$type": "Vector2", "value": [10, 20] }
{ "$type": "Color", "value": "#ff8800ff" }
{ "$type": "NodePath", "value": "../Target" }
{ "$type": "Transform2D", "value": [[1, 0], [0, 1], [30, 40]] }
{ "$type": "PackedVector2Array", "value": [{ "$type": "Vector2", "value": [0, 0] }], "size": 1 }
{ "$res": "res://art/player.png", "class": "CompressedTexture2D" }
{ "$node": "World/Spawn" }
```

**输入**按目标属性的类型做宽松转换，带标签的写法总是接受：

| 目标类型 | 接受的写法 |
|---|---|
| `int` | 整数；整数值的浮点数 |
| `Vector2` / `Vector3` 等 | 数组 `[x, y]`；对象 `{"x":1,"y":2}`；带标签 |
| `Color` | `"#rrggbb"`、`"#rrggbbaa"`、颜色名；数组 `[r,g,b,a]` |
| `Rect2` / `AABB` / `Plane` | 数组：`[x, y, 宽, 高]`；`[x, y, z, 宽, 高, 深]`；`[法线 x, 法线 y, 法线 z, d]` |
| `Transform2D` / `Basis` / `Transform3D` / `Projection` | 列向量数组，顺序与构造函数一致：`Transform2D` 是 `[x 轴, y 轴, 原点]`，`Basis` 是 `[x, y, z]`，`Transform3D` 是 `[x, y, z, 原点]`，`Projection` 是 `[x, y, z, w]`；也接受把这些数摊平成一个数组 |
| `Packed*Array` | 数组，每个元素按元素类型转换，如 `PackedVector2Array` 写 `[[0,0],[16,0]]`；最多 65536 个元素 |
| `NodePath`、`StringName` | 字符串 |
| 上面各数学类型和 `Color` | 也接受脚本里的写法 `"Vector2(100, 50)"`：类型名必须与目标类型一致，括号里只能是数字。这是桥接自己读的，不嵌套、不构造对象 |
| 枚举 | 整数；脚本里的常量名（`"MOUSE_FILTER_IGNORE"`，前面可带类名）；检查器里显示的标签（`"Ignore"`）。常量按属性所在对象的类及其父类查找，且它的值必须是这个枚举的成员之一 |
| 资源 | `{"$res":"res://…"}` 加载已有资源；`{"$new":"RectangleShape2D","properties":{…}}` 新建子资源 |
| 节点引用 | `{"$node":"相对场景根的路径"}` |

规则：

- 转换失败返回 `TYPE_MISMATCH`，`details` 里给出属性的期望类型和收到的值。出错的属性在 `$new` 里面时，`details.property` 是完整路径（`mesh.size`）。
- 可以设置的属性是检查器显示的或文件里保存的那些，另加一小组"换一种写法"的派生属性：`rotation_degrees`、`global_position`、`global_rotation`、`global_rotation_degrees`、`global_scale`、`global_skew`、`global_transform`、`global_basis`、`transform`、`basis`、`quaternion`。它们本身不存盘，但设置后改变的是存盘的属性。其他不存盘的属性（`owner`、`scene_file_path` 等）仍然不能设。
- `$new` 里的属性**按书写顺序逐个设置**，后面的属性按对象当时的样子检查。因此"先有甲才有乙"的属性可以写在一起：着色器材质先写 `shader` 再写 `shader_parameter/…`。
- **不使用 `str_to_var`**。它能按文本构造任意对象，等于给了一条绕过 `exec` 分级的代码执行路径。
- 为了不让 `$new` 和 `$res` 变成同样的旁路：
  - `$new` 只能构造引擎原生的 `Resource` 子类。`Script` 及其子类、`PackedScene`、`GDExtension` 不能用 `$new` 构造，也就是说**不能凭空造出一段代码**，代码只能来自项目里的文件。反过来说，`$res` 加载的资源如果引用了带 `@tool` 的脚本，那段脚本会在加载时运行（见 4.1）。
  - `$res` 的路径要过第 4.4 节的检查。
  - 任何命令都不接受直接设置 `script` 属性（包括嵌套在 `properties` 里的）。挂脚本只有 `node_attach_script` 一个入口，参数是项目内脚本文件的路径。
- Godot 的 JSON 解析把所有数字读成浮点数，桥接按目标类型还原成整数。超出 ±2^53 的整数在输出里用 `{"$type":"int","value":"<十进制字符串>"}`。

完整类型表在第 1 至第 3 阶段随命令实现补全，补充不算破坏性变更。

### 6.5 第 1 版命令清单

阶段指 [roadmap.md](roadmap.md) 里的阶段。

| 分组 | 命令 | 风险 | 阶段 |
|---|---|---|---|
| editor | `editor_status`、`editor_selection` | read | 1 |
| scene | `scene_tree`、`scene_list_open` | read | 1 |
| node | `node_get`、`node_find` | read | 1 |
| fs | `fs_list`、`fs_read_text` | read | 1 |
| project | `project_settings_get`、`project_input_map` | read | 1 |
| editor | `editor_errors`（需要 4.5 的日志接口，更早的版本返回 `UNSUPPORTED_GODOT_VERSION`） | read | 3 |
| editor | `editor_screenshot`（图片存到 `~/.gdcli/screenshots/`，只留最近 20 张；无头宿主不可用） | write | 3 |
| scene | `scene_open`、`scene_new`、`scene_save` | write | 3 |
| node | `node_create`、`node_set`、`node_rename`、`node_move`、`node_duplicate`、`node_attach_script`、`node_connect_signal`、`node_add_to_group`、`node_instantiate_scene` | write | 3 |
| node | `node_delete` | write（可撤销） | 3 |
| resource | `resource_create`、`resource_set`（不进撤销栈） | write | 3 |
| fs | `fs_write_text`、`fs_scan` | write | 3 |
| fs | `fs_delete`（移到系统回收站，可找回）、`fs_move`（同时更新引用，见下） | destructive | 3 |
| project | `project_settings_set`、`project_input_map_set` | destructive | 3 |
| edit | `edit_undo`、`edit_redo` | write | 3 |
| editor | `editor_play`、`editor_stop` | write | 3 |
| exec | `eval` | exec | 3 |
| host | `host_quit`（只对 `gd host start` 拉起的无头宿主有效） | write | 3 |
| animation | `animation_list` | read | 3 |
| animation | `animation_create`（可撤销） | write | 3 |
| game | `game_tree`、`game_node_get`、`game_errors`、`game_output`、`game_debug`、`game_locals`（第 6.7 节） | read | 3 |
| game | `game_node_set`、`game_call`、`game_input`、`game_screenshot`、`game_breakpoint`、`game_pause`、`game_step`、`game_continue`（第 6.7 节） | write | 3 |

表里是命令的基础等级。目标落在第 4.4 节的敏感路径上时，`fs_write_text` 等命令按 `destructive` 处理；覆盖已有文件同样如此。

类信息、脚本检查、运行并收集报错、导入、导出不在这张表里，它们走离线通道（第 1.1 节）。

**几条容易出错、所以由命令替调用方处理的规则**（来自用真实模型反复跑评测得到的经验）：

- `node_create` 先把节点加进场景树，再按给定的顺序设属性，整个过程是一步撤销。Control 的锚点和布局是相对父节点算的，没入树时设了不生效。属性的检查同样按顺序进行，所以 `mesh` 后面可以直接跟 `surface_material_override/0`。`node_set` 则是先按节点当前的样子检查全部属性再动手，这类属性要分两次设。
- `node_get` 不带 `properties` 时返回检查器显示的属性；按名字可以读任何属性，包括检查器不显示的（`global_position`、被锚点预设隐藏的 `offset_left`）。
- 给 Control 设 `anchors_preset` 时，`node_create` 和 `node_set` 会先把 `layout_mode` 切到锚点模式（检查器也是这么做的）；调用方自己给了 `layout_mode`、或父节点是容器时不动。
- `node_move` 换父节点时默认保持节点在屏幕上的位置（`keep_global_transform`，默认真；撤销时恢复原来的本地值）。移到容器下面的 Control 由容器摆放，这个选项对它不起作用。
- `fs_write_text` 写完 `.gd` 后立刻编译检查，结果放在 `data.check`（`{compiles, errors?}`，报错文本需要 4.5 及以上）。**不通过也照样写入**，因为它可能引用下一步才创建的东西；此时带一条警告。有三类脚本不做这项检查，`data.check` 里是 `{skipped: 原因}`，需要时用 `gd check`：带工具注解的；用了 `preload` 或 `extends "路径"` 的（编译会去加载别的文件）；引用了自己的 `class_name` 的（文本是单独编译的，那时类名还不存在）。在编辑器里编译一个非工具脚本不会运行其中任何代码（包括静态初始化），这一点实测确认过。
- `animation_create` 用关键帧在 AnimationPlayer 上建一个动画：每条轨道给出场景里的节点路径、属性名和若干 `{time, value}`，值按属性类型转换；不能混合的类型（布尔、整数、字符串、资源）默认在关键帧处跳变。可指定循环方式和是否自动播放。只支持属性轨道，不支持方法调用、音频、贝塞尔轨道。
- `gd run` 用的是磁盘上的文件。发现有编辑器开着这个项目时会给一条警告，提醒先保存场景；它无法知道是否真有未保存的改动。

**`fs_move` 与引用。** `fs_move` 移动文件或文件夹，然后把其他文件里对旧路径的引用改成新路径：

- 范围：项目里的 `.tscn`、`.tres`、`.gd`、`.gdshader`、`.gdshaderinc` 文件，以及项目设置里的字符串和字符串数组（主场景、自动加载、翻译文件列表等）。隐藏目录、任意深度的 `.git`、桥接自己的目录不动。
- 文件的匹配规则：**完整的旧路径出现在哪里就改哪里**，不管在引号里、场景的 `path="…"` 里还是注释里。只是开头相同的更长路径不改：`res://a.gd.uid`、`res://a.gd/x`、`res://a.gdx`、`res://a.gd-old` 都不算对 `res://a.gd` 的引用。`uid://` 引用本来就不受移动影响。
- 文件夹的匹配规则：旧文件夹路径后面跟 `/` 的（它下面的任何路径，包括用来拼路径的前缀 `"res://levels/"`），以及引号里单独的文件夹路径。文件夹里的文件随文件夹移动后，在新位置上改写。
- **运行时拼出来的路径改不了**，因为静态看不出它最终是什么。桥接把"看起来在拼这个路径"的字符串片段列出来（`possible_dynamic_references`，每项有文件、行号、原文），由调用方自己判断：一是旧路径的开头片段（`"res://levels/level_" + str(n)`），二是套进去能得到旧路径的格式串（`"res://levels/level_%d.tscn"`）。只查 `.gd` 文件，最多 50 条。
- 新路径会被原样写进引用它的脚本和场景，所以开启引用更新时，新路径里不能有引号、`;`、`%`、`{`、`}`、`(`、`)`、`#`、`$`；否则返回 `PATH_NOT_ALLOWED`。
- 文件夹移动的限制：不能移到自己里面；不能移动项目根目录；不能移动包含桥接自身的文件夹（`res://addons`）。文件夹里正开着的场景会留在旧路径的标签页上，需要从新路径重新打开，响应里有警告。
- 编辑器里打开着、且引用了该文件的场景：先保存，改写磁盘文件后重新加载，最后切回原来正在编辑的场景。这些场景的撤销历史会清空，响应的 `warnings` 会说明。编辑器每帧只接受一次场景切换，所以这种情况下命令要跨几帧才返回。
- 空跑（`dry_run`）返回将要改动的文件、项目设置和会被保存重载的场景，不做任何改动。其中落在敏感位置（第 4.4 节，如 `addons/`、`gdcli_commands/`）的文件单独列在 `sensitive_files` 里；`fs_move` 本身需要确认，这些文件不再单独确认，实际执行后会在 `warnings` 里点名。改了项目设置就会保存 `project.godot`。
- 跨帧执行期间，其他会改动东西的命令返回 `EDITOR_BUSY`（可重试），只读命令照常。调用方中途断开连接或等不及，桥接仍会把剩下的步骤做完，不会停在"文件已移动、场景还没重新加载"的状态。
- 查找在编辑器主线程上做，上限是 2 万个文件、256 MB；超出时空跑结果里 `search_incomplete` 为真，实际执行会给出警告。
- `update_references=false` 关闭以上行为，只移动文件及其 `.uid`、`.import`（或整个文件夹）。

### 6.6 项目自定义命令

项目可以在 `res://gdcli_commands/` 放脚本来注册自己的命令。自定义命令是项目自己的编辑器代码，信任等级与项目里任何 `@tool` 脚本相同。

脚本必须以 `@tool` 开头（编辑器里没有它的脚本无法实例化），继承 `RefCounted`，并提供两个函数：

```gdscript
@tool
extends RefCounted

func descriptor() -> Dictionary:
    return {"name": "level_stats", "summary": "…", "risk": "write",
            "params": {"type": "object", "properties": {}}}

func run(args: Dictionary, options: Dictionary) -> Variant:
    return {"enemies": 3}
```

`options` 里有 `dry_run`、`confirm`、`mode`。返回值会按第 6.4 节编码。返回 `{"ok": false, "error": {...}}` 表示失败：桥接把它报告为 `COMMAND_FAILED`，`message` 用桥接自己的固定文案，脚本给的 `code`、`message`、`hint` 清洗后放进 `details`（`reported_code` 等），因为调用方信任 `message` 和 `hint` 出自桥接。加载失败的脚本不会让桥接起不来，原因会出现在握手响应的 `warnings` 里。

约束：

- **只在桥接启动时加载**，不随文件系统变化重新扫描。否则"写一个文件"就等于"立即执行一段代码"。新增或修改自定义命令后要重启编辑器或重新启用插件。
- 自报的风险等级只能往高报：桥接把低于 `write` 的声明一律当作 `write`。脚本的实际行为桥接无法核实。
- `readonly` 模式下不加载自定义命令。
- 该目录是第 4.4 节的敏感路径，通过桥接写入需要确认。

---

### 6.7 运行中的游戏

编辑器启动的游戏是另一个进程。`game_*` 命令通过编辑器与游戏之间**已有的调试器连接**同游戏里的一个辅助节点通信，不新开端口，游戏进程也不监听任何东西。

```
gd ──HTTP──▶ 桥接（编辑器进程）──调试器消息 gdcli:request──▶ GdcliGame（游戏进程）
   ◀────────                    ◀──────── gdcli:reply ────────
```

- **辅助节点**是自动加载项 `GdcliGame`（`res://addons/gdcli/runtime/game_agent.gd`）。`gd bridge install` 把它写进 `project.godot` 的 `[autoload]`；在编辑器里启用插件时也会加上，停用时移除。只有同时满足"有调试器连接"和"运行的是编辑器版本的可执行文件"（即由编辑器启动的游戏）它才工作；其他情况（导出的游戏，包括用 `--remote-debug` 连到别处的调试版导出）它在 `_ready` 里立刻把自己删掉，什么都不做。导出时如果排除了 `addons/gdcli`，要同时去掉这个自动加载项，否则引擎会报找不到脚本。
- **只对编辑器启动的游戏有效**（`editor_play`，或在编辑器里按 F5）。`gd run` 启动的游戏没有编辑器的调试器连接，不能用这些命令。
- **节点路径相对根窗口**，主场景通常是第一段：`Main/Player`。`game_tree` 返回的 `current_scene` 给出当前场景的路径和文件。自动加载项也在这棵树里。
- `game_node_get` 能读到检视面板不显示的属性（`velocity`、`global_position`、脚本变量）；不带 `properties` 时返回检视面板属性加脚本变量。`game_node_set` 同样能写这些属性，值按第 6.4 节转换；改的只是运行中的游戏，场景文件和编辑器里的场景都不变。
- `game_input` 按下或松开输入映射里的一个动作，相当于玩家操作；`hold` 是按住的秒数（游戏时间，0 表示一直按着直到再发一次 `pressed=false`），上限 10 秒。
- `game_screenshot` 的图片由游戏发给编辑器、由编辑器写到 `~/.gdcli/screenshots/`（先检查是 PNG）；游戏不写文件。游戏以无头方式运行时没有画面，返回 `PRECONDITION_FAILED`。
- **等待**：答案要过几帧才到，桥接保持 HTTP 连接，最多等 5 秒。游戏还没启动完（辅助节点还没报到）时会在这 5 秒内等它；始终没报到返回 `PRECONDITION_FAILED`，发出请求后没有回答返回 `TIMEOUT`。游戏停在调试器里时照常应答（见下）。
- **信任**：游戏是项目代码，它发回的内容按项目文本对待：只保留 JSON 值，字符串全部清洗；失败时错误码只接受固定的几种，`message` 用桥接自己的文案，游戏给的文字放进 `details.reported_message`。
- **分级说明**：`game_tree`、`game_node_get` 是 `read`，所以只读模式下也能用。它们读到的是运行时的值，包括脚本变量；游戏运行时才载入内存的东西（比如从 `user://` 读进来的内容）也在其中，这比读项目文件能看到的多。`game_node_set` 是 `write`：它能改运行中任何节点的任何属性，效果取决于游戏自己的代码。
- `game_output` 返回游戏启动以来打印的内容（`print`、`printerr`），最多保留最近 500 行。
- `game_call` 调用节点的一个方法并返回结果，参数按方法声明的类型转换（第 6.4 节）。`call`、`callv`、`set`、`set_script`、`connect` 这类"间接做别的事"的方法不接受。带 `await` 的方法在挂起处就返回。方法里如果触发断点或报错，游戏会停在调试器里，这次调用在约半秒后返回 `PRECONDITION_FAILED`（不等满 5 秒）。

**调试器一侧**的命令不经过辅助节点，用的是编辑器调试器本身：

| 命令 | 作用 | 风险 |
|---|---|---|
| `game_errors` | 游戏启动以来报告的错误和警告（`push_error`、引擎报错、脚本报错），每条带脚本调用栈；最多保留最近 200 条 | read |
| `game_debug` | 游戏是否停在调试器里、原因（断点或报错文本）、调用栈（第 0 帧是停住的位置） | read |
| `game_locals` | 停住时某一帧的局部变量、所属对象的成员、全局量。游戏里的对象以 `{"$type":"Object","id":…}` 表示 | read |
| `game_breakpoint` | 在运行中的游戏里设置或取消断点；只对这一次运行有效，不会出现在脚本编辑器里 | write |
| `game_pause` | 让游戏在下一行脚本处停住（游戏当时不在跑脚本就要等到它跑） | write |
| `game_step` | 停住时走一步：`over`（不进函数）、`into`（进函数）、`out`（跑到当前函数返回） | write |
| `game_continue` | 继续运行 | write |

- `game_pause`、`game_step` 等游戏再次停住后返回，内容与 `game_debug` 相同；3 秒内没停住则返回当时的状态并带一条警告。
- **游戏停住时辅助节点仍然应答**，所以停在断点上可以照常用 `game_node_get`、`game_tree`、`game_call`。
- 从编辑器运行时，**脚本报错会让游戏停在报错处**（这是 Godot 调试器的行为）。此时 `game_debug` 的 `reason` 是报错文本，栈顶是出错的行；看完用 `game_continue` 让它继续。这条报错同时也记在 `game_errors` 里（4.5 起由引擎报告；4.3、4.4 的引擎不报告，桥接根据停住的原因和调用栈自己补记一条）；`game_debug` 的 `errors` 字段是累计数量。
- 实现上的依赖：读报错、调用栈和变量靠的是编辑器调试面板节点（`ScriptEditorDebugger`）上转发每条调试消息的 `debug_data` 信号。它不在公开的脚本接口里，引擎自己的调试适配器也用它。某个版本里找不到时，这几条命令返回 `UNSUPPORTED_GODOT_VERSION`，`game_tree` 等不受影响。
- `out` 在 4.6 之前的引擎里没有对应的调试命令，桥接用"逐行 `over` 直到调用栈变浅"来实现，效果相同，只是长函数会慢一些（最多 2000 步或 10 秒，到限后返回当时的位置并带警告）。传 `emulate=true` 可以在任何版本上强制用这种方式。
- 变量应答不带帧号，而编辑器在游戏停住时会自己请求第 0 帧的变量。`game_locals` 先等这一轮结束（或停住满 0.4 秒），再发自己的请求并取其后的第一组完整应答，所以不会把第 0 帧的数据当成别的帧。
- 条件断点、监视表达式、多线程调试不在范围内；只跟主线程。

无头环境（CI）里要让编辑器启动的游戏也无头运行，在项目设置里把 `editor/run/main_run_args` 设为 `--headless`。

## 7. 版本

- `protocol` 是整数。只在出现破坏性变更时加一：删除或改名命令、字段，改变已有字段的含义，改变认证或发现方式。
- 新增命令、新增可选参数、新增响应字段不改协议号。调用方必须忽略不认识的字段。
- 命令行声明自己支持的协议范围。握手返回的协议号不在范围内时返回 `PROTOCOL_MISMATCH`，`hint` 指明该升级哪一边（`gd bridge upgrade` 或升级命令行）。
- 桥接版本、命令行版本、Claude 插件版本保持一致，一起发布。

---

## 8. 未决问题

实现时验证，结论回填到本文：

1. Flatpak 等沙箱版 Godot 能否写到 `~/.gdcli`。不能则需要 `GDCLI_HOME` 的文档说明。
2. `DirAccess.is_link` 对 Windows 的目录联接（junction）是否返回真。不是的话第 4.4 节的链接检查在 Windows 上要另找办法。
3. 同一台机器开第二个编辑器时，语言服务器和调试适配器的默认端口会冲突并报错。`gd host start` 已经显式指定端口；带界面的第二个实例是否需要处理，待定。

已验证：无头宿主里除截图外的命令都可用（端到端测试整套跑在无头编辑器上）；`editor_status` 的 `capabilities` 在有窗口时含 `screenshot`。

已验证：`--check-only` 对普通脚本能给出带文件和行号的解析报错，出错时退出码非零。引擎在脚本运行时报错后退出码仍是 0，所以 `gd run` 以解析输出为准。

已验证（CI，Linux，4.3 至 4.7）：`TCPServer.listen(0, "127.0.0.1")` 能拿到系统分配的端口；`Crypto.hmac_digest` 可用。
