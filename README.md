# gdcli

从命令行和编码智能体里控制 Godot：一个编辑器桥接插件，一个 `gd` 命令行，一个 Claude 插件。

**状态：0.3.1，第 6 阶段（加固与发布）进行中。** `gd` 能读写运行中编辑器里的场景（每一步都进编辑器的撤销栈），能查看和操作编辑器启动的游戏，也能不开编辑器运行场景、检查脚本、导入、导出、查接口；`gd mcp` 把这些提供给任何 MCP 客户端。Claude 插件有十个技能和两个写入拦截钩子，见 [plugin/README.md](plugin/README.md)。

## 安装

```bash
npm install -g gdcli    # Node.js 22 以上；Godot 4.3 以上
```

装好后 `gd` 和 `gdcli` 是同一个命令。`gd` 被别名占用时（oh-my-zsh 的 git 插件把它设成了 `git diff`）用 `gdcli`。也可以从源码构建（见"开发"），用 `node cli/dist/main.js` 代替 `gd`。

Claude Code 用户再装插件，得到技能和写入钩子：

```bash
claude plugin marketplace add spardanviro/GodotCli
claude plugin install godot@gdcli
```

发布流程见 [docs/releasing.md](docs/releasing.md)。

## 用法

```bash
gd new my-game --renderer mobile   # 新建项目，带桥接
gd bridge install          # 把桥接插件装进当前项目并启用
gd open                    # 启动编辑器
gd status                  # 编辑器就绪了吗
gd list                    # 编辑器提供哪些命令
gd command scene_tree      # 读场景树
gd command node_create --type CharacterBody2D --name Player   # 建节点，可在编辑器里 Ctrl+Z
gd command node_set --path Player --properties '{"position":[100,50]}'
gd command fs_write_text --path res://scripts/player.gd --text-file /tmp/player.gd   # 脚本正文从文件读
gd command edit_undo       # 撤销上一步
gd command scene_save
gd command editor_play     # 在编辑器里运行项目
gd command game_tree       # 运行中游戏的节点树
gd command game_node_get --path Main/Player --properties '["velocity","global_position"]'
gd command game_input --action ui_accept --hold 0.2   # 按住一个输入动作 0.2 秒
gd command game_errors     # 游戏运行以来报的错，带脚本调用栈
gd command game_breakpoint --path res://player.gd --line 42
gd command game_debug      # 停住了吗、为什么、调用栈
gd command game_locals     # 停住处的局部变量
gd command game_continue
gd command editor_stop
gd host start              # 没开编辑器时，起一个无头编辑器当宿主；gd host stop 关闭
gd run --headless --seconds 5   # 不开编辑器跑 5 秒，返回报错
gd check scripts/player.gd      # 检查脚本
gd api class CharacterBody2D    # 查当前版本的接口
gd docs install                 # 下载当前 Godot 版本的官方手册（只取文本，需要 git）
gd docs search one way collision   # 在手册里找
gd docs page tutorials/physics/using_character_body_2d --section "Platformer movement"
gd doctor                  # 哪里不对
```

任何命令加 `--json`，标准输出就是一个信封：`{success, command, data, errors, warnings, meta}`，失败时也是。

### 给其他智能体用（MCP）

Codex、Cursor、VS Code、Gemini CLI 等支持 Model Context Protocol 的客户端，通过 `gd mcp` 使用同一套命令：编辑器的每条命令是一个同名工具，另有 `gd_run`、`gd_check`、`gd_api_*`、`gd_docs_*`、`gd_host_start` 等不需要编辑器的工具。

```bash
gd mcp configure codex          # 显示要加进 ~/.codex/config.toml 的条目
gd mcp configure codex --yes    # 写进去；claude、cursor、vscode、gemini 写进项目里对应的文件
gd skills install codex --yes   # 把 Claude 插件的十个技能装进 ~/.codex/skills（同一种 SKILL.md 格式）
gd skills install --dir <目录> --yes   # 其他读 SKILL.md 文件夹的智能体
```

工具让智能体能做事，技能告诉它怎么做才对（命令怎么组合、值怎么写、常见的坑）。Claude Code 装插件就同时有了两样；其他智能体用 `gd mcp` 或自己的 shell 拿到工具，用 `gd skills install` 拿到技能。

桥接的规则对这些客户端同样生效：会让代码进入编辑器的改动由人在编辑器里批准，无头编辑器里一律拒绝。但写普通脚本再运行游戏不需要批准，游戏里的代码以用户权限运行；要限制它，在客户端里不要自动放行写文件和运行类工具。详见 [docs/protocol.md](docs/protocol.md) 第 4.3 节和第 6.8 节。

## 文档

- [docs/protocol.md](docs/protocol.md)：两条通道、线上协议、返回信封、错误码和退出码
- [docs/architecture.md](docs/architecture.md)：决策、同类项目、差异点
- [docs/roadmap.md](docs/roadmap.md)：阶段与验收

## 目录

| 目录 | 内容 |
|---|---|
| `bridge/` | 开发测试用的 Godot 项目；`bridge/addons/gdcli/` 是桥接插件（GDScript，Godot 4.3 起） |
| `cli/` | `gd` 命令行（TypeScript，Node 22 起） |
| `plugin/` | Claude 插件：技能、参考资料、写入拦截钩子 |
| `scripts/` | 仓库级检查脚本，以及生成插件参考资料的脚本 |

## 开发

```bash
npm install
```

```bash
npm run verify
```

`verify` 依次做版本一致性检查、插件检查（技能格式、命令名和参数名）、钩子测试、类型检查、代码检查、测试（含覆盖率门槛）和构建。

桥接的测试（单元测试加端到端）需要一个 Godot 编辑器可执行文件：

```bash
GODOT_BIN=/path/to/godot npm run test:bridge
```

命令行的端到端测试同样需要它，会在临时目录里建项目、装桥接、起一个无头编辑器：

```bash
GODOT_BIN=/path/to/godot npm run test:e2e
```
