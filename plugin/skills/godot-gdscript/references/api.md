# Class notes: GDScript, nodes, scenes, resources, files, threads and platforms

Members that are used most and the notes that matter, one section per class. This is a reminder, not the documentation:
`gd api class <Name>` and `gd api class <Name> --member <member>` print the reference of the Godot version that is installed, and they win where the two differ.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

## Timer
Timer: wait_time:float, one_shot:bool, autostart:bool, paused:bool.
  start(time_sec:float=-1) — pass -1 to use wait_time. stop(). time_left:float (read-only).
  is_stopped()->bool. Signals: timeout.
  IMPORTANT: Timer is a Node — add it to the scene tree with add_child().

## JSON
JSON (static class in GDScript): JSON.stringify(data:Variant)->String, JSON.parse_string(str:String)->Variant.
  Also: var j = JSON.new(); j.parse(str:String)->Error; j.data->Variant.
  IMPORTANT: JSON.parse_string() returns null on parse failure (not an error object).

## FileAccess
FileAccess (static open): FileAccess.open(path, mode)->FileAccess (null if fails).
  Modes: READ, WRITE, READ_WRITE, WRITE_READ.
  file_exists(path:String)->bool (static). get_as_text()->String, store_string(str), store_line(str).
  get_line()->String, get_length()->int, eof_reached()->bool. close() — always close after use.

## DirAccess
DirAccess: DirAccess.open(path)->DirAccess. make_dir(path), make_dir_recursive(path).
  DirAccess.make_dir_recursive_absolute(path:String)->Error (static, preferred).
  get_files()->PackedStringArray, get_directories()->PackedStringArray. list_dir_begin(), get_next()->String.
  remove(path:String)->Error (static: DirAccess.remove_absolute(path)).

## SceneTree
SceneTree: get_nodes_in_group(group:StringName)->Array[Node].
  call_group(group:StringName, method:StringName, ...) — broadcasts method call.
  change_scene_to_file(path:String)->Error, change_scene_to_packed(packed:PackedScene)->Error.
  paused:bool, quit(exit_code:int=0), create_tween()->Tween.
  process_frame signal (emitted each frame), physics_frame signal.

## Node
Node: name:StringName, owner:Node, process_mode:ProcessMode.
  add_child(node:Node, force_readable_name:bool=false), remove_child(node:Node).
  get_node(path:NodePath)->Node, get_node_or_null(path)->Node (safe), find_child(pattern)->Node.
  queue_free() — deferred free (safe in callbacks). free() — immediate (dangerous in callbacks).
  add_to_group(group:StringName, persistent:bool=false), remove_from_group, is_in_group->bool.
  call_deferred(method:StringName, ...) — deferred call (safe for physics callbacks).
  set_deferred(property:StringName, value) — deferred assignment.
  IMPORTANT: set_owner(root) MUST come AFTER add_child(), never before.

## Node2D
Node2D: position:Vector2, rotation:float (radians), rotation_degrees:float, scale:Vector2.
  global_position:Vector2, global_rotation:float, global_transform:Transform2D.
  look_at(point:Vector2). visible:bool, show(), hide().

## HTTPRequest
HTTPRequest (Node): request(url:String, headers:PackedStringArray=[], method:HTTPClient.Method=GET, body:String='')->Error.
  request_raw(url, headers, method, body:PackedByteArray)->Error.
  Signals: request_completed(result:int, response_code:int, headers:PackedStringArray, body:PackedByteArray).
  result codes: RESULT_SUCCESS=0, RESULT_CANT_CONNECT=2, RESULT_NO_RESPONSE=6, etc.
  Must be added to scene tree (add_child). max_redirects:int, timeout:float.
