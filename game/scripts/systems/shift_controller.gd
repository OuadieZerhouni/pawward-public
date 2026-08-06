extends Node2D

## The core loop. One patient at a time:
##   PATIENT_ENTER -> INSPECT -> VERDICT -> CONSEQUENCE -> (next | SHIFT_END)
##
## The screen is composed in code rather than authored in a .tscn. That is deliberate for this
## project: layout is driven by data (strike count, hint count, mode) and there is no artist
## editing scenes, so a script keeps the single source of truth in one readable place.
##
## Input is only accepted during INSPECT. Every other state ignores stamps, which is what stops
## a double-tap during the consequence beat from judging the *next* patient.

enum State { PATIENT_ENTER, INSPECT, VERDICT, CONSEQUENCE, SHIFT_END }

const CANVAS := Vector2(1080, 1920)
const CREATURE_CANVAS := 1024
const BACKDROP_STEM := "res://assets/backdrops/clinic_night"
const BACKDROP_META := "res://assets/backdrops/clinic_night.json"
## Extensions to try, in order. Hardcoding ".png" here silently blanked the entire clinic when the
## assets were converted to WebP — the room simply stopped loading and the creature floated in
## black. Resolving at runtime makes a format change a non-event.
const IMAGE_EXTS := [".webp", ".png"]

## Fallback opening if the backdrop metadata is missing, so the scene still runs.
const DEFAULT_OPENING := Rect2(266, 549, 536, 649)

## Creature canvas width as a multiple of the opening width. Above 1.0 because the animal only
## occupies the middle ~60% of its 1024 canvas, so scaling the canvas to exactly the opening
## would leave the creature small and marooned in the middle of the glass.
const CREATURE_FILL := 1.35

## Vertical layout below the hatch. The hatch ends around y=1198 and the screen is 1920, so
## these three bands consume everything that is left and are kept as constants to make an
## overlap obvious rather than emergent.
const TOOLBAR_Y := 1206.0
const CHART_Y := 1292.0
const STAMPS_Y := 1706.0

var _opening := DEFAULT_OPENING
var _patient_home := Vector2.ZERO
var _patient_scale := 1.0
var _window_clip: Control

const OK_COLOR := Color(0.36, 0.62, 0.42)
const BAD_COLOR := Color(0.68, 0.28, 0.30)

var state: State = State.PATIENT_ENTER

var _patient: Patient
var _chart: ChartPanel
var _grain: ColorRect
var _glitch: ColorRect
var _lamp: ColorRect
var _camera: Camera2D
var _strike_dots: Array[ColorRect] = []
var _score_label: Label
var _queue_label: Label
var _night_label: Label
var _hint_button: Button
var _admit_button: Button
var _reject_button: Button
var _banner: Label
var _creature_highlight: ColorRect
var _shake := 0.0

# Inspection tools. Which ones exist is per-night data, so the toolbar grows across the campaign
# without any code branching on night numbers.
var _tools: Array = []
var _tool_buttons: Dictionary = {}
var _xray_sprite: Sprite2D
var _xray_reference: TextureRect
var _xray_reference_label: Label
var _scanline: ColorRect
var _xray_on := false
var _handbook: HandbookPanel
var _listening := false
var _coach: Coach
var _pause_button: Button
var _pause_root: Control
var _abandon_button: Button
var _abandon_armed := false
var _settings: SettingsPanel
var _weather: ColorRect


func _ready() -> void:
	_build_scene()

	GameState.strike_added.connect(_on_strike_added)
	GameState.score_changed.connect(_on_score_changed)
	GameState.shift_over.connect(_on_shift_over)

	AudioBus.play_music()
	_refresh_hud()
	_present_next_patient()


# --- construction -------------------------------------------------------------------

func _build_scene() -> void:
	_load_room()

	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.062, 0.078)
	bg.size = CANVAS
	bg.z_index = -100
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# The clinic wall with its service hatch. The patient is clipped to the hatch below, which
	# is what makes it read as an animal at a window instead of a sprite on a background.
	var backdrop := _resolve_image(BACKDROP_STEM)
	if backdrop != "":
		var room := Sprite2D.new()
		room.texture = load(backdrop)
		room.centered = false
		room.z_index = -90
		add_child(room)

	_lamp = ColorRect.new()
	_lamp.size = CANVAS
	_lamp.z_index = -80
	_lamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lamp.material = _shader_material("res://shaders/lamp_glow.gdshader")
	# Match the painted desk lamp's position and warmth rather than lighting from nowhere.
	var lamp_mat := _lamp.material as ShaderMaterial
	lamp_mat.set_shader_parameter("centre", Vector2(0.16, 0.60))
	lamp_mat.set_shader_parameter("radius", 0.95)
	lamp_mat.set_shader_parameter("strength", 0.10)
	add_child(_lamp)

	_camera = Camera2D.new()
	_camera.position = CANVAS * 0.5
	_camera.ignore_rotation = true
	add_child(_camera)

	# clip_contents on a Control clips its canvas children, which is the cheapest way to mask
	# the creature to the hatch — no SubViewport, no light-mask shader.
	_window_clip = Control.new()
	_window_clip.position = _opening.position
	_window_clip.size = _opening.size
	_window_clip.clip_contents = true
	_window_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_window_clip.z_index = -70
	add_child(_window_clip)

	_patient = Patient.new()
	_patient.name = "Patient"
	_patient.scale = Vector2(_patient_scale, _patient_scale)
	_window_clip.add_child(_patient)

	# The X-ray plate occupies the same hatch as the creature and simply swaps in. Sharing the
	# clip rect is what makes the scan feel like the same window rather than a separate screen.
	_xray_sprite = Sprite2D.new()
	_xray_sprite.name = "XRay"
	_xray_sprite.centered = false
	_xray_sprite.visible = false
	_window_clip.add_child(_xray_sprite)

	# Weather lives inside the hatch, on top of whatever is in it. The player is standing inside
	# the clinic — rain drawn across the interior wall and the desk lamp reads as a rendering bug.
	_weather = ColorRect.new()
	_weather.size = _opening.size
	_weather.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_weather.material = _shader_material("res://shaders/rain.gdshader")
	var wm := _weather.material as ShaderMaterial
	wm.set_shader_parameter("aspect", _opening.size.x / _opening.size.y)
	# Columns scale with the opening so drops stay the same apparent width as the hatch changes.
	wm.set_shader_parameter("columns", maxf(24.0, _opening.size.x / 7.0))
	_window_clip.add_child(_weather)

	_scanline = ColorRect.new()
	_scanline.color = Color(0.62, 0.85, 1.0, 0.30)
	_scanline.size = Vector2(_opening.size.x, 10)
	_scanline.visible = false
	_scanline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_window_clip.add_child(_scanline)
	_apply_weather()

	_creature_highlight = ColorRect.new()
	_creature_highlight.color = Color(1.0, 0.85, 0.30, 0.30)
	_creature_highlight.visible = false
	_creature_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_creature_highlight)

	_build_hud()
	_build_chart()
	_build_tools()
	_build_stamps()
	_build_overlays()
	_build_handbook()
	_build_coach()
	_build_pause()


## Read where the hatch is from the backdrop's sidecar JSON, and work out how to fit a
## 1024-canvas creature into it. Derived rather than hardcoded so a regenerated backdrop
## re-frames the game automatically instead of needing these numbers re-measured by hand.
func _load_room() -> void:
	if FileAccess.file_exists(BACKDROP_META):
		var json := JSON.new()
		if json.parse(FileAccess.get_file_as_string(BACKDROP_META)) == OK and json.data is Dictionary:
			var rect: Array = json.data.get("opening", [])
			if rect.size() == 4:
				_opening = Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))

	_layout_patient(Vector2(CREATURE_CANVAS, CREATURE_CANVAS))


## Work out the creature's scale and resting position from the size of the art that actually
## loaded, not from a constant. The roster is authored at 1536 while the placeholder generator
## emits 1024; assuming either one silently mis-scales the other and pushes it off-centre.
func _layout_patient(canvas: Vector2) -> void:
	_patient_scale = (_opening.size.x / maxf(canvas.x, 1.0)) * CREATURE_FILL
	var scaled := canvas * _patient_scale
	# Sit the creature on the bottom of the opening: the sill is painted there, so aligning to the
	# base is what makes it look like it is standing behind the counter.
	_patient_home = Vector2(
		(_opening.size.x - scaled.x) * 0.5,
		_opening.size.y - scaled.y * 0.94,
	)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

	_night_label = Label.new()
	_night_label.position = Vector2(40, 36)
	_night_label.add_theme_font_size_override("font_size", 34)
	_night_label.add_theme_color_override("font_color", Color(0.78, 0.80, 0.84))
	layer.add_child(_night_label)

	_score_label = Label.new()
	_score_label.position = Vector2(40, 82)
	_score_label.add_theme_font_size_override("font_size", 28)
	_score_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.70))
	layer.add_child(_score_label)

	_queue_label = Label.new()
	_queue_label.position = Vector2(40, 120)
	_queue_label.add_theme_font_size_override("font_size", 28)
	_queue_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.70))
	layer.add_child(_queue_label)

	# Strike dots fill in rather than counting down: seeing the empty slots is what creates
	# the dread, and it makes the fail condition legible without any text.
	for i in range(GameState.max_strikes):
		var dot := ColorRect.new()
		dot.size = Vector2(34, 34)
		dot.position = Vector2(CANVAS.x - 60 - i * 48, 40)
		dot.color = Color(0.22, 0.23, 0.26)
		layer.add_child(dot)
		_strike_dots.append(dot)

	_hint_button = Button.new()
	_hint_button.position = Vector2(CANVAS.x - 250, 100)
	_hint_button.size = Vector2(210, 62)
	_hint_button.add_theme_font_size_override("font_size", 26)
	_hint_button.pressed.connect(_on_hint_pressed)
	layer.add_child(_hint_button)

	_banner = Label.new()
	_banner.size = Vector2(CANVAS.x, 90)
	_banner.position = Vector2(0, 1030)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 44)
	_banner.modulate.a = 0.0
	layer.add_child(_banner)


func _build_chart() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 4
	add_child(layer)
	_chart = ChartPanel.new()
	_chart.position = Vector2(70, CHART_Y)
	_chart.size = ChartPanel.PANEL_SIZE
	layer.add_child(_chart)


## One button per unlocked tool, laid out from the night's `tools` list. The chart is always on
## screen so it gets no button.
func _build_tools() -> void:
	_tools = Difficulty.tools_for(_night_config())

	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)

	var usable: Array = []
	for t in _tools:
		if t != "chart":
			usable.append(t)

	if not usable.is_empty():
		var gap := 16.0
		var width: float = (CANVAS.x - 140.0 - gap * (usable.size() - 1)) / float(usable.size())
		for i in range(usable.size()):
			var tool_id: String = usable[i]
			var b := Button.new()
			b.text = Difficulty.tool_label(tool_id)
			b.position = Vector2(70 + i * (width + gap), TOOLBAR_Y)
			b.size = Vector2(width, 74)
			b.add_theme_font_size_override("font_size", 30)
			var style := StyleBoxFlat.new()
			style.bg_color = Color(0.13, 0.15, 0.19)
			style.border_color = Color(0.36, 0.44, 0.52)
			style.set_border_width_all(2)
			style.set_corner_radius_all(8)
			b.add_theme_stylebox_override("normal", style)
			var hover := style.duplicate() as StyleBoxFlat
			hover.bg_color = Color(0.19, 0.22, 0.28)
			b.add_theme_stylebox_override("hover", hover)
			b.pressed.connect(_on_tool_pressed.bind(tool_id))
			layer.add_child(b)
			_tool_buttons[tool_id] = b

	# Reference plate inset, only shown while scanning: the species' NORMAL skeleton, small,
	# beside the live plate. Comparing the two is the skeleton mechanic, so both must be
	# visible at once or a subtle bone anomaly is pure guesswork.
	_xray_reference = TextureRect.new()
	_xray_reference.position = Vector2(CANVAS.x - 244, _opening.position.y + 10)
	_xray_reference.size = Vector2(212, 212)
	_xray_reference.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_xray_reference.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_xray_reference.visible = false
	_xray_reference.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_xray_reference)

	_xray_reference_label = Label.new()
	_xray_reference_label.text = "NORMAL"
	_xray_reference_label.position = _xray_reference.position + Vector2(0, -34)
	_xray_reference_label.size = Vector2(212, 30)
	_xray_reference_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_xray_reference_label.add_theme_font_size_override("font_size", 24)
	_xray_reference_label.add_theme_color_override("font_color", Color(0.62, 0.78, 0.92))
	_xray_reference_label.visible = false
	layer.add_child(_xray_reference_label)


## The coach exists only for the onboarding night. Building it conditionally rather than
## building it always and hiding it keeps every later night completely free of tutorial code.
func _build_coach() -> void:
	if GameState.mode != GameState.Mode.CAMPAIGN or GameState.night != 0:
		return
	var layer := CanvasLayer.new()
	layer.layer = 7
	add_child(layer)
	_coach = Coach.new()
	# Night 0 unlocks no tools, so the toolbar band is empty and the line can live there
	# instead of over the painted wall.
	_coach.position = Vector2(70, TOOLBAR_Y - 4)
	layer.add_child(_coach)


func _build_handbook() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 12
	add_child(layer)
	_handbook = HandbookPanel.new()
	_handbook.position = Vector2(60, 330)
	layer.add_child(_handbook)


func _night_config() -> Dictionary:
	if GameState.mode == GameState.Mode.ENDLESS:
		return Difficulty.endless_config(GameState.wave)
	return Difficulty.night_config(GameState.night)


func _on_tool_pressed(tool_id: String) -> void:
	if state != State.INSPECT:
		return
	match tool_id:
		"xray":
			_toggle_xray()
		"stethoscope":
			_use_stethoscope()
		"handbook":
			_toggle_handbook()


## Swap the hatch between the creature and its radiograph, with a sweep across the plate.
func _toggle_xray() -> void:
	var spec := GameState.current
	if spec == null:
		return
	_xray_on = not _xray_on

	if _xray_on:
		_xray_sprite.texture = _as_texture(spec.xray_source)
		if _xray_sprite.texture == null:
			# No plate for this creature. Say so rather than showing an empty window, which
			# would read as a bug — or worse, be mistaken for an anomaly.
			_xray_on = false
			_flash_banner("SCANNER FOUND NOTHING", BAD_COLOR)
			return
		_fit_xray()
		_xray_sprite.visible = true
		_patient.visible = false
		_xray_reference.texture = _as_texture(spec.creature.get("xray", ""))
		_xray_reference.visible = _xray_reference.texture != null
		_xray_reference_label.visible = _xray_reference.visible
		AudioBus.play("static", -20.0, 0.02)
		_sweep_scanline()
	else:
		_xray_sprite.visible = false
		_scanline.visible = false
		_xray_reference.visible = false
		_xray_reference_label.visible = false
		_patient.visible = true
	_refresh_tool_states()


## Cover the hatch regardless of the plate's aspect, so no wall shows through behind it.
func _fit_xray() -> void:
	var tex := _xray_sprite.texture
	if tex == null:
		return
	var fit: float = maxf(_opening.size.x / float(tex.get_width()),
			_opening.size.y / float(tex.get_height()))
	_xray_sprite.scale = Vector2(fit, fit)
	_xray_sprite.position = Vector2(
		(_opening.size.x - tex.get_width() * fit) * 0.5,
		(_opening.size.y - tex.get_height() * fit) * 0.5)


func _sweep_scanline() -> void:
	_scanline.visible = true
	_scanline.position = Vector2(0, 0)
	var t := create_tween()
	t.tween_property(_scanline, "position:y", _opening.size.y, 0.7).set_trans(Tween.TRANS_SINE)
	t.tween_callback(func(): _scanline.visible = false)


## Listen to the patient. The cue is the entire tell, so the visual is only an indicator that
## something is playing — the player has to actually listen to it.
func _use_stethoscope() -> void:
	var spec := GameState.current
	if _listening or spec == null:
		return
	_listening = true
	var button: Button = _tool_buttons.get("stethoscope")
	if button != null:
		button.text = "listening..."
	AudioBus.play_heart(spec.heart_cue)
	var t := create_tween()
	t.tween_interval(3.2)
	t.tween_callback(func():
		_listening = false
		if button != null:
			button.text = Difficulty.tool_label("stethoscope"))


func _toggle_handbook() -> void:
	if _handbook.visible:
		_handbook.close_book()
	else:
		_handbook.show_for(GameState.current)


func _refresh_tool_states() -> void:
	var b: Button = _tool_buttons.get("xray")
	if b != null:
		b.text = "Hide X-Ray" if _xray_on else Difficulty.tool_label("xray")


func _as_texture(source: Variant) -> Texture2D:
	if source is Texture2D:
		return source
	var path := str(source)
	if path != "" and ResourceLoader.exists(path):
		return load(path)
	return null


## Pause. Uses the SceneTree's own pause so tweens, the idle animation and the speed-bonus clock
## all stop together — hand-rolled pausing would leave the scoring clock running while the game
## sat still, quietly punishing the player for stopping.
func _build_pause() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 14
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)

	_pause_button = Button.new()
	_pause_button.text = "II"
	_pause_button.position = Vector2(CANVAS.x - 250, 172)
	_pause_button.size = Vector2(96, 62)
	_pause_button.add_theme_font_size_override("font_size", 26)
	_pause_button.pressed.connect(_open_pause)
	layer.add_child(_pause_button)

	_pause_root = Control.new()
	_pause_root.size = CANVAS
	_pause_root.visible = false
	layer.add_child(_pause_root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.04, 0.86)
	dim.size = CANVAS
	_pause_root.add_child(dim)

	var heading := Label.new()
	heading.text = "PAUSED"
	heading.size = Vector2(CANVAS.x, 90)
	heading.position = Vector2(0, 300)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 64)
	heading.add_theme_color_override("font_color", Color(0.88, 0.90, 0.92))
	_pause_root.add_child(heading)

	var y := 520.0
	_pause_button_at(_pause_root, "Resume", y, _close_pause)
	y += 160.0
	_pause_button_at(_pause_root, "Settings", y, func():
		_settings.open_panel())
	y += 160.0
	_abandon_button = _pause_button_at(_pause_root, "Abandon shift", y, _abandon)

	_settings = SettingsPanel.new()
	_settings.position = Vector2(90, 340)
	_settings.closed.connect(func(): _apply_scare_setting())
	layer.add_child(_settings)


func _pause_button_at(parent: Node, text: String, y: float, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = Vector2(240, y)
	b.size = Vector2(600, 120)
	b.add_theme_font_size_override("font_size", 38)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.16, 0.19)
	style.border_color = Color(0.32, 0.34, 0.38)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.20, 0.21, 0.25)
	b.add_theme_stylebox_override("hover", hover)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _open_pause() -> void:
	if state == State.SHIFT_END:
		return
	_pause_root.visible = true
	_abandon_armed = false
	_abandon_button.text = "Abandon shift"
	get_tree().paused = true


func _close_pause() -> void:
	_settings.close_panel()
	_pause_root.visible = false
	get_tree().paused = false


## Two presses to abandon. One mis-tap should not discard a shift the player was most of the way
## through.
func _abandon() -> void:
	if not _abandon_armed:
		_abandon_armed = true
		_abandon_button.text = "Tap again to abandon"
		return
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/Title.tscn")


## Reduce-scare can be toggled mid-shift, so the vignette has to be re-evaluated on close rather
## than only when a strike lands.
func _apply_scare_setting() -> void:
	_on_strike_added(GameState.strikes)


func _build_stamps() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)

	_reject_button = _make_stamp("REJECT", BAD_COLOR, Vector2(70, STAMPS_Y))
	_reject_button.pressed.connect(func(): _stamp(false))
	layer.add_child(_reject_button)

	_admit_button = _make_stamp("ADMIT", OK_COLOR, Vector2(570, STAMPS_Y))
	_admit_button.pressed.connect(func(): _stamp(true))
	layer.add_child(_admit_button)


func _make_stamp(text: String, color: Color, pos: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(440, 150)
	b.add_theme_font_size_override("font_size", 52)
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	b.add_theme_stylebox_override("normal", style)
	var pressed_style := style.duplicate() as StyleBoxFlat
	pressed_style.bg_color = color.darkened(0.25)
	b.add_theme_stylebox_override("pressed", pressed_style)
	var hover_style := style.duplicate() as StyleBoxFlat
	hover_style.bg_color = color.lightened(0.08)
	b.add_theme_stylebox_override("hover", hover_style)
	return b


func _build_overlays() -> void:
	# Atmosphere goes BELOW the UI (layers 2-3, versus chart 4 / HUD 5 / stamps 6).
	#
	# Overlaying grain and a strong vignette on top of everything looked right on the creature
	# and wrecked the interface: the chart paper went muddy grey and the stamp buttons lost
	# their colour, because both sit at the screen edge where the vignette is heaviest. Reading
	# the chart IS the core mechanic, so legibility beats a uniform filter. The creature still
	# gets the full treatment, which is where the mood actually comes from.
	var glitch_layer := CanvasLayer.new()
	glitch_layer.layer = 2
	add_child(glitch_layer)
	_glitch = ColorRect.new()
	_glitch.size = CANVAS
	_glitch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glitch.material = _shader_material("res://shaders/glitch.gdshader")
	glitch_layer.add_child(_glitch)

	var grain_layer := CanvasLayer.new()
	grain_layer.layer = 3
	add_child(grain_layer)
	_grain = ColorRect.new()
	_grain.size = CANVAS
	_grain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grain.material = _shader_material("res://shaders/grain_vignette.gdshader")
	grain_layer.add_child(_grain)


## Weather comes from the night's data row, so each night has its own feel without any code
## branching on night numbers.
func _apply_weather() -> void:
	var cfg: Dictionary = _night_config().get("weather", {})
	var mat := _weather.material as ShaderMaterial
	mat.set_shader_parameter("amount", float(cfg.get("rain", 0.0)))
	mat.set_shader_parameter("fog", float(cfg.get("fog", 0.0)))


## First existing file for a path stem, across the known image extensions.
func _resolve_image(stem: String) -> String:
	for ext in IMAGE_EXTS:
		if ResourceLoader.exists(stem + ext):
			return stem + ext
	return ""


func _shader_material(path: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(path)
	mat.set_shader_parameter("aspect", CANVAS.x / CANVAS.y)
	return mat


# --- loop ---------------------------------------------------------------------------

func _present_next_patient() -> void:
	var spec := GameState.current
	if spec == null:
		return

	state = State.PATIENT_ENTER
	_set_stamps_enabled(false)
	_creature_highlight.visible = false
	_banner.modulate.a = 0.0

	_reset_zoom()
	_reset_tools()
	if _coach != null:
		_coach.hide_line()
	_patient.build(spec.creature, spec.anomaly)
	_layout_patient(_patient.canvas_size)
	_patient.scale = Vector2(_patient_scale, _patient_scale)
	_chart.show_spec(spec)
	_refresh_hud()

	# Slide in from the right, out to the left, so the queue reads as a queue. Movement is in
	# clip-local space, so a patient slides out of the hatch rather than across the wall.
	_patient.position = _patient_home + Vector2(_travel(), 0)
	AudioBus.play("bell", -7.0)
	var tween := create_tween()
	tween.tween_property(_patient, "position", _patient_home, 0.55) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_callback(func(): AudioBus.play("paper", -12.0)).set_delay(0.3)
	tween.finished.connect(_begin_inspect)


## The physical beat of stamping: the stamp drives down and springs back, and the chart jolts
## as if struck. Cheap, and it is most of the difference between "pressed a button" and
## "stamped a document".
func _punch_stamp(button: Button) -> void:
	var rest: Vector2 = button.position
	var t := create_tween()
	t.tween_property(button, "position", rest + Vector2(0, 16), 0.05).set_trans(Tween.TRANS_QUAD)
	t.tween_property(button, "position", rest, 0.16).set_trans(Tween.TRANS_ELASTIC) 		.set_ease(Tween.EASE_OUT)

	var chart_rest: Vector2 = _chart.position
	var c := create_tween()
	c.tween_property(_chart, "position", chart_rest + Vector2(0, 9), 0.05)
	c.tween_property(_chart, "position", chart_rest, 0.22).set_trans(Tween.TRANS_ELASTIC) 		.set_ease(Tween.EASE_OUT)


## Put every tool back to rest between patients. A scanner left on would show the next
## patient's skeleton before they had even been looked at.
func _reset_tools() -> void:
	_xray_on = false
	_listening = false
	if _xray_sprite != null:
		_xray_sprite.visible = false
	if _scanline != null:
		_scanline.visible = false
	if _xray_reference != null:
		_xray_reference.visible = false
	if _xray_reference_label != null:
		_xray_reference_label.visible = false
	if _patient != null:
		_patient.visible = true
	if _handbook != null:
		_handbook.close_book()
	var st: Button = _tool_buttons.get("stethoscope")
	if st != null:
		st.text = Difficulty.tool_label("stethoscope")
	_refresh_tool_states()


## Far enough for the creature to clear the hatch entirely, in clip-local units.
func _travel() -> float:
	return _opening.size.x + _patient.canvas_size.x * _patient_scale


func _begin_inspect() -> void:
	if state != State.PATIENT_ENTER:
		return
	state = State.INSPECT
	if _coach != null:
		_coach.show_for(GameState.current, GameState.index)
	# The clock for the speed bonus starts now, not when the patient was created — the
	# entrance animation must not be scored against the player.
	GameState.mark_patient_shown()
	_set_stamps_enabled(true)


func _stamp(admit: bool) -> void:
	if state != State.INSPECT:
		return
	state = State.VERDICT
	_set_stamps_enabled(false)
	_chart.clear_highlight()
	_creature_highlight.visible = false

	_punch_stamp(_admit_button if admit else _reject_button)
	AudioBus.play("stamp")
	var spec := GameState.current
	var correct := GameState.register_verdict(admit)
	if _coach != null and not correct:
		_coach.correct(admit, spec)
	_run_consequence(correct, admit, spec)


func _run_consequence(correct: bool, admit: bool, spec: PatientSpec) -> void:
	state = State.CONSEQUENCE

	if correct:
		_flash_banner("CORRECT" if admit else "SENT AWAY", OK_COLOR)
	else:
		if admit:
			# Admitting something wrong is the scary failure: the lights go, the image tears.
			_flash_banner("SOMETHING GOT IN", BAD_COLOR)
			AudioBus.play("static", -3.0)
			AudioBus.play("heartbeat", -4.0)
			_glitch_burst()
			_shake = 1.0
			_lamp_flicker()
		else:
			# Rejecting a healthy patient is the sad failure. Consequence lands on paperwork,
			# never on the animal — that is what keeps this creepy-cute instead of cruel.
			_flash_banner("THAT ONE WAS FINE", BAD_COLOR)
			AudioBus.play("paper", -4.0)
			_chart.show_sad_note("Turned away. It waited outside a while.")

	# Slide the patient out, then hand back to GameState to decide whether the shift goes on.
	var tween := create_tween()
	tween.tween_interval(0.55 if correct else 1.05)
	tween.tween_property(_patient, "position", _patient_home - Vector2(_travel(), 0), 0.45) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.finished.connect(_after_consequence)


func _after_consequence() -> void:
	if state != State.CONSEQUENCE:
		return
	if GameState.advance():
		_present_next_patient()
	# When advance() returns false it has already emitted shift_over; _on_shift_over drives
	# the transition, so there is nothing to do here.


# --- feedback -----------------------------------------------------------------------

func _flash_banner(text: String, color: Color) -> void:
	_banner.text = text
	_banner.add_theme_color_override("font_color", color)
	var tween := create_tween()
	tween.tween_property(_banner, "modulate:a", 1.0, 0.12)
	tween.tween_interval(0.5)
	tween.tween_property(_banner, "modulate:a", 0.0, 0.35)


func _glitch_burst() -> void:
	var mat := _glitch.material as ShaderMaterial
	var tween := create_tween()
	tween.tween_method(func(v: float): mat.set_shader_parameter("intensity", v), 0.0, 1.0, 0.08)
	tween.tween_method(func(v: float): mat.set_shader_parameter("intensity", v), 1.0, 0.0, 0.34)


func _lamp_flicker() -> void:
	var mat := _lamp.material as ShaderMaterial
	var tween := create_tween()
	tween.tween_method(func(v: float): mat.set_shader_parameter("flicker", v), 0.0, 1.0, 0.05)
	tween.tween_interval(0.45)
	tween.tween_method(func(v: float): mat.set_shader_parameter("flicker", v), 1.0, 0.0, 0.3)


func _on_strike_added(strikes: int) -> void:
	for i in range(_strike_dots.size()):
		_strike_dots[i].color = BAD_COLOR if i < strikes else Color(0.22, 0.23, 0.26)
	# The vignette starts breathing as strikes accumulate — the room closing in.
	var mat := _grain.material as ShaderMaterial
	var ratio := float(strikes) / float(maxi(1, GameState.max_strikes))
	mat.set_shader_parameter("vignette_pulse", 0.10 + 0.22 * ratio)
	mat.set_shader_parameter("pulse_rate", 1.2 + 2.2 * ratio)
	if SaveGame.get_value("reduce_scare", false):
		mat.set_shader_parameter("vignette_pulse", 0.0)
		mat.set_shader_parameter("pulse_rate", 0.0)
	Input.vibrate_handheld(90)


func _on_score_changed(score: int) -> void:
	_score_label.text = "Score  %d" % score


func _on_shift_over(passed: bool, stats: Dictionary) -> void:
	state = State.SHIFT_END
	_set_stamps_enabled(false)
	GameState.last_passed = passed
	GameState.last_stats = stats
	# Let the exit tween and banner finish reading before cutting away.
	var t := create_tween()
	t.tween_interval(0.7)
	t.finished.connect(func(): get_tree().change_scene_to_file("res://scenes/ShiftEnd.tscn"))


func _on_hint_pressed() -> void:
	if state != State.INSPECT:
		return
	var hint := GameState.use_hint()
	if hint.is_empty():
		return
	_refresh_hud()

	if not bool(hint.get("has_target", false)):
		_flash_banner("SECOND OPINION: LOOKS FINE", OK_COLOR)
		return

	# Channels whose tell is neither on the creature nor on the chart get named explicitly.
	# Falling through to "check the chart" for a skeleton anomaly actively sends the player to
	# the wrong place.
	var spec_now := GameState.current
	if spec_now != null and spec_now.channel in ["skeleton", "sound"]:
		_flash_banner("SECOND OPINION: USE THE %s" %
				Difficulty.tool_label(spec_now.required_tool).to_upper(), OK_COLOR)
		return

	if bool(hint.get("on_chart", false)):
		var spec := GameState.current
		_chart.highlight_field(str(spec.anomaly.get("params", {}).get("field", "")))
	else:
		var rect: Rect2 = hint.get("rect", Rect2())
		if rect.size == Vector2.ZERO:
			_flash_banner("SECOND OPINION: CHECK THE CHART", OK_COLOR)
			return
		_creature_highlight.position = _opening.position + _patient.position 				+ rect.position * _patient_scale
		_creature_highlight.size = rect.size * _patient_scale
		_creature_highlight.visible = true

	var t := create_tween()
	t.tween_interval(float(Difficulty.hints.get("highlight_seconds", 1.5)))
	t.finished.connect(func():
		_chart.clear_highlight()
		_creature_highlight.visible = false)


func _refresh_hud() -> void:
	if GameState.mode == GameState.Mode.ENDLESS:
		_night_label.text = "Endless — wave %d" % (GameState.wave + 1)
	else:
		_night_label.text = "Night %d" % GameState.night
	_score_label.text = "Score  %d" % GameState.score
	_queue_label.text = "Patients left  %d" % GameState.patients_remaining
	_hint_button.text = "Hint  (%d)" % GameState.hints_left
	_hint_button.disabled = GameState.hints_left <= 0


func _set_stamps_enabled(enabled: bool) -> void:
	_admit_button.disabled = not enabled
	_reject_button.disabled = not enabled


# --- per-frame ----------------------------------------------------------------------

## Zoom is applied to the patient inside the clip rect, NOT to the camera.
##
## Zooming the camera would scale the chart and the stamps with it, and the whole point is to
## lean in on the animal while still reading the paperwork. Panning is clamped so the creature
## can never be dragged out of the hatch and lost.
const ZOOM_RANGE := Vector2(1.0, 2.6)
const ZOOM_STEP := 0.18

var _zoom := 1.0
var _pan := Vector2.ZERO
var _dragging := false
var _touches: Dictionary = {}
var _pinch_start_distance := 0.0
var _pinch_start_zoom := 1.0


func _apply_zoom() -> void:
	_patient.scale = Vector2(_patient_scale * _zoom, _patient_scale * _zoom)
	# Zoom about the centre of the opening, then offset by the pan.
	var scaled := _patient.canvas_size * _patient_scale
	var centre_correction := (scaled * (_zoom - 1.0)) * 0.5
	var slack := Vector2(
		maxf(0.0, scaled.x * _zoom - _opening.size.x) * 0.5,
		maxf(0.0, scaled.y * _zoom - _opening.size.y) * 0.5,
	)
	_pan = _pan.clamp(-slack, slack)
	_patient.position = _patient_home - centre_correction + _pan


func set_zoom(value: float) -> void:
	_zoom = clampf(value, ZOOM_RANGE.x, ZOOM_RANGE.y)
	if is_equal_approx(_zoom, ZOOM_RANGE.x):
		_pan = Vector2.ZERO
	_apply_zoom()


func _reset_zoom() -> void:
	_zoom = 1.0
	_pan = Vector2.ZERO
	_dragging = false
	_touches.clear()
	if _patient != null:
		_patient.scale = Vector2(_patient_scale, _patient_scale)


func _process(delta: float) -> void:
	# Pupils track the finger during inspection only. A patient whose eyes keep following you
	# after you have stamped it undercuts the beat.
	if state == State.INSPECT and not _xray_on:
		_patient.look_at_point(get_global_mouse_position())

	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta * 3.0)
		var amount := _shake * _shake * 14.0
		_camera.offset = Vector2(
			randf_range(-amount, amount), randf_range(-amount, amount))
	elif _camera.offset != Vector2.ZERO:
		_camera.offset = Vector2.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			if _pause_root.visible:
				_close_pause()
			else:
				_open_pause()
			return
	if _pause_root.visible or state != State.INSPECT:
		return

	# --- pinch zoom (two fingers) ---
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touches[touch.index] = touch.position
		else:
			_touches.erase(touch.index)
		if _touches.size() == 2:
			var pts: Array = _touches.values()
			_pinch_start_distance = pts[0].distance_to(pts[1])
			_pinch_start_zoom = _zoom
		return

	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_touches[drag.index] = drag.position
		if _touches.size() == 2 and _pinch_start_distance > 1.0:
			var pts: Array = _touches.values()
			var ratio: float = pts[0].distance_to(pts[1]) / _pinch_start_distance
			set_zoom(_pinch_start_zoom * ratio)
		elif _touches.size() == 1 and _zoom > 1.001:
			_pan += drag.relative
			_apply_zoom()
		return

	# --- mouse: wheel zooms, drag pans (desktop playtesting) ---
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			set_zoom(_zoom + ZOOM_STEP)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			set_zoom(_zoom - ZOOM_STEP)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed and _zoom > 1.001
		return

	if event is InputEventMouseMotion and _dragging:
		_pan += (event as InputEventMouseMotion).relative
		_apply_zoom()
		return

	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		# Keyboard shortcuts for desktop playtesting; the shipped build is touch-only.
		match key.keycode:
			KEY_A, KEY_LEFT:
				_stamp(true)
			KEY_R, KEY_RIGHT:
				_stamp(false)
			KEY_H:
				_on_hint_pressed()
			KEY_X:
				if "xray" in _tools:
					_toggle_xray()
			KEY_S:
				if "stethoscope" in _tools:
					_use_stethoscope()
			KEY_B:
				if "handbook" in _tools:
					_toggle_handbook()
			KEY_EQUAL, KEY_KP_ADD:
				set_zoom(_zoom + ZOOM_STEP)
			KEY_MINUS, KEY_KP_SUBTRACT:
				set_zoom(_zoom - ZOOM_STEP)
