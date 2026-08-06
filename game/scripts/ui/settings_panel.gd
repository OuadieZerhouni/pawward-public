class_name SettingsPanel
extends Control

## Settings, as one overlay reused by the title screen and the in-shift pause.
##
## Built as a panel rather than a screen so pausing mid-shift can show it without tearing down the
## Shift scene — abandoning a shift has to be a deliberate choice, not a side effect of wanting to
## turn the music down.
##
## Every control writes straight through to SaveGame, so there is no apply/cancel state to get
## wrong and settings survive a crash.

const PANEL_SIZE := Vector2(900, 940)
const PAPER := Color(0.10, 0.11, 0.13, 0.97)
const TEXT := Color(0.86, 0.88, 0.90)
const DIM := Color(0.56, 0.59, 0.63)

signal closed

var _reduce_button: Button


func _ready() -> void:
	custom_minimum_size = PANEL_SIZE
	size = PANEL_SIZE
	_build()
	visible = false


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = PAPER
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var title := Label.new()
	title.text = "SETTINGS"
	title.position = Vector2(40, 34)
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", TEXT)
	add_child(title)

	var y := 140.0
	y = _add_slider("Music", "music_volume", y)
	y = _add_slider("Sound", "sfx_volume", y)

	y += 30.0
	_reduce_button = _add_button("", Vector2(40, y), Vector2(820, 96), _toggle_reduce_scare)
	_refresh_reduce_label()
	y += 120.0

	var note := Label.new()
	note.text = ("Reduce scares softens the vignette pulse and silences the startle sounds. "
			+ "Heart sounds stay audible — the stethoscope needs them.")
	note.position = Vector2(40, y)
	note.size = Vector2(820, 90)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 24)
	note.add_theme_color_override("font_color", DIM)
	add_child(note)
	y += 120.0

	# Restore Purchases must be reachable, and App Review rejects builds where it is not. Wired to
	# the IAP layer when that exists; until then it is honest about doing nothing.
	_add_button("Restore Purchases", Vector2(40, y), Vector2(820, 88), _restore_purchases)
	y += 110.0

	_add_button("Close", Vector2(40, PANEL_SIZE.y - 120), Vector2(820, 90), close_panel)


func _add_slider(label_text: String, key: String, y: float) -> float:
	var label := Label.new()
	label.text = label_text
	label.position = Vector2(40, y)
	label.add_theme_font_size_override("font_size", 30)
	label.add_theme_color_override("font_color", TEXT)
	add_child(label)

	var value := Label.new()
	value.position = Vector2(760, y)
	value.size = Vector2(100, 40)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_font_size_override("font_size", 28)
	value.add_theme_color_override("font_color", DIM)
	add_child(value)

	var slider := HSlider.new()
	slider.position = Vector2(40, y + 46)
	slider.size = Vector2(820, 44)
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(SaveGame.get_value(key, 0.8))
	value.text = "%d%%" % roundi(slider.value * 100.0)
	slider.value_changed.connect(func(v: float):
		value.text = "%d%%" % roundi(v * 100.0)
		SaveGame.set_value(key, v)
		# Preview the change immediately — a volume slider you cannot hear is guesswork.
		if key == "sfx_volume":
			AudioBus.play("paper", -6.0)
		else:
			AudioBus.apply_music_volume())
	add_child(slider)
	return y + 130.0


func _add_button(text: String, pos: Vector2, dims: Vector2, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = dims
	b.add_theme_font_size_override("font_size", 30)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.16, 0.18, 0.21)
	style.border_color = Color(0.34, 0.37, 0.42)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.21, 0.24, 0.28)
	b.add_theme_stylebox_override("hover", hover)
	b.pressed.connect(action)
	add_child(b)
	return b


func _toggle_reduce_scare() -> void:
	SaveGame.set_value("reduce_scare", not bool(SaveGame.get_value("reduce_scare", false)))
	_refresh_reduce_label()


func _refresh_reduce_label() -> void:
	var on := bool(SaveGame.get_value("reduce_scare", false))
	_reduce_button.text = "Reduce scares:   %s" % ("ON" if on else "off")


func _restore_purchases() -> void:
	if bool(SaveGame.get_value("pro", false)):
		AudioBus.play("bell", -6.0)
		return
	# No store layer yet. Saying so beats a button that silently does nothing.
	if OS.is_debug_build():
		print("[IAP] restore purchases — no store layer wired yet")


func open_panel() -> void:
	visible = true


func close_panel() -> void:
	visible = false
	closed.emit()
