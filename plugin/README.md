# Claude 插件

让 Claude Code 通过 `gd` 命令行在 Godot 项目里干活：六个技能，加一个拦住"直接改项目脚本"的钩子。

## 安装

前提：装好 `gd`（Node 22 起），项目里装好桥接（`gd bridge install`）。

```
/plugin marketplace add spardanviro/GodotCli
/plugin install godot@gdcli
```

从本地源码试用：

```bash
claude --plugin-dir /path/to/gdcli/plugin
```

## 技能

| 技能 | 内容 |
|---|---|
| `godot-cli` | 怎么用 `gd`：调用方式、命令地图、值的写法、脚本怎么写进项目、人工批准、运行与检查、运行中游戏的检视与调试。附一个从头到尾实测过的例子（2D 平台跳跃角色） |
| `godot-gdscript` | GDScript 里真正会让脚本出错的写法、场景与脚本的分工、信号、自动加载、文件放哪、大任务怎么拆 |
| `godot-physics-gameplay` | 角色移动、刚体、区域、碰撞层、射线、输入、相机、瓦片地图、导航、生成物 |
| `godot-ui` | Control、锚点、容器、主题覆盖、HUD 和菜单的常见部件、输入与焦点、分辨率适配 |
| `godot-3d-rendering` | 3D 场景、材质、灯光、三种渲染器的差别、着色器、模型和贴图导入、画面不对时怎么查 |
| `godot-animation-audio` | AnimationPlayer、补间、动画树、粒子、音频 |

每个领域技能的 `references/` 里有两份资料：

- `gotchas.md`：Godot 4 里容易踩的坑，每条带关键词，按类名或方法名搜索，不通读。
- `api.md`：常用类的要点速查。以 `gd api class <类名>` 查到的为准。

这两份来自原生模块（[spardanviro/Godot_AI](https://github.com/spardanviro/Godot_AI)）的知识库，共 394 条易错点、50 个类，由脚本按主题分到各技能，不手工编辑。原生模块的知识库更新后重新导入：

```bash
node scripts/import-knowledge.mjs /path/to/godot/modules/ai_assistant/knowledge
```

`godot-cli/references/commands.md` 是从运行中的桥接生成的命令清单。`scripts/bridge-test.mjs` 每次都会核对它与桥接是否一致；命令有变动时这样重新生成：

```bash
GDCLI_UPDATE_PLUGIN=1 GODOT_BIN=/path/to/godot node scripts/bridge-test.mjs
```

技能正文里的每条 `gd command` 写法都在真实编辑器里跑过。`npm run check:plugin` 会检查技能里提到的命令名和参数名确实存在。

## 钩子：项目脚本不能直接写

桥接有一条规则：会让代码进入编辑器进程的改动（带 `@tool` 的脚本、`addons/` 下的文件、自动加载等）必须由人在编辑器里点确认。但 Claude Code 自己有写文件的工具，可以绕过桥接直接把文件写到磁盘上。

`hooks/guard-project-writes.mjs` 在 Claude 调用 Write、Edit、MultiEdit、NotebookEdit 之前检查目标路径，命中下面任何一条就拒绝，并告诉它改用 `gd command fs_write_text`：

- 项目里的 `.gd`、`.tscn`、`.tres`、`.scn`、`.res`、`.import`、`.gdextension`、`.csproj`、`.sln`、`.props`、`.targets`
- 项目根目录的 `project.godot`、`project.binary`、`override.cfg`、`export_presets.cfg`
- `addons/`、`gdcli_commands/`、`.godot/` 下的任何文件

只对**装了桥接的项目**生效（存在 `addons/gdcli/plugin.cfg`）；没装桥接的 Godot 项目和项目外的文件不受影响。子文件夹里另放一个 `project.godot` 不会让外层项目失去保护。读文件不受限制，Markdown、JSON、着色器、图片等照常直接写。

这样，脚本进项目只剩"经过编辑器"这一条顺手的路：写入后立刻有编译检查结果，该由人批准的改动会弹给人看，只读模式和 `ask` 模式也对 Claude 生效。

**它管不住的**，要说清楚：

- 只拦文件工具。shell 命令（重定向、`cp`、脚本）照样能写任何文件。这是护栏，不是沙箱；技能里明确要求不得用别的办法绕过，被拒绝或没被批准就停下来告诉用户。要做成硬约束，还需要在 Claude Code 的权限设置里限制 shell，或者用操作系统层面的隔离。
- **C# 源文件（`.cs`）不拦。** 桥接目前对 C# 脚本没有人工批准的规则，让它们绕道桥接不增加任何保护；带 `[Tool]` 的 C# 类在构建后同样会在编辑器里运行，这是桥接一侧还没补上的缺口。
- Claude Code 自己的配置不归它管：项目里的 `.claude/settings.json` 可以设置环境变量或关掉全部钩子。克隆来的仓库如果自带这样的配置，这个钩子可能根本不运行。
- 游戏进程里的代码不受约束，离线通道（`gd run`、`gd exec`）也不经过桥接。

需要临时关掉时（比如开发桥接自身），由用户在自己的 Claude Code 设置的 `env` 里加 `GDCLI_ALLOW_DIRECT_WRITES=1`。Claude 在 shell 里设这个变量不起作用，钩子读的是 Claude Code 进程自己的环境。

## 测试

```bash
npm run check:plugin    # 清单、钩子配置、技能格式、命令名和参数名
npm run test:plugin     # 钩子的单元测试
```

两项都在 `npm run verify` 里。
