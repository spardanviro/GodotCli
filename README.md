# gdcli

从命令行和编码智能体里控制 Godot：一个编辑器桥接插件，一个 `gd` 命令行，一个 Claude 插件。

**状态：第 3 阶段完成，尚未发布。** `gd` 能读写运行中编辑器里的场景（每一步都进编辑器的撤销栈），能查看和操作编辑器启动的游戏，也能不开编辑器运行场景、检查脚本、导入、导出、查接口。Claude 插件在第 4 阶段。

## 用法

目前要从源码构建（见"开发"），然后用 `node cli/dist/main.js` 代替下面的 `gd`。

```bash
gd bridge install          # 把桥接插件装进当前项目并启用
gd open                    # 启动编辑器
gd status                  # 编辑器就绪了吗
gd list                    # 编辑器提供哪些命令
gd command scene_tree      # 读场景树
gd command node_create --type CharacterBody2D --name Player   # 建节点，可在编辑器里 Ctrl+Z
gd command node_set --path Player --properties '{"position":[100,50]}'
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
gd doctor                  # 哪里不对
```

任何命令加 `--json`，标准输出就是一个信封：`{success, command, data, errors, warnings, meta}`，失败时也是。

## 文档

- [docs/protocol.md](docs/protocol.md)：两条通道、线上协议、返回信封、错误码和退出码
- [docs/architecture.md](docs/architecture.md)：决策、同类项目、差异点
- [docs/roadmap.md](docs/roadmap.md)：阶段与验收

## 目录

| 目录 | 内容 |
|---|---|
| `bridge/` | 开发测试用的 Godot 项目；`bridge/addons/gdcli/` 是桥接插件（GDScript，Godot 4.3 起） |
| `cli/` | `gd` 命令行（TypeScript，Node 22 起） |
| `plugin/` | Claude 插件 |
| `scripts/` | 仓库级检查脚本 |

## 开发

```bash
npm install
```

```bash
npm run verify
```

`verify` 依次做版本一致性检查、类型检查、代码检查、测试（含覆盖率门槛）和构建。

桥接的测试（单元测试加端到端）需要一个 Godot 编辑器可执行文件：

```bash
GODOT_BIN=/path/to/godot npm run test:bridge
```

命令行的端到端测试同样需要它，会在临时目录里建项目、装桥接、起一个无头编辑器：

```bash
GODOT_BIN=/path/to/godot npm run test:e2e
```
