extends Node2D

## Entry point. Deliberately spare: the game's whole appeal is the patient at the window, so
## the title screen shows one and gets out of the way.

const CANVAS := Vector2(1080, 1920)


func _ready() -> void:
	_build()
	AudioBus.play_music()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.048, 0.054, 0.068)
	bg.size = CANVAS
	bg.z_index = -100
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var lamp := ColorRect.new()
	lamp.size = CANVAS
	lamp.z_index = -99
	lamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lamp.material = _shader("res://shaders/lamp_glow.gdshader")
	add_child(lamp)

	# A live patient rather than a static logo — it breathes and watches the cursor, which is
	# the single best advertisement the game has.
	var greeter := Patient.new()
	greeter.position = Vector2((CANVAS.x - 1024) * 0.5, 300)
	add_child(greeter)
	var roster_pick: Dictionary = Roster.creatures[0] if not Roster.creatures.is_empty() else {}
	if not roster_pick.is_empty():
		greeter.build(roster_pick, {})
	_greeter = greeter

	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

	var title := Label.new()
	title.text = "PawWard"
	title.size = Vector2(CANVAS.x, 120)
	title.position = Vector2(0, 120)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 92)
	title.add_theme_color_override("font_color", Color(0.90, 0.88, 0.84))
	layer.add_child(title)

	var tagline := Label.new()
	tagline.text = "Spot the odd patient at night"
	tagline.size = Vector2(CANVAS.x, 50)
	tagline.position = Vector2(0, 236)
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tagline.add_theme_font_size_override("font_size", 32)
	tagline.add_theme_color_override("font_color", Color(0.58, 0.60, 0.64))
	layer.add_child(tagline)

	var night := int(SaveGame.get_value("night_reached", 1))
	var onboarding_done := bool(SaveGame.get_value("onboarding_done", false))

	var y := 1380.0
	if not onboarding_done:
		_add_button(layer, "First Night", Vector2(240, y), func(): _start_campaign(0))
	else:
		_add_button(layer, "Night %d" % night, Vector2(240, y), func(): _start_campaign(night))
	y += 180.0

	if onboarding_done:
		var best := int(SaveGame.get_value("best_endless", 0))
		var label := "Endless" if best == 0 else "Endless   best %d" % best
		_add_button(layer, label, Vector2(240, y), func(): _start_endless())
		y += 180.0

	_add_button(layer, "Settings", Vector2(240, y), func(): _settings.open_panel())

	_settings = SettingsPanel.new()
	_settings.position = Vector2(90, 340)
	layer.add_child(_settings)

	var roster_note := Label.new()
	roster_note.size = Vector2(CANVAS.x, 40)
	roster_note.position = Vector2(0, CANVAS.y - 70)
	roster_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	roster_note.add_theme_font_size_override("font_size", 22)
	roster_note.add_theme_color_override("font_color", Color(0.40, 0.42, 0.46))
	if Roster.placeholder_count > 0:
		roster_note.text = "%d of %d creatures are placeholder art" % [
			Roster.placeholder_count, Roster.creatures.size()]
	layer.add_child(roster_note)


var _greeter: Patient
var _settings: SettingsPanel


func _process(_delta: float) -> void:
	if _greeter != null:
		_greeter.look_at_point(get_global_mouse_position())


func _add_button(parent: Node, text: String, pos: Vector2, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(600, 130)
	b.add_theme_font_size_override("font_size", 40)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.16, 0.19)
	style.border_color = Color(0.32, 0.34, 0.38)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.20, 0.21, 0.25)
	b.add_theme_stylebox_override("hover", hover)
	if action.is_valid():
		b.pressed.connect(action)
	parent.add_child(b)
	return b


func _start_campaign(night: int) -> void:
	GameState.start_campaign_night(night)
	get_tree().change_scene_to_file("res://scenes/Shift.tscn")


func _start_endless() -> void:
	GameState.start_endless(true)
	get_tree().change_scene_to_file("res://scenes/Shift.tscn")


func _shader(path: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(path)
	mat.set_shader_parameter("aspect", CANVAS.x / CANVAS.y)
	return mat
