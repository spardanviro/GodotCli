# gdcli

从命令行和编码智能体里控制 Godot：一个编辑器桥接插件，一个 `gd` 命令行，一个 Claude 插件。

**状态：第 0 阶段。** 目前只有协议文档和仓库骨架，`gd` 还没有可用命令。

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

桥接的冒烟测试需要一个 Godot 编辑器可执行文件：

```bash
GODOT_BIN=/path/to/godot npm run smoke:bridge
```
