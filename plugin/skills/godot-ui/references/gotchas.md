# Pitfalls: user interface

23 entries, each a mistake that is easy to make in Godot 4 and what to do instead. Do not read this file from top to bottom:
search it for the class, method or term you are about to use (the `keywords` line of each entry lists them) and read the entries that match.
The other skills of this plugin have a file like this one for their topics: `../../*/references/gotchas.md` searches all of them.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

<!-- keywords: Control -->
### Control centering: use set_anchors_preset() or set anchor + offset pairs
To center a Control node in its parent from code, use the preset method (cleanest):
```gdscript
control.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
# Or for full-rect fill:
control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
```
Manual approach: set `anchor_left/right/top/bottom` to 0.5, then `offset_left/right/top/bottom` to ±(size/2). Negative offsets place the control above/left of the anchor point.


<!-- keywords: Windows, Exclusive, Fullscreen -->
### Windows: use Exclusive Fullscreen, not Fullscreen, for games
Godot has two 'fullscreen' window modes:
- `WINDOW_MODE_FULLSCREEN`: leaves a 1-pixel-high gap at the bottom so Windows treats it as an overlay window. Intended for GUI apps needing per-pixel transparency. Windows does NOT give it elevated priority — more jitter and input lag.
- `WINDOW_MODE_EXCLUSIVE_FULLSCREEN`: uses actual screen dimensions. Windows gives it elevated GPU scheduling priority, reducing jitter and input lag. **Use this for games.**
Also note: when using integer scaling for pixel art, the 1-pixel gap in regular Fullscreen can cause the scale factor to be 1 smaller than expected.


<!-- keywords: SubViewport, SubViewportContainer, Viewport, Container, Input, input -->
### SubViewport: input not received by default, must be inside SubViewportContainer
A `SubViewport` node does NOT automatically receive mouse/touch/keyboard input unless it is a direct child of a `SubViewportContainer`. Without the container, forward input manually. Additionally:
- For 3D/2D audio positional sound to work inside a SubViewport, enable `audio_listener_enable_3d` / `audio_listener_enable_2d` on the viewport.
- Shadows in SubViewports require `positional_shadow_atlas_size > 0` (default 4096 on desktop, 2048 on mobile).
- SubViewports use their own separate World2D (always). World3D is shared with parent by default unless `own_world_3d=true` is set.


<!-- keywords: Thread, MANDATORY, Windows, threading -->
### Thread: wait_to_finish() is MANDATORY — also, creating threads is slow on Windows
After a `Thread.start()`, you **must** call `thread.wait_to_finish()` when done — even if you know the thread function has already returned. Skipping it causes memory leaks or crashes. Always call it in `_exit_tree()` or equivalent cleanup. Additionally, thread creation is expensive on Windows (much more so than on Linux/macOS). Avoid creating threads just-in-time for short tasks. Instead, pre-create threads during level loading and keep them alive for the session, using Semaphores to signal work.


<!-- keywords: Localization, Labels, Buttons, Label, RichTextLabel, UI, Button -->
### Localization: Labels/Buttons auto-translate text matching translation keys — can be a bug
Controls like Label, Button, and RichTextLabel automatically call `tr()` on their text. If the text matches a translation key in the loaded translations, it will be replaced with the translated string. This is usually desired for UI text but can accidentally translate player names, usernames, item names, etc. if they happen to match a key. Fix: set `Auto Translate > Mode = Disabled` in the Inspector on nodes displaying user-generated content.


<!-- keywords: Localization, Default, Latin, Cyrillic -->
### Localization: Default project font only supports Latin-1 — CJK/Cyrillic will show blank
Godot's built-in default font (the editor font) only covers the Latin-1 character set. If you're localizing to Russian, Chinese, Japanese, Korean, Arabic, etc., characters will appear as blank boxes (tofu) unless you:
1. Download a multilingual font (e.g., Noto Fonts from google.com/get/noto)
2. Import the TTF file as a FontFile resource
3. Set it as a custom font on your Control nodes (or globally in Theme)
Also: the resource remapping system for localized assets **doesn't work for DynamicFonts**. For font-per-language scenarios, use the DynamicFont fallback system instead.


<!-- keywords: Control, Containers, MarginContainer, Node, UI, theme, Theme, Container, VBoxContainer, HBoxContainer -->
### Control nodes inside Containers give up manual positioning; MarginContainer margins are theme values
UI Container non-obvious behavior:
- When a **Control** node is a child of a **Container**, it gives up its own position/size control. Any manual `position` or `size` changes will be overridden or ignored the next time the container reflows.
- **MarginContainer** margins are **Theme** constants (not direct properties) — edit them via the node's **Theme Overrides > Constants** section.
- **ScrollContainer** only accepts a **single child node** (wrap multiple children in a VBoxContainer/HBoxContainer first).
- Custom containers override the **NOTIFICATION_SORT_CHILDREN** notification and must call `queue_sort()` to trigger a re-layout when settings change.


<!-- keywords: Stretch, Mode, Disabled, Scale, int -->
### Stretch Mode and resolution: 'Disabled' = 1:1 pixels; for pixel art use 'integer' Scale Mode
Project Settings > Display > Window > Stretch settings:
- **Disabled** (default): 1 game unit = 1 pixel. No stretching. Best for tools and apps with explicit sizing.
- **Canvas Items**: Scene rendered at target resolution, base size scaled to fill screen. 3D is unaffected. May cause 2D scaling artifacts.
- **Viewport**: Scene first rendered at base resolution (lower quality), then the result is scaled to fit screen. Best for pixel art quality.
- **Stretch Scale Mode = Integer** (Godot 4.2+): Rounds scale factor DOWN to the nearest integer — prevents sub-pixel distortion for pixel art.
- For both portrait and landscape support: use a **square** base resolution (e.g., 720×720) instead of a rectangle.
- `GUI > Theme > Default Theme Scale` project setting **cannot be changed at runtime** — it's read once at startup.


<!-- keywords: Windows, Exclusive, Fullscreen, Input, input -->
### Windows: use 'Exclusive Fullscreen' not 'Fullscreen' for lower jitter and input lag
Godot's **Fullscreen** window mode intentionally leaves a 1-pixel gap at the bottom so Windows does NOT treat it as exclusive fullscreen. This prevents Windows from automatically enabling per-pixel transparency features, but it DISABLES Windows' game-specific optimizations. **Exclusive Fullscreen** uses the actual screen size and allows Windows to reduce jitter and input lag for games. Note: physics interpolation improves visual smoothness but INCREASES input lag for physics-dependent behavior (player movement) — compensate by increasing Physics Ticks Per Second.


<!-- keywords: Input, input -->
### _input() receives ALL events first; _unhandled_input() only gets events NOT consumed by _input() or UI
Input processing order:
1. _input() — receives every event before anything else. Call get_viewport().set_input_as_handled() to consume it.
2. GUI controls (_gui_input) — consume UI interactions
3. _unhandled_input() — receives events not consumed by _input() or UI. Use this for gameplay input to avoid conflicts with UI.


<!-- keywords: Resolution, AXIS, Forward, ONLY -->
### Resolution scale is PER-AXIS: 0.5 scale = 4x fewer pixels, not 2x; FSR 1.0/2.2 are Forward+ ONLY
Resolution scaling gotchas:
- Scale is per-axis, so 0.5 renders 1/4 the pixels (not 1/2). Very low scales have outsized performance impact.
- FSR 1.0 and FSR 2.2 upscaling are ONLY available in Forward+ renderer.
- FSR2 provides its own TAA — the 'Use TAA' project setting is IGNORED when FSR2 is active.
- FSR Sharpness slider is INVERTED: 0.0 = sharpest, 2.0 = least sharp (default 0.2).
- Resolution scaling is NOT available for 2D. Simulate with viewport stretch mode.


<!-- keywords: Default, Latin -->
### i18n: Default font silently fails on non-Latin characters; CJK line breaking requires opt-in ICU data (+4MB)
Internationalization gotchas:
- The default Godot font only supports Latin-1. CJK (Chinese/Japanese/Korean), Arabic, Cyrillic, etc. render as blank squares with no error
- For languages without spaces (CJK, Thai), line/word breaking requires ICU data that is NOT included in exports by default. Enable 'Include Text Server Data' in export settings (+4MB)
- If a Label's text accidentally matches a translation key, it WILL be auto-translated. Disable Auto Translate Mode on labels displaying player names or dynamic strings
- For RTL (Arabic/Hebrew): layout and text direction are mirrored, but the X/Y coordinate system is NOT. Sprites/non-Control nodes are unaffected by RTL mirroring
- Test Locale project setting persists and shows up in version control — reset to empty before committing


<!-- keywords: Code, Godot, Windows, instantiate -->
### VS Code for Godot on Windows must use 'code.cmd' not 'code.exe'; LSP/DAP require a running Godot instance
External editor gotchas:
- On Windows, setting VS Code path to 'code.exe' fails — must use 'code.cmd' (the batch file wrapper)
- LSP (port 6005) and DAP (port 6006) require Godot to be RUNNING. Closing the editor breaks all language server features in your external editor
- Visual Studio cannot jump to specific lines (no {line} support) — only opens the file


<!-- keywords: Godot -->
### gettext/PO: 'fuzzy' comment after msgmerge silently prevents translation from loading in Godot
Localization with gettext gotchas:
- After running `msgmerge`, strings marked with `#, fuzzy` comment are SILENTLY IGNORED by Godot — they look correct in the file but never appear in-game. Must manually remove the fuzzy comment.
- `msgmerge` parameter order is critical: `msgmerge [po-file] [pot-template]` — reversing them corrupts the translation file
- `.pot` template files must have EMPTY `msgstr` values — translations belong only in `.po` files. Non-empty msgstr in .pot causes incorrect base strings.
- The Godot gettext extractor only finds localizable strings in CONSTANT string expressions — dynamic strings and concatenations are silently skipped


<!-- keywords: Video, WebM, URLs, FFmpeg, Windows, Theora -->
### Video: CPU-only decoding; WebM removed in 4.0; streaming URLs not supported; FFmpeg 64-bit on Windows corrupts Theora
VideoStreamPlayer gotchas:
- Video decoding is ENTIRELY CPU-based — no GPU acceleration. High resolution (1440p+) videos will stutter on mobile and low-end hardware
- WebM video format was REMOVED in Godot 4.0 — Ogg Theora (.ogv) is the only built-in video codec
- Streaming video from URLs is NOT supported — only local files work
- Multichannel audio (5.1, 7.1) in videos is automatically downmixed to stereo with no option to preserve
- CRITICAL: 64-bit FFmpeg on Windows produces CORRUPTED Theora output — must use 32-bit FFmpeg to encode .ogv files
- Setting Video Delay Compensation to non-zero causes frame drops at loop boundaries


<!-- keywords: Container, OVERRIDES, MarginContainer, Theme, Control -->
### Container silently OVERRIDES child position/size; MarginContainer needs theme constant overrides to have any margin
GUI Container gotchas:
- Any manual position or size set on Control nodes INSIDE a Container is silently overridden/reset whenever the Container resizes. The Container takes complete layout control — do NOT manually position children inside containers.
- MarginContainer only applies margins if the theme's constant overrides define them. Without theme overrides, MarginContainer behaves identically to a regular container with zero margins.
- Fill and Expand flags are independent: a control can Expand (takes extra space in layout) without Fill (using that space), leading to surprising gaps. Fill defaults ON, masking this behavior.
- Control anchors use anchor-relative offsets: when anchor is at 1.0 (right/bottom), NEGATIVE offset values move the control left/up — opposite of what feels intuitive.


<!-- keywords: Transform3D -->
### Transform3D.translated() vs translated_local(): one is world-relative, the other is object-relative — mixing them silently moves objects wrong
translated(offset) applies the offset in PARENT/GLOBAL space (ignoring the object's rotation). translated_local(offset) applies in the OBJECT'S LOCAL space (relative to the object's own axes). Using translated() to move an object 'forward' in its local Z direction won't work if the object is rotated.


<!-- keywords: Import, MUST, Control, import -->
### Import .import files MUST be in version control — .godot/imported/ folder should NOT be
The .import files (next to each asset) store import settings and must be committed to git. The generated cache in .godot/imported/ is machine-specific and should be in .gitignore. If .import files are missing, team members lose all custom import settings.


<!-- keywords: autowrap_mode, TextServer, AutowrapMode, AUTOWRAP_WORD_SMART, AUTOWRAP_ARBITRARY, AUTOWRAP_WORD, AUTOWRAP_OFF -->
### Label.autowrap was replaced by autowrap_mode (Godot 4.x)
The old boolean `Label.autowrap` no longer exists. Use `Label.autowrap_mode` with the `TextServer.AutowrapMode` enum:
  WRONG:  label.autowrap = true
  CORRECT: label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART  # wraps at word boundaries
Other values: AUTOWRAP_ARBITRARY (any character), AUTOWRAP_WORD (word only), AUTOWRAP_OFF (no wrap).


<!-- keywords: export_tool_button, IconName, _bake_button -->
### @export_tool_button — adds a clickable button in the Inspector (Godot 4.3+)
`@export_tool_button("Label", "IconName")` creates a button in the Inspector that calls a Callable when clicked. Only works in `@tool` scripts. The second argument is optional (icon name from the editor theme):
  @tool
  @export_tool_button("Bake", "Bake") var _bake_button = bake
  func bake() -> void: pass


<!-- keywords: auto_translate, auto_translate_mode, can_auto_translate, AUTO_TRANSLATE_MODE_DISABLED -->
### Control.auto_translate deprecated — use Node.auto_translate_mode
The `auto_translate` property on Control is deprecated. Use `Node.auto_translate_mode` (inherited by all nodes) and `Node.can_auto_translate()` instead.
  WRONG:  control.auto_translate = false
  CORRECT: control.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED


<!-- keywords: LAYOUT_DIRECTION_LOCALE, LAYOUT_DIRECTION_APPLICATION_LOCALE, layout_direction -->
### Control.LAYOUT_DIRECTION_LOCALE deprecated — use LAYOUT_DIRECTION_APPLICATION_LOCALE
  WRONG:  control.layout_direction = Control.LAYOUT_DIRECTION_LOCALE
  CORRECT: control.layout_direction = Control.LAYOUT_DIRECTION_APPLICATION_LOCALE


<!-- keywords: get_theme_, add_theme_, theme_override_colors, font_color, add_theme_color_override, get_theme_color, add_theme_font_override, add_theme_font_size_override -->
### Control theme items — read with get_theme_*(), override with add_theme_*_override()
Theme items (colors, fonts, constants, icons, styles) are not ordinary properties. `control.get("theme_override_colors/font_color")` only returns a value when an override was set on that control — it never returns the value inherited from the theme. Read with get_theme_*() and write with add_theme_*_override():
  CORRECT: label.add_theme_color_override("font_color", Color.RED)
  CORRECT: label.get_theme_color("font_color")  # read
Theme override methods: `add_theme_color_override`, `add_theme_font_override`, `add_theme_font_size_override`, `add_theme_constant_override`, `add_theme_icon_override`, `add_theme_stylebox_override`. Remove with `remove_theme_*_override`.
