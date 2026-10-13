# Class notes: user interface

Members that are used most and the notes that matter, one section per class. This is a reminder, not the documentation:
`gd api class <Name>` and `gd api class <Name> --member <member>` print the reference of the Godot version that is installed, and they win where the two differ.

Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.

## Control
Control: position:Vector2, size:Vector2, custom_minimum_size:Vector2, pivot_offset:Vector2.
  anchor_left/right/top/bottom:float (0.0-1.0). set_anchors_preset(preset:LayoutPreset).
  PRESET_FULL_RECT, PRESET_TOP_LEFT, PRESET_CENTER, PRESET_TOP_WIDE.
  size_flags_horizontal/vertical: SIZE_FILL|SIZE_EXPAND|SIZE_SHRINK_CENTER|SIZE_EXPAND_FILL.
  add_theme_color_override(name, color), add_theme_font_size_override(name, size).
  add_theme_constant_override(name, value), add_theme_stylebox_override(name, stylebox).
  IMPORTANT: For FULL_RECT anchors, set_deferred('size', value) instead of direct assignment in _ready().

## Button
Button: text:String, icon:Texture2D, disabled:bool, toggle_mode:bool, button_pressed:bool.
  flat:bool, alignment:HorizontalAlignment, expand_icon:bool.
  Signals: pressed(), button_up(), button_down(), toggled(button_pressed:bool).

## LineEdit
LineEdit: text:String, placeholder_text:String, max_length:int, secret:bool (password), editable:bool.
  clear(), select_all(), select(from, to), deselect().
  Signals: text_submitted(new_text:String), text_changed(new_text:String), focus_entered, focus_exited.

## RichTextLabel
RichTextLabel: bbcode_enabled:bool, text:String (plain), fit_content:bool, scroll_active:bool.
  append_text(bbcode:String), add_text(text:String), clear(), newline().
  set_use_bbcode(true) for bbcode. push_color(color), pop(). [b], [i], [url], [img] tags supported.

## Label
Label: text:String, horizontal_alignment:HorizontalAlignment, vertical_alignment:VerticalAlignment.
  autowrap_mode:AutowrapMode — CRITICAL: NOT a bool. Use TextServer.AUTOWRAP_WORD_SMART (most common),
    AUTOWRAP_ARBITRARY, AUTOWRAP_WORD, or AUTOWRAP_OFF. WRONG: label.autowrap=true. CORRECT: label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART.
  clip_text:bool, text_overrun_behavior:OverrunBehavior, max_lines_visible:int.
  add_theme_font_size_override('font_size', 24), add_theme_color_override('font_color', Color.WHITE).
