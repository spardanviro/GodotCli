---
name: godot-export
description: Export a Godot 4 game to a file people can run - export presets and templates (what the person sets up in the editor), gd export from the command line (release, debug, pack only), what goes into the pack (resource filters, files that are not resources), and the Web export in particular (Compatibility renderer, threads and cross-origin isolation headers, serving the files, audio, saving in the browser, file size). Use when the user wants a build, a release, an .exe, an APK, a web or HTML5 version, to put the game on itch.io, or when something works in the editor but not in the exported game.
---

# Exporting

An export turns the project into a program for one platform. It needs two things the person sets up once in the
editor, and then runs from the command line as often as wanted.

## What the person sets up

1. **Export templates** for this exact Godot version: Editor > Manage Export Templates > Download and Install.
   They are a large download into the user's Godot folder; gd does not fetch them.
2. **A preset per platform**: Project > Export > Add... (Windows Desktop, Linux, macOS, Web, Android, ...). The
   presets are saved in `res://export_presets.cfg`. Android and iOS also need their SDKs and signing set up there.

`export_presets.cfg` decides what gets built and shipped, so the bridge does not write it unasked: a change through
`fs_write_text` waits for the person's approval, and a headless editor refuses. Ask the person to add or change a
preset in the editor. Passwords and keystores live in `.godot/export_credentials.cfg`, which stays out of version
control; `export_presets.cfg` itself can be committed.

## Building

```bash
gd export "Windows Desktop" build/windows/mygame.exe
gd export Web build/web/index.html
gd export Linux build/linux/mygame.x86_64 --debug     # a debug build: prints errors, can attach the debugger
gd export "Windows Desktop" build/mygame.pck --pack   # the game's data only, no program
```

- The preset name is exactly as in the editor (quote it when it has spaces). A wrong name answers with the names
  there are: `RESOURCE_NOT_FOUND` with `available`.
- The output path is resolved from the current folder, and its folder is made if needed. An existing file is
  replaced only with `--yes`, and so is a path outside the project. Expected endings: Windows `.exe`, Linux any
  (usually `.x86_64`), macOS `.zip` or `.app`, Web `.html` (call it `index.html`) or `.zip`, Android `.apk` or `.aab`.
- Export runs the project's tool scripts and plugins, like opening the project does.
- Missing templates fail the export with the engine's message; that is for the person to fix (step 1).
- A build folder inside the project needs an empty `.gdignore` file in it (write it with `fs_write_text`), or the
  editor imports the build's images and the next export may pack them. Or export outside the project with `--yes`.

## What goes in

- By default every resource the project uses. Files Godot does not import (`.txt`, `.json`, `.csv` you read
  yourself) are left out unless the preset's include filter names them (`*.json`). Folders and files whose names
  start with a dot are never exported.
- `res://` is read-only in an exported game: save games and settings go to `user://`.
- Paths are case-sensitive in a pack even when Windows was not: `res://Art/Player.png` and `res://art/player.png`
  are different files there. A game that loads a path with the wrong case works in the editor and fails exported.
- A resource only loaded by a path built at run time (`load("res://levels/" + name + ".tscn")`) is still exported
  when the preset exports all resources; with "selected scenes" it may be missing.
- `--pack` makes a `.pck` of the data, usable with an already exported program of the same version.

## The Web export

- **Renderer**: the Web runs the Compatibility renderer only. A project made for Forward+ or Mobile is switched to
  it for the Web build (`rendering/renderer/rendering_method.web`), and may look different or lose features (some
  post-processing, particles counts, shadows). Test with Compatibility, or start the project with it
  (`gd new --renderer gl_compatibility`).
- **Threads**: off by default since 4.3; that build runs on itch.io and similar sites with no setup. With **Thread
  Support** on, the server must send `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp`, or the game does not start. Leave it off unless something needs it.
- **Serving**: open it through a web server, not by double-clicking `index.html`. Keep the exported file names.
  Serve `.wasm` as `application/wasm`; gzip or Brotli on `.wasm` and `.pck` makes the download several times
  smaller. For a quick local look: `python -m http.server` in the build folder (threads off).
- **Audio** starts only after the player clicks or presses a key (browsers block autoplay): put a start screen first.
  The Web plays sounds as samples by default, which has no bus effects (reverb, filters); setting
  `audio/general/default_playback_type.web` to Stream (`0`) brings them back, with more latency.
- **Saving**: `user://` is kept in the browser (IndexedDB). Private windows and some iframe embeds lose it.
- **Fullscreen and mouse capture** only work from an input event handler (`_input`, `_unhandled_input`), not from
  code that polls `Input`.
- **C#** projects cannot be exported to the Web in Godot 4.
- A game left in a background tab stops processing until the tab is shown again.
- After a new upload, a browser may still show the old build: the page's service worker caches it (PWA option).

## When the exported game misbehaves

Run a debug export from a terminal and read what it prints, or `gd run --headless` the project for errors first.
The usual causes are the case of a path, a file the filters left out, `res://` being written to, and a feature the
export's renderer does not have. See also the `godot-troubleshooting` skill.
