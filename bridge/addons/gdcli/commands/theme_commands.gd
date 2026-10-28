extends RefCounted
## Building a Theme file item by item (a button's font colour, a panel's
## style box): a Theme lists only the items it already has as properties, so
## resource_set cannot add new ones.

const AccessPolicy = preload("../core/access_policy.gd")
const Edit = preload("../core/edit.gd")
const PathPolicy = preload("../core/path_policy.gd")
const Reply = preload("../core/reply.gd")
const TextSanitizer = preload("../core/text_sanitizer.gd")
const ValueDecoder = preload("../core/value_decoder.gd")

const MAX_ITEMS := 200
const _KINDS: Array[String] = ["color", "constant", "font_size", "font", "stylebox", "icon"]

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func register(registry: RefCounted) -> void:
	registry.register({
		"name": "theme_set",
		"summary": "Set items of a Theme file, creating it when it does not exist: colours, constants, font sizes, fonts, style boxes and icons of a control type.",
		"risk": AccessPolicy.RISK_WRITE,
		"params": {
			"type": "object",
			"properties": {
				"path": {"type": "string", "description": "The theme file, e.g. res://ui/theme.tres."},
				"items": {
					"type": "array",
					"items": {"type": "object"},
					"description": "At most 200: {\"type\": \"Button\", \"kind\": \"color\", \"name\": \"font_color\", \"value\": \"#ffffff\"}; kind is color, constant, font_size, font ({\"$res\": ...}), stylebox ({\"$new\": \"StyleBoxFlat\", \"properties\": {...}}) or icon ({\"$res\": ...}).",
				},
				"default_font_size": {"type": "integer", "minimum": 1, "maximum": 512},
			},
			"required": ["path"],
		},
		"returns": "{path, created, set}. Give the theme to a Control with node_set --properties '{\"theme\": {\"$res\": path}}', or set it as the project's (gui/theme/custom). Not undoable.",
	}, _theme_set)


func _theme_set(args: Dictionary, options: Dictionary) -> Dictionary:
	var checked := PathPolicy.check(args["path"], PathPolicy.ACCESS_WRITE)
	if not checked["ok"]:
		return checked
	var path: String = checked["path"]
	if path.get_extension().to_lower() not in ["tres", "res"]:
		return Reply.fail("INVALID_ARGS", "A theme is a .tres (or .res) file.", "", {"path": path})
	if checked["sensitive"]:
		return Reply.fail("PATH_NOT_ALLOWED", "Themes in a sensitive location are changed in the editor.", "", {"path": path})
	var exists := FileAccess.file_exists(path)
	var theme: Theme
	if exists:
		var outside := PathPolicy.refuse_outside_dependency(path)
		if not outside.is_empty():
			return outside
		# Loading the file runs a script it carries or names: a person allows that first.
		var text := FileAccess.get_file_as_string(path)
		if Edit.runs_in_editor(text, path.get_extension()) or text.contains("type=\"Script\"") or text.contains("script = "):
			var what := {"command": "theme_set", "reason": "the theme file carries or names a script, which loading it runs in the editor", "target": path, "preview": text}
			var gate := Edit.person_gate(_context, options, what, _theme_set.bind(args, Edit.approved(options)))
			if not gate.is_empty():
				return gate
		# A copy of its own: the editor's open copy is not changed until the file is saved.
		theme = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Theme
		if theme == null:
			return Reply.fail("TYPE_MISMATCH", "The file is not a Theme.", "", {"path": path})
	else:
		theme = Theme.new()
	var items: Array = args.get("items", [])
	if items.size() > MAX_ITEMS:
		return Reply.fail("INVALID_ARGS", "At most %d items at once." % MAX_ITEMS)
	var decoded := []
	for index in items.size():
		var item := _decode(items[index])
		if item.has("error"):
			var failure: Dictionary = item["error"]
			failure["error"]["details"] = failure["error"].get("details", {})
			failure["error"]["details"]["item"] = index
			return failure
		decoded.append(item)
	if items.is_empty() and not args.has("default_font_size"):
		return Reply.fail("INVALID_ARGS", "Nothing to set.", "Give items, default_font_size, or both.")
	if options["dry_run"]:
		return Edit.planned({"theme": path, "creates": not exists, "set": decoded.size()})

	for item in decoded:
		match item["kind"]:
			"color":
				theme.set_color(item["name"], item["type"], item["value"])
			"constant":
				theme.set_constant(item["name"], item["type"], item["value"])
			"font_size":
				theme.set_font_size(item["name"], item["type"], item["value"])
			"font":
				theme.set_font(item["name"], item["type"], item["value"])
			"stylebox":
				theme.set_stylebox(item["name"], item["type"], item["value"])
			"icon":
				theme.set_icon(item["name"], item["type"], item["value"])
	if args.has("default_font_size"):
		theme.default_font_size = args["default_font_size"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var saved := ResourceSaver.save(theme, path)
	if saved != OK:
		return Reply.fail("COMMAND_FAILED", "The theme could not be saved.", "", {"path": path, "error": error_string(saved)})
	_context.file_changed(path)
	return Reply.ok({"path": path, "created": not exists, "set": decoded.size()}, [Edit.NOT_UNDOABLE])


## {type, kind, name, value} with the value decoded, or {error: reply}.
func _decode(item: Variant) -> Dictionary:
	if not (item is Dictionary and item.get("type") is String and item.get("name") is String and item.get("kind") in _KINDS):
		return {"error": Reply.fail("INVALID_ARGS", "Each item is {type, kind, name, value}; kind is %s." % ", ".join(_KINDS))}
	if not (item["type"].is_valid_identifier() and item["name"].is_valid_identifier()):
		return {"error": Reply.fail("INVALID_ARGS", "type and name are identifiers, e.g. Button and font_color.")}
	var kind: String = item["kind"]
	var value: Variant = item.get("value")
	var decoder := ValueDecoder.new()
	var result: Dictionary
	match kind:
		"color":
			result = decoder.decode(value, TYPE_COLOR)
		"constant", "font_size":
			result = decoder.decode(value, TYPE_INT)
		_:
			# Through a control's own override property, so a resource gets the
			# same checks as anywhere else ($res inside the project, $new built-in).
			var holder: Control = Label.new() if kind == "font" else (Panel.new() if kind == "stylebox" else Button.new())
			var property: String = {"font": "theme_override_fonts/font", "stylebox": "theme_override_styles/panel", "icon": "icon"}[kind]
			var decoded: Dictionary = decoder.decode_properties(holder, {property: value})
			holder.free()
			if not decoded["ok"]:
				return {"error": decoded}
			result = {"ok": true, "value": decoded["values"][property]}
	if not result["ok"]:
		return {"error": result}
	return {"type": item["type"], "kind": kind, "name": item["name"], "value": result["value"]}
