<p align="center"><img src="docs/images/icon.png" width="96" alt="gdcli"></p>

<h1 align="center">gdcli</h1>

<p align="center">
  <a href="https://www.npmjs.com/package/@spardanviro/gdcli"><img src="https://img.shields.io/npm/v/@spardanviro/gdcli?label=npm" alt="npm"></a>
  <a href="https://godotengine.org/asset-library/asset/5539"><img src="https://img.shields.io/badge/Godot%20Asset%20Library-gdcli%20bridge-478cbf" alt="Godot Asset Library"></a>
  <a href="https://github.com/spardanviro/GodotCli/actions/workflows/ci.yml"><img src="https://github.com/spardanviro/GodotCli/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Godot-4.3%20to%204.7-478cbf" alt="Godot 4.3 to 4.7">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache-2.0"></a>
</p>

<p align="center"><b>从命令行和编码智能体里驾驶 Godot 编辑器。</b></p>

> **In English:** gdcli lets coding agents (Claude Code, Codex, Cursor and any MCP client) and people at a terminal build Godot 4 games through the real editor: read and change the open scene with every step on the editor's undo stack, run the game and inspect, steer and debug it while it runs, check scripts and run scenes without an editor, and look up the engine's API and manual. Changes that would run code inside the editor wait for a person to approve them. It is three parts: a bridge plugin in the editor, the `gd` command line (`npm install -g @spardanviro/gdcli`), and a Claude Code plugin with 13 skills. The documentation is in Chinese.

---

## 它解决什么问题

让 AI 写 Godot 游戏，常见的做法是让它直接改 `.tscn` 和 `.gd` 文件。这样做的问题很多：场景文件的格式容易写坏，改动不进编辑器的撤销栈，看不到游戏实际跑起来是什么样，而且任何代码都可能被写进编辑器里运行。

gdcli 换了一条路：**智能体通过编辑器来做事**，和人点编辑器的效果一样。

- **改场景走编辑器**：建节点、改属性、挂脚本、连信号、做动画、画瓦片，每一步都是编辑器撤销栈里的一步，`Ctrl+Z` 能撤销。
- **能看见游戏在干什么**：从编辑器运行游戏后，可以读运行中节点的属性、模拟按键、调用方法、读报错和输出、下断点、单步、看局部变量。
- **不开编辑器也能做的事**：运行场景并拿到结构化的报错、检查脚本、导入、导出、查当前引擎版本的接口和官方手册。
- **危险的改动要人点头**：会让代码进入编辑器进程的改动（`@tool` 脚本、`addons/`、自动加载、C#、`eval` 等）会在编辑器里弹窗，人同意才执行；没有窗口的编辑器一律拒绝。
- **一套命令，多种用法**：人在终端里用，Claude Code 通过插件用，Codex、Cursor、VS Code、Gemini CLI 通过 MCP 用。

## 组成

| 部分 | 是什么 | 从哪里装 |
|---|---|---|
| **桥接**（`addons/gdcli`） | 编辑器插件（GDScript）。在 `127.0.0.1` 上监听，执行命令，管撤销栈和人工批准 | `gd bridge install`，或 [Godot 资源库](https://godotengine.org/asset-library/asset/5539) |
| **`gd` 命令行** | 找到编辑器、发命令、输出结果；也能自己启动 Godot 做离线的事；还是一个 MCP 服务器 | `npm install -g @spardanviro/gdcli` |
| **Claude 插件**（`godot@gdcli`） | 13 个技能（怎么用 `gd`、Godot 的坑和做法），3 个钩子 | `claude plugin install godot@gdcli` |

```
 智能体 / 终端                       Godot 编辑器
┌──────────────┐   HTTP（本机）    ┌────────────────────────┐
│ gd command … │ ───────────────▶ │ 桥接 addons/gdcli        │──▶ 场景、撤销栈、文件
│ gd mcp       │   令牌 + 握手     │   需要时弹窗请人批准       │──▶ 运行中的游戏（调试器）
└──────┬───────┘                  └────────────────────────┘
       │ 直接启动 Godot（不经过编辑器）
       └──▶ gd run / check / import / export / api / docs
```

桥接只监听本机回环地址，令牌保存在用户目录（`~/.gdcli`）里，每次连接都先用 HMAC 握手，确认对方真的持有令牌。细节见 [docs/protocol.md](docs/protocol.md)。

## 快速开始

需要 **Node.js 22** 以上和 **Godot 4.3** 以上（4.3 到 4.7 在持续集成里测试，Windows、macOS、Linux 和 .NET 版都有）。

```bash
npm install -g @spardanviro/gdcli
gd doctor                       # 找到 Godot 了吗、还缺什么
```

`gd` 按这个顺序找 Godot：`--godot <路径>` → 环境变量 `GODOT_BIN` → `~/.gdcli/config.json` 里的 `godot_bin` → PATH 上的 `godot`、`godot4`。Windows 上请指向 `*_console.exe`。

装好后 `gd` 和 `gdcli` 是同一个命令。如果 `gd` 被 shell 别名占用（oh-my-zsh 的 git 插件把它设成了 `git diff`），就用 `gdcli`。

### 新项目

```bash
gd new my-game --renderer mobile      # 建项目并装好桥接（渲染器：forward_plus / mobile / gl_compatibility）
cd my-game
gd open                               # 打开编辑器；没有显示器时用 gd host start 起一个无头编辑器
gd status                             # 编辑器连上了吗
```

### 已有项目

```bash
cd your-game
gd bridge install                     # 把桥接装进项目并启用（已装的也用它更新）
gd open
```

### 试几条命令

```bash
gd command scene_new --path res://main.tscn --root-type Node2D --root-name Main
gd command node_create --type Sprite2D --name Logo --properties '{"position": [100, 50]}'
gd command scene_tree
gd command edit_undo                  # 撤销上一步，和在编辑器里按 Ctrl+Z 一样
gd command scene_save
gd run --headless --seconds 3         # 不开编辑器跑 3 秒，把报错整理好返回
```

`gd list` 列出编辑器提供的全部命令、参数和说明（加 `--json` 是完整的参数结构）。

## 配合 Claude Code 使用

```bash
claude plugin marketplace add spardanviro/GodotCli
claude plugin install godot@gdcli
```

然后在项目文件夹里打开 Claude Code，直接说要做什么，比如：

> 做一个 2D 平台跳跃角色，能左右移动和跳跃，脚下有地面可以站，做完后运行确认。

插件带来三样东西：

- **技能**：模型需要时自动加载。

  | 技能 | 内容 |
  |---|---|
  | `godot-cli` | 怎么用 `gd`：命令地图、值的写法、脚本怎么写进项目、人工批准、运行与检查、调试运行中的游戏 |
  | `godot-gdscript` | GDScript 里真正会出错的写法、场景与脚本的分工、信号、自动加载 |
  | `godot-physics-gameplay` | 角色移动、刚体、区域、碰撞层、射线、输入、相机、导航 |
  | `godot-ui` | Control、锚点、容器、主题、HUD 和菜单、焦点、分辨率适配 |
  | `godot-3d-rendering` | 3D 场景、材质、灯光、三种渲染器、着色器、导入 |
  | `godot-animation-audio` | AnimationPlayer、补间、动画树、粒子、音频 |
  | `godot-new-project` | 从零开始一个项目：先定下以后难改的几件事 |
  | `godot-troubleshooting` | 从症状找原因：掉出地面、不动、信号不触发、黑屏…… |
  | `godot-tilemap` | 瓦片集、画关卡、瓦片碰撞、地形自动拼接 |
  | `godot-sprite-animation` | 图集切帧动画、动画状态机、像素风设置 |
  | `godot-localization` | 翻译表、`tr()`、切换语言、中日韩字体 |
  | `godot-export` | 导出模板与预设、`gd export`、Web 导出 |
  | `godot-audio-buses` | 总线布局、效果器、设置菜单里的音量 |

- **会话开始时的钩子**：在 Godot 项目里开始的会话，会被告知先用这些技能、通过 `gd` 操作。需求里不提 Godot 也一样。
- **写入钩子**：拦住 Claude 用自己的文件工具或 shell 直接改项目里的脚本、场景和项目文件，让改动都经过编辑器。这是护栏，不是沙箱；要有真正的约束，请配合 Claude Code 的沙箱，见 [plugin/README.md](plugin/README.md)。

## 配合其他智能体使用（MCP）

`gd mcp` 是一个标准输入输出上的 MCP 服务器：编辑器的每条命令是一个同名工具，另有 `gd_run`、`gd_check`、`gd_api_*`、`gd_docs_*`、`gd_host_start` 等不需要编辑器的工具。

```bash
gd mcp configure codex                # 先显示要写进 ~/.codex/config.toml 的条目
gd mcp configure codex --yes          # 写入
gd mcp configure cursor --yes         # cursor、vscode、gemini、claude 写进项目里对应的配置文件
gd skills install codex --yes         # 把 13 个技能装进 ~/.codex/skills（同一种 SKILL.md 格式）
gd skills install --dir <目录> --yes   # 其他读 SKILL.md 的智能体
```

工具让智能体能做事，技能告诉它怎么做才对。人工批准的规则对这些客户端同样生效。

## 命令速查

**需要编辑器**（桥接在运行中的编辑器里）

| 命令 | 作用 |
|---|---|
| `gd status` / `gd list` | 能连上的编辑器 / 它提供的命令 |
| `gd command <名字> [--参数 值]` | 执行一条编辑器命令，参数也可以用 `--args '<json>'` 或 `--<参数>-file <文件>` 给 |
| `gd host start` / `gd host stop` | 没开编辑器时起一个无头编辑器 / 关掉它 |
| `gd eval <代码>` | 在编辑器里执行 GDScript（默认关闭，要在编辑器设置里打开，每次都要人批准） |

编辑器命令按类别：

| 类别 | 命令 |
|---|---|
| 场景 | `scene_new` `scene_open` `scene_save` `scene_tree` `scene_list_open` |
| 节点 | `node_create` `node_get` `node_set` `node_find` `node_move` `node_rename` `node_duplicate` `node_delete` `node_instantiate_scene` `node_attach_script` `node_connect_signal` `node_add_to_group` |
| 文件与资源 | `fs_list` `fs_read_text` `fs_write_text` `fs_move` `fs_delete` `fs_scan` `resource_create` `resource_set` |
| 项目 | `project_settings_get` `project_settings_set` `project_input_map` `project_input_map_set` |
| 动画 | `animation_create` `animation_list` `animation_state_machine_create` `animation_blend_space_create` `sprite_frames_create` |
| 瓦片与导航 | `tileset_add_atlas` `tileset_set_collision` `tileset_set_terrain` `tilemap_set_cells` `tilemap_get` `navigation_bake` |
| 编辑器 | `editor_status` `editor_play` `editor_stop` `editor_errors` `editor_selection` `editor_screenshot` `edit_undo` `edit_redo` |
| 运行中的游戏 | `game_tree` `game_node_get` `game_node_set` `game_call` `game_input` `game_output` `game_errors` `game_screenshot` |
| 调试 | `game_breakpoint` `game_pause` `game_step` `game_continue` `game_debug` `game_locals` |

**不需要编辑器**（`gd` 自己启动 Godot）

| 命令 | 作用 |
|---|---|
| `gd run [场景] [--seconds N] [--headless]` | 运行项目或某个场景，返回整理好的报错（文件、行号、调用栈） |
| `gd check <脚本>…` | 检查脚本能否编译 |
| `gd import` / `gd export <预设> <输出> [--debug\|--pack]` | 导入资源 / 导出游戏 |
| `gd exec <脚本>` | 无头运行一个 SceneTree 脚本 |
| `gd api class <类名> [--member 成员]` / `gd api search <文字>` | 查当前 Godot 版本的接口 |
| `gd docs install` / `search` / `page` | 下载当前版本的官方手册（只取文本）并检索 |

**项目与安装**：`gd new`、`gd bridge install`、`gd bridge status`、`gd open`、`gd doctor`。

**全局选项**：`--json`、`--project <路径>`、`--godot <路径>`、`--instance <id>`（同一项目开着多个编辑器时选一个）、`--timeout <秒>`、`--yes`（确认覆盖或删除）、`--dry-run`（只说会改什么，不改）。

## 输出格式

任何命令加 `--json`，标准输出就是一个固定结构的信封，失败时也是：

```json
{
  "success": true,
  "command": "node_create",
  "data": { "path": "Logo", "type": "Sprite2D" },
  "errors": [],
  "warnings": [],
  "meta": { "protocol": 1, "undo": "gdcli: node_create Logo", "scene": "res://main.tscn" }
}
```

失败时 `errors` 里每一项都有 `code`、`message`、`hint`、`details`。退出码：

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 内部错误 |
| 2 | 用法或参数错误 |
| 3 | 认证失败 |
| 4 | 前置条件不满足（比如没有编辑器、要确认、人拒绝了） |
| 5 | 暂时性失败，稍后重试 |
| 6 | 命令执行失败 |

## 调试运行中的游戏

```bash
gd command editor_play
gd command game_tree --max-depth 3
gd command game_node_get --path Main/Player --properties '["velocity", "global_position"]'
gd command game_input --action jump --hold 0.1       # 发送真正的输入事件，_input 和按钮也能收到
gd command game_call --path Main/Player --method take_damage --arguments '[1]'
gd command game_errors                               # 运行以来的报错，带脚本调用栈
gd command game_breakpoint --path res://player.gd --line 42
gd command game_debug                                # 停住了吗、为什么、调用栈
gd command game_locals                               # 停住处的局部变量
gd command game_continue
gd command editor_stop
```

## 安全模型

- **一般的改动**（建节点、改属性、写普通脚本）直接执行，并进入撤销栈。
- **破坏性的改动**（删除、覆盖、改项目设置）要调用方带上 `--yes`。这是减速带，不是授权。
- **会让代码进入编辑器进程的改动**，一律弹窗请人批准，调用方说什么都不算数。包括：`@tool` 脚本、内嵌脚本的场景和资源、任何 C# 文件、`addons/`、自动加载和其他决定加载哪些代码的项目设置、.NET 构建会读取的文件，以及 `eval`。无头编辑器没人可问，一律拒绝。
- **访问模式**存在编辑器设置里（每个用户一份，不随项目走）：`standard`（默认）、`ask`（每个破坏性操作都要人批准）、`readonly`（不做任何修改）。
- 游戏本身的代码以用户权限运行，这和自己按 F5 一样。要限制它，请在智能体客户端里不要自动放行写文件和运行类工具。

完整说明见 [docs/protocol.md](docs/protocol.md) 第 4 节。

## 常见问题

**`gd` 找不到 Godot**：运行 `gd doctor`。用 `--godot`、`GODOT_BIN` 或 `~/.gdcli/config.json` 指定；Windows 上要指向 `*_console.exe`。

**`NO_EDITOR`**：编辑器没开，或者没装桥接。先 `gd bridge install`，再 `gd open`；没有显示器时用 `gd host start`。

**`NOT_APPROVED`**：这个改动需要人在编辑器里批准，而人拒绝了，或者编辑器没有窗口。到有窗口的编辑器里再试，或者换一种不需要批准的做法；不要绕过。

**`MULTIPLE_EDITORS`**：同一个项目开着不止一个编辑器，用 `--instance <id>` 选一个（`gd status` 里有 id）。

**`gd` 被别名占用**：用 `gdcli`，或者在 shell 配置里 `unalias gd`。

**导出失败**：导出模板和预设要先在编辑器里准备好（Editor > Manage Export Templates，Project > Export）。见 `godot-export` 技能。

## 评测

`evals/` 里有 33 个任务，覆盖场景、脚本、界面、玩法、3D、动画、瓦片、本地化、音频总线、排错、中文需求等。其中 10 个是难题，在运行中的游戏里检查实际行为，比如巡逻和追击的状态机、存档读档、暂停菜单、没有报错的逻辑 bug。

- 回放参考答案时全部通过，什么都不做时全部失败（只有"被拒绝后不绕路"例外），两者都跑在持续集成里。
- 用真实 Claude 跑的第二次基线：31 个任务各跑 3 次，**93/93 通过**，结果见 [evals/results/claude-baseline.json](evals/results/claude-baseline.json)。

一条命令就能重跑，并和以前的结果比较通过率、轮数和花费：

```bash
GODOT_BIN=/path/to/godot node evals/run.mjs --agent claude --repeat 3 --baseline evals/results/claude-baseline.json
```

详见 [evals/README.md](evals/README.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/protocol.md](docs/protocol.md) | 两条通道、线上协议、返回信封、错误码、安全规则、每条命令的约定 |
| [docs/architecture.md](docs/architecture.md) | 设计决策、同类项目、差异点 |
| [docs/roadmap.md](docs/roadmap.md) | 各阶段与验收结果 |
| [docs/releasing.md](docs/releasing.md) | 发布流程（npm、GitHub Release、资源库） |
| [plugin/README.md](plugin/README.md) | Claude 插件、钩子、沙箱设置 |
| [evals/README.md](evals/README.md) | 评测集 |

## 仓库结构

| 目录 | 内容 |
|---|---|
| `bridge/` | 开发测试用的 Godot 项目；`bridge/addons/gdcli/` 是桥接插件（GDScript，Godot 4.3 起） |
| `cli/` | `gd` 命令行（TypeScript，Node 22 起，运行时零依赖） |
| `plugin/` | Claude 插件：技能、参考资料、钩子 |
| `evals/` | 评测集：任务、检查、运行器、基线结果 |
| `scripts/` | 测试与检查脚本、生成插件参考资料的脚本 |

## 开发

```bash
npm install
npm run verify                              # 版本一致、插件检查、钩子测试、类型、代码检查、单元测试、构建
GODOT_BIN=/path/to/godot npm run test:bridge  # 桥接的单元测试和端到端测试
GODOT_BIN=/path/to/godot npm run test:e2e     # 构建后的 gd 对真实编辑器的端到端测试
npm run test:package                        # 打包后装进空目录再运行
```

持续集成在 Linux 上测 Godot 4.3 到 4.7，在 Windows、macOS 和 .NET 版上测 4.7，命令行在三个系统上都测。

## 许可证

[Apache-2.0](LICENSE)。
