# Pitfalls: GDScript, nodes, scenes, resources, files, threads and platforms

139 entries, each a mistake that is easy to make in Godot 4 and what to do instead. Do not read this file from top to bottom:
search it for the class, method or term you are about to use (the `keywords` line of each entry lists them) and read the entries that match.
The other skills of this plugin have a file like this one for their topics: `../../*/references/gotchas.md` searches all of them.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

<!-- keywords: JSON, Godot, Vector2, Vector3, Color, Rect2, Quaternion, serialization -->
### JSON cannot serialize Godot types: Vector2, Vector3, Color, Rect2, Quaternion
`JSON.stringify()` / `JSON.parse()` only handle bool, int, float, String, Array, and Dictionary. Godot-specific types like `Vector2`, `Vector3`, `Color`, `Rect2`, `Transform3D`, and `Quaternion` CANNOT be directly serialized. Decompose them manually:
```gdscript
# Saving
var data = { "pos_x": position.x, "pos_y": position.y }   # decompose Vector2
# Loading
position = Vector2(data["pos_x"], data["pos_y"])
# Alternative: use binary serialization (FileAccess.store_var / get_var) which handles all types
```


<!-- keywords: Inspector -->
### _init() assignment order: Inspector values always override _init()
When instantiating a scene, property values are applied in this order:
1. Default value (no setter called)
2. `_init()` runs and may assign values (setter IS called)
3. Inspector (exported property values) overwrite whatever `_init()` set (setter IS called)
This means values set in `_init()` are ALWAYS clobbered by Inspector values for `@export` properties. Use `_init()` for logic that must run before `_ready()`, but don't rely on it to set final `@export` values.


<!-- keywords: Autoload, scene, Node, autoload -->
### Autoload nodes persist across scene changes — they are NOT freed
Nodes added via Project Settings > Autoloads are children of the root node and persist when you call `get_tree().change_scene_to_file()`. They are NEVER freed during normal gameplay. This makes them suitable for cross-scene managers (audio, saves, UI), but means any state they hold survives scene transitions. Reset their state explicitly if needed on scene load.


<!-- keywords: Path2D, Path3D, PathFollow2D, PathFollow3D -->
### preload() requires a compile-time constant path — use load() for dynamic paths
`preload()` only accepts a LITERAL string (constant at compile time). You cannot use a variable or computed path:
  CORRECT: var scene = preload("res://scenes/player.tscn")  # literal string
  WRONG:   var scene = preload(my_path_var)                  # variable path — compile error
  CORRECT: var scene = load(my_path_var)                     # load() accepts variables


<!-- keywords: _draw, cached -->
### _draw() is cached — call queue_redraw() to trigger re-draw
`CanvasItem._draw()` is called **once** and its draw commands are cached. The function will NOT be called again automatically when your data changes. To trigger a redraw (e.g. when a variable changes), call `queue_redraw()` on the same node. A good pattern is to call it from a property setter:
```gdscript
@export var color: Color = Color.WHITE:
    set(value):
        color = value
        queue_redraw()  # trigger _draw() on next frame

func _draw() -> void:
    draw_circle(Vector2.ZERO, 32.0, color)
```


<!-- keywords: Editor, GDScript, gdscript, @tool, EditorPlugin -->
### Editor plugins: ALL helper GDScript files must have @tool
The EditorPlugin root script must be `@tool extends EditorPlugin`. But every OTHER GDScript file that the plugin loads or uses must ALSO start with `@tool`. A GDScript file without `@tool` that is used by an editor plugin acts as an **empty file** — its classes and functions are invisible to the plugin. Use `_enter_tree()` for initialization and `_exit_tree()` for cleanup (not `_ready()`).


<!-- keywords: Godot -->
### randomize() not needed in Godot 4 — random seed is automatic
Since Godot 4.0, the global random seed is automatically randomized at project start. You do NOT need to call `randomize()` in `_ready()`. Only call it explicitly if you need a specific deterministic seed:
  seed(12345)              # deterministic — same sequence every run
  seed("hello".hash())   # string-based seed
For per-object RNG, use `RandomNumberGenerator.new()` and call `.randomize()` on it to get an independent stream.


<!-- keywords: READ, ONLY, export -->
### res:// is READ-ONLY in exported games — use user:// for all saves and writes
`res://` is read-write only inside the editor. In exported builds it is read-only. Always use `user://` for any file that your game needs to write at runtime (save games, settings, downloads):
```gdscript
# WRONG — crashes or silently fails in exports:
var f = FileAccess.open("res://save.dat", FileAccess.WRITE)
# CORRECT:
var f = FileAccess.open("user://save.dat", FileAccess.WRITE)
```
Always use forward slashes `/` as path delimiter — even on Windows.


<!-- keywords: GDScript, gdscript, int, float -->
### GDScript integer division truncates — use float to get decimals
When both operands of `/` are `int`, GDScript performs integer division (truncates toward zero):
  5 / 2 == 2    # NOT 2.5 !
  5 / 2.0 == 2.5  # OK — one float operand
  float(5) / 2 == 2.5  # OK — explicit cast
Also: `%` is integer-only. For float remainder use `fmod(a, b)`. For math-correct (always positive) modulo use `posmod(a, b)` / `fposmod(a, b)` (unlike `%`, which truncates like C).


<!-- keywords: GDScript, LEFT, Python, gdscript -->
### GDScript ** is LEFT-associative (unlike Python)
`2 ** 2 ** 3` evaluates as `(2 ** 2) ** 3 = 64`, NOT `2 ** 8 = 256` like in Python. Use parentheses to specify the intended order: `2 ** (2 ** 3)`.


<!-- keywords: GDScript, VALUE, gdscript, lambda, Callable -->
### GDScript lambdas capture variables by VALUE at creation time
Outer local variables captured by a lambda are copied at creation time — later reassignments to the outer variable do NOT update the lambda's copy:
```gdscript
var x = 42
var fn = func(): print(x)
x = 99
fn.call()  # Prints 42, not 99 !
```
Exception: pass-by-reference types (Array, Dictionary, Object) share their *contents* until the outer variable is reassigned to a different object. Also: call lambdas via `.call()` — the `()` operator on a Callable is not supported.


<!-- keywords: GDScript, await, coroutine, gdscript, error -->
### GDScript await: calling a coroutine without await causes an error
If a function uses `await` inside, it becomes a coroutine. Storing its return value without `await` raises a runtime error:
```gdscript
# WRONG:
var result = my_coroutine()  # Error: result is a GDScriptFunctionState, not the value
# CORRECT:
var result = await my_coroutine()
```
Calling without saving the result (`my_coroutine()` alone) is fine — it runs fire-and-forget.


<!-- keywords: GDScript, gdscript, enum, global -->
### GDScript named enum keys are NOT global constants
When you declare `enum State { IDLE, JUMP = 5, SHOOT }`, the keys `IDLE`, `JUMP`, `SHOOT` are **not** in global scope. You must prefix them with the enum name:
```gdscript
var s = State.JUMP   # CORRECT — prints 5
var s = JUMP         # ERROR — not found
```
Anonymous enums `enum { A, B, C }` DO register keys as global constants.


<!-- keywords: GDScript, gdscript, debug, assert -->
### GDScript: assert() is stripped in non-debug (release) builds
`assert(condition)` silently disappears in release exports. Never put code with side effects inside assert:
  assert(array.size() > 0)         # OK — pure check
  assert(spawn_enemy() != null)     # BAD — enemy NOT spawned in release!


<!-- keywords: GDScript, gdscript -->
### GDScript variable initialization order trap
Member variable initializers run top-to-bottom **before** `_init()`. `_init()` runs **before** `@export` values are set by the Inspector. So if `_init()` sets a var, the Inspector value will overwrite it afterward. Reference order also matters:
```gdscript
var _data: Dictionary = {}  # initialized first
var a: int = proxy(1)       # proxy() called; _data exists
# If _data were declared AFTER a, proxy() would find it empty
```


<!-- keywords: Euler, Camera, FPS -->
### FPS camera: rotate Y first, then X — never accumulate Euler angles
For a first-person controller, always apply Y-axis (horizontal look) rotation first, then X-axis (vertical look) in LOCAL space. Reversing the order causes the camera to tilt sideways. Also never lerp `Node3D.rotation` (Euler) for smooth 3D rotation — use `Transform3D.interpolate_with()` or `Quaternion.slerp()` instead:
```gdscript
# Correct FPS mouse look:
var yaw := 0.0   # horizontal (Y axis, global)
var pitch := 0.0 # vertical (X axis, local)
func _input(event):
    if event is InputEventMouseMotion:
        yaw -= event.relative.x * sensitivity
        pitch = clamp(pitch - event.relative.y * sensitivity, -89.0, 89.0)
        transform.basis = Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0))
```


<!-- keywords: GDScript, Godot, gdscript -->
### GDScript setters/getters: Godot 4 always calls them — even from same class
In Godot 4, property setters and getters are **always** invoked, even when accessed from inside the same class (with or without `self.`). This is different from Godot 3's `setget` which only triggered from outside. Inside the setter/getter itself, referring to the variable by name directly accesses the underlying value (bypasses the setter, preventing infinite recursion). But calling any OTHER function that also sets the variable WILL cause infinite recursion:
```gdscript
var x: int:
    set(value):
        x = value     # OK — direct variable access, no recursion
        set_x(value)  # BAD — calls set_x() which sets x through the setter → infinite loop
```


<!-- keywords: Node, RefCounted, queue_free -->
### Node memory: RefCounted is auto-freed, Node needs queue_free()
- `RefCounted` (and `Resource`) are freed **automatically** when refcount reaches 0
- `Node` objects stay in memory until explicitly freed: use `queue_free()` (safe, end of frame) or `free()` (immediate)
- `queue_free()` on a Node recursively frees ALL its children
- Use `weakref(obj)` to hold a reference without preventing auto-free
- Use `is_instance_valid(obj)` to check if an object has been freed before using it


<!-- keywords: Signal, signal, connect, emit -->
### Callable.bind() — add extra arguments at connection time
Use `.bind(extra_arg)` to pass additional context to a signal handler that the signal itself doesn't emit:
```gdscript
# Signal only emits (old_health, new_health), but we want character name too:
character.health_changed.connect(battle_log._on_health_changed.bind(character.name))

func _on_health_changed(old_val, new_val, char_name: String):
    # char_name comes from bind() — appended AFTER signal args
    label.text = char_name + " took damage"
```


<!-- keywords: Cannot, GDScript, gdscript -->
### Cannot override non-virtual engine methods in GDScript
Non-virtual engine methods like `get_class()`, `queue_free()`, `_to_string()` **cannot** be overridden in GDScript — attempting to will trigger the `NATIVE_METHOD_OVERRIDE` warning, which is treated as an error by default. Only methods marked `virtual` in the docs (and named with `_` prefix) can be overridden: `_ready()`, `_process()`, `_input()`, `_draw()`, etc.


<!-- keywords: export, property, @tool -->
### @export setters/getters only run in editor if @tool is present
When editing exported properties in the Inspector, setters/getters on those properties are only executed if the script has `@tool` at the top. Without `@tool`, Inspector edits write the raw value directly, bypassing your setter logic. This means validation and visual updates you put in setters won't run at edit time — only at runtime.


<!-- keywords: export -->
### @export_range: 'or_greater'/'or_less' allow values outside the slider range
By default, `@export_range(min, max)` clamps Inspector input to the range. Add `"or_greater"` and/or `"or_less"` hints to allow typing or dragging values outside the range:
  @export_range(0, 100, 1, "or_greater") var speed: int  # Can exceed 100
For angle variables stored in radians but shown as degrees in the Inspector, use:
  @export_range(-180, 180, 0.1, "radians_as_degrees") var angle: float


<!-- keywords: Resource, instantiate, load, preload -->
### load() and preload() return a cached, shared Resource — use .duplicate() for separate instances
Godot caches every resource loaded from disk. Calling `load("res://item.tres")` twice returns the **same object**. If multiple enemies should each have their own independent `stats` resource (so modifying one doesn't affect others), call `.duplicate()` after loading:
  var stats = load("res://base_stats.tres").duplicate()  # independent copy
For deep nesting (sub-resources inside resources), pass `true` to `duplicate(true)`. `preload()` has the same caching behavior.


<!-- keywords: COMPILE, TIME, String -->
### preload() is COMPILE-TIME only — path must be a constant string literal
`preload()` loads a resource when the script is compiled, not at runtime. Therefore its argument must be a **literal string constant**, not a variable:
  var r = preload("res://my_scene.tscn")  # OK
  var path = "res://my_scene.tscn"
  var r2 = preload(path)  # ERROR: path is a variable
Use `load(path)` or `ResourceLoader.load(path)` when the path is dynamic. `preload()` is unavailable in C#.


<!-- keywords: Resource, CANNOT, export, property, inner class -->
### Resource inner class CANNOT serialize @export properties
Defining a Resource subclass as an **inner class** of another script (using the `class` keyword inside a script) will NOT properly serialize `@export` properties when saved with `ResourceSaver.save()`:
  # WRONG — inner class
  extends Node
  class MyRes extends Resource:
      @export var value = 5  # NOT saved!
  # CORRECT — use a separate script file with class_name
Always place custom Resource classes in **their own .gd file** with `class_name` at the top. This is required for proper Inspector editing and serialization.


<!-- keywords: Node, _ready, scene, _process -->
### Node lifecycle order: _ready() is post-order, _process() is pre-order
In Godot's scene tree, callback order differs by function:
- `_process()`, `_physics_process()`, `_input()`, `_enter_tree()`: **pre-order** (parent called BEFORE children — top-to-bottom in the editor)
- `_ready()`: **post-order** (children called BEFORE parent — children are fully ready when parent's _ready() runs)
- `_exit_tree()`: **reverse pre-order** (bottom-to-top)
So in `_ready()` you can safely call methods on child nodes. In `_enter_tree()` the children may not be ready yet.


<!-- keywords: Autoloads, MUST, queue_free, Node, autoload -->
### Autoloads MUST NOT be freed — engine crash if you call free() or queue_free() on them
Autoloaded nodes are managed by the engine and persist for the entire game session. Calling `free()` or `queue_free()` on an autoload node **crashes the engine**. To 'reset' an autoload, expose a reset method instead. Autoloads are NOT freed when changing scenes with `change_scene_to_file()`.


<!-- keywords: Autoload, scene, Node, get_node, autoload, singleton -->
### Autoload is NOT a true singleton — it's just a node added before the game scene
When you autoload a script, Godot creates a Node, attaches the script, and adds it as a direct child of the root Viewport **before** any game scenes load. It can still be instantiated manually. You can access it two ways:
  MyAutoload.some_method()   # if 'Enable' is checked (GDScript only)
  get_node("/root/MyAutoload")  # always works
In an autoload's `_ready()`, the game's main scene is the **last** child of root: `get_tree().root.get_child(-1)`.


<!-- keywords: Freeing, signal, scene -->
### Freeing a scene from within its own running signal callback crashes — use call_deferred()
If a signal fires (e.g., a button pressed) and the callback calls `current_scene.free()` or `get_tree().change_scene_to_file(...)`, the node may still be executing code, causing a crash or undefined behavior. **Always defer scene switches**:
  func _on_button_pressed():
      # WRONG: get_tree().change_scene_to_file("res://next.tscn")
      change_level.call_deferred("res://next.tscn")  # safe


<!-- keywords: GDScript, gdscript -->
### GDScript 'as' keyword returns null silently on type mismatch — does NOT throw
Unlike C++ or C# casting, GDScript's `as` operator never throws an exception. If the object is not of the target type, it silently returns `null`. This can cause subtle bugs:
  var player := body as Player  # null if body is not a Player — no error!
  player.take_damage(10)  # CRASH: null reference, no prior warning
Always null-check after `as`, or use `is` first. Prefer `is` for checking + direct cast for reliability:
  if body is Player:
      var player: Player = body


<!-- keywords: GDScript, Arrays, Dicts, gdscript, Array, typed -->
### GDScript typed Arrays/Dicts: nested types are NOT supported
Typed containers like `Array[int]` and `Dictionary[String, int]` are supported, but **nested typed collections are syntax errors**:
  var scores: Array[int] = []          # OK
  var nested: Array[Array[int]] = []   # SYNTAX ERROR
  var map: Dictionary[String, Dictionary[String, int]] = {}  # SYNTAX ERROR
Use `Array[Array]` (untyped inner) as a workaround. Element types must be built-in types, native classes, or custom classes — not other typed collections.


<!-- keywords: Scripts, RefCounted, Node -->
### Scripts without 'extends' implicitly extend RefCounted — NOT Node
A GDScript file that has no `extends` keyword at all implicitly extends `RefCounted`. This means you cannot attach such a script to a Node in the scene tree. If you get an error like 'Script does not inherit from Node', check that your script has `extends Node` (or the appropriate class) at the top. The implicit `extends RefCounted` is useful for pure data/logic classes, but is often an oversight when the intent was to create a Node script.


<!-- keywords: Object, RefCounted, instantiate -->
### Object (non-RefCounted) references go stale silently — use is_instance_valid()
`Object` (not `RefCounted`) instances are NOT reference-counted. When a `Node` is freed (via `free()` or `queue_free()`), any variables still holding a reference become a **dangling pointer** in GDScript. Accessing a freed object crashes with 'Invalid instance'. Always guard with `is_instance_valid(obj)` before using stored Object/Node references:
  if is_instance_valid(enemy):
      enemy.take_damage(10)
Alternatively, use `WeakRef` to hold a weak reference: `var ref = weakref(enemy)` and `ref.get_ref()` returns null after the object is freed. Note: `RefCounted` subclasses (including `Resource`) are reference-counted and are automatically freed when there are no more references — no need for `is_instance_valid()` there.


<!-- keywords: INVISIBLE, Inspector, export -->
### @export_storage: serialized to file but INVISIBLE in the Inspector
`@export_storage` marks a variable to be serialized when saving a scene/resource, but does NOT show it in the Inspector. Use it for internal state that should persist across saves (e.g., a character's current HP that is managed by code) but shouldn't be accidentally changed in the Inspector. This is distinct from:
- `@export`: shown in Inspector AND serialized
- No annotation: shown in Inspector if it's a simple type, but NOT serialized in .tscn/.tres files
- `@export_storage`: NOT shown in Inspector, but IS serialized


<!-- keywords: Reading, DEFAULT, Inspector, export -->
### Reading @export var in _init() gets DEFAULT value, not the Inspector-set value
When a script is instantiated, `_init()` is called BEFORE the scene file is applied (i.e., before Inspector-set export values are loaded). If you read an `@export var` in `_init()`, you get its **default value** as declared in the script, not whatever was typed in the Inspector:
  @export var speed = 100.0
  func _init():
      print(speed)  # ALWAYS prints 100.0, even if Inspector shows 200.0
To use Inspector-set values, read them in `_ready()` or later. This also applies to `_enter_tree()` — export values are not yet applied there.


<!-- keywords: SceneTree, scene -->
### NOTIFICATION_PARENTED fires even when NOT in the SceneTree
`NOTIFICATION_PARENTED` (and its counterpart `NOTIFICATION_UNPARENTED`) is emitted whenever a node is **added as a child** of another node, regardless of whether either node is in the active SceneTree. This is useful for nodes that need to react to being connected in a hierarchy even during deferred loading. In contrast, `NOTIFICATION_ENTER_TREE` fires only when the node and its ancestors are added to the running SceneTree. Don't confuse the two.


<!-- keywords: Set, BEFORE, Node, add_child, scene -->
### Set node properties BEFORE add_child() for correct initialization order
When creating and configuring nodes at runtime, set ALL properties before calling `add_child()`. Once a node enters the tree, `_ready()` fires on it (and its children), which may trigger signal connections or layout recalculations. Setting properties afterward can cause a double-initialization. Canonical pattern:
  var enemy = EnemyScene.instantiate()
  enemy.health = 200      # set BEFORE adding to tree
  enemy.position = spawn_point
  add_child(enemy)        # _ready() fires here with correct values


<!-- keywords: Custom, Mutex, Thread, threading -->
### Custom logger _log_message() is called from multiple threads — protect with Mutex
In Godot 4.5+, you can override `_log_message()` in an autoload to intercept all `print()`, `push_error()`, `push_warning()` calls. However, **_log_message() can be called from any thread** (audio, physics, background threads). If your logger writes to a file, array, or any shared state, protect it with a Mutex:
  var _mutex = Mutex.new()
  func _log_message(msg: String, is_error: bool) -> void:
      _mutex.lock()
      log_file.store_line(msg)
      _mutex.unlock()
Without a Mutex, two threads writing simultaneously can corrupt the log data or crash.


<!-- keywords: Scene, Name, scene, Node, get_node, Unique, Nodes, SAME, NodeName, instantiate -->
### Scene unique nodes (%Name) only work within the same scene — not across scene boundaries
The `%NodeName` syntax (Unique Name access) resolves to a node tagged with 'Access as Unique Name' in the editor. It only searches **within the same scene file** that the script belongs to. If you try `%SomeNode` from a script in scene A, but `SomeNode` is in an instantiated child scene B, it will NOT be found — even if `SomeNode` exists and is visible in the scene tree. You must either:
- Tag it as unique within scene B and access it from a script also in scene B
- Use `$ChildSceneRoot/SomeNode` or `get_node()` with the full relative path from scene A
Also: `find_child("SomeNode", true)` recursively scans ALL descendants — it is significantly slower than `%Name` (which is cached) or direct `$Path`. Avoid `find_child()` in `_process()` loops.


<!-- keywords: Feature -->
### Feature tags are immutable — OS.has_feature('mobile') is false on web/mobile
Feature tags like `pc`, `mobile`, `web`, `android` are set at compile time based on the **export platform**, not at runtime based on the device. If you export to Web and the player runs on an Android phone, `OS.has_feature('mobile')` returns **false** (it's a web export, not Android). To detect web-on-mobile, use `OS.has_feature('web_android')` or `OS.has_feature('web_ios')`. The only dynamic feature tags are texture compression, `web_<platform>`, and `movie`.


<!-- keywords: ProjectSettings, settings -->
### ProjectSettings.get_setting() ignores feature tag overrides — use get_setting_with_override()
When you define per-feature-tag overrides in Project Settings (e.g., different screen resolution for `mobile`), they are stored as e.g. `section/key.mobile`. Using `ProjectSettings.get_setting("section/key")` always returns the base value, ignoring feature tag overrides. To get the override-aware value based on the current feature tags, use `ProjectSettings.get_setting_with_override("section/key")`. Custom feature tags defined in export presets are also only available in exported builds, not when running from the editor.


<!-- keywords: Scene, scene, Tree, Thread, threading -->
### Scene tree is NOT thread-safe — use call_deferred() from worker threads
The active scene tree is **not thread-safe**. You cannot call `add_child()`, `remove_child()`, `queue_free()`, or set most node properties from a background thread. Doing so can cause random crashes or corruption. Use `call_deferred()` or `set_deferred()` to queue the operation for the main thread:
  # In a worker thread:
  node.add_child.call_deferred(child)  # safe
  # NOT safe: node.add_child(child)
Exception: you CAN instantiate and configure nodes **outside** the scene tree in a background thread, then add them to the tree via call_deferred from the main thread. The NavigationServer is thread-safe. AStar2D/AStar3D are NOT thread-safe (one AStar per thread only).


<!-- keywords: GDScript, Array, Dictionary, RESIZING, gdscript, Thread, Mutex, threading -->
### GDScript Array/Dictionary: element access is thread-safe; RESIZING is NOT
Reading and writing individual elements of an Array or Dictionary from multiple threads simultaneously is safe in GDScript. However, **any operation that changes the size** (append, push_back, erase, resize, insert, remove_at, clear) requires a Mutex, as it modifies the container's internal structure and can corrupt it:
  # SAFE without mutex (reading/writing existing element):
  array[index] = value
  # UNSAFE without mutex (size change):
  array.append(value)   # must lock mutex first


<!-- keywords: Web, AudioStreamPlayer, audio, export -->
### Web export: C# NOT supported; audio effects NOT supported; fullscreen needs user gesture
Critical web export limitations:
- **C# projects cannot be exported to Web** in Godot 4 (use GDScript or C++/GDExtension)
- **AudioEffects are not supported** in the default 'Sample' playback mode (Web Audio API). Switch AudioStreamPlayer Playback Type to 'Stream' for effects, but this increases latency
- **Entering fullscreen** or capturing the mouse cursor requires a direct response to a user input event (click, keypress) — cannot be done from _ready() or a timer. The fullscreen project setting doesn't work on Web without a custom HTML shell
- **Tab inactive** = all _process() stops. Networked games may disconnect
- **Gamepads** are not detected until the player presses a button
- **Low-level UDP/TCP networking not available** — only HTTP, WebSocket, WebRTC
- **Multi-threading** requires CORS headers on the server; single-threaded export is the new default/preferred approach since 4.3


<!-- keywords: HTTPRequest, Node, add_child, network -->
### HTTPRequest node: only ONE request at a time — create multiple nodes for parallel requests
An HTTPRequest node can only handle one in-flight request. A second call to `request()` while a request is pending will fail. Strategy for parallel requests: create and delete HTTPRequest nodes at runtime as needed (`var req = HTTPRequest.new(); add_child(req); ... req.queue_free()`). Also: Android exports require **Internet** permission enabled in the export preset, or all network communication will be silently blocked.


<!-- keywords: In, TOPMOST, BEHIND, scene, Node, int -->
### In the scene panel, TOPMOST nodes draw BEHIND lower nodes (counterintuitive Z order)
In Godot's 2D scene tree, the node listed **first (topmost)** in the Scene panel is rendered **behind** nodes listed later (lower in the list). The last child in the panel draws on top. This is opposite to many other tools. Use the node's `z_index` property or `CanvasItem > Z Index` for explicit depth control. CanvasLayer nodes are independent of scene tree order — they draw based on their `layer` number only, not their position in the tree.


<!-- keywords: All, GDScript, EditorPlugin, gdscript, @tool, editor -->
### All GDScript files in an EditorPlugin must be @tool, not just the main plugin script
When creating an EditorPlugin, the main plugin script MUST have `@tool` and `extends EditorPlugin`. But any **other** GDScript files that the plugin uses (helper classes, custom nodes, utilities) must ALSO have `@tool` at the top. GDScript files without `@tool` that are used by the editor plugin will **behave as empty files** — no functions will run. Additionally: C# EditorPlugin scripts require the project to be built first before the plugin can be enabled in the Plugins tab.


<!-- keywords: READ, ONLY, Godot, export -->
### res:// is READ-ONLY in exported projects; user:// default path is buried in Godot's data folder
In exported (non-editor) projects, `res://` is read-only. NEVER try to write files to `res://`. Always use `user://` for saves, config, and user data. Non-obvious `user://` behavior:
- **Default location**: `%APPDATA%/Godot/app_userdata/[project_name]` (Windows) — buried inside Godot's editor data, NOT the standard application data folder.
- To put saves in the standard location (`%APPDATA%/[project_name]`), enable `application/config/use_custom_user_dir` in Project Settings.
- **HTML5**: `user://` maps to a virtual filesystem stored via **IndexedDB** in the browser, NOT real disk files.
- To convert `res://` or `user://` paths to absolute OS paths (e.g. for OS.shell_open()), use `ProjectSettings.globalize_path()`.


<!-- keywords: JSON, Vector2, Vector3, Color, Rect2, Quaternion, serialization -->
### JSON serialization can't handle Vector2, Vector3, Color, Rect2, Quaternion — use binary for complex state
GDScript's JSON.stringify() only supports: int, float, String, bool, Array, Dictionary, null. It does NOT support Godot-specific types. Must manually convert them:
- Vector2/3 → Dictionary {"x":..., "y":...}
- Color → {"r":..., "g":..., "b":..., "a":...}
Alternative: use `FileAccess.store_var()` / `get_var()` for **binary serialization** which handles ALL common Godot types, produces smaller files, and requires no custom encoding.
Warning: when saving nested Persist objects (both parent and child saved), **NodePaths become invalid** on load. Save in stages: load parent objects first, then resolve child references.


<!-- keywords: In, Godot, _ready -->
### In Godot 4.0+, randomize() is called automatically — don't call it in _ready()
Since Godot 4.0, the random seed is automatically set to a random value when the project starts. Calling randomize() in _ready() is unnecessary. If you need deterministic results, use seed(12345). To hash a string into a seed: seed("my_seed".hash()).


<!-- keywords: Use, Array, GDScript -->
### Use shuffle bags for non-repeating randomness; Array.pick_random() has no repeat prevention
Array.pick_random() can return the same element consecutively. For uniform non-repeating distribution, use the shuffle bag pattern:
```gdscript
# Shuffle bag: each item appears once before repeating
var _bag = []
var _full = ["a", "b", "c", "d"]

func _ready():
    _bag = _full.duplicate()
    _bag.shuffle()

func get_next():
    if _bag.is_empty():
        _bag = _full.duplicate()
        _bag.shuffle()
    return _bag.pop_front()
```
rand_weighted() on RandomNumberGenerator returns an INDEX into the weights array, not a value.


<!-- keywords: Physical, DoF, Camera -->
### Physical camera units force GPU depth-of-field even if DoF visually looks minimal
Enabling physical light/camera units (Rendering > Lights And Shadows > Use Physical Light Units) enforces depth of field on the GPU even when DoF is subtle, causing a moderate performance hit. If using physical units, assign CameraAttributes to WorldEnvironment too, or the 3D viewport appears extremely bright with DirectionalLights.


<!-- keywords: Visibility, AABB, CENTER, Begin, End, Margin, Disabled -->
### Visibility range distances are from AABB CENTER, not surface; use Begin/End Margin with Disabled fade for hysteresis
Visibility Range is configured per-GeometryInstance3D node:
- Begin/End values are measured from the AABB center of the object, not from mesh surface
- Fade Mode 'Disabled' + margins = hysteresis (instant snap, prevents ping-pong at LOD boundary). Best performance.
- Fade Mode 'Self' or 'Dependencies' = alpha blend transition. Looks smoother but forces transparent rendering (perf cost).
- Can mix node types in LOD: MeshInstance3D near, Sprite3D impostor far — set visibility ranges accordingly


<!-- keywords: COMPILE, TIME, PackedScene, scene, Node, Resource, load, preload, Mesh, mesh -->
### preload() is COMPILE-TIME only (constant path required); load() is runtime (variable path OK); PackedScene.instantiate() creates new nodes but still shares embedded image/mesh resources
- preload() is resolved at parse time — path MUST be a string literal constant, not a variable
- load() is resolved at runtime — can use a variable path, string expressions, etc.
- Scenes (PackedScene) are also cached; instantiate() creates new node trees but sub-resources (meshes, textures) inside the scene file are still shared — call duplicate(true) on a resource if you need a per-instance copy


<!-- keywords: Autoload, BEFORE, scene, autoload, singleton -->
### Autoload is NOT a true singleton — it can be instantiated multiple times; added to root BEFORE any scene loads
Godot Autoloads are added to the root viewport before any game scene. They persist across scene changes. But Godot does NOT enforce a singleton — the user can still instantiate the class manually.
In C#, the 'Enable' column in Project Settings > Autoload has NO effect — for C# autoloads, create a static Instance property and assign it in _Ready().


<!-- keywords: export, property, @tool -->
### @export requires type specifier OR constant default; setters/getters only fire when script is @tool in editor
- `@export var x` requires either a type annotation OR a constant/literal default, or it will error
- In the editor, exported properties are editable even if the script is not @tool, BUT setters/getters won't be called unless the script has the @tool annotation
- Groups cannot be nested — use @export_subgroup for sub-groups inside @export_group
- @export_category breaks the automatic inheritance-based property grouping — use carefully


<!-- keywords: Node, Tree, delta -->
### remove_child() stops processing and groups but keeps node in memory; data goes stale without delta/tree access
Scene management strategies when changing scenes:
- **change_scene_to_file/packed**: Deletes current scene immediately. Memory freed, processing stops. Must reload to return.
- **hide()**: Node invisible but still processes. Memory used. Data stays fresh. Good for quick returns.
- **remove_child()**: Processing stops, memory kept. BUT the node loses access to groups, SceneTree signals, delta time — data can go stale.
To preserve data across scene changes without an Autoload: re-attach the data node to a persistent parent before changing scenes.


<!-- keywords: In, Godot, DOWN, Transform2D, int, 2D -->
### In Godot 2D, Y-axis points DOWN; Transform2D.x = first column = X axis vector, t.x.y = bottom-left of matrix
Coordinate system reminders:
- 2D: Y increases DOWNWARD (opposite of math textbooks). Rotations are clockwise for positive values.
- Transform2D stores basis as column vectors: t.x = X axis column, t.y = Y axis column, t.origin = translation
- t.x.y means Y component of X column = bottom-left of the 2x2 basis. t.y.x = top-right. t.x.x = top-left.
- 3D: Y is up by default. Forward direction is -Z in Godot's right-handed system.


<!-- keywords: GDScript, gdscript, int, float -->
### GDScript integer division: 5 / 2 == 2 (not 2.5); use posmod() for mathematical modulo with negative values
Division and modulo gotchas:
- `5 / 2` = 2 (integer division if both operands are int). Use `5 / 2.0` or `float(5) / 2` for float result.
- `%` only works on ints. For floats, use fmod().
- `%` and fmod() use TRUNCATION for negatives (like C++, unlike Python). `-7 % 3 == -1`, not 2. Use posmod(-7, 3) for mathematical modulo (= 2).
- Float comparison: never use `==` for floats. Use is_equal_approx(a, b) or is_zero_approx(a) instead.


<!-- keywords: Moving, OUTSIDE, Godot, Resource, FileSystem -->
### Moving/renaming files OUTSIDE Godot editor breaks all resource references; use only lowercase filenames
File system rules:
- ALWAYS move/rename/delete assets through Godot's FileSystem dock — doing it outside breaks all res:// references
- Windows/macOS are case-insensitive, but Linux/Android/web are NOT. 'MyFile.png' vs 'myfile.png' = works on Windows, breaks on Linux.
- Convention: use ONLY lowercase filenames and paths to prevent cross-platform issues
- Godot only supports `/` as path separator (even on Windows). Never use `\` in resource paths.


<!-- keywords: JavaScriptBridge, Godot, Array -->
### JavaScriptBridge callbacks must be stored as member variables; JS callback args arrive as single Godot Array
Web platform (JavaScriptBridge) gotchas:
- JavaScriptBridge.create_callback() returns a JavaScriptObject reference. You MUST store it as a member variable — if the reference is lost, the callback is garbage-collected by JavaScript.
- All arguments passed from JavaScript to a Godot callback arrive as a single Array parameter, not individual arguments.
- Base types (int, float, string, bool) are auto-converted between JS and Godot. Objects/arrays/functions become JavaScriptObjects.
- Floats may lose precision when crossing the JS↔Godot boundary.


<!-- keywords: Large, float, int -->
### Large world coordinates: single-precision float breaks at ~16 million units; objects vibrate far from origin
Single-precision floats lose integer precision beyond ±16,777,216. At large coordinates, objects vibrate/jitter because positions snap to nearest representable float value. Solutions:
- Enable large world coordinates in project settings (uses double-precision floats for physics)
- Origin shifting: periodically recenter the world around the player
- Large world coordinates mainly benefit 3D; 2D rendering doesn't improve with double precision.


<!-- keywords: WebSocketPeer, MUST -->
### WebSocketPeer.poll() MUST be called every frame — no data transfer happens without it
WebSocketPeer requires calling poll() in _process() or _physics_process() for ANY data transfer or state updates. Without it, no packets are received and no state changes occur. Also:
- Android export requires INTERNET permission enabled in export preset
- Close code -1 means the disconnect was NOT properly notified by the remote peer


<!-- keywords: Expression, REQUIRED, instantiate -->
### Expression class: ALL parameters are REQUIRED (no optional args); base_instance exposes ALL methods (security risk)
Unlike GDScript functions, Expression.execute() requires ALL parameters even if marked optional in docs. Setting base_instance to non-null allows the expression to call ANY method on that object — a security risk if users can input expressions. The Expression class works even without the GDScript module.


<!-- keywords: JSON, Vector2, Vector3, Color, Rect2, Quaternion, ConfigFile, serialization -->
### JSON save/load does NOT preserve Vector2/Vector3/Color/Rect2/Quaternion — use ConfigFile or var_to_bytes() instead
JSON converts everything to basic types (string, number, bool, array, dict). Saving Vector2(1, 2) and loading it back gives a Dictionary, not a Vector2. Workarounds:
- Use ConfigFile which natively supports many Godot types
- Use var_to_bytes()/bytes_to_var() for full type preservation (binary format)
- Manually serialize: save as array [x, y], reconstruct on load with Vector2(arr[0], arr[1])
- ResourceSaver/ResourceLoader preserve all types and work with custom Resources


<!-- keywords: BLOCKS, Resource, load, Thread, threading -->
### load_threaded_get() BLOCKS main thread if resource isn't ready — always check status first
Background loading gotcha: calling load_threaded_get() before the resource finishes loading will BLOCK the main thread until it completes, defeating the purpose of threaded loading. Always check first:
```gdscript
var status = ResourceLoader.load_threaded_get_status(path)
if status == ResourceLoader.THREAD_LOAD_LOADED:
    var res = ResourceLoader.load_threaded_get(path)
elif status == ResourceLoader.THREAD_LOAD_FAILED:
    print('Load failed!')
# If IN_PROGRESS: wait more, show loading progress
```


<!-- keywords: Self -->
### Self-contained mode: place '._sc_' file next to editor binary; user:// resolves to 'user_data/' subdir beside exe
When a file named `._sc_` or `_sc_` exists next to the Godot editor binary, the editor runs in self-contained mode:
- user:// path resolves to a 'user_data/' subdirectory beside the executable instead of AppData/Roaming
- Useful for portable installations (e.g., USB drives)
- The exported game also runs self-contained if `._sc_` is next to the game executable
- res:// is always read-only in exported games (packed PCK); always write to user:// instead


<!-- keywords: NEVER, Node3D, Euler, Basis, Quaternion, rotation -->
### NEVER use Node3D.rotation (Euler angles) in game logic — use basis vectors or quaternions instead
The `rotation` property exists for editor convenience and 2D parity, but the official Godot docs explicitly warn against using it in game code:
- Euler angle interpolation does NOT take the shortest path (e.g., 270°→0° may go the wrong direction)
- Gimbal lock causes unexpected direction reversals at certain orientations
- There's no unique way to decompose a rotation into Euler angles — results depend on application order
Use basis vectors instead: `-transform.basis.z` = forward, `transform.basis.y` = up, `transform.basis.x` = right.
Use quaternion slerp for smooth rotation interpolation.


<!-- keywords: Transform -->
### Transform precision degrades every frame when rotating — call orthonormalized() periodically (but it discards scale)
Successive rotation operations accumulate floating-point errors: axis lengths drift from 1.0, axes deviate from 90°. An object rotating every frame will eventually deform visibly. Fix:
```gdscript
# In _physics_process, occasionally:
transform.basis = transform.basis.orthonormalized()
```
WARNING: orthonormalized() silently discards any non-uniform scale applied to the basis. If you need scale, re-apply it after.
Also: Quaternion conversion (for slerp) silently drops scale information with no warning.


<!-- keywords: Custom, Project, Settings, REPLACES -->
### Custom TLS certificate bundle in Project Settings REPLACES the OS bundle entirely — does not supplement it
When you set a custom certificate bundle in Project Settings > Network > TLS:
- The operating system's certificate bundle is completely replaced, not supplemented
- All certificate validation uses ONLY your custom bundle
- NEVER include the private key in the client-side certificate file — this silently compromises all TLS security
- HTTPClient on Web platform does NOT support blocking/synchronous requests — must use async polling pattern


<!-- keywords: Export, export -->
### Export path in --export-release CLI is relative to project.godot directory, NOT current working directory
Command line gotchas:
- `godot --export-release preset_name ./build/game.exe`: the `./build/` path is relative to the folder containing `project.godot`, not your shell's CWD
- Unknown/invalid command line arguments are SILENTLY IGNORED — no warning, no error
- On macOS: must run `Godot.app/Contents/MacOS/Godot`, not just `Godot` (it's a bundle/directory)
- `--recovery-mode` silently disables tool scripts, editor plugins, and GDExtension addons


<!-- keywords: SurfaceTool, MUST, TRIANGLES -->
### SurfaceTool: attributes MUST come immediately before add_vertex(); generate_normals() only works with TRIANGLES
SurfaceTool gotchas:
- All vertex attributes (set_normal, set_uv, set_color, etc.) must be called IMMEDIATELY before add_vertex(). Attributes set then overwritten before add_vertex() use the LAST value only. Attributes after the final add_vertex() are silently discarded.
- generate_normals() only works with PRIMITIVE_TRIANGLES — silently fails or produces garbage with other primitive types
- Normal mapping requires BOTH generate_normals() AND generate_tangents(). generate_tangents() requires UVs and normals to be set on ALL vertices first — if any vertex is missing UVs, tangent generation produces wrong results
- deindex() permanently expands the vertex array (removes index buffer), irreversibly increasing memory and draw calls


<!-- keywords: Compositor, RENDERING, THREAD, rendering, Thread, Mutex, threading -->
### Compositor effects run on the RENDERING THREAD — accessing game state requires mutex; push constants need 16-byte alignment
Compositor (custom render effects) gotchas:
- Compositor effect code runs on the rendering thread. Accessing any game state (node positions, game variables) requires mutex protection to avoid crashes
- Push constants MUST be padded to 16-byte alignment (array length must be a multiple of 4 floats). Missing padding causes shader compilation or runtime errors
- Compositor effects only have access to the 3D rendering pipeline — 2D post-processing is NOT supported
- free_rid() is POSTPONED until all in-flight frames finish — freed resources aren't immediately deallocated


<!-- keywords: All, GDScript, MUST, gdscript, @tool, EditorPlugin -->
### All GDScript files in an editor plugin MUST have @tool — without it they silently act as empty files
Editor plugin gotchas:
- Every GDScript file your plugin uses (not just EditorPlugin.gd) must have the `@tool` annotation at the top. Without it, the script is silently ignored in the editor context — no error, no warning
- Main screen plugins: call `make_visible(false)` immediately after adding the panel in `_enter_tree()` — skipping this makes the panel permanently visible and competing for space
- C# plugins must be built (compiled) before enabling them in Project Settings — enabling an unbuilt plugin silently fails


<!-- keywords: EXIT, int, Thread, threading, print, debug -->
### print() stdout only flushes on EXIT in release builds — use printerr() for real-time logging; custom loggers must be thread-safe
Logging gotchas:
- In RELEASE builds, print() output is only written to the log file when stdout is flushed at exit/crash. Debug builds flush every print. This means print() is useless for real-time diagnostics in shipped games.
- printerr(), push_error(), push_warning() flush IMMEDIATELY in both debug and release — use these for critical runtime logging
- Script backtraces are DISABLED in release builds for performance. Enable 'Debug > Always Track Call Stacks' to get actionable error traces in production
- Custom logger functions are called from ANY thread (including non-main threads) and possibly concurrently — must be thread-safe
- Using print()/push_error() INSIDE a custom logger causes silent suppression (infinite recursion prevention) instead of your expected output


<!-- keywords: IMMEDIATE, queue_free, Node -->
### free() is IMMEDIATE and cascades to ALL children; prefer queue_free() — dangling references crash instantly
Node deletion gotchas:
- free() destroys the node AND all its children IMMEDIATELY. Any code holding a reference to the node or its descendants will crash on next access.
- queue_free() defers deletion to end of frame — safe for nodes that may still be referenced in current frame logic
- NEVER call free() on a node that may receive more signals or callbacks in the same frame
- get_node() on a node not yet added to the scene tree fails silently — always access nodes in _ready() or later, not in _init()


<!-- keywords: CRASH, queue_free, @tool -->
### @tool scripts: queue_free() can CRASH the editor; every dependency must also be @tool; restart required after adding @tool
@tool script gotchas:
- Calling queue_free() or free() in a @tool script runs in the editor and CAN CRASH the editor — there is no protection
- Every GDScript instantiated by a @tool script MUST also have @tool. Non-@tool scripts cannot be instantiated in tool mode (silently acts as empty)
- Exception: static methods, constants, and enums from non-@tool scripts CAN be accessed from @tool scripts without @tool
- Known Godot 4 bug (GH-66381): adding @tool to an existing script requires an EDITOR RESTART to take effect
- Modifying a @export Resource property's sub-properties in inspector does NOT trigger the property's setter — setter only fires when creating/deleting/pasting the resource itself


<!-- keywords: ProjectSettings, EFFECT, settings -->
### ProjectSettings.set_setting() at runtime has NO EFFECT on startup-read settings — use runtime class properties instead
Many project settings are read ONCE at engine startup and cached in runtime classes. Calling ProjectSettings.set_setting() afterwards does nothing:
- Physics settings → PhysicsServer2D/3D
- Rendering settings → RenderingServer
- Window/display settings → Window or Viewport
- Engine settings → Engine class
Always modify the runtime class directly (e.g., Engine.physics_ticks_per_second) instead of ProjectSettings at runtime.


<!-- keywords: Web, IndexedDB, LOST -->
### Web editor: project data in IndexedDB is LOST if browser storage is cleared; files outside /home/web_user/ lost on close
Web editor limitations:
- Project files are stored in browser IndexedDB (not real filesystem) — clearing browser storage or site data destroys the project with NO warning
- Files/projects placed outside `/home/web_user/` are LOST when closing the browser tab
- No auto-save warning when closing the tab with unsaved changes (unlike native editor)
- Cannot open new windows — running the game replaces the editor view
- Lightmap baking is unavailable (import only); GDExtension plugins are unsupported


<!-- keywords: AnimationTree, SHARED, RESET, scene, instantiate, Node, Resource, animation -->
### AnimationTree: node resources SHARED across all scene instances; RESET animation must have exactly 1 frame
AnimationTree gotchas:
- AnimationTree node resources (BlendSpace, StateMachine, etc.) are SHARED between ALL instances of a scene. Modifying blend values on one instance affects ALL instances. Use unique resources per instance.
- RESET animation is NOT for playback — it defines the default pose baseline for blending. It must have exactly ONE frame at t=0. Playing it directly produces wrong results.
- Rotation blending with Linear/Cubic interpolation ALWAYS takes the shortest path through the bone's rest pose — rotations > 180° from rest are impossible in blended animations. Import T-pose skeletons to maximize interpolation range.
- StateMachine requires an explicit `start()` call OR connection to the 'Start' node before `travel()` works
- When using Polygon2D with bones, newly added INTERNAL vertices must also have weights painted — omitting weight painting causes unintended deformation


<!-- keywords: Call, Method, Track, DISABLED, Bezier, Property, property -->
### Call Method Track events are DISABLED during editor preview; Bezier and Property tracks cannot be blended together
Animation track gotchas:
- Call Method Track events are intentionally DISABLED when previewing animations in the editor (for safety). They only execute in-game. Test method call effects by running the game, not scrubbing the timeline.
- Bezier curve tracks and regular Property tracks CANNOT be blended in AnimationPlayer or AnimationTree — pick one type per property and stick with it
- AnimationPlayer CANNOT reference itself in an Animation Playback Track — only external AnimationPlayers
- Instanced scene AnimationPlayer is inaccessible until 'Editable Children' is enabled in the scene tree
- IK chains set up in the editor are EDITOR-ONLY — they do NOT function at runtime for procedural animation


<!-- keywords: GDScript, MUST, gdscript -->
### GDScript custom iterators: _iter_init() MUST reset state or nested loops using the same iterator silently fail
GDScript advanced gotchas:
- Custom iterators must completely reset their state in _iter_init(). Failure to reset means the second for-loop over the same object continues from where the first left off — nested loops break silently.
- Only primitive types (int, float, String, Vector2, etc.) are passed BY VALUE to functions. Everything else (Object instances, Arrays, Dicts) is passed BY REFERENCE.
- Classes inheriting RefCounted are auto-freed when unreferenced; classes inheriting Object directly require manual free() calls


<!-- keywords: Feature, IGNORES -->
### Feature tags: get_setting() IGNORES overrides; 'mobile' returns false on web; custom tags don't work in editor
Feature tag gotchas:
- `ProjectSettings.get_setting('key')` completely IGNORES feature tag overrides. Must use `ProjectSettings.get_setting_with_override('key')` to respect overrides.
- `OS.has_feature('mobile')` returns FALSE when a web export runs on a mobile device. Use `OS.has_feature('web_android')` or `OS.has_feature('web_ios')` instead.
- Custom feature tags defined in export presets are SILENTLY IGNORED when running from the editor — they only apply to exported builds
- Feature tag names are CASE-SENSITIVE: 'debug' works, 'Debug' does not


<!-- keywords: GDScript, Array, gdscript, typed, int -->
### GDScript 'as' keyword silently returns null on type mismatch; nested typed arrays (Array[Array[int]]) not supported
GDScript static typing gotchas:
- The `as` keyword returns NULL (no error, no warning) if the cast fails. Code like `var x: MyClass = node as MyClass` silently gives null if node is wrong type, causing NullReferenceError later.
- Nested typed collections are NOT supported: `Array[Array[int]]` and `Dictionary[String, Dictionary[String, int]]` are syntax errors. Must use untyped nesting.
- Enum type hints are just `int` at runtime — no validation that the value is a valid enum member. Must validate manually.
- Typed Array/Dictionary methods like push_back() and equality == are UNTYPED internally — type violations can slip through silently


<!-- keywords: BEFORE, Node -->
### _draw() is cached — call queue_redraw() to update; draw_set_transform() applies BEFORE node transform
Custom 2D drawing gotchas:
- `_draw()` is called once and the result is CACHED. Changing any variable that affects drawing has NO visual effect until you call `queue_redraw()` explicitly.
- `draw_set_transform()` applies BEFORE the node's own transform — resulting in unintuitive pivot behavior. The custom transform is local, not applied on top of node position.
- Lines with ODD pixel widths must have coordinates shifted by 0.5 to center correctly (e.g., draw from (0.5, 0) to (0.5, 10) for a 1px vertical line at x=0)
- draw_line(), draw_polyline(), draw_multiline(), draw_arc(), draw_circle() and draw_rect() take an `antialiased` argument; draw_polygon() and the texture/string calls do not — for those, enable 2D MSAA in the project settings
- Draw call order is the ONLY depth control — later calls overdraw earlier ones; no z-ordering within a single _draw() invocation


<!-- keywords: Resource, load, preload -->
### PCK/ZIP files: loaded resources silently override existing same-path resources; preload() defeats dynamic pack loading
Resource pack (PCK) gotchas:
- When loading a PCK/ZIP file, resources with the SAME path as existing resources are silently replaced with no warning — can corrupt saves or game state if paths collide
- Packs loaded after `preload()` calls have already executed will NOT affect those preloaded resources. Loading a pack in _ready() doesn't patch preloaded menu assets.
- C# projects must manually call `Assembly.LoadFile()` to load the DLL before loading the resource pack — extra step not required in GDScript
- Dedicated server 'Strip Visuals' mode: placeholder textures store ONLY the image dimensions, not pixel data. Anything reading pixel colors (collision baking from image, procedural code) will silently get wrong data


<!-- keywords: Asset, ResourceLoader, FileAccess, Resource, load, export, file, import, resource -->
### Asset import: use ResourceLoader (not FileAccess) — FileAccess works in editor but fails in exported builds
Asset pipeline gotchas:
- FileAccess.open() works in the editor but FAILS for imported assets (images, audio, meshes, etc.) in exported builds — use ResourceLoader.load() instead
- ResourceLoader can ONLY access imported resources — it cannot read raw non-imported files (use FileAccess for those)
- `.import` metadata files MUST be committed to version control — without them, assets cannot be reimported correctly on other machines
- The `.godot/imported/` folder should NOT be committed — it's large and auto-regenerated from the .import files


<!-- keywords: CanvasLayer, BEHIND, scene, Node, CanvasItem, canvas, Tree -->
### CanvasLayer: layer number determines draw order, NOT scene tree position; topmost scene node draws BEHIND
Canvas layer gotchas:
- CanvasLayer draw order depends ONLY on the layer number (int), not the node's position in the scene tree
- Within the same layer, nodes draw in scene tree order with TOPMOST nodes drawn BEHIND lower siblings — opposite of what many developers expect
- CanvasLayers are completely independent of 3D camera transform — they render at a fixed screen-space position regardless of camera movement
- InputEvent coordinates use a different coordinate system than CanvasItem coordinates — converting requires traversing the full transform chain: Window → Stretch → Global Canvas → Canvas Layer → Node


<!-- keywords: Resources, ONCE, SAME, instantiate, Resource, load -->
### Resources are loaded ONCE and shared — all instances reference the SAME resource; use duplicate() to get independent copy
One of the most common Godot gotchas: when you load() a Resource, the engine returns the SAME cached instance to everyone. Modifying it affects ALL users of that resource:
```gdscript
# BAD: both enemies share the same material; changing one changes both
enemy1.material = load('res://enemy.material')
enemy2.material = load('res://enemy.material')

# GOOD: each enemy gets its own independent copy
enemy1.material = load('res://enemy.material').duplicate()
enemy2.material = load('res://enemy.material').duplicate()
```
This applies to all Resource types: Materials, AudioStream, Font, etc. Especially critical for materials where you want per-instance color/texture changes.


<!-- keywords: POST, ORDER, Signals, Light, signal, _ready, Node, scene, light -->
### _ready() is POST-ORDER (children before parents); Signals fire even when paused; Light cull mask doesn't block shadows
Scene tree and processing gotchas:
- `_ready()` uses POST-ORDER traversal: children's _ready() is called BEFORE their parent's _ready(). `_process()` uses pre-order (parent before children). Don't assume _ready() order matches _process() order.
- `process_priority` overrides scene tree order — lower numbers execute FIRST regardless of position in tree
- Signals still FIRE when the SceneTree is paused — nodes that can't process can still receive signals. Check pause state in signal callbacks if needed.
- 3D Light cull mask does NOT prevent shadow casting — only affects which objects are LIT by the light. To stop an object casting shadows, set GeometryInstance3D > Cast Shadow = Off.


<!-- keywords: Autoload, NEVER, instantiate, scene, Node, queue_free, Resource, load, autoload -->
### Autoload nodes: NEVER call free() or queue_free() — crashes the engine; built-in resources still deduplicated across instances
Autoload and Resource gotchas:
- Calling free() or queue_free() on an Autoload node at runtime CRASHES the engine — autoloads must exist for the entire lifetime of the application
- Even resources saved as 'built-in' inside a .tscn file are DEDUPLICATED — instancing the same scene 10 times still gives all 10 instances the same resource object
- Custom Resource inner classes (defined with `class` inside a script) do NOT serialize properties — must define Resource subclasses as TOP-LEVEL scripts
- Custom Resource _init() must have ALL parameters with default values or the Inspector cannot create/edit instances


<!-- keywords: BLOCKS, ResourceLoader, scene, load, Thread, threading -->
### change_scene_to_file() BLOCKS until fully loaded — no loading screen possible without ResourceLoader.load_threaded_request()
Scene management gotchas:
- change_scene_to_file() and change_scene_to_packed() block the main thread until the scene is completely loaded and ready — no progress indicator or animation is possible during this time
- For loading screens with progress: use ResourceLoader.load_threaded_request() to load in background, then change_scene_to_packed() once complete
- _exit_tree() is called in BOTTOM-TO-TOP order (children before parents) when a scene is being removed — opposite of the top-to-bottom order used when entering the tree


<!-- keywords: ONCE, Node, add_child, _ready, scene, Tree, MULTIPLE, TIMES -->
### _enter_tree() can be called MULTIPLE TIMES (node re-added); _ready() is guaranteed exactly ONCE per lifetime
Node lifecycle gotchas:
- _enter_tree() fires EVERY TIME the node enters the scene tree — if a node is removed and re-added, _enter_tree() runs again. Don't put one-time initialization there.
- _ready() is called exactly ONCE in a node's lifetime (after the first _enter_tree()). Use it for one-time initialization.
- _exit_tree() fires every time the node leaves the tree and is received AFTER all children have already received their _exit_tree() (bottom-up order)


<!-- keywords: File, Windows, INSENSITIVE, Linux, Android, SENSITIVE, export -->
### File paths: Windows/macOS are case-INSENSITIVE (works), Linux/Android are case-SENSITIVE (silently fails on export)
Cross-platform file path gotchas:
- On Windows/macOS, `load('res://myfile.PNG')` works even if the file is `myfile.png`. On Linux/Android export, this SILENTLY FAILS. Always match case exactly in code.
- Moving or renaming assets using the OS file explorer (not Godot's FileSystem dock) breaks all references — Godot detects but doesn't prevent saving broken references
- res:// is READ-ONLY in exported builds — any attempt to write files to res:// works in editor but silently fails in exported games. Write game state to user:// instead.


<!-- keywords: NEVER, Default, Theme, Scale, Resource, load, preload, UI -->
### hide() keeps ALL processing active; preload() resources are NEVER unloaded; Default Theme Scale can't change at runtime
Scene management and UI gotchas:
- Using hide() to 'swap' scenes leaves all processing, physics, groups, and animations ACTIVE on the hidden scene. 10 hidden scenes = 10 fully processing scenes eating CPU/memory.
- preload() resources are baked into the compiled script and NEVER unloaded, even when all instances are freed. Using preload() for multiple large scenes causes permanent memory growth.
- `Project Settings > GUI > Theme > Default Theme Scale` is read-only at runtime. Use `get_tree().root.content_scale_factor` (a Window property) instead for runtime UI scaling.
- Regular 'Fullscreen' window mode leaves a 1-pixel line at the bottom, breaking integer pixel scale calculations. Use 'Exclusive Fullscreen' for correct integer scaling.


<!-- keywords: Resource, IMMEDIATELY, load, export -->
### @export vars return hardcoded default in _init() NOT inspector value; @export Resource loads IMMEDIATELY (hard dependency)
GDScript export gotchas:
- Reading an @export variable inside `_init()` returns the HARDCODED default (e.g., `= 2`), NOT the value set in the Inspector (e.g., `3`). Inspector values are applied AFTER _init(). Read @export vars in `_ready()` or via setters.
- `@export var texture: Texture2D` creates a HARD DEPENDENCY — the texture loads immediately when the scene loads, even if never used. Use `@export_file` for lazy/optional loading.
- @export getter/setter is IGNORED in the editor unless the script has `@tool`. Developers expecting setters to fire on inspector change are surprised they don't.
- `@export_storage` variables ARE copied when duplicating nodes/resources; non-exported variables are silently LOST on duplicate()


<!-- keywords: AFTER, export, error -->
### @onready + @export on same variable is an error — @onready fires AFTER inspector values apply, overwriting them
GDScript initialization order gotchas:
- Combining `@onready` and `@export` on the same variable raises ONREADY_WITH_EXPORT warning/error by default — @onready initializes AFTER exported inspector values are applied, silently overwriting whatever was set in the Inspector
- Initialization order: class variables (top to bottom) → _init() → inspector values applied → @onready variables. Understanding this prevents subtle override bugs.
- Integer division silently truncates: `5 / 2 == 2` (not 2.5). Must write `5 / 2.0` or `float(5) / 2` to get a float result. No warning or error.
- GDScript `%` (modulo) uses TRUNCATION for negatives (like C), not floor division (like Python): `-7 % 3 == -1` in GDScript, but `2` in Python. Use `posmod(-7, 3)` for always-positive remainder.


<!-- keywords: Typed, Array, GDScript, typed, lambda -->
### Typed arrays cannot be assigned between subtypes; native method overrides silently fail; lambda captures are by value
GDScript type system gotchas:
- `Array[Node2D]` CANNOT be assigned to `Array[Node]` even though Node2D inherits Node. Use `.assign()` method to copy elements between typed arrays of related types.
- Overriding non-virtual engine methods (get_class(), queue_free(), etc.) SILENTLY FAILS — the engine calls its own implementation, not yours. Only override methods marked as `virtual` in the docs.
- Lambda variable captures are BY VALUE at creation time for primitives. Reassigning a captured variable outside the lambda doesn't update the lambda's copy. For reference types (Array, Dict, Object), changes to the object's contents ARE shared, but reassigning the variable is not.


<!-- keywords: GDScript, Resource, Godot, load, gdscript, inner class -->
### GDScript: inner Resource classes defined with 'class' cannot be serialized — save/load fails because Godot can't find inner class by name
If you need a Resource subclass that can be saved to disk, define it as a SEPARATE .gd file with class_name. Inner classes (defined with 'class' inside another script) are invisible to Godot's resource saving system and cannot be deserialized from .tres/.res files.


<!-- keywords: Resource, MUST -->
### Resource._init() MUST have all parameters with default values or the inspector cannot create/edit it
If your custom Resource subclass has _init() with required parameters, the editor inspector will silently fail when trying to create or edit instances. Always give every _init() parameter a default value.


<!-- keywords: CONSTANT, String, error -->
### preload() requires a CONSTANT string literal — using a variable path causes a parse error
preload() is resolved at parse time, not at runtime. Passing a variable or expression as the path causes a syntax error. Use load() for dynamic paths, but preload() only accepts string literals.


<!-- keywords: GDScript, gdscript, static, int, enum -->
### GDScript enum types in static typing are just ints — no range validation, can hold any integer
Declaring a variable as an enum type (var state: MyEnum) only provides editor hints, not runtime enforcement. Any integer can be assigned without error. Use match with an else clause to catch unexpected values.


<!-- keywords: Deleting, CRASHES, signal, emit, scene, Node -->
### Deleting the current scene node inside a signal callback CRASHES — use call_deferred('free') instead
When a signal fires, the node that emitted it is still on the call stack. Calling free() or queue_free() on the scene root or an ancestor during the signal handler causes a crash. Defer cleanup: call_deferred("free") or set a flag and clean up in _process().


<!-- keywords: Expression, int, float, GDScript -->
### Expression class: integer division (5/2=2) — pass floats explicitly to get float results
The Expression class performs integer division when both operands are integers, just like GDScript. '5 / 2' evaluates to 2, not 2.5. Pass '5.0 / 2' or cast in the expression string to get float division.


<!-- keywords: Expression, SILENTLY, instantiate -->
### Expression.execute() returns null SILENTLY when methods are called without a base_instance
If your expression calls instance methods (non-static functions) but you pass null as base_instance to execute(), the call returns null with no error. Always pass the object instance as base_instance when calling methods.


<!-- keywords: CASE, SENSITIVE, Node, get_node -->
### get_node() is CASE-SENSITIVE — renaming a node in the editor silently breaks all get_node() calls for it
There's no static analysis to catch get_node("MyNode") calls when the node is renamed to "myNode". Using @onready var x = $MyNode gives a parse-time error on scene load, which is better. But even @onready breaks if you rename the node.


<!-- keywords: SAME, scene, Node, Tree -->
### process_priority: nodes with the SAME priority still execute in scene-tree order (not random)
process_priority controls ordering across different priority values. Nodes with identical priority values fall back to scene-tree order (parent before child, top to bottom). This is rarely documented and causes confusion when debugging execution order.


<!-- keywords: TREE, _ready, Tree -->
### _ready() guarantees children are IN THE TREE, but NOT that their _ready() has run yet
Since _ready() is post-order (children first), by the time a parent's _ready() runs, all children have already had their _ready() called. However, if a child was added DYNAMICALLY after initial setup, its _ready() fires when it's added, which may be after the parent's _ready().


<!-- keywords: Groups, Global, Scene, COSMETIC, scene, global -->
### Groups: 'Global' vs 'Scene' organization in editor is COSMETIC — same-named groups are identical at runtime
The editor groups dialog shows 'Global' and 'Scene' tabs for organizational purposes only. A group named 'enemies' in Scene tab and 'enemies' in Global tab are the SAME group at runtime. There is no runtime distinction.


<!-- keywords: IMMEDIATE, SYNCHRONOUS, Node -->
### call_group() is IMMEDIATE and SYNCHRONOUS — changing group membership during the call affects which nodes receive it
Unlike signals, call_group() calls the method on every group member synchronously in sequence. If a method handler adds or removes nodes from the group, those changes take effect immediately and affect subsequent members receiving the call in the same frame. Use call_group_flags(GROUP_CALL_DEFERRED) to avoid this.


<!-- keywords: Sync -->
### V-Sync with double-buffered swapchain (2 images): missing one frame drops GPU throughput to 50% of refresh rate
With V-Sync enabled and a 2-image swapchain, if the GPU takes longer than 16.6ms (at 60Hz), it misses the vsync window entirely and has to wait another full frame — causing 30 FPS not 59 FPS. Triple-buffering (3 images) reduces this effect but increases input latency.


<!-- keywords: GDScript, SILENTLY, gdscript -->
### GDScript doc comments: tags with spaces before the colon SILENTLY fail — '@tutorial  :' does nothing
In GDScript documentation comments, tags like @tutorial, @param, @return must have zero spaces between the tag name and the colon. '@tutorial  : https://...' (with extra spaces) silently fails to parse and the link doesn't appear in the generated docs.


<!-- keywords: GDScript, PRIVATE, HIDDEN, gdscript -->
### GDScript: members starting with underscore are treated as PRIVATE and HIDDEN in generated documentation
The documentation generator treats any function or variable prefixed with underscore (e.g., _helper_method) as private and excludes it from the public API documentation, even if it has documentation comments. This is intentional but surprises developers trying to document semi-public methods.


<!-- keywords: Array, SAME -->
### Array.pick_random() can return the SAME element consecutively — use shuffle bag pattern to guarantee unique ordering
pick_random() uniformly picks from all elements including the previously returned one. For game mechanics like random loot, music shuffle, or enemy sequences that shouldn't repeat, implement a shuffle bag: shuffle the array once, iterate through it, and re-shuffle only when exhausted.


<!-- keywords: INDEX, INDICES, Array -->
### rand_weighted() returns an INDEX, not a value — the weights array maps to array INDICES, not to the values themselves
RandomNumberGenerator.rand_weighted([0.5, 1.0, 2.0]) returns 0, 1, or 2 (the index). Index 2 is returned twice as often as index 1. You then use this index to look up your actual value array. A common mistake is passing the value array directly and expecting a value back.


<!-- keywords: DEPENDENT, _process, delta -->
### lerp() for smooth following in _process() is framerate-DEPENDENT — use exponential decay for framerate independence
A common pattern like 'position = lerp(position, target, 0.1)' runs slower on high framerates and faster on low framerates. For framerate-independent smoothing, use: position = position.lerp(target, 1.0 - exp(-SPEED * delta)). This gives identical visual results at any framerate.


<!-- keywords: Bezier -->
### Bezier curve t parameter does NOT map to constant speed — use tessellate() and sample by arc length for even movement
Moving from t=0 to t=1 at constant rate on a Bezier curve does NOT produce constant speed motion. The curve moves faster near control points and slower at extremes. For constant-speed movement along a curve, tessellate the curve into equal-length segments using Curve3D.tessellate() and interpolate by arc length.


<!-- keywords: SceneTree, BYPASSES, scene -->
### SceneTree.quit() BYPASSES NOTIFICATION_WM_CLOSE_REQUEST — custom cleanup code won't run
If you call get_tree().quit() directly, the engine exits immediately without firing NOTIFICATION_WM_CLOSE_REQUEST on any node. If you have cleanup code (save progress, close network connections) in that notification handler, it will be skipped. Trigger your cleanup manually before calling quit().


<!-- keywords: Software, Sprite2D, LEAST, sprite -->
### Software cursor (Sprite2D) adds at LEAST one frame of latency vs hardware cursor — hardware cursor always feels snappier
Hiding the OS cursor and drawing a Sprite2D at mouse position adds lag equal to one render frame (16ms at 60 FPS) because position updates are tied to the frame cycle. Hardware cursors (set with Input.set_custom_mouse_cursor()) are updated by the OS compositor at display rate, not game framerate. Use hardware cursors for responsiveness.


<!-- keywords: Text, Linux, SILENTLY, error -->
### Text-to-speech on Linux SILENTLY fails if system libraries missing — no error, just empty voice list
On Linux, DisplayServer.tts_get_voices() returns an empty array if the required speech-dispatcher or espeak-ng libraries are not installed. There's no error or warning — the TTS system just silently produces nothing. Always check if tts_get_voices().is_empty() before using TTS, and provide a graceful fallback.


<!-- keywords: drag_rate -->
### Frame-rate independent drag/damping
`speed *= (1 - drag)` per tick is frame-rate dependent (varies wildly between 60Hz and 120Hz). Use exponential decay instead:
WRONG (frame-rate dependent):  velocity *= (1.0 - drag)
CORRECT (frame-rate independent):  velocity *= exp(-drag_rate * delta)


<!-- keywords: target_yaw, turn_speed -->
### Smooth yaw rotation — avoid 360-degree spin-around
`lerp()` on raw angles causes objects to spin 360 degrees when crossing the 0/2PI boundary. Always wrap the angle difference to `[-PI, PI]` first:
WRONG:  rotation.y = lerp(rotation.y, target_yaw, t)
CORRECT:
```gdscript
var diff: float = fmod(target_yaw - rotation.y + 3.0 * PI, TAU) - PI
rotation.y += diff * turn_speed * delta
```


<!-- keywords: SiblingA, data_changed, _on_data_changed, has_data, get_data -->
### Sibling signal timing in _ready()
`_ready()` fires on children in scene order. If sibling A emits a signal in its `_ready()` and sibling B hasn't connected yet, B misses the signal. Fix: after connecting in B's `_ready()`, check if A already has data and call the handler manually:
```gdscript
func _ready() -> void:
    %SiblingA.data_changed.connect(_on_data_changed)
    if %SiblingA.has_data():  # check if already populated
        _on_data_changed(%SiblingA.get_data())
```


<!-- keywords: get_rpc_config, get_node_rpc_config -->
### Node.get_rpc_config() renamed to get_node_rpc_config() (Godot 4.5)
For multiplayer RPC setup, the method was renamed:
  WRONG:  node.get_rpc_config()
  CORRECT: node.get_node_rpc_config()


<!-- keywords: ONREADY_WITH_EXPORT, label_path, NodePath, get_node -->
### @onready + @export on the same variable — @onready silently overwrites the exported value
Using both `@onready` and `@export` on the same variable is treated as an **error** (ONREADY_WITH_EXPORT). The `@export` value set in the inspector is discarded when `_ready()` fires because `@onready` runs then and overwrites it. NEVER combine them:
  WRONG:  @export @onready var label: Label = $Label  # export value ignored!
  CORRECT: @export var label_path: NodePath; @onready var label: Label = get_node(label_path)
  OR:      @onready var label: Label = $Label  # without @export


<!-- keywords: static_unload, class_name -->
### @static_unload does not currently work — scripts are never freed
The `@static_unload` annotation is supposed to allow a script's static data to be freed when no instances exist. Due to a current bug, scripts are NEVER freed even with this annotation. Do not rely on `@static_unload` for memory management. Place `@static_unload` at the very top of the script (before `class_name` and `extends`) if used, as it applies to the entire script including inner classes.


<!-- keywords: singleton_ref, get_singleton, MySingleton -->
### Static variables cannot use @export or @onready
Static class variables (`static var`) cannot be decorated with `@export` or `@onready`. They belong to the class, not to instances. Local variables also cannot be declared static. Static variables share their value across ALL instances.
  WRONG:  @export static var count: int = 0
  WRONG:  @onready static var singleton_ref = Engine.get_singleton("MySingleton")
  CORRECT: static var count: int = 0  # class-level, no annotation


<!-- keywords: export_storage, cached_data -->
### @export_storage — persist non-exported properties in scene files
`@export_storage` saves a property in `.tscn`/`.tres` files without showing it in the inspector. Useful for runtime state that should be saved with the scene but not edited directly. Different from `@export` (which shows in the inspector) and plain `var` (not saved).
  @export_storage var cached_data: Dictionary = {}


<!-- keywords: export_custom, hint_string -->
### @export_custom — override display in Inspector without changing the type
`@export_custom(hint, hint_string)` allows a custom inspector hint for a property that cannot be achieved with standard @export annotations. The property type is unchanged.


<!-- keywords: PackedScene -->
### Typed arrays in @export: use Array[Type] directly
Exported typed arrays use bracket syntax. `Array[PackedScene]`, `Array[int]`, `Array[String]` all work. Inner classes can also be array element types:
  @export var scenes: Array[PackedScene] = []
  @export var scores: Array[int] = []
NOTE: Nested typed arrays like `Array[Array[int]]` are NOT supported — use `Array[Array]` for 2D arrays.


<!-- keywords: export_range, radians_as_degrees -->
### @export_range suffix — annotate unit directly on the slider
`@export_range(min, max, step, "suffix:UNIT")` shows a unit label on the slider in the Inspector:
  @export_range(0, 100, 1, "suffix:kg") var weight: float = 0.0
  @export_range(0, 360, 0.1, "radians_as_degrees") var angle: float = 0.0
The `"radians_as_degrees"` flag stores radians internally but displays and edits degrees in the Inspector.


<!-- keywords: name_list, INFERENCE_ON_VARIANT -->
### for-loop typed variable — type inference works in for loops (Godot 4.2+)
Loop variables can have explicit type annotations even when iterating an untyped array:
  for name: String in name_list:  # name is typed String
This avoids INFERENCE_ON_VARIANT warnings when the array is untyped.


<!-- keywords: _iter_init, _iter_next, _iter_get, my_obj -->
### Custom iterators — implement _iter_init, _iter_next, _iter_get
Objects can be iterable in `for` loops by implementing three methods:
  func _iter_init(arg) -> bool: ...  # returns false if empty
  func _iter_next(arg) -> bool: ...  # advances, returns false at end
  func _iter_get(arg) -> Variant: ... # returns current element
The `arg` parameter is passed from the `for` loop (e.g., `for x in my_obj.range(5):`).


<!-- keywords: NOTIFICATION_MOVED_IN_PARENT, NOTIFICATION_CHILD_ORDER_CHANGED -->
### Node.NOTIFICATION_MOVED_IN_PARENT deprecated — use NOTIFICATION_CHILD_ORDER_CHANGED
The constant `Node.NOTIFICATION_MOVED_IN_PARENT` is deprecated. The engine no longer sends it. Use `Node.NOTIFICATION_CHILD_ORDER_CHANGED` instead to detect reordering of children.


<!-- keywords: SceneTree, change_scene_to_file, change_scene, get_tree, my_scene, change_scene_to_packed, packed_scene, PackedScene, change_scene_to_node -->
### SceneTree.change_scene_to_file() replaces change_scene()
The old `SceneTree.change_scene(path)` method is gone. Use:
  get_tree().change_scene_to_file("res://my_scene.tscn")  # from path string
  get_tree().change_scene_to_packed(packed_scene)           # from PackedScene
  get_tree().change_scene_to_node(scene_node)               # from instantiated node


<!-- keywords: GDScript, Vector2, Vector3, Rect2, Transform2D, Transform3D -->
### Variant types (except Nil and Object) are NEVER null
In GDScript, `int`, `float`, `bool`, `Vector2`, `Vector3`, `Color`, `String`, `Array`, `Dictionary`, `Rect2`, `Transform2D`, `Transform3D`, `Basis`, `Quaternion`, `AABB`, `Plane`, and other built-in Variant types CANNOT be null. They always have a default zero-initialised value. Only variables of type `Object` (or an Object subclass) can be null. Do NOT check `if my_vector == null` or `if my_string == null` — it is always false. Check `Object`-typed variables for null before calling methods on them.
  WRONG:  if my_vec3 == null: return   # Vector3 is never null
  WRONG:  if my_dict == null: return   # Dictionary is never null
  CORRECT: if my_node == null: return  # Object/Node can be null


<!-- keywords: HashMap, HashSet, GDScript -->
### HashMap does NOT preserve insertion order — use Array or Dictionary
The internal C++ `HashMap` (and `HashSet`) do NOT guarantee insertion order — iteration order is effectively random. The GDScript `Dictionary`, however, DOES preserve insertion order (it is an ordered map). When writing GDScript, use `Dictionary` when order matters. When iterating a `Dictionary`, keys are yielded in insertion order. `Array` always maintains insertion order.


<!-- keywords: PackedByteArray, _thread_func, _shared_array -->
### Godot containers are NOT thread-safe — use Mutex for cross-thread access
`Array`, `Dictionary`, `String`, `PackedByteArray`, and all other Godot containers are NOT thread-safe. Reading or writing from multiple threads simultaneously without a `Mutex` causes crashes or undefined behavior. Use `Mutex.lock()`/`unlock()` or the `with Mutex` pattern when sharing data across threads.
  var _mutex := Mutex.new()
  func _thread_func() -> void:
      _mutex.lock()
      _shared_array.append(1)
      _mutex.unlock()


<!-- keywords: load_steps -->
### TSCN format: load_steps deprecated, uid:// paths mandatory in 4.6+
In `.tscn` and `.tres` files: the `load_steps` header field is deprecated in Godot 4.6 (it still parses but is no longer generated). The `uid://` scheme is the canonical resource reference format — every resource saved in 4.6+ gets a stable UID embedded in its file, and TSCN files prefer `uid://xxxxx "res://path"` references so the scene stays valid even if you rename the file. Do NOT hardcode bare `res://` paths in handwritten TSCN if you expect the file to be renamed. The `format=3` header field identifies Godot 4.x TSCN.
