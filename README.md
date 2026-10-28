<p align="center"><img src="docs/images/icon.png" width="96" alt="gdcli"></p>

<h1 align="center">gdcli</h1>

<p align="center">
  <a href="https://www.npmjs.com/package/@spardanviro/gdcli"><img src="https://img.shields.io/npm/v/@spardanviro/gdcli?label=npm" alt="npm"></a>
  <a href="https://godotengine.org/asset-library/asset/5539"><img src="https://img.shields.io/badge/Godot%20Asset%20Library-gdcli%20bridge-478cbf" alt="Godot Asset Library"></a>
  <a href="https://github.com/spardanviro/GodotCli/actions/workflows/ci.yml"><img src="https://github.com/spardanviro/GodotCli/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Godot-4.3%20to%204.7-478cbf" alt="Godot 4.3 to 4.7">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache-2.0"></a>
</p>

<p align="center"><b>Let Claude Code, Codex, Cursor or any MCP agent build your Godot 4 game through the real editor.</b></p>

<p align="center"><b>English</b> | <a href="README.zh-CN.md">简体中文</a></p>

---

gdcli connects a coding agent to a running Godot editor. You describe a game feature in plain words ("a 2D
character that runs and jumps, with ground to stand on"). The agent builds it the way a person would: it creates
nodes, sets properties, writes and attaches scripts, paints tiles and makes animations. Every step is on the
editor's undo stack. Then it runs the game, presses keys and reads values in the running game to check that the
character really jumps.

It works with the official Godot 4.3 to 4.7 builds, standard or .NET, on Windows, macOS and Linux. Nothing is
compiled into the engine and no API key goes into Godot: the agent you already use does the thinking, and gdcli
gives it hands and eyes in the editor.

```text
You:   Make a 2D platformer character that moves left and right and jumps, with ground under it. Run it to check.

Agent: gd command scene_new --path res://main.tscn --root-type Node2D
       gd command node_create --type CharacterBody2D --name Player --properties '{"position": [200, 300]}'
       gd command node_create --type CollisionShape2D --parent Player --properties '{"shape": {"$new": "RectangleShape2D", ...}}'
       gd command fs_write_text --path res://player.gd --text-file /tmp/player.gd
       gd command node_attach_script --path Player --script res://player.gd
       gd command project_input_map_set --action jump --events '[{"key": "Space"}]' --yes
       gd command scene_save
       gd command editor_play
       gd command game_input --action jump --hold 0.1
       gd command game_node_get --path Main/Player --properties '["velocity", "position"]'   # it went up: done
```

## Why

The usual way to let an AI write a Godot game is to have it edit `.tscn` and `.gd` files directly. That breaks in
several ways:

- Scene files are easy to corrupt.
- Changes skip the editor's undo stack.
- The model never sees how the game actually behaves.
- Any code it writes may end up running inside your editor.

gdcli takes the other road: **the agent works through the editor.**

| | Editing files directly | With gdcli |
|---|---|---|
| Scenes and nodes | hand-written `.tscn` text, ids and paths by guesswork | 72 structured commands; the editor writes the files |
| Undo | none | every change is a step of the editor's undo stack, `Ctrl+Z` works |
| Seeing the result | at best, the text the game prints | read and set values in the running game, press inputs, take screenshots, breakpoints, locals |
| Unsaved work in the editor | overwritten or ignored | the same scene the person sees, live |
| Code running in the editor | whatever was written | `@tool` scripts, addons, autoloads, C# and `eval` wait for a person to click Allow |
| Engine knowledge | whatever the model remembers | 17 skills with Godot 4 pitfalls, the API of your installed version, and the official manual |

## What you can do with it

- **Build scenes**: nodes, properties, scripts, signals, groups, resources, animations (players, state machines,
  blend spaces, sprite frames), tile sets and tile maps with terrains, GridMap levels, themes, navigation meshes,
  import settings, ready-made particle effects and animations, collision shapes fitted to sprites and meshes.
- **Change the project**: project settings, input actions, moving and renaming files with references updated
  across scenes and scripts.
- **Run and look inside**: start the game from the editor and read its node tree and live values, play key,
  mouse and gamepad sequences, slow it down or speed it up, list what its UI shows, check several values at once, call methods, read errors and output with script stack traces, take screenshots, read the frame rate,
  memory, draw calls and orphan nodes.
- **Debug**: set breakpoints, pause, step, read the call stack and local variables of a stopped game.
- **Without an editor**: run a scene and get its errors with file and line, check scripts, run GUT or gdUnit4
  tests, import, export, run a SceneTree script, look up any class of your Godot version, search the manual.
- **From any agent**: the same commands as a CLI (`gd`), as a Claude Code plugin, and as an MCP server for Codex,
  Cursor, VS Code, Gemini CLI and others.

## The three parts

| Part | What it is | Required? | Install |
|---|---|---|---|
| **Bridge** (`addons/gdcli`) | An editor plugin in GDScript. Listens on `127.0.0.1`, runs the commands, keeps the undo stack, asks a person when needed | Yes, for anything that touches the open editor | `gd bridge install`, the [Godot Asset Library](https://godotengine.org/asset-library/asset/5539), or the zip on [Releases](https://github.com/spardanviro/GodotCli/releases) |
| **`gd` command line** | Finds the editor, sends commands, prints results; starts Godot itself for offline work; an MCP server | Yes | `npm install -g @spardanviro/gdcli` |
| **Claude plugin** (`godot@gdcli`) | 17 skills (how to use `gd`, how Godot 4 is meant to be used) and 3 hooks (start-of-session hint, guards against writing project files behind the editor's back) | Optional, recommended with Claude; other agents get the same skills with `gd skills install` | the plugin marketplace, or upload the zip from [Releases](https://github.com/spardanviro/GodotCli/releases) in the Claude app |

```text
 agent / terminal                     Godot editor
┌──────────────┐   HTTP (loopback)   ┌──────────────────────────────┐
│ gd command … │ ──────────────────▶ │ bridge addons/gdcli          │──▶ scenes, undo stack, files
│ gd mcp       │   token + handshake │   asks a person when needed  │──▶ running game (debugger)
└──────┬───────┘                     └──────────────────────────────┘
       │ starts Godot directly (no editor)
       └──▶ gd run / check / test / import / export / api / docs
```

The bridge listens on the loopback address only. Its token is kept in your home folder (`~/.gdcli`), and every
connection starts with an HMAC handshake that proves the other side holds the token. Details:
[docs/protocol.md](docs/protocol.md) (in Chinese).

## Getting started

### 1. What you need

- **Godot 4.3 or newer**, any official build (standard or .NET). gdcli does not install Godot.
- **Node.js 22 or newer**, for the `gd` command line.
- For the agent part: [Claude Code](https://claude.com/claude-code), or any MCP client (Codex, Cursor, VS Code,
  Gemini CLI, ...).

### 2. Install the command line and point it at Godot

```bash
npm install -g @spardanviro/gdcli
gd doctor
```

`gd doctor` says which Godot it found and what is missing. `gd` looks for Godot in this order:

1. `--godot <path>`
2. the `GODOT_BIN` environment variable
3. `godot_bin` in `~/.gdcli/config.json`
4. `godot`, then `godot4`, on the PATH

On Windows, point it at the `*_console.exe` next to the editor, so that its output can be read.

`gd` and `gdcli` are the same command. If `gd` is taken by a shell alias (oh-my-zsh's git plugin makes it
`git diff`), use `gdcli` or `unalias gd`.

### 3. Put the bridge into your project

Pick one of these:

**a. With `gd` (recommended)**: it always installs the bridge of the same version as `gd`.

```bash
gd new my-game --renderer mobile   # a new project with the bridge already in it
                                   # (renderers: forward_plus, mobile, gl_compatibility)
# or, for a project you already have:
cd your-game
gd bridge install                  # copies addons/gdcli and enables it; --force to replace another version
```

**b. From the Godot Asset Library, inside the editor**:

1. Open your project in Godot and switch to the **AssetLib** tab at the top.
2. Search for **gdcli**, open "gdcli bridge", click **Download**, then **Install**. Keep `addons/gdcli` ticked.
3. **Project > Project Settings > Plugins**: tick **Enable** next to gdcli. This also adds its small `GdcliGame`
   autoload, which lets `gd` look into the running game.

The page is [godotengine.org/asset-library/asset/5539](https://godotengine.org/asset-library/asset/5539). The
Asset Library can be a version behind while a new release waits for review. `gd` warns when the bridge in a
project differs from its own; `gd bridge install --force` brings them in line.

**c. From a release zip**: download `gdcli-bridge-<version>.zip` from
[Releases](https://github.com/spardanviro/GodotCli/releases). Copy the `addons/gdcli` folder inside it into
your project's `addons/` folder, then enable it as in b.3.

### 4. Open the editor and check the connection

```bash
gd open          # starts the editor on the project (or open it yourself as usual)
gd status        # lists the editors gd can reach: you should see your project
```

On a machine without a display (a server, CI, WSL without a desktop), `gd host start` runs a headless editor
instead, and `gd host stop` ends it.

### 5. Try a few commands yourself

```bash
gd command scene_new --path res://main.tscn --root-type Node2D --root-name Main
gd command node_create --type Sprite2D --name Logo --properties '{"position": [100, 50]}'
gd command scene_tree
gd command edit_undo                  # the same as Ctrl+Z in the editor
gd command edit_redo
gd command scene_save
gd run --headless --seconds 3         # runs the project for 3 seconds without an editor and reports its errors
```

You see each change appear in the editor as it happens. `gd list` lists every command the editor offers, with
its arguments (`--json` gives the full schemas).

### 6. Hand it to an agent

#### Claude Code

Install the plugin (optional, but it is what teaches Claude how to use `gd` well):

```bash
claude plugin marketplace add spardanviro/GodotCli
claude plugin install godot@gdcli
```

Without the marketplace, use `gdcli-claude-plugin-<version>.zip` from
[Releases](https://github.com/spardanviro/GodotCli/releases):

- **Claude desktop app**: Customize > Plugins > Add > **Upload plugin**, and pick the zip. The skills and hooks
  work in sessions that run on your machine (Cowork, Claude Code), where `gd` is installed. Chat on claude.ai
  loads only the skills and cannot reach your editor.
- **Claude Code, for one session**: `claude --plugin-dir gdcli-claude-plugin-<version>.zip`, or
  `claude --plugin-url <the zip's release URL>`.

See [plugin/README.md](plugin/README.md) for the details.

Then open Claude Code in the project folder and say what you want. For example:

> Make a 2D platformer character that runs and jumps, with ground to stand on. Run it and check that jumping works.

> The enemy walks through walls. Find out why and fix it.

> Add a pause menu with Resume and Quit, opened with Escape, and check that the game really stops.

> Translate the main menu into Chinese and Japanese, and add a language switch.

What happens:

- The skills load when they are needed: `godot-cli` for the commands, plus the topic or task one (tile maps, UI,
  shaders, multiplayer, troubleshooting, ...).
- Claude builds through `gd command ...`, and you watch the editor change. `Ctrl+Z` in the editor undoes its
  steps like your own.
- When a change would run code inside the editor (a `@tool` script, an addon, an autoload, C#), a dialog appears
  in the editor showing the full content. Nothing happens until you click **Allow**.
- It checks its work: `gd run` for errors, and the game commands to see the behaviour.
- The plugin's hooks stop Claude from writing scripts and scenes straight to disk behind the editor's back. That
  is a guard rail, not a sandbox: for a real boundary, use Claude Code's sandbox as described in
  [plugin/README.md](plugin/README.md).

#### Codex, Cursor, VS Code, Gemini CLI and other MCP clients

`gd mcp` is an MCP server on standard input and output. Every editor command is a tool of the same name, plus
`gd_run`, `gd_check`, `gd_test`, `gd_api_*`, `gd_docs_*`, `gd_host_start` and others that work without an editor.

```bash
gd mcp configure codex                # shows the entry it would add to ~/.codex/config.toml
gd mcp configure codex --yes          # writes it
gd mcp configure cursor --yes         # cursor, vscode, gemini, claude: the project's own config file
gd skills install codex --yes         # the 17 skills into ~/.codex/skills (the same SKILL.md format)
gd skills install --dir <folder> --yes   # for any other agent that reads SKILL.md
```

A client with a cap on tools, or a small model, can take only some groups:
`gd mcp --tools core,game` (groups: core, game, animation, level, import, docs, test, exec, custom; `gd mcp configure`
takes the same option). The read commands are also MCP resources (`godot://scene/tree`, `godot://node/{path}`,
`godot://file/{path}`, `godot://class/{name}`, ...), which a client can attach to a conversation directly.

The tools let the agent act; the skills tell it how to do it right. Person approval works the same for every
client.

## A walkthrough: a jumping character, by hand

The same flow the agent follows, step by step, so you can see what each command does. Start in a project with the
bridge and the editor open.

```bash
# A scene with a character and a floor.
gd command scene_new --path res://main.tscn --root-type Node2D --root-name Main
gd command node_create --type CharacterBody2D --name Player --properties '{"position": [200, 200]}'
gd command node_create --type ColorRect --parent Player \
  --properties '{"position": [-50, -50], "size": [100, 100], "color": "#4a90d9"}'
gd command node_create --type CollisionShape2D --parent Player \
  --properties '{"shape": {"$new": "RectangleShape2D", "properties": {"size": [100, 100]}}}'
gd command node_create --type StaticBody2D --name Floor --properties '{"position": [400, 500]}'
gd command node_create --type CollisionShape2D --parent Floor \
  --properties '{"shape": {"$new": "RectangleShape2D", "properties": {"size": [800, 40]}}}'

# Input actions the script will read.
gd command project_input_map_set --action move_left --events '[{"key": "A"}, {"key": "Left"}]' --yes
gd command project_input_map_set --action move_right --events '[{"key": "D"}, {"key": "Right"}]' --yes
gd command project_input_map_set --action jump --events '[{"key": "Space"}]' --yes
```

Write the script to a scratch file (`player.gd`):

```gdscript
extends CharacterBody2D

const SPEED := 300.0
const JUMP_VELOCITY := -600.0


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	velocity.x = Input.get_axis("move_left", "move_right") * SPEED
	move_and_slide()
```

```bash
# Into the project, onto the node, and saved.
gd command fs_write_text --path res://player.gd --text-file player.gd
gd command node_attach_script --path Player --script res://player.gd
gd command project_settings_set --name application/run/main_scene --value '"res://main.tscn"' --yes
gd command scene_save

# Does it compile and run without errors?
gd check res://player.gd
gd run --seconds 3 --headless

# Does it behave? Run it from the editor and look inside.
gd command editor_play
gd command game_node_get --path Main/Player --properties '["position", "velocity"]'
gd command game_input --action jump --hold 0.1
gd command game_node_get --path Main/Player --properties '["position", "velocity"]'   # velocity.y < 0: it jumped
gd command game_performance                                                           # fps, frame times, nodes
gd command editor_stop
```

Something wrong? Stop at a line and look:

```bash
gd command editor_play
gd command game_breakpoint --path res://player.gd --line 12
gd command game_debug        # stopped? where, and why
gd command game_locals       # the local variables at that line (delta)
gd command game_breakpoint --path res://player.gd --line 12 --enabled false
gd command game_continue
gd command editor_stop
```

`--yes` on the input actions and the main scene: they change project settings, which the bridge counts as
destructive and wants confirmed.

A fuller version, with tiles and checks, is in
[plugin/skills/godot-cli/references/walkthrough-platformer.md](plugin/skills/godot-cli/references/walkthrough-platformer.md).

## gdcli and Godot AI

gdcli has the same author as [Godot AI](https://github.com/spardanviro/Godot_AI), and the two take different
roads to the same goal.

| | gdcli (this project) | Godot AI |
|---|---|---|
| What it is | An editor addon (GDScript), a command line (`gd`, npm) and a Claude Code plugin | A native C++ module, compiled into a custom build of the engine |
| Godot version | Official builds, 4.3 to 4.7, standard and .NET | 4.7+ from source (godot-master) |
| Install | Asset Library or `gd bridge install`; `npm install` | Build the editor from source with the module |
| Where the AI is | Outside the editor: the agent you already use (Claude Code, Codex, Cursor, Gemini CLI, any MCP client), with its own account | A chat panel docked inside the editor; you enter an API key for Anthropic, OpenAI, Gemini, DeepSeek or GLM |
| How changes are made | Structured commands, each one an undoable editor step; free code (`eval`) is off by default and needs a person's approval each time | Tool calls and generated `EditorScript` code run in the editor, with permissions, checkpoints and a safety check |
| The running game | Inspect, steer and debug it: values, inputs, calls, screenshots, breakpoints, locals, performance | Error monitoring and fixes inside the panel |
| Without an editor | `gd run`, `check`, `test`, `import`, `export`, `api`, `docs` | Lives in the editor |
| Good for | Using stable Godot with a coding agent in the terminal or an IDE, automation and CI | An assistant panel inside the editor, with a model of your choice |

They share their Godot knowledge: the pitfalls collected for Godot AI became references in gdcli's skills.

## Command reference

**With an editor** (the bridge runs in an open or headless editor)

| Command | What it does |
|---|---|
| `gd status` / `gd list` | the editors gd can reach / the commands the editor offers |
| `gd command <name> [--arg value]` | runs one editor command; arguments also as `--args '<json>'` or `--<arg>-file <file>` |
| `gd host start` / `gd host stop` | a headless editor when none is open / stop it |
| `gd eval <code>` | runs GDScript in the editor (off by default, enabled in the editor settings, approved by a person each time) |

Editor commands by area:

| Area | Commands |
|---|---|
| Scenes | `scene_new` `scene_open` `scene_save` `scene_tree` `scene_list_open` |
| Nodes | `node_create` `node_get` `node_set` `node_find` `node_move` `node_rename` `node_duplicate` `node_delete` `node_instantiate_scene` `node_attach_script` `node_connect_signal` `node_disconnect_signal` `node_connections` `node_add_to_group` `node_remove_from_group` |
| Files and resources | `fs_list` `fs_read_text` `fs_write_text` `fs_edit_text` `fs_move` `fs_delete` `fs_scan` `resource_create` `resource_get` `resource_set` `import_settings_get` `import_settings_set` |
| Project | `project_settings_get` `project_settings_set` `project_input_map` `project_input_map_set` |
| Animation | `animation_create` `animation_list` `animation_state_machine_create` `animation_blend_space_create` `sprite_frames_create` |
| Effects and shapes | `preset_create` `collision_shape_fit` `theme_set` |
| 3D levels | `gridmap_library_add` `gridmap_set_cells` `gridmap_get` |
| Project | `project_analyze` |
| Tiles and navigation | `tileset_add_atlas` `tileset_set_collision` `tileset_set_terrain` `tilemap_set_cells` `tilemap_get` `navigation_bake` |
| Several at once | `batch` (undoable steps and reads; a failure undoes the steps done) |
| Editor | `editor_status` `editor_play` `editor_stop` `editor_errors` `editor_selection` `editor_select` `editor_screenshot` `edit_undo` `edit_redo` |
| Running game | `game_tree` `game_node_get` `game_node_set` `game_call` `game_input` `game_output` `game_errors` `game_input_events` `game_speed` `game_ui` `game_expect` `game_screenshot` `game_performance` |
| Debugger | `game_breakpoint` `game_pause` `game_step` `game_continue` `game_debug` `game_locals` |

A project can add commands of its own in `res://gdcli_commands/`.

**Without an editor** (`gd` starts Godot itself)

| Command | What it does |
|---|---|
| `gd run [scene] [--seconds N] [--headless]` | runs the project or a scene and reports its errors with file, line and stack |
| `gd check <script>...` | compiles scripts and reports their errors |
| `gd test [paths] [--framework gut\|gdunit4] [--select text] [--junit file]` | runs the project's GUT or gdUnit4 tests and lists each failure |
| `gd import` / `gd export <preset> <output> [--debug\|--pack]` | imports resources / exports the game |
| `gd exec <script> [-- args]` | runs a SceneTree script headless |
| `gd api class <Name> [--member m]` / `gd api search <text>` | the API of your installed Godot version |
| `gd docs install` / `search` / `page` | downloads the official manual for your version (text only) and searches it |

**Project and setup**: `gd new`, `gd bridge install`, `gd bridge status`, `gd open`, `gd doctor`.

**Global options**: `--json`, `--project <path>`, `--godot <path>`, `--instance <id>` (when several editors have
the project open), `--timeout <seconds>`, `--yes` (confirm overwriting or deleting), `--dry-run` (say what would
change, change nothing).

## Output

With `--json`, every command prints one envelope of a fixed shape on standard output, on failure too:

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

On failure each entry of `errors` has a `code`, `message`, `hint` and `details`. Exit codes: 0 success, 1 internal
error, 2 usage, 3 authentication, 4 precondition (no editor, confirmation needed, a person declined), 5 retry
later, 6 the command failed.

## Safety

- **Ordinary changes** (nodes, properties, plain scripts) run at once and go on the undo stack.
- **Destructive changes** (deleting, overwriting, project settings) need `--yes` from the caller. That is a speed
  bump, not an authorization.
- **Changes that would bring code into the editor process** always wait for a person: `@tool` scripts, scenes and
  resources with embedded scripts, any C# file, `addons/`, autoloads and other settings that decide which code
  loads, files a .NET build reads, and `eval`. The dialog shows the full content; what the caller says does not
  count. A headless editor has no one to ask and refuses.
- **Access modes** live in the editor settings, per user and not in the project: `standard` (default), `ask` (a
  person approves every destructive change), `readonly`, and `full` (asks no one; for unattended headless editors
  and CI).
- The game's own code runs with your rights, as when you press F5 yourself. To limit that, do not let your agent
  client auto-approve writing files and running the game.

The full rules: [docs/protocol.md](docs/protocol.md), section 4 (in Chinese).

## Troubleshooting

**`gd` cannot find Godot**: run `gd doctor`. Set it with `--godot`, `GODOT_BIN` or `~/.gdcli/config.json`; on
Windows point it at `*_console.exe`.

**`NO_EDITOR`**: no editor is open, or the project has no bridge. `gd bridge install`, then `gd open`; without a
display, `gd host start`.

**`NOT_APPROVED`**: the change needs a person's approval in the editor, and they declined, or the editor has no
window. Try again in an editor with a window, or do it another way that needs no approval. Do not work around it.

**`MULTIPLE_EDITORS`**: more than one editor has the project open; pick one with `--instance <id>` (from
`gd status`).

**The bridge version differs from `gd`**: `gd bridge install --force` installs the bridge that matches.

**Exporting fails**: export templates and presets are set up in the editor first (Editor > Manage Export
Templates, Project > Export). The `godot-export` skill explains it.

## Evals

`evals/` holds 40 tasks: scenes, scripts, UI, gameplay, 3D, animation, tiles, localization, audio buses, themes,
GridMap, shaders, particles,
debugging, and requests written in Chinese. 11 of them are hard ones checked by behaviour in the running game: a
patrol-and-chase state machine, saving and loading, a pause menu, a logic bug that prints no error.

- Replaying the reference answers passes every task; doing nothing fails them all (except "do not work around a
  refusal"). Both run in CI.
- With real Claude, the second baseline ran 31 tasks 3 times each: **93/93 passed**
  ([evals/results/claude-baseline.json](evals/results/claude-baseline.json)).

```bash
GODOT_BIN=/path/to/godot node evals/run.mjs --agent claude --repeat 3 --baseline evals/results/claude-baseline.json
```

Details in [evals/README.md](evals/README.md).

## Documentation

The detailed documents are in Chinese.

| Document | Contents |
|---|---|
| [docs/protocol.md](docs/protocol.md) | the two channels, the wire protocol, the envelope, error codes, safety rules, every command's contract |
| [docs/architecture.md](docs/architecture.md) | design decisions, similar projects, how this one differs |
| [docs/roadmap.md](docs/roadmap.md) | phases and their acceptance results |
| [docs/releasing.md](docs/releasing.md) | releasing (npm, GitHub Release, Asset Library) |
| [plugin/README.md](plugin/README.md) | the Claude plugin, its hooks, sandbox settings |
| [evals/README.md](evals/README.md) | the eval set |

## Repository layout

| Folder | Contents |
|---|---|
| `bridge/` | a Godot project for development and tests; `bridge/addons/gdcli/` is the bridge (GDScript, Godot 4.3+) |
| `cli/` | the `gd` command line (TypeScript, Node 22+, no runtime dependencies) |
| `plugin/` | the Claude plugin: skills, references, hooks |
| `evals/` | the eval set: tasks, checks, runner, baseline results |
| `scripts/` | test and check scripts, and the scripts that generate the plugin's references |

To report a security problem, see [SECURITY.md](SECURITY.md).

The three parts are released together with the same version number, from this one repository: the plugin's
command reference is generated from the bridge, so they cannot drift apart.

## Development

```bash
npm install
npm run verify                                 # versions, plugin check, hook tests, types, lint, unit tests, build
GODOT_BIN=/path/to/godot npm run test:bridge   # the bridge's unit and end-to-end tests
GODOT_BIN=/path/to/godot npm run test:e2e      # the built gd against a real editor
GODOT_BIN=/path/to/godot npm run test:windowed # a game with a window: clicks at game_ui's positions, screenshots
npm run test:package                           # pack, install into an empty folder, run
```

CI tests Godot 4.3 to 4.7 on Linux, and 4.7 on Windows, macOS and the .NET build; the command line on all three
systems; and a game with a window on a virtual display.

## License

[Apache-2.0](LICENSE).
