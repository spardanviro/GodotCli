# 发布

三样东西一起发布、版本号相同：npm 上的命令行 `gdcli`（里面带着桥接和技能）、Claude 插件 `godot@gdcli`（从本仓库安装）、Godot 资源库里的桥接插件。

## 每次发布

1. 改版本号。四处要一致，`npm run check:versions` 会核对：
   - `cli/package.json`
   - `plugin/.claude-plugin/plugin.json`
   - `bridge/addons/gdcli/plugin.cfg`
   - `bridge/addons/gdcli/plugin.gd` 的 `BRIDGE_VERSION`

   另外 `package-lock.json` 里 `cli` 那一项的版本也改掉（或运行一次 `npm install`）。
2. 本地验证：`npm run verify`、`npm run test:package`，有 Godot 时再跑 `npm run test:bridge` 和 `npm run test:e2e`。
3. 提交，打标签，推送：

   ```bash
   git tag -a v0.4.0 -m "gdcli 0.4.0"
   git push origin main v0.4.0
   ```

4. 标签触发 `.github/workflows/release.yml`，它会做这些事：
   - 核对标签与版本号一致，重跑验证和打包检查。
   - 把桥接打成 `gdcli-bridge-<版本>.zip`，挂到这个标签的 GitHub Release 上。还没有 Release 时，先建一个草稿。已经发布的 Release 上如果已有这个 zip，不会覆盖它，因为资源库下载的就是它。
   - 打开了 npm 自动发布的话（见下文），把命令行发布到 npm。发布的就是核对任务里打包并测试过的那个文件；发布任务本身不安装依赖、不运行仓库里的任何代码。
5. 在 GitHub 上写好 Release 的说明，然后发布（草稿要点 Publish）。
6. 资源库：在资源页面上点 Edit，把 Version 和 Download Commit（新 zip 的地址）改掉，提交后等审核。

Claude 插件不需要另外发布：用户运行 `claude plugin marketplace update gdcli` 和 `claude plugin update godot@gdcli` 时，会读到 main 上的新版本号。

工作流也可以从 Actions 页面手动运行（Run workflow，填一个已有的标签），用来补做某个标签的发布文件。

## 第一次发布到 npm（只做一次）

npm 的"可信发布"让 GitHub Actions 直接发布，仓库里不放令牌。但它只能给已经存在的包设置，所以第一个版本要手动发：

```bash
npm login
cd cli
npm publish --access public
```

`prepack` 会先构建，把桥接、技能和 LICENSE 复制进包里。发布之前可以先运行 `npm pack --dry-run`，看包里有哪些文件。

然后设置自动发布：

1. 在 npmjs.com 打开包 `gdcli` 的 Settings，找到 Trusted Publisher，选 GitHub Actions，填写：
   - Organization or user：`spardanviro`
   - Repository：`GodotCli`
   - Workflow filename：`release.yml`
   - Environment：`npm`
2. 在 GitHub 仓库的 Settings → Environments 里新建环境 `npm`，并加上保护规则：
   - Deployment branches and tags 选 Selected，只加标签规则 `v*`。
   - 想每次发布前自己点一下确认的话，勾选 Required reviewers，把自己加进去。

   npm 只认这个环境里运行的发布任务。所以即使有人有仓库写权限，没有经过这个环境的规则也发布不了。
3. 在 Settings → Rules → Rulesets 里给 `v*` 标签加一条规则，禁止删除和改写。这样已发布的标签不会被挪到别的提交上。
4. 在 Settings → Secrets and variables → Actions → Variables 里，新建变量 `NPM_PUBLISH`，值为 `true`。

此后每次推送标签都会自动发布到 npm，并附带来源证明（provenance）。同一个版本已经在 npm 上时，这一步会跳过。

## Godot 资源库（第一次提交）

资源库直接下载一个 zip。我们的 zip 是发布工作流挂在 Release 上的那个，里面是一个顶层文件夹，下面是 `addons/gdcli/`；安装器会去掉顶层文件夹，把 `addons/gdcli` 装进项目。

在 <https://godotengine.org/asset-library/asset/submit> 提交时，各字段这样填：

| 字段 | 填写 |
|---|---|
| Asset Name | gdcli bridge |
| Category | Tools（属于 Addons） |
| Godot version | 4.3 |
| Version | 当前版本，如 0.3.1 |
| Repository host | Custom |
| Repository URL | https://github.com/spardanviro/GodotCli |
| Issues URL | https://github.com/spardanviro/GodotCli/issues |
| Download Commit | https://github.com/spardanviro/GodotCli/releases/download/v<版本>/gdcli-bridge-<版本>.zip（选 Custom 时，这一栏就是下载地址，必须以 `.zip` 结尾） |
| Icon URL | https://raw.githubusercontent.com/spardanviro/GodotCli/main/docs/images/icon.png |
| License | Apache-2.0 |

Custom 这种方式在资源库的源码里（`getComputedDownloadUrl`）：Download Commit 原样作为下载地址，不检查提交哈希。图标须是正方形的 PNG 或 JPG，至少 128×128；`docs/images/icon.png` 为 256×256，由同目录的 `icon.svg` 生成。

描述可以用这一段：

> The editor side of gdcli. With it enabled, the `gd` command line (npm: gdcli) and coding agents (Claude Code, Codex, Cursor and other MCP clients) can read and change the open scene through the editor's undo stack, run and inspect the game, and query the engine. It listens on 127.0.0.1 only, with a per-session token kept in your home folder. Changes that would run code inside the editor (tool scripts, addons, autoloads, eval) wait for you to approve them in a dialog. Install the command line with `npm install -g gdcli`; `gd bridge install` also installs this plugin into a project.
