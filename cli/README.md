# gdcli

Drive the Godot editor and engine from the command line and from coding agents: read and change the open scene (every change goes on the editor's undo stack), inspect and steer the running game, run scenes and check scripts without an editor, and serve all of it over MCP. Godot 4.3 or newer, Node.js 22 or newer.

从命令行和编码智能体里控制 Godot：读写编辑器里打开的场景（每一步都进撤销栈），查看和操作运行中的游戏，不开编辑器运行场景、检查脚本，并通过 MCP 提供给其他智能体。需要 Godot 4.3 以上、Node.js 22 以上。

## 安装

```bash
npm install -g @spardanviro/gdcli
```

装好后有两个同样的命令：`gd` 和 `gdcli`。如果 `gd` 被别名占用（oh-my-zsh 的 git 插件把它设成了 `git diff`），用 `gdcli`，或者在 shell 配置里 `unalias gd`。

`gd` 按这个顺序找 Godot：`--godot <路径>`、环境变量 `GODOT_BIN`、`~/.gdcli/config.json` 里的 `godot_bin`、PATH 上的 `godot`，再是 `godot4`。`gd doctor` 告诉你找到了哪个、还缺什么。

## 开始

```bash
gd new my-game                 # 新建项目，装好桥接
cd my-game
gd open                        # 启动编辑器（或 gd host start：无头编辑器）
gd status                      # 编辑器就绪了吗
gd command scene_tree          # 读场景树
gd command node_create --type Sprite2D --name Logo   # 建节点，可在编辑器里 Ctrl+Z
gd command scene_save
gd run --headless --seconds 5  # 不开编辑器跑 5 秒，返回报错
```

已有的项目用 `gd bridge install` 装桥接。任何命令加 `--json`，标准输出就是一个结构化的信封。

## 给智能体用

- **Claude Code**：装插件，同时得到技能和写入拦截钩子：`claude plugin marketplace add spardanviro/GodotCli`，再 `claude plugin install godot@gdcli`。
- **MCP 客户端**（Codex、Cursor、VS Code、Gemini CLI 等）：`gd mcp configure <codex|cursor|vscode|gemini|claude>` 先显示要写的配置，加 `--yes` 写入；`gd skills install codex --yes` 装上技能。

会让代码进入编辑器的改动（工具脚本、`addons/`、自动加载、`eval`）要人在编辑器里批准，无头编辑器里一律拒绝。

## 文档

- 完整说明：<https://github.com/spardanviro/GodotCli#readme>
- 协议与安全规则：<https://github.com/spardanviro/GodotCli/blob/main/docs/protocol.md>

Apache-2.0
