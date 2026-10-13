# Class notes: animation, tweens, particles and audio

Members that are used most and the notes that matter, one section per class. This is a reminder, not the documentation:
`gd api class <Name>` and `gd api class <Name> --member <member>` print the reference of the Godot version that is installed, and they win where the two differ.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

## AnimationPlayer
AnimationPlayer: current_animation:StringName (read/write to play; was String pre-4.6), speed_scale:float, autoplay:StringName.
  play(name:StringName='', custom_blend:float=-1, custom_speed:float=1.0, from_end:bool=false).
  play_backwards(name), stop(keep_state:bool=false), pause().
  has_animation(name)->bool, get_animation_list()->PackedStringArray.
  current_animation_position:float, current_animation_length:float.
  Signals: animation_finished(anim_name:StringName), animation_changed(old_name, new_name).
  NOTE (4.6+): current_animation/assigned_animation/autoplay are StringName; GDScript auto-converts from String.

## AnimationTree
AnimationTree: tree_root:AnimationRootNode, anim_player:NodePath, active:bool.
  State machine: var playback = tree.get('parameters/playback') (AnimationNodeStateMachinePlayback); playback.travel('state_name'), playback.start('state_name'), playback.get_current_node().
  Read/write blend param: set('parameters/BlendSpace2D/blend_position', Vector2(x,y)).
  Read/write 1D blend: set('parameters/BlendSpace1D/blend_position', 0.5).
  AnimationNodeTransition (a blend-tree node, not a state machine): set('parameters/<TransitionNodeName>/transition_request', 'state_name'); read 'parameters/<TransitionNodeName>/current_state'.
  IMPORTANT: parameter paths are 'parameters/' + the node's name in the tree + '/blend_position' (blend spaces) or '/transition_request' (Transition nodes); a root state machine's playback is 'parameters/playback'.

## GPUParticles3D
GPUParticles3D: emitting:bool, amount:int, lifetime:float, one_shot:bool, preprocess:float.
  process_material:Material (usually ParticleProcessMaterial), draw_pass_1:Mesh.
  restart() — restart emission. finished signal (only when one_shot=true).
  visibility_aabb:AABB — must cover full path of particles or they disappear.
  ParticleProcessMaterial: emission_shape, direction, spread, gravity, initial_velocity_min/max,
    scale_min/max, color, color_ramp:GradientTexture1D, attractor_interaction_enabled.

## GPUParticles2D
GPUParticles2D: emitting:bool, amount:int, lifetime:float, one_shot:bool.
  process_material:ParticleProcessMaterial, texture:Texture2D.
  restart(). finished signal (one_shot only).

## AudioStreamPlayer
AudioStreamPlayer: stream:AudioStream, volume_db:float=0, pitch_scale:float=1, autoplay:bool, bus:StringName='Master'.
  play(from_position:float=0.0), stop(), seek(pos:float).
  playing:bool (read-only), get_playback_position()->float.
  Signals: finished.

## AudioStreamPlayer2D
AudioStreamPlayer2D: stream:AudioStream, volume_db:float, pitch_scale:float, max_distance:float, attenuation:float, bus:StringName.
  play(from_position:float=0.0), stop(). playing:bool (read-only). Signals: finished.

## AudioStreamPlayer3D
AudioStreamPlayer3D: stream:AudioStream, volume_db:float, unit_size:float, max_distance:float, bus:StringName.
  play(from_position:float=0.0), stop(). playing:bool (read-only). Signals: finished.

## Tween
Tween: created via node.create_tween() — NOT Tween.new().
  tween_property(obj:Object, prop:NodePath, final_val:Variant, dur:float)->PropertyTweener.
  tween_method(method:Callable, from, to, dur)->MethodTweener.
  tween_callback(callback:Callable)->CallbackTweener.
  tween_interval(time:float)->IntervalTweener.
  set_loops(loops:int=0), set_parallel(parallel:bool), set_ease(ease), set_trans(trans).
  Signals: finished, step_finished(idx:int), loop_finished(loop_count:int).
  Chain: tween_property(...).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT).

## Skeleton3D
Skeleton3D: get_bone_count()->int, find_bone(name:String)->int (-1 if not found).
  get_bone_pose(bone_idx:int)->Transform3D, set_bone_pose(bone_idx:int, pose:Transform3D).
  get_bone_pose_position(bone_idx)->Vector3, set_bone_pose_position(bone_idx, pos:Vector3).
  get_bone_pose_rotation(bone_idx)->Quaternion, get_bone_global_pose(bone_idx)->Transform3D.
