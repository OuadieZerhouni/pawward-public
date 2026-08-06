extends Node2D

## PHASE 0 GO/NO-GO HARNESS.
##
## Two questions this scene exists to answer:
##   1. Does a layered still image, moved only by code, feel alive and slightly unsettling?
##   2. Is the anomaly findable in ~5 seconds when you know to look, and missable when you don't?
##
## Controls:
##   mouse            pupils track the cursor
##   SPACE (hold)     show the anomaly variant  — the flip test, at real screen scale
##   1 / 2 / 3        pick which anomaly variant to flip to
##   G                toggle the grain + vignette overlay
##
## It loads real art from res://assets/creatures/axolotl_01/ when present and falls back to
## procedurally drawn placeholders, so the motion can be judged before any slicing is done.

const CREATURE_DIR := "res://assets/creatures/axolotl_01/"
const CANVAS := 1024
## Logical canvas — must match display/window/size/viewport_* in project.godot.
const CANVAS_SIZE := Vector2(1080, 1920)
const LAYER_NAMES := ["shadow", "body", "head", "eye_l", "eye_r", "pupil_l", "pupil_r", "jaw"]
const ANOMALY_IDS := ["doubled_pupils", "too_many_teeth", "third_eye"]
const SKIN := Color(0.93, 0.72, 0.78)

var _patient: Patient
var _overlay: ColorRect
var _status: Label
var _using_placeholders := false
var _anomaly_index := 0
var _showing_anomaly := false
var _creature: Dictionary = {}
var _anomalies: Array = []


func _ready() -> void:
	_build_background()
	_build_overlay()
	_build_status()

	_creature = _load_or_fake_creature()
	_patient = Patient.new()
	_patient.name = "Patient"
	# Centre the 1024 canvas in the portrait viewport, biased upward so the creature sits
	# where the intake window will be rather than dead centre.
	_patient.position = Vector2((CANVAS_SIZE.x - CANVAS) * 0.5, 330)
	add_child(_patient)
	_apply(0, false)
	_refresh_status()


func _build_background() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.062, 0.078)
	bg.size = CANVAS_SIZE
	bg.z_index = -100
	add_child(bg)

	# A warm pool of lamplight so the creature is lit rather than floating in void. Radial
	# and additive — a flat rect leaves visible seams where its edges land.
	var lamp := ColorRect.new()
	lamp.size = CANVAS_SIZE
	lamp.z_index = -99
	lamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lamp_mat := ShaderMaterial.new()
	lamp_mat.shader = load("res://shaders/lamp_glow.gdshader")
	lamp_mat.set_shader_parameter("aspect", CANVAS_SIZE.x / CANVAS_SIZE.y)
	lamp.material = lamp_mat
	add_child(lamp)


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)

	_overlay = ColorRect.new()
	_overlay.size = CANVAS_SIZE
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/grain_vignette.gdshader")
	mat.set_shader_parameter("aspect", CANVAS_SIZE.x / CANVAS_SIZE.y)
	_overlay.material = mat
	layer.add_child(_overlay)


func _build_status() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_status = Label.new()
	_status.position = Vector2(28, 28)
	_status.add_theme_font_size_override("font_size", 26)
	_status.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	layer.add_child(_status)


func _process(_delta: float) -> void:
	if _patient != null:
		_patient.look_at_point(get_global_mouse_position())


func _input(event: InputEvent) -> void:
	if event is not InputEventKey:
		return
	var key := event as InputEventKey

	if key.keycode == KEY_SPACE:
		if key.pressed != _showing_anomaly:
			_apply(_anomaly_index, key.pressed)
			_refresh_status()
		return

	if not key.pressed or key.echo:
		return

	match key.keycode:
		KEY_1, KEY_2, KEY_3:
			_anomaly_index = key.keycode - KEY_1
			_apply(_anomaly_index, _showing_anomaly)
			_refresh_status()
		KEY_G:
			_overlay.visible = not _overlay.visible
			_refresh_status()


func _apply(anomaly_index: int, show_anomaly: bool) -> void:
	_showing_anomaly = show_anomaly
	var anomaly: Dictionary = {}
	if show_anomaly and anomaly_index < _anomalies.size():
		anomaly = _anomalies[anomaly_index]
	_patient.build(_creature, anomaly)


func _refresh_status() -> void:
	var source := "PLACEHOLDER ART" if _using_placeholders else "real art"
	var which := "BASE"
	if _showing_anomaly:
		var id := "?"
		if _anomaly_index < ANOMALY_IDS.size():
			id = ANOMALY_IDS[_anomaly_index]
		which = "ANOMALY: %s" % id
	var grain := "on" if _overlay.visible else "off"
	_status.text = "%s  |  %s\nhold SPACE to flip  ·  1/2/3 pick anomaly  ·  G grain %s" % [
		source, which, grain,
	]


# --- creature spec loading ---------------------------------------------------------

func _load_or_fake_creature() -> Dictionary:
	if ResourceLoader.exists(CREATURE_DIR + "base_head.png"):
		_using_placeholders = false
		return _real_creature()
	_using_placeholders = true
	return _fake_creature()


func _real_creature() -> Dictionary:
	var layers := {}
	for layer_name in LAYER_NAMES:
		var path := CREATURE_DIR + "base_%s.png" % layer_name
		if ResourceLoader.exists(path):
			layers[layer_name] = path

	_anomalies = []
	for id in ANOMALY_IDS:
		var overrides := {}
		for layer_name in LAYER_NAMES:
			var path := CREATURE_DIR + "anom_%s_%s.png" % [id, layer_name]
			if ResourceLoader.exists(path):
				overrides[layer_name] = path
		if not overrides.is_empty():
			_anomalies.append({"id": id, "overrides": overrides})

	var frames := {}
	if ResourceLoader.exists(CREATURE_DIR + "frame_blink.png"):
		frames["blink"] = CREATURE_DIR + "frame_blink.png"

	return {
		"id": "axolotl_01",
		"species": "axolotl",
		"layers": layers,
		"frames": frames,
		"rig": {"head_pivot": [512, 620], "pupil_radius": 9},
	}


## Placeholder art is generated by the shared PlaceholderArt generator, so this harness and
## the real game show the same stand-ins and there is only one thing to replace when art lands.
func _fake_creature() -> Dictionary:
	var creature := PlaceholderArt.creature("axolotl", ANOMALY_IDS)
	_anomalies = creature.get("anomalies", [])
	return creature
