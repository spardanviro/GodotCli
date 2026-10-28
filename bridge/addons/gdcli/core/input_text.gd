extends RefCounted
## An input event described in the same words whatever language the editor
## uses ("Ctrl+S", "Mouse button 1", "Joypad axis 0 -"), unlike
## InputEvent.as_text(), which follows the editor's language.

const _MODIFIERS := [["ctrl_pressed", "Ctrl"], ["shift_pressed", "Shift"], ["alt_pressed", "Alt"], ["meta_pressed", "Meta"]]


static func describe(event: InputEvent) -> String:
	if event is InputEventKey:
		var code: int = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
		var parts := []
		for modifier in _MODIFIERS:
			if event.get(modifier[0]):
				parts.append(modifier[1])
		parts.append(OS.get_keycode_string(code) if code != KEY_NONE else "?")
		return "+".join(parts) + (" (physical)" if event.keycode == KEY_NONE and event.physical_keycode != KEY_NONE else "")
	if event is InputEventMouseButton:
		return "Mouse button %d" % event.button_index
	if event is InputEventJoypadButton:
		return "Joypad button %d" % event.button_index
	if event is InputEventJoypadMotion:
		return "Joypad axis %d %s" % [event.axis, "-" if event.axis_value < 0.0 else "+"]
	if event is InputEventAction:
		return "Action %s" % event.action
	return event.get_class()
