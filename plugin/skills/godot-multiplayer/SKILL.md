---
name: godot-multiplayer
description: Online and LAN multiplayer in Godot 4 with its built-in high-level networking - hosting and joining with ENetMultiplayerPeer (WebSocket for the Web), peer ids and the server as peer 1, multiplayer authority, @rpc functions and their modes, spawning players and objects for everyone with MultiplayerSpawner, keeping positions in step with MultiplayerSynchronizer, who decides what (server authority versus each player owning their character), a lobby, and how to test with several game instances. Use when the user wants multiplayer, co-op, online play, LAN games, a dedicated server, or mentions ENet, RPC, MultiplayerSpawner, MultiplayerSynchronizer or multiplayer authority.
---

# Multiplayer

Godot's high-level multiplayer is part of the engine: no service or account is needed. One game instance hosts
(the server), the others join (clients). Every instance runs the **same project**; what each does depends on who
it is. Commands are run with `gd command ...` (see the `godot-cli` skill); most of this is script work, written
with `fs_write_text`.

Decide before writing code, it shapes everything:

- **Who decides.** Server authority (clients send input, the server moves everything and tells the others) is
  harder to cheat and right for competitive games. Each player owning their own character (the client moves it and
  the others copy) is simpler and fine for co-op with friends.
- **Where it runs.** ENet (UDP) for desktop and mobile. A Web export cannot use ENet: use
  `WebSocketMultiplayerPeer` (or WebRTC), and a server reachable over WebSocket.
- **How players find the host.** Godot does not punch through home routers. On the internet the host needs a
  forwarded port or a public server; on a LAN, the host's local address is enough.

## Hosting and joining

```gdscript
extends Node
## Network: an autoload that starts and ends the session.

const PORT := 7000
const MAX_CLIENTS := 8

signal player_joined(id: int)
signal player_left(id: int)


# Connected once: the multiplayer API outlives each session.
func _ready() -> void:
	multiplayer.peer_connected.connect(func(id: int) -> void: player_joined.emit(id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void: player_left.emit(id))
	multiplayer.connection_failed.connect(leave)
	multiplayer.server_disconnected.connect(leave)


func host() -> Error:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(PORT, MAX_CLIENTS)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	player_joined.emit(1)  # the host plays too, as peer 1
	return OK


func join(address: String) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, PORT)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	return OK


func leave() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
```

Register it as an autoload (`project_settings_set --name autoload/Network --value '"*res://network.gd"'`; a person
approves autoloads). `create_client` returning OK only means the attempt started: the connection is made when
`connected_to_server` arrives, or fails with `connection_failed`.

- Every peer has an id: the server is always **1**, clients get large random numbers.
  `multiplayer.get_unique_id()` is your own; `multiplayer.is_server()` says whether you host.
- `peer_connected` fires on the server for each client, and on each client for every other peer.

## Authority

Every node has a **multiplayer authority**, the peer whose version of it counts. By default it is 1 (the server)
for everything. A player's character is usually given to its player:

```gdscript
# player.gd: the node is named after its peer id, so every instance agrees who owns it.
func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return  # someone else moves this one; the synchronizer brings their position
	velocity = Input.get_vector("move_left", "move_right", "move_up", "move_down") * 200.0
	move_and_slide()
```

Read input only on the authority: otherwise every instance moves every character with its own keyboard.

## RPCs

A function marked `@rpc` can be called on other peers with `rpc()` (everyone) or `rpc_id(id)` (one peer).

```gdscript
@rpc("any_peer", "call_local", "reliable")
func say(text: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	print("%d says %s" % [sender, text])

# elsewhere: say.rpc("hello")    or    say.rpc_id(1, "only to the server")
```

| Argument | Choices |
|---|---|
| who may call it | `"authority"` (default: only the node's authority) or `"any_peer"` |
| run it here too | `"call_remote"` (default: only on the others) or `"call_local"` |
| delivery | `"reliable"` (in order, resent; chat, hits, game events), `"unreliable"` (positions sent every frame), `"unreliable_ordered"` |

- The function must exist with the **same** `@rpc` line on every peer: they all run the same script, so keep RPCs
  in shared scripts, never behind `if is_server()` definitions.
- A node is found on the other peers by its path. Peers must have the same node at the same path, which is what
  the spawner below takes care of.
- `"any_peer"` functions run code a client asked for: on the server, check `get_remote_sender_id()` is allowed to
  do it (its own character, its turn) before acting.
- Arguments are plain values (numbers, strings, vectors, arrays, dictionaries). Do not send nodes or resources.

## Spawning for everyone: MultiplayerSpawner

Nodes added by code exist only on the instance that added them. A MultiplayerSpawner watches one node (its
`spawn_path`) and recreates on every peer each child the **authority** (the server) adds there, if that child's
scene is in its list.

```bash
gd command node_create --type Node2D --name Players
gd command node_create --type MultiplayerSpawner --name PlayerSpawner --properties '{"spawn_path": "../Players"}'
```

```gdscript
# main.gd, on the server only
@export var player_scene: PackedScene

func _ready() -> void:
	$PlayerSpawner.add_spawnable_scene(player_scene.resource_path)
	if multiplayer.is_server():
		Network.player_joined.connect(_add_player)
		Network.player_left.connect(func(id: int) -> void: $Players.get_node(str(id)).queue_free())
		_add_player(1)


func _add_player(id: int) -> void:
	var player := player_scene.instantiate()
	player.name = str(id)  # player.gd turns the name into its authority
	$Players.add_child(player, true)
```

`add_spawnable_scene` must run on every peer (it is outside the `is_server()` check); the list can also be set in
the spawner's Inspector. Clients must not add children under `Players` themselves.

## Keeping state in step: MultiplayerSynchronizer

A MultiplayerSynchronizer inside the player scene sends chosen properties from the node's authority to everyone
else. Which properties is its `replication_config`, set in the editor's Replication panel (bottom of the editor,
with the synchronizer selected), or in code before the synchronizer enters the tree:

```gdscript
# player.gd
func _enter_tree() -> void:
	set_multiplayer_authority(name.to_int())
	var config := SceneReplicationConfig.new()
	config.add_property(NodePath(".:position"))
	config.add_property(NodePath("Sprite2D:flip_h"))
	$MultiplayerSynchronizer.replication_config = config
```

`set_multiplayer_authority` also sets it on the children (the synchronizer included) unless told otherwise. Paths in the
config are relative to the synchronizer's `root_path` (by default its parent). Synchronize the few values others
need to see; derive the rest. For smooth movement on the receiving side, interpolate toward the received position
instead of jumping to it.

## A lobby

Show a menu with Host and Join (an address field); on host or connection, change to the game scene **on every
peer** (the server calls an RPC with `"call_local"` that does `get_tree().change_scene_to_file(...)`), and have
the server spawn players once the scene is there. Keep player names and choices in a dictionary on the Network
autoload, filled by an RPC each client sends to the server when it connects.

## Testing

A multiplayer game needs at least two instances running:

- In the editor: **Debug > Customize Run Instances**, enable it and set 2 or more instances (a person sets this).
  `gd command editor_play` then starts all of them. Give them a way to choose host or join (buttons, or the
  instance's command-line arguments read with `OS.get_cmdline_user_args()`).
- `gd run` starts one instance; start a second one with another `gd run` in the background for a quick check of the
  errors each prints.
- `game_*` commands talk to a game the editor started; with several instances, check which one answered
  (`game_tree` shows its nodes) before drawing conclusions.
- Test with lag: real networks lose and delay packets that a single machine never does.

## Mistakes that cost the most time

- Spawning a player on a client: it exists only there. Spawn on the server, under the spawner's `spawn_path`.
- Two instances moving the same character: input not guarded by `is_multiplayer_authority()`.
- "Node not found" in RPCs: the node has a different name or path on the other peer. Name spawned nodes
  deliberately (`str(id)`) and pass `true` to `add_child` to force readable names.
- Calling RPCs before the connection is up: wait for `connected_to_server` (client) or `peer_connected` (server).
- Trusting clients: the server checks every `"any_peer"` request.
- Old tutorials: Godot 3's `remote`, `master`, `puppet` and `rset` are gone; it is `@rpc` and synchronizers now.
