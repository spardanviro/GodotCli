# Pitfalls: animation, tweens, particles and audio

36 entries, each a mistake that is easy to make in Godot 4 and what to do instead. Do not read this file from top to bottom:
search it for the class, method or term you are about to use (the `keywords` line of each entry lists them) and read the entries that match.
The other skills of this plugin have a file like this one for their topics: `../../*/references/gotchas.md` searches all of them.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

<!-- keywords: Audio, AudioStreamPlayer, audio -->
### Audio: linear volume ≠ dB — use linear_to_db() / db_to_linear()
`AudioStreamPlayer.volume_db` uses the decibel scale where 0 dB = maximum, and every -6 dB halves perceived loudness. Working range is typically -60 dB (near-silent) to 0 dB (max). To convert a 0.0–1.0 slider value to dB:
  volume_db = linear_to_db(slider_value)   # 1.0 → 0 dB, 0.5 → -6 dB, 0.0 → -inf
  slider_value = db_to_linear(volume_db)   # reverse
Never set volume_db above 0 — it causes clipping distortion on the master bus.


<!-- keywords: AnimationTree, AnimationPlayer, animation -->
### AnimationTree requires a separate AnimationPlayer — it has no animations of its own
`AnimationTree` does NOT store animations. It blends and transitions animations from an `AnimationPlayer` node. You must: (1) create/import animations in `AnimationPlayer`, (2) add `AnimationTree` to your scene, (3) set its `anim_player` property to point to the `AnimationPlayer`. This is especially relevant for imported 3D scenes: the `AnimationPlayer` lives inside the imported scene; your own scene's `AnimationTree` references it.


<!-- keywords: int, print, debug -->
### print() output may NOT appear in release builds until game exits — use printerr() for realtime logging
`print()` in Godot writes to **stdout** with buffering. In release builds (and in some launchers), stdout is not flushed until the process exits, meaning `print()` messages may never appear in real time. By contrast, `printerr()` writes to **stderr** which is **unbuffered** (always flushed immediately). For debug logging that you need to see in real time (especially if the game might crash), use `printerr()`. You can also call `print_rich()` which flushes immediately in the editor. In editor/debug builds, `print()` does flush immediately.


<!-- keywords: AnimationTree, RESET, AnimationPlayer, animation -->
### AnimationTree: RESET animation is required for correct blending
When blending two animations in AnimationTree and one animation lacks a property track that the other has, the missing animation uses an **initial value** for that property. For most properties, this initial value is `0` (or `Vector2(0,0)`) — NOT the current node value. This causes jarring jumps. The fix: create a `RESET` animation in AnimationPlayer (exact name, case-sensitive) and add tracks for every property you want to blend, with a single keyframe at time 0 set to the correct default. AnimationTree uses RESET as the reference for blend calculations. For Skeleton3D bones, the initial value is Bone Rest instead of 0.


<!-- keywords: AnimationTree, animation, Bone, import -->
### AnimationTree: humanoid models should be imported in T-pose for correct bone blending
Linear Angle and Cubic Angle rotation track modes interpolate along the SHORTEST path from the initial pose (Bone Rest / RESET animation). For humanoid characters, if bones are in T-pose rest, the shortest rotation path naturally avoids bones passing through the body. If the rest pose is not T-pose, the shortest rotation path may cause bones to penetrate through the mesh during blends. Import humanoid 3D characters in T-pose to set correct Bone Rest values.


<!-- keywords: AnimationTree, Advance, Condition, Expression, animation -->
### AnimationTree Advance Condition cannot check 'false' — use Advance Expression
StateMachine Advance Condition only checks if a named parameter is `true`. It does NOT support negation (`!`) or any expression. To have a transition trigger when a condition is false, you need two separate boolean variables (`is_walking` and `is_not_walking`) set to opposite values. A better alternative: use **Advance Expression** (available in Godot 4) which supports full boolean expressions like `!is_walking`, `speed > 0`, or `player.is_on_floor()`. When using Advance Expression with script variables, set the **Advance Expression Base Node** in the AnimationTree inspector to point to the node that contains the script with those variables.


<!-- keywords: Call, Method, Track, AnimationPlayer, animation -->
### AnimationPlayer: Call Method Track events NOT executed in editor preview
When previewing an animation in the AnimationPlayer editor panel, **Call Method Track keyframes are NOT executed** (this is intentional, for safety — you don't want `queue_free()` to delete nodes while editing). This means you cannot test Call Method Track timing in the editor by scrubbing. You must run the game (F5) to test method calls. Similarly, audio tracks only play audio in-editor if using the Animation panel's play button (not when scrubbing the timeline).


<!-- keywords: AnimationPlayer, RESET, animation, AnimationTree -->
### AnimationPlayer: RESET animation name is case-sensitive and must be exactly 'RESET'
The special 'default pose' animation must be named exactly `RESET` — all caps, no spaces. It is used by:
1. `Reset On Save`: saves the scene with the reset pose applied (property on AnimationPlayer)
2. AnimationTree blending: provides the reference values for properties not present in all animations
3. `Apply Reset` in the Animation panel's Edit menu to restore the default pose in the editor
RESET should contain exactly ONE keyframe at time 0 for each property you want to reset. It is not meant to be played back as a regular animation.


<!-- keywords: Audio, RIGHT, LEFT, audio -->
### Audio buses route RIGHT to LEFT only — cannot route to buses on the right
Godot's audio bus layout enforces a LEFT-TO-RIGHT dependency order. Each bus can only send audio to a bus that is **further to the left** of it. The leftmost bus is always the **Master** bus, which sends to the audio output. You cannot route audio backwards (left to right) to prevent infinite loops. To avoid clipping, ensure the Master bus output never exceeds **0 dB** (that's the digital maximum — not the loudest possible, but the clip point). Typical working range is -60 dB to 0 dB; silence is around -60 to -80 dB.


<!-- keywords: AudioSample, AudioEffects, AudioStreamPlayer3D, Doppler, Reverb, Web, audio -->
### AudioSample does NOT support AudioEffects; AudioStreamPlayer3D Doppler/Reverb not on Web
AudioSample (used for sample-based playback) does not support any AudioEffect bus effects. Only AudioStream-based playback supports effects. Also:
- AudioStreamPlayer3D's **Reverb Bus** and **Doppler** features are NOT supported on Web when playback mode is **Sample** (the default for Web). Switch to Stream mode to enable them, at the cost of higher latency unless threads are enabled.
- Doppler tracking must be explicitly enabled on BOTH the AudioStreamPlayer3D **and** the Camera3D nodes. Set tracking to **Idle** for objects moved in `_process()`, or **Physics** for objects moved in `_physics_process()`.
- The old `AudioEffectLimiter` is deprecated — use `AudioEffectHardLimiter` instead.


<!-- keywords: Not, Ogg, Vorbis, Theora, audio -->
### Not all .ogg files are Ogg Vorbis audio — Theora video also uses .ogg extension
Some `.ogg` files contain Ogg **Theora** video or Ogg **Opus** audio, not Vorbis. Loading Theora video as `AudioStreamOggVorbis` will fail. Use `VideoStreamTheora` for video, `AudioStreamOggVorbis.load_from_file()` for Vorbis audio. Also: `VideoStreamPlayer.autoplay` will NOT trigger if the stream property is empty when the node enters the tree — always call `play()` manually after setting `stream`. When loading glTF from a buffer (not a file), you must set `GLTFState.base_path` manually so external textures can be found. And when loading runtime images to display on 3D surfaces, call `image.generate_mipmaps()` to prevent grainy appearance at distance.


<!-- keywords: Audio, audio, light -->
### Audio format trade-offs: WAV = lightest CPU; OGG = smallest files; MP3 = mobile balance
Audio format selection guide:
- **WAV**: Lightest CPU usage (hundreds of simultaneous voices fine). Largest files. Best for short/repetitive sound effects.
- **Ogg Vorbis**: Smallest file size, highest CPU decoding cost. Best for music, long speech, ambient sounds.
- **MP3**: Less CPU than Ogg Vorbis, larger files than Ogg. Best for mobile/web where CPU is limited but multiple streams needed simultaneously.
For WAV import: use Trim to remove silence, Loop to enable looping, and Force Mono to halve file size on mono sounds. Prefer 22050 Hz for voices (indistinguishable from 44100 Hz for speech).


<!-- keywords: GDScript, LEFT, AudioStreamPlayer, audio, gdscript, debug, assert -->
### GDScript: ** operator is LEFT-associative; assert() ignored in non-debug builds; rename bus = AudioStreamPlayer loses it
GDScript operator gotchas:
- `**` (power) is LEFT-associative like C++ (unlike Python): `2 ** 2 ** 3` = `(2**2)**3 = 64`, NOT 256. Use parentheses to clarify intent.
- `assert(condition)` is completely IGNORED in exported (non-debug) builds — don't rely on it for production logic
- `%` operator behaves like C++ (can return negative for negative dividends), not like Python
- `!`, `&&`, `||` work but are not idiomatic — prefer `not`, `and`, `or`


<!-- keywords: AudioStreamPlayer, NAME, Master, audio -->
### AudioStreamPlayer bus reference is by NAME — renaming a bus silently reroutes to Master
Audio bus management gotchas:
- AudioStreamPlayers reference buses by NAME. If a bus is RENAMED, the player silently falls back to Master.
- Audio buses auto-disable after a few seconds of silence (VU turns blue). No need to manually disable silent buses.
- Bus routing always flows RIGHT to LEFT to prevent feedback loops. You cannot route a bus to a bus that is to its right.
- Audio effects on web require playback mode = Stream (not the default Sample mode).
- Default bus layout is saved to res://default_bus_layout.tres automatically.


<!-- keywords: For, Time, AudioStreamPlayer, audio -->
### For rhythm game audio sync: use Time.get_ticks_usec() + get_time_to_next_mix() + get_output_latency()
AudioStreamPlayer.play() has inherent latency. For precise sync:
```gdscript
var time_begin = Time.get_ticks_usec()
var time_delay = AudioServer.get_time_to_next_mix() + AudioServer.get_output_latency()
$Player.play()

func _process(delta):
    var time = (Time.get_ticks_usec() - time_begin) / 1000000.0
    time = max(0.0, time - time_delay)
```
Use Time.get_ticks_usec() — not accumulated delta — for accurate timing (delta accumulates floating point errors).


<!-- keywords: ONLY, GPUParticles, CPUParticles, Shader, shader, GPUParticles2D, particles -->
### GPU particle shaders keep data from previous frame; ONLY work with GPUParticles, not CPUParticles
Unlike other shader types, particle shaders preserve output data between frames, enabling multi-frame effects. Custom particle shaders (start()/process() functions) only work with GPUParticles2D/3D nodes. CPUParticles simulate on CPU and can only use the built-in ParticleProcessMaterial properties. To use particle COLOR in a StandardMaterial3D, you must enable vertex_color_use_as_albedo.


<!-- keywords: GPUParticles2D, Visibility, Rect, MUST, particles -->
### GPUParticles2D Visibility Rect MUST contain all particles or they disappear when offscreen
GPU particles use a Visibility Rect for culling. If particles travel outside this rect, they become invisible when the rect is offscreen even though particles would still be visible. Use 'Particles > Generate Visibility Rect' in toolbar to auto-calculate. Also: particles start with zero emissions — use Preprocess to pre-simulate seconds of particles before first frame.


<!-- keywords: Audio, SILENT, Driver, Enable, Input, AudioStreamPlayer, audio, input, Project, Settings -->
### Audio input produces SILENT recordings if 'Audio > Driver > Enable Input' project setting is not enabled
Recording from microphone silently fails (no error, no exception) if:
- Project Settings > Audio > Driver > Enable Input is not checked
- On iOS: Audio > General > iOS > Session Category must include 'Record' or 'Play and Record'
- The AudioStreamMicrophone resource must be assigned and the AudioStreamPlayer must be 'playing' before calling get_stream_playback()


<!-- keywords: GPUParticles3D, DISABLES, particles -->
### GPUParticles3D sub-emitter assignment DISABLES emission on that particle system — cannot re-enable while assigned
Particle sub-emitter gotchas:
- When a GPUParticles3D node is assigned as a sub-emitter, it automatically stops emitting and the Emitting property cannot be re-enabled while assigned as sub-emitter. Silently produces nothing if you test the sub-emitter node in isolation.
- A particle system cannot be its own sub-emitter — produces nothing silently (no error)
- VectorField attractor texture: neutral gray (0.5, 0.5, 0.5) means ZERO velocity (not default direction). Y axis is inverted between texture UV space and world space — top of texture = bottom of attractor volume


<!-- keywords: GPUParticles3D, Visibility, AABB, collision, 3D, particles -->
### GPUParticles3D collision: SDF must be manually baked; Visibility AABB must overlap collider or no collision occurs
3D particle collision gotchas:
- SDF collision must be MANUALLY baked in the editor — if you forget to bake, particles pass through everything silently. Also: SDF collision is Forward+/Mobile only (not Compatibility)
- The particle's Visibility AABB must overlap the collider's AABB for collision to work at all. If particles spawn outside the AABB, they won't collide. Use GPUParticles3D > Generate Visibility AABB
- Height field 'When Moved' update mode only triggers when the HEIGHT FIELD NODE itself moves — NOT when meshes inside it move. Dynamic geometry is not supported
- Low resolution height fields can silently IGNORE small meshes entirely (not just fuzz them — they disappear from collision)
- Fast particles tunnel through thin colliders — increase collider thickness or Fixed FPS (but higher FPS has significant performance cost)


<!-- keywords: Particle, Forward, Mobile, Transform, Align, Velocity, velocity -->
### Particle trails only work in Forward+/Mobile; tube trails flatten without 'Transform Align = Y to Velocity'
3D particle trail gotchas:
- Particle trails are Forward+/Mobile only — silent failure in Compatibility renderer
- Ribbon trails using tubes flatten and lose volume during direction changes unless 'Transform Align' is set to 'Y to Velocity'
- Turbulence modifies existing movement — it does NOT create movement. Zero-gravity particles with only turbulence enabled show nothing
- Turbulence Noise Speed moves the NOISE PATTERN (not particles). Confusing it with particle speed produces hard-to-debug results
- 3D turbulence noise is very expensive on mobile/web — causes dramatic frame drops on multiple emitters


<!-- keywords: ParticleProcessMaterial, MULTIPLY, Angle, Rotate, Color, Material, material -->
### ParticleProcessMaterial: curves MULTIPLY base value (don't replace); Angle requires Rotate Y enabled; Color multiplies material color
GPU particle process material gotchas:
- If a Curve is set on any property (scale, velocity, etc.), it MULTIPLIES the Min/Max base value — it does not replace it. A curve returning 1.0 leaves the base unchanged; 0.0 zeroes it.
- The Angle property has ZERO visible effect unless 'Rotate Y' is enabled OR the material uses 'Particle Billboard' mode
- Color property MULTIPLIES with the material's existing Color/Texture — white (1,1,1,1) leaves material color unchanged; to override, set material texture to white
- Tangential acceleration is permanently restricted to the XZ-plane — particles never move along Y due to tangential force
- Damping only affects linear velocity — does NOT slow particle rotation (angular velocity)
- Direction property alone has ZERO effect without velocity or acceleration set
- Animation smoothness depends on: Animation FPS = (Number of frames) / Lifetime. Changing Lifetime without adjusting animation speed breaks frame timing


<!-- keywords: Looping, NEVER, Ogg, signal, emit, AudioStreamPlayer, audio -->
### Looping audio NEVER emits 'finished' signal; Ogg/MP3 only support forward loops (no ping-pong/reverse)
Audio import gotchas:
- AudioStreamPlayer.finished signal NEVER fires for audio streams with Loop enabled — any cleanup or chaining logic tied to 'finished' will never run for looping audio
- Ogg Vorbis and MP3 only support a single loop begin point with forward looping. WAV format supports ping-pong and backward loop modes; Ogg/MP3 do not.
- 24-bit audio provides zero perceptible quality benefit in games — wastes memory and load time. 16-bit is sufficient.
- The 'Trim' import option removes audio below -50 dB (not absolute silence) — very quiet content at the start/end is also trimmed, potentially adding unexpected latency


<!-- keywords: Godot, INCLUDES, English, Bone, animation -->
### Godot 4 bone pose INCLUDES bone rest (changed from Godot 3); auto-retargeting needs English bone names
3D skeleton/retargeting gotchas:
- Godot 4 changed how bone poses work: the pose transform now INCLUDES the bone rest. In Godot 3, pose was applied ON TOP of rest separately. Porting code that manipulates bone transforms directly requires this adjustment.
- Skeleton retargeting auto-mapping uses pattern matching on bone names — use standard English anatomical names (Hips, Spine, Head, UpperArm, etc.) for best auto-detection
- 'Unimportant Positions' option removes position tracks except root and scale_base — important for sharing animations across different-sized characters


<!-- keywords: Large, GDExtensions, GPUParticles, Shader, shader, GPUParticles3D, particles, GDExtension -->
### Large world coordinates: GDExtensions must be recompiled; triplanar/GPUParticles still jitter; fragment shader can't reconstruct world pos
Large world coordinates (double precision) gotchas:
- GDExtensions compiled for single-precision builds are INCOMPATIBLE with double-precision builds (and vice versa) — all extensions must be recompiled when switching. No error is thrown; things just break.
- Triplanar materials and GPUParticles3D with 'Local Coords' disabled still exhibit visible jitter far from origin even WITH large world coordinates enabled
- In double-precision builds, you CANNOT reconstruct world coordinates from view-space in a fragment shader using normal matrix math. Must calculate world coordinates in the vertex shader and pass them as varyings.
- Networked games with mismatched client/server precision (single vs. double) will appear to work but silently produce 'various issues' — all peers must use the same precision build
- 2D rendering does NOT benefit from double precision (only 2D physics does) — model snapping still occurs from a few million pixels at normal zoom
- Performance penalty is severe on 32-bit CPUs and mobile hardware — consider reducing physics tick rate to compensate


<!-- keywords: Audio, NAME, Master, AudioStreamPlayer, audio -->
### Audio bus references stored by NAME — renaming a bus silently routes audio to Master instead
AudioStreamPlayer.bus is a string property storing the bus name. If you rename a bus in the Audio panel, all AudioStreamPlayers set to that bus silently fall back to 'Master' — there's no warning or error. Update bus names in all players after renaming.


<!-- keywords: Audio, DISABLES, AudioStreamPlayer, audio -->
### Audio bus DISABLES itself automatically after silence — effects stop processing too
Godot automatically disables audio buses after a few seconds of silence to save CPU. This means real-time audio effects (reverb, delay) on the bus also stop processing. If you need continuous effect processing (e.g., for ambient sound), keep a silent AudioStreamPlayer looping on the bus.


<!-- keywords: Web, AudioStreamPlayer, Sample, audio, export -->
### Web export: AudioStreamPlayer 'Sample' playback mode does NOT support audio bus effects
When Playback Type is set to 'Sample' (the recommended default for Web export performance), audio bus effects are silently skipped. Only 'Stream' playback type runs effects on Web. This means reverb, EQ, and other effects are silently absent in Web exports unless you switch playback type.


<!-- keywords: Audio, CHUNKS, AudioStreamPlayer, audio -->
### Audio: get_playback_position() updates in CHUNKS, not continuously — direct timing comparisons will drift
AudioStreamPlayer.get_playback_position() only updates when the audio thread processes a block (typically every 512-1024 samples). Between blocks, the value is stale. For precise audio synchronization, compensate using a Time.get_ticks_usec() delta relative to when you last sampled get_playback_position().


<!-- keywords: Retargeting, Bone, Rest, DIFFERS, Blender, Maya, animation, blender -->
### Retargeting animations: Bone Rest DIFFERS between Blender and Maya — animations from different software can't be shared without retargeting
Blender applies Edit Bone Orientation as Bone Rest; Maya does not. This means the same animation data produces different poses on models from different DCC tools. Godot's skeleton retargeting system can compensate, but you must enable it and configure 'Overwrite Axis' carefully — wrong settings produce garbage poses.


<!-- keywords: Audio, Amplify, SILENTLY, Limiter, audio -->
### Audio effects: Amplify can SILENTLY clip audio — add a Limiter effect after any Amplify to prevent distortion
The Amplify audio effect applies gain without any clipping protection. Setting volume_db above 0 dB on Amplify will cause digital clipping if the audio signal was already at maximum. Always follow Amplify with a HardLimiter effect (AudioEffectLimiter is deprecated) to prevent distortion, especially for dynamic audio content.


<!-- keywords: AnimationPlayer, StringName, GDScript, current_animation, assigned_animation, current_animation_changed -->
### AnimationPlayer string properties are StringName in 4.6+ (GDScript auto-converts)
`AnimationPlayer.current_animation`, `assigned_animation`, and `autoplay` changed from String to StringName in Godot 4.6. GDScript auto-converts, so existing code still works. However in C# you must update types explicitly. The `current_animation_changed` signal parameter is also now StringName.


<!-- keywords: AnimationPlayer, ANIMATION_PROCESS_, AnimationMixer, ANIMATION_PROCESS_PHYSICS, ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS, ANIMATION_PROCESS_IDLE, ANIMATION_CALLBACK_MODE_PROCESS_IDLE, ANIMATION_PROCESS_MANUAL, ANIMATION_CALLBACK_MODE_PROCESS_MANUAL -->
### AnimationPlayer: old ANIMATION_PROCESS_* constants deprecated (use AnimationMixer)
The following AnimationPlayer constants and methods are deprecated in favour of AnimationMixer equivalents:
  DEPRECATED → CORRECT:
  AnimationPlayer.ANIMATION_PROCESS_PHYSICS → AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
  AnimationPlayer.ANIMATION_PROCESS_IDLE    → AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
  AnimationPlayer.ANIMATION_PROCESS_MANUAL  → AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
  AnimationPlayer.ANIMATION_METHOD_CALL_DEFERRED  → AnimationMixer.ANIMATION_CALLBACK_MODE_METHOD_DEFERRED
  AnimationPlayer.ANIMATION_METHOD_CALL_IMMEDIATE → AnimationMixer.ANIMATION_CALLBACK_MODE_METHOD_IMMEDIATE
Properties `callback_mode_method`, `callback_mode_process`, `root_node` moved to AnimationMixer base class.


<!-- keywords: AnimationPlayer, play_section, set_section_with_markers, start_marker, end_marker, play_section_with_markers, loop_start -->
### AnimationPlayer: section-based playback (Godot 4.4+)
AnimationPlayer gained section-based playback in 4.4. You can play a sub-range of an animation:
  player.play_section("Run", 0.2, 0.8)  # play only 0.2s→0.8s of Run
  player.set_section_with_markers("start_marker", "end_marker")
  player.play_section_with_markers("Run", "loop_start", "loop_end")
New property `playback_auto_capture` (default: true) — automatically captures current pose before blending to a new animation. Set `playback_auto_capture_duration` to control blend time.


<!-- keywords: MeshInstance3D, NodePath, Skeleton3D, ProjectSettings, default_parent_skeleton_in_mesh_instance_3d -->
### MeshInstance3D.skeleton default changed in Godot 4.6 — may break rigged meshes
The default lookup behavior of `MeshInstance3D.skeleton` (NodePath) changed in 4.6. Old code that relied on auto-detection of a parent Skeleton3D will fail. Fix:
  Option 1: Enable ProjectSettings → animation/compatibility/default_parent_skeleton_in_mesh_instance_3d
  Option 2: Explicitly set skeleton path in code or Inspector


<!-- keywords: AnimationPlayer, AnimationMixer, Position3D, Rotation3D, Scale3D -->
### AnimationPlayer optimized 3D tracks — no per-keyframe easing or blending
When `AnimationMixer.deterministic = false` and the animation targets 3D nodes via optimized tracks (Position3D, Rotation3D, Scale3D), per-keyframe easing curves and transition types are IGNORED. The track uses simple linear interpolation. To use custom easing, switch to generic `value` tracks or set `deterministic = true`. This is a deliberate performance trade-off for 3D skeletal animation.
