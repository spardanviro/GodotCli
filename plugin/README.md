# Claude 插件

让 Claude Code 通过 `gd` 命令行在 Godot 项目里干活：十三个技能；一个会话开始时的钩子，在 Godot 项目里提醒 Claude 用这些技能；两个拦住"直接改项目脚本"的钩子。

## 安装

前提：装好 `gd`（Node 22 起），项目里装好桥接（`gd bridge install`）。

直接从 GitHub 安装，不需要手动打包。在 Claude Code 里：

```
/plugin marketplace add spardanviro/GodotCli
/plugin install godot@gdcli
```

或者在终端里：

```bash
claude plugin marketplace add spardanviro/GodotCli
claude plugin install godot@gdcli
```

仓库更新后拉取新版本：

```bash
claude plugin marketplace update gdcli
claude plugin update godot@gdcli
```

Claude Code 按 `plugin.json` 里的版本号判断有没有新版本，所以每次改动插件都要提升版本号（`npm run check:versions` 保证它与命令行、桥接的版本一致）。这条安装路径在 WSL 的 Claude Code 2.1 上实测过：装上后显示 8 个技能和钩子。

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

| `godot-new-project` | 按任务切的技能：从零开始一个项目。先定下以后难改的几件事（2D 还是 3D、渲染器、分辨率、是否像素风），再 `gd new`、打开编辑器、建出能运行的第一个场景 |
| `godot-troubleshooting` | 按任务切的技能：从症状找原因（掉出地面、不动、信号不触发、按钮没反应、黑屏、动画不播、空引用报错、改了不生效、导出后不对），先读运行中的值再改代码 |
| `godot-tilemap` | 按任务切的技能：从一张图建瓦片集、画关卡、给瓦片加碰撞（含斜坡和单向平台）、地形自动拼接、分层 |
| `godot-sprite-animation` | 按任务切的技能：从图集切帧动画、用代码切换动画、动画状态机、像素风的项目设置 |
| `godot-localization` | 按任务切的技能：翻译表（CSV）导入与注册、`tr()`/`tr_n()`、控件自动翻译、切换并记住语言、中日韩等字体、测试语言与伪本地化 |
| `godot-export` | 按任务切的技能：人在编辑器里准备的（导出模板、预设）、`gd export`、哪些文件进包、Web 导出（渲染器、线程与跨源隔离头、怎么托管、音频、浏览器里的存档） |
| `godot-audio-buses` | 按任务切的技能：写出总线布局 `default_bus_layout.tres`（Music、SFX 等，带效果器）、把播放器接到总线、设置菜单里的音量滑块、压低音乐 |

前五个领域技能的 `references/` 里各有两份资料：

- `gotchas.md`：Godot 4 里容易踩的坑，每条带关键词，按类名或方法名搜索，不通读。
- `api.md`：常用类的要点速查。以 `gd api class <类名>` 查到的为准。

这两份来自原生模块（[spardanviro/Godot_AI](https://github.com/spardanviro/Godot_AI)）的知识库，共 394 条易错点、50 个类，由脚本按主题分到各技能，不手工编辑。原生模块的知识库更新后重新导入：

```bash
node scripts/import-knowledge.mjs /path/to/godot/modules/ai_assistant/knowledge
```

**官方文档没有打包进插件。** 它有一千五百多页、文本就有 36 MB，而且跟引擎版本走；类参考部分 `gd api` 已经能从你装的引擎里直接读到。手册部分（教程、最佳实践、排错）通过 `gd docs` 按需查：`gd docs install` 从官方的 godot-docs 仓库下载**当前所用 Godot 版本**的手册（只取文本，约 36 MB，十秒左右，需要 git），之后 `gd docs search`、`gd docs page` 只取用得上的那一页或一节。已经有一份文档的话用 `gd docs use <文件夹>` 指过去。技能里写了什么时候去查，以及没装时先装。

`godot-cli/references/commands.md` 是从运行中的桥接生成的命令清单。`scripts/bridge-test.mjs` 每次都会核对它与桥接是否一致；命令有变动时这样重新生成：

```bash
GDCLI_UPDATE_PLUGIN=1 GODOT_BIN=/path/to/godot node scripts/bridge-test.mjs
```

技能正文里的每条 `gd command` 写法都在真实编辑器里跑过。`npm run check:plugin` 会检查技能里提到的命令名和参数名确实存在。

## 钩子：会话开始时说明这是 Godot 项目

`hooks/godot-project-context.mjs` 在会话开始时运行：当前目录或它的上级有 `project.godot`，就告诉 Claude 这是一个 Godot 项目，先加载 `godot-cli` 技能，用 `gd` 改脚本、场景和设置，并说明桥接装好了没有。不在 Godot 项目里时什么也不说。它只看这两个文件在不在，不读别的。

加它的原因：需求里不一定提到 Godot（"捡金币应该加 1 分，现在加了 2 分"）。第二次基线里，这样的需求在 3 个会话里都没有加载技能，是靠写入钩子挡回来才改用 `gd` 的。

## 钩子：项目脚本不能直接写

桥接有一条规则：会让代码进入编辑器进程的改动（带 `@tool` 的脚本、`addons/` 下的文件、自动加载等）必须由人在编辑器里点确认。但 Claude Code 自己有写文件的工具，可以绕过桥接直接把文件写到磁盘上。

`hooks/guard-project-writes.mjs` 在 Claude 调用 Write、Edit、MultiEdit、NotebookEdit 之前检查目标路径，命中下面任何一条就拒绝，并告诉它改用 `gd command fs_write_text`：

- 项目里的 `.gd`、`.cs`、`.tscn`、`.tres`、`.scn`、`.res`、`.import`、`.gdextension`、`.csproj`、`.sln`、`.props`、`.targets`
- 项目根目录的 `project.godot`、`project.binary`、`override.cfg`、`export_presets.cfg`
- `addons/`、`gdcli_commands/`、`.godot/` 下的任何文件

只对**装了桥接的项目**生效（存在 `addons/gdcli/plugin.cfg`）；没装桥接的 Godot 项目和项目外的文件不受影响。子文件夹里另放一个 `project.godot` 不会让外层项目失去保护。读文件不受限制，Markdown、JSON、着色器、图片等照常直接写。

这样，脚本进项目只剩"经过编辑器"这一条顺手的路：写入后立刻有编译检查结果，该由人批准的改动会弹给人看，只读模式和 `ask` 模式也对 Claude 生效。

**它管不住的**，要说清楚：

- **shell 命令只能按文本检查。** 第二个钩子 `hooks/guard-shell-writes.mjs` 在 Bash 和 PowerShell 命令执行前读命令文本，拦住常见的写法：重定向到这些文件、`cp`/`mv`/`rm`/`tee`/`touch`/`sed -i`、`Set-Content`/`Out-File`/`Copy-Item`/`Remove-Item` 等、`git checkout`/`git restore` 指定这些文件、一行脚本（`python -c`、`node -e`、`bash -c`）里写这些文件。读文件、把文件复制到项目外、`gd` 命令都放行。它挡不住变量拼出来的路径、先写一个脚本文件再运行、没列进去的工具。这是护栏，不是沙箱。
- **硬约束要靠 Claude Code 的沙箱**（见下一节，已在 WSL2 上实测），而沙箱不支持原生 Windows。
- C#：桥接一侧凡是写入 `.cs`、改名成 `.cs`、挂上 C# 脚本都要人批准，因为在 .NET 版编辑器上实测，普通类的字段初始化也会在编辑器里运行（`scripts/dotnet-probe.mjs`）。所以无头编辑器里不能经由桥接写 C#。
- Claude Code 自己的配置不归它管：项目里的 `.claude/settings.json` 可以设置环境变量或关掉全部钩子。克隆来的仓库如果自带这样的配置，这个钩子可能根本不运行。
- 游戏进程里的代码不受约束，离线通道（`gd run`、`gd exec`）也不经过桥接。

### 用沙箱做成硬约束

Claude Code 的沙箱由操作系统限制 shell 命令能写哪些文件，不靠读命令文本。它支持 macOS、Linux 和 WSL2，**不支持原生 Windows**：在 Windows 上要在 WSL2 里运行 Claude Code，项目和 Godot 也都放在 WSL2 里（WSL2 里的 `gd` 找不到 Windows 上的编辑器：主目录和路径写法都不同）。

把 [sandbox-settings.example.json](sandbox-settings.example.json) 的内容放进游戏项目的 `.claude/settings.json`：

```json
{
  "sandbox": {
    "enabled": true,
    "allowUnsandboxedCommands": false,
    "excludedCommands": ["gd command *", "gd status", "gd status *", "gd list", "gd list *", "gd doctor", "gd doctor *", "gd api *", "gd eval *"],
    "filesystem": {
      "denyWrite": ["."],
      "allowWrite": ["~/.local/share/godot", "~/.cache/godot", "~/.config/godot", "~/.gdcli"]
    }
  }
}
```

它的意思是：

- **shell 命令对整个项目只读**（`denyWrite` 写的是项目根）。项目里的文件只有两条路能改：Claude 的文件工具（受上面第一个钩子管，脚本、场景、项目文件会被拒绝），和 `gd command`（交给编辑器写，该批准的会弹给人）。
- **跟编辑器对话的 `gd` 子命令在沙箱外运行**（`excludedCommands`）。在 Linux 和 WSL2 上，沙箱里的命令连不到宿主机回环地址上的服务，所以不排除就连不上桥接。只排除了经过桥接的子命令；`gd run`、`gd check`、`gd exec`、`gd import`、`gd export` 会启动 Godot 运行项目里的代码，它们**留在沙箱里**。
- `allowWrite` 让沙箱里的 Godot 能写它自己的数据目录，否则 `gd run` 起不来。

这套配置在 WSL2（Ubuntu，Claude Code 2.1，Godot 4.5）上实测过，结果如下：

| 做法 | 结果 |
|---|---|
| 用变量拼出路径写一个新脚本（钩子看不出来） | 被系统拒绝：`Read-only file system` |
| 追加内容到 `project.godot`、在 `addons/` 下建文件 | 被系统拒绝 |
| shell 重定向写一个普通文件（`notes.md`） | 同样被拒绝：shell 对整个项目只读 |
| 用 Write 工具写 `notes.md` | 成功 |
| 用 Write 工具写 `.gd` | 被钩子拒绝 |
| 单独一条 `gd command editor_status` | 成功（在沙箱外运行） |
| `gd command fs_write_text --text-file /tmp/x.gd` | 成功，文件由编辑器写入 |
| `gd command ... \| head`（带管道） | 失败，报 `NO_EDITOR`：带管道、重定向或 `cd` 的整条命令会留在沙箱里 |
| `gd run --headless`、`gd check` | 成功，在沙箱里运行；游戏代码同样写不了项目 |

实测中确认**行不通**的两种写法，不要用：

- `permissions.deny` 里的 `Edit(**/*.gd)` 管得住文件工具，**管不住沙箱里的 shell**：用变量拼路径照样写进去了。
- `denyWrite` 里写通配符（`./**/*.gd`）在 WSL2 上**不起作用**，已有的脚本和新建的脚本都能被改。所以只能按目录禁写，也就是整个项目。

这套配置的边界：

- 把 `gd command *` 放到沙箱外，等于信任 `gd` 本身。它只把请求发给编辑器，由编辑器按访问模式和人工批准的规则处理。
- 由编辑器启动的游戏（`gd command editor_play`）是编辑器的子进程，不在沙箱里。只有 `gd run` 启动的游戏在沙箱里。
- 只读的是当前项目。Claude Code 的其他可写目录（临时目录等）不受影响。

需要临时关掉时（比如开发桥接自身），由用户在自己的 Claude Code 设置的 `env` 里加 `GDCLI_ALLOW_DIRECT_WRITES=1`。Claude 在 shell 里设这个变量不起作用，钩子读的是 Claude Code 进程自己的环境。

## 测试

```bash
npm run check:plugin    # 清单、钩子配置、技能格式、命令名和参数名
npm run test:plugin     # 两个钩子的单元测试
```

两项都在 `npm run verify` 里。
