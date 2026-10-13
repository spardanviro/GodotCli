---
name: godot-new-project
description: Start a brand-new Godot 4 game from nothing with the gd command line - settle the few decisions that are costly to change later (2D or 3D, renderer, resolution, pixel art or not), create the project with the bridge in it, open the editor, lay out folders, input actions and a first scene that runs. Use when the user wants to make, start, create, bootstrap or prototype a new game or project, joins a game jam, or works in a folder that has no project.godot yet.
---

# Starting a new Godot project

This takes an idea to an empty project that opens, runs and is ready to build in. It does not write the game.
For that, continue with the `godot-cli` skill and the skills for the kind of work at hand.

## 1. Decide what is costly to change later

Ask only what the user has not already said, in one message, and take sensible defaults for the rest.

| Decision | Options | Default when the user does not care |
|---|---|---|
| 2D or 3D | decides the first scene's root and most of the skills that follow | from the game they describe |
| Where it must run | desktop; phones; web browser | desktop |
| Look | pixel art (a small, fixed resolution) or anything else | not pixel art |
| Name and folder | the folder becomes the project | a folder named after the game, in the current directory |

Where it runs decides the renderer, which decides what graphics features exist:

- `forward_plus`: desktop. Everything works.
- `mobile`: phones, and desktops that should stay light. No volumetric fog, SDFGI or VoxelGI; fewer lights per mesh.
- `gl_compatibility`: **the web**, and old hardware. The fewest features. A game that must run in a browser
  starts here; moving to it later means redoing what leaned on the other renderers.

Do not ask about things that are easy to change later: window size, input keys, folder names, version control host.

## 2. Create it

```bash
gd doctor                                   # is there a Godot binary gd can use?
gd new my-game --name "My Game" --renderer forward_plus
```

`gd new` makes the folder with `project.godot`, a `.gitignore` and `.gitattributes` that suit Godot, and installs
and enables the bridge. It refuses a folder that already has files in it. `--dry-run` shows what it would do.

If `gd doctor` finds no Godot binary, ask the user where their Godot is (`--godot <path>` or the `GODOT_BIN`
variable). `gd` does not download the engine.

## 3. Open the editor

```bash
cd my-game
gd open                                     # starts the editor on the project; the user sees a window
gd status                                   # repeat until it says ready
```

When nobody is at the machine, `gd host start` runs an editor without a window instead. It cannot ask a person
to approve anything and cannot take screenshots, so prefer the real editor when the user is there.

The first start imports the project and may take a while. Run every later command from inside the project
folder, or pass `--project`.

## 4. Settings that follow from the decisions

Only what the answers in step 1 call for. A desktop game for which the user named no resolution and no look
needs none of this: leave the engine's defaults and go to step 5.

```bash
# When the user named a resolution: the size the game is designed at, and how it meets other screen sizes.
gd command project_settings_set --name display/window/size/viewport_width --value 1280 --yes
gd command project_settings_set --name display/window/size/viewport_height --value 720 --yes
gd command project_settings_set --name display/window/stretch/mode --value canvas_items --yes
gd command project_settings_set --name display/window/stretch/aspect --value expand --yes
```

- Pixel art uses other values (a small viewport, `viewport` stretch mode, integer scaling, nearest filtering):
  they are in the `godot-sprite-animation` skill, under "Pixel art".
- A phone game in portrait swaps width and height and sets `display/window/handheld/orientation` to `1`
  (portrait; `0` is landscape).
- Leave physics, audio and rendering quality settings at their defaults until something asks for a change.

## 5. A first scene that runs

A project needs a main scene before it can run. Make the smallest one that shows the project works:

```bash
gd command scene_new --path res://scenes/main.tscn --root-type Node2D --root-name Main    # Node3D for a 3D game
gd command scene_save
gd command project_settings_set --name application/run/main_scene --value res://scenes/main.tscn --yes
gd run --seconds 2 --headless                                                             # 0 errors
```

Folders appear as files are written into them; there is nothing to create up front. Use `res://scenes/`,
`res://scripts/`, `res://art/`, `res://audio/` unless the user has their own layout
(more in `godot-gdscript`, under "Where files go").

Input actions are registered when the first script needs them (`project_input_map_set`), not now.

## 6. Version control

`gd new` has written the ignore file. Whether to make a repository, and where to push it, is the user's call:
offer `git init` and a first commit, and do it when they say yes. Do not create remote repositories or push.

```bash
git init -b main
git add -A
git status                                  # .godot/ must not be in the list
git commit -m "Empty Godot project"
```

## 7. Hand over

Say in two or three sentences what exists now: where the project is, which renderer it has and any settings you
changed, that an empty main scene was made so that it runs, and what the natural next step is for the game they
described. Then build that next step with the skills
for it: `godot-physics-gameplay` for a character that moves, `godot-tilemap` for a level made of tiles,
`godot-ui` for menus.

## When something is in the way

- `ALREADY_EXISTS` from `gd new`: the folder has files. Ask before choosing another folder; an existing Godot
  project is not replaced, it is opened (`gd open`).
- `GODOT_NOT_FOUND`: no engine binary. Ask for its path.
- `NO_EDITOR` after `gd open`: the editor is still starting or importing. Check `gd status` again after a few
  seconds; `gd doctor` says what is missing.
- The editor shows a dialog (project conversion, missing files): the user has to answer it; say so.
