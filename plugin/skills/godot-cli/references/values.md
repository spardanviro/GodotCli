# Writing values

Arguments are JSON. What JSON can say directly (numbers, strings, booleans, arrays, objects) is passed as it is.
Engine types are converted to the type of the property they are assigned to, so the short forms below are enough.

## What you write

| Target type | Accepted |
|---|---|
| `int` | an integer; a float with an integer value |
| `Vector2`, `Vector3`, `Vector2i`, ... | `[x, y]`, `{"x": 1, "y": 2}`, or as in a script: `"Vector2(100, 50)"` |
| `Color` | `"#rrggbb"`, `"#rrggbbaa"`, a colour name (`"red"`), `[r, g, b, a]`, `"Color(1, 0.5, 0, 1)"` |
| `Rect2`, `AABB`, `Plane` | `[x, y, width, height]`; `[x, y, z, width, height, depth]`; `[normal x, normal y, normal z, d]` |
| `Transform2D` | column vectors `[x axis, y axis, origin]`: `[[1, 0], [0, 1], [30, 40]]` |
| `Basis`, `Transform3D`, `Projection` | column vectors in constructor order (`Transform3D` is `[x, y, z, origin]`), or the same numbers as one flat array |
| `Packed*Array` | an array, each element in the element's form: `[[0, 0], [16, 0], [16, 16]]` for a `PackedVector2Array` |
| `NodePath`, `StringName` | a string |
| an enum | the number, the constant's name as a script writes it (`"MOUSE_FILTER_IGNORE"`, `"Control.MOUSE_FILTER_IGNORE"`), or the Inspector's label (`"Ignore"`) |
| a resource | `{"$res": "res://art/player.png"}` loads a file; `{"$new": "RectangleShape2D", "properties": {"size": [32, 32]}}` makes a new one inside the scene |
| a node | `{"$node": "World/Spawn"}`, a path from the scene root |

The script form (`"Vector2(100, 50)"`) takes the type's name and plain numbers, nothing else: no expressions, no
nesting, no constants such as `Vector2.ZERO`.

## What you get back

Output is always tagged, so it cannot be mistaken for something else:

```json
{ "$type": "Vector2", "value": [10, 20] }
{ "$type": "Color", "value": "#ff8800ff" }
{ "$type": "NodePath", "value": "../Target" }
{ "$res": "res://art/player.png", "class": "CompressedTexture2D" }
{ "$node": "World/Spawn" }
```

A tagged value is accepted as input too, so a value that was read can be written back unchanged.

## Resources inside resources

`$new` nests. A particle material with a colour ramp, a mesh with a material:

```bash
gd command node_create --type MeshInstance3D --name Crate --properties '{
  "mesh": {"$new": "BoxMesh", "properties": {
    "size": [1, 1, 1],
    "material": {"$new": "StandardMaterial3D", "properties": {"albedo_color": "#b5651d"}}}}}'
```

A resource made with `$new` is stored inside the scene. When several scenes need the same one, make a file with
`resource_create` and refer to it with `$res`.

## Order matters for properties that depend on each other

Some properties exist only after another one is set: `surface_material_override/0` after `mesh`,
`shader_parameter/<name>` after `shader`, `stream_0/stream` after `streams_count`.

- In `node_create` and inside `$new`, properties are set in the order you write them, so the one that brings the
  other into being goes first, in the same call.
- `node_set` and `resource_set` check every name against the object as it is before changing anything: set the
  first property in one call and the dependent one in the next.

Properties that are another way of writing a stored one can be set too: `rotation_degrees`, `global_position`,
`global_rotation`, `global_transform`, `quaternion`, `basis`.

## What cannot be written

- **`script` is not a property you set.** A script is attached with `node_attach_script`, from a file of the project.
- `$new` builds the engine's own resource classes. It does not build a script, a packed scene or a native extension:
  code comes from files, never from a value.
- A wrong type answers `TYPE_MISMATCH`, with the type that was expected in `details`. Look the property up
  (`gd api class <Name> --member <property>`) instead of trying variations.
- Paths are `res://` paths inside the project. `user://`, absolute paths and `..` are refused (`PATH_NOT_ALLOWED`).
