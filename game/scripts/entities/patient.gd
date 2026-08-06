class_name Patient
extends Node2D

## A creature at the intake window. Builds itself from a manifest entry, so adding creatures
## never means touching this file.
##
## THREE LAYERS, NOT EIGHT. An earlier design sliced body/head/eyes/jaw/shadow separately so each
## could animate independently. Almost all of that was unnecessary: of the four idle motions,
## only the pupils genuinely need their own geometry.
##
##     breathing   whole creature, scale.y about its feet
##     sway        whole creature, small rotation about its feet
##     blink       swap the body texture for an eyes-closed render
##     mouth       swap the body texture for a mouth-open render
##     pupils      translate independently   <-- the only motion needing a separate layer
##
## So: one body layer (rendered with BLANK eyes), two pupil layers on top. Fewer moving parts,
## no seams between slices, and the slicing is fully automatic.
##
## Every layer is a full-canvas PNG, so they register with each other for free and an anomaly is
## nothing but a texture override. Anomalous patients therefore run the IDENTICAL animation stack
## as healthy ones — otherwise players would learn to spot anomalies by their motion instead of
## by looking at the creature.

const CANVAS := 1024.0

# Idle motion. Small numbers on purpose: this should read as breathing, not bobbing.
const BREATH_AMPLITUDE := 0.012
const BREATH_RATE := 1.4
const SWAY_AMPLITUDE := 0.011
const SWAY_RATE := 0.6
const BLINK_DURATION := 0.13
const BLINK_INTERVAL := Vector2(3.0, 7.0)
const MOUTH_DURATION := 0.5
const MOUTH_INTERVAL := Vector2(9.0, 18.0)
const PUPIL_LERP_SPEED := 6.0

var spec: Dictionary = {}
var pupil_travel := 12.0
var blink_enabled := true
var pupil_tracking_enabled := true
var breathing_enabled := true

var _pivot: Node2D
var _body: Sprite2D
var _pupils: Array[Sprite2D] = []
var _pupil_home: Array[Vector2] = []

var _tex_body: Texture2D
var _tex_blink: Texture2D
var _tex_mouth: Texture2D

var _time := 0.0
var _blink_timer := 0.0
var _blink_remaining := 0.0
var _mouth_timer := 0.0
var _mouth_remaining := 0.0
var _pupil_target := Vector2.ZERO
var _canvas_size := Vector2(CANVAS, CANVAS)

## Actual pixel size of this creature's layers, read from the loaded texture. Callers must use
## this rather than assuming a constant: the roster is authored at 1536 but the placeholder
## generator emits 1024, and a mismatch silently mis-scales and off-centres the creature.
var canvas_size: Vector2:
	get: return _canvas_size


func _ready() -> void:
	_blink_timer = randf_range(BLINK_INTERVAL.x, BLINK_INTERVAL.y)
	_mouth_timer = randf_range(MOUTH_INTERVAL.x, MOUTH_INTERVAL.y)


## `creature` is a roster.json entry; `anomaly` is one of its anomalies, or {} for a healthy one.
func build(creature: Dictionary, anomaly: Dictionary = {}) -> void:
	spec = creature
	for child in get_children():
		child.queue_free()
	_pupils.clear()
	_pupil_home.clear()

	var layers: Dictionary = creature.get("layers", {}).duplicate()
	var frames: Dictionary = creature.get("frames", {}).duplicate()
	var rig: Dictionary = creature.get("rig", {})

	# Art anomalies override whichever layers/frames they touch.
	for name in anomaly.get("overrides", {}):
		var value = anomaly["overrides"][name]
		if name in ["blink", "mouth_open"]:
			frames[name] = value
		else:
			layers[name] = value

	_tex_body = _texture(layers.get("body", layers.get("head", "")))
	_tex_blink = _texture(frames.get("blink", ""))
	_tex_mouth = _texture(frames.get("mouth_open", ""))
	if _tex_body != null:
		_canvas_size = _tex_body.get_size()

	# Pivot sits at the creature's feet so breathing and sway are anchored where it stands.
	_pivot = Node2D.new()
	_pivot.name = "Pivot"
	_pivot.position = Vector2(_canvas_size.x * 0.5, _canvas_size.y)
	add_child(_pivot)
	var offset := -_pivot.position

	_body = Sprite2D.new()
	_body.name = "Body"
	_body.centered = false
	_body.position = offset
	_body.texture = _tex_body
	_pivot.add_child(_body)

	# Pupil positions come from the slicer's measurement of the actual render, not a per-species
	# guess, so eye tracking is correct on a moth and a capybara alike.
	var homes: Array = rig.get("pupils", [])
	pupil_travel = float(rig.get("pupil_travel", 12.0))
	for i in range(2):
		var key := "pupil_l" if i == 0 else "pupil_r"
		if not layers.has(key):
			continue
		var sprite := Sprite2D.new()
		sprite.name = key.to_pascal_case()
		sprite.centered = false
		sprite.position = offset
		sprite.texture = _texture(layers[key])
		_pivot.add_child(sprite)
		_pupils.append(sprite)
		_pupil_home.append(offset)
		# `homes` is informational for tools/hints; the layers are already full-canvas so the
		# sprite needs no per-pupil positioning of its own.
		if i < homes.size():
			pass

	# Zero-art anomalies subvert the animation rather than the art.
	var params: Dictionary = anomaly.get("params", {})
	blink_enabled = not bool(params.get("blink_disabled", false))
	pupil_tracking_enabled = not bool(params.get("pupil_tracking_disabled", false))
	breathing_enabled = not bool(params.get("breathing_disabled", false))

	_blink_remaining = 0.0
	_mouth_remaining = 0.0
	_apply_body_texture()


func _texture(source: Variant) -> Texture2D:
	if source is Texture2D:
		return source
	var path := str(source)
	if path != "" and ResourceLoader.exists(path):
		return load(path)
	if path != "":
		push_warning("Patient: missing texture %s" % path)
	return null


func _process(delta: float) -> void:
	_time += delta

	if _pivot != null:
		# A creature that does not breathe at all is a tier-3 anomaly, so this is gated rather
		# than always-on. Held at rest instead of frozen mid-cycle to avoid a visible snap.
		var breath := 1.0
		if breathing_enabled:
			breath = 1.0 + BREATH_AMPLITUDE * sin(_time * BREATH_RATE)
		_pivot.scale = Vector2(1.0, breath)
		_pivot.rotation = SWAY_AMPLITUDE * sin(_time * SWAY_RATE)

	_update_frames(delta)
	_update_pupils(delta)


## Blink and mouth are body-texture swaps. Blink wins when both want the body, because closed
## eyes with a moving mouth underneath reads as a glitch.
func _update_frames(delta: float) -> void:
	if _blink_remaining > 0.0:
		_blink_remaining -= delta
		if _blink_remaining <= 0.0:
			_apply_body_texture()
	elif blink_enabled and _tex_blink != null:
		_blink_timer -= delta
		if _blink_timer <= 0.0:
			_blink_timer = randf_range(BLINK_INTERVAL.x, BLINK_INTERVAL.y)
			_blink_remaining = BLINK_DURATION
			_apply_body_texture()

	if _mouth_remaining > 0.0:
		_mouth_remaining -= delta
		if _mouth_remaining <= 0.0:
			_apply_body_texture()
	elif _tex_mouth != null and _blink_remaining <= 0.0:
		_mouth_timer -= delta
		if _mouth_timer <= 0.0:
			_mouth_timer = randf_range(MOUTH_INTERVAL.x, MOUTH_INTERVAL.y)
			_mouth_remaining = MOUTH_DURATION
			_apply_body_texture()


func _apply_body_texture() -> void:
	if _body == null:
		return
	var blinking := _blink_remaining > 0.0
	if blinking and _tex_blink != null:
		_body.texture = _tex_blink
	elif _mouth_remaining > 0.0 and _tex_mouth != null:
		_body.texture = _tex_mouth
	else:
		_body.texture = _tex_body
	# Pupils must vanish behind closed lids, or they float over the eyelids.
	for p in _pupils:
		p.visible = not blinking


func _update_pupils(delta: float) -> void:
	if _pupils.is_empty():
		return
	var wanted := Vector2.ZERO
	if pupil_tracking_enabled:
		wanted = _pupil_target.limit_length(pupil_travel)
	for i in range(_pupils.size()):
		var sprite := _pupils[i]
		sprite.position = sprite.position.lerp(_pupil_home[i] + wanted, PUPIL_LERP_SPEED * delta)


## Point the pupils at a global position (the player's finger). Eyes that follow you are the one
## effect that makes these creatures feel present rather than drawn.
func look_at_point(global_point: Vector2) -> void:
	if _pivot == null:
		return
	var local := _pivot.to_local(global_point)
	if local.length() < 1.0:
		_pupil_target = Vector2.ZERO
		return
	# Scale by proximity so a finger near the face pulls the pupils further than one at the edge.
	var reach := clampf(local.length() / (_canvas_size.x * 0.6), 0.0, 1.0)
	_pupil_target = local.normalized() * pupil_travel * reach
