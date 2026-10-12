# gdcli

从命令行和编码智能体里控制 Godot：一个编辑器桥接插件，一个 `gd` 命令行，一个 Claude 插件。

**状态：第 2 阶段完成，尚未发布。** `gd` 能读取运行中编辑器的状态，也能不开编辑器运行场景、检查脚本、导入、导出、查接口。修改场景的命令在第 3 阶段。

## 用法

目前要从源码构建（见"开发"），然后用 `node cli/dist/main.js` 代替下面的 `gd`。

```bash
gd bridge install          # 把桥接插件装进当前项目并启用
gd open                    # 启动编辑器
gd status                  # 编辑器就绪了吗
gd list                    # 编辑器提供哪些命令
gd command scene_tree      # 读场景树
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
