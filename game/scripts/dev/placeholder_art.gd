class_name PlaceholderArt
extends RefCounted

## Procedural stand-in creatures, so the whole game is playable and tunable before any art
## exists. This is what decouples the week-2 code build from the week-1 art pass: Roster
## falls back to these whenever a creature's PNGs are missing, and the swap to real art is
## just files appearing on disk — no code change.
##
## Deliberately crude. It is not trying to look good; it is trying to be *distinguishable*
## per species and to exercise every layer the real pipeline emits, at the same full-canvas
## registration, so difficulty tuning done now still means something later.

const CANVAS := 1024

## Layer set matches the naming law in README.md exactly.
const LAYERS := ["shadow", "body", "head", "eye_l", "eye_r", "pupil_l", "pupil_r", "jaw"]


## Build a complete creature spec (layers + frames + rig + anomalies) for a species name.
## Shape and palette are derived from the species string, so every species looks different
## but the same species always looks the same.
static func creature(species: String, anomaly_ids: Array = []) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(species)

	var hue := rng.randf()
	var skin := Color.from_hsv(hue, rng.randf_range(0.18, 0.42), rng.randf_range(0.72, 0.94))
	var head_w := rng.randf_range(210.0, 275.0)
	var head_h := rng.randf_range(185.0, 235.0)
	var eye_sep := rng.randf_range(70.0, 95.0)
	var eye_r := rng.randf_range(44.0, 58.0)
	var ear_kind := rng.randi_range(0, 2)

	var head_c := Vector2(512, 560)
	var eye_y := head_c.y - 15.0
	var eye_l_c := Vector2(head_c.x - eye_sep, eye_y)
	var eye_r_c := Vector2(head_c.x + eye_sep, eye_y)
	var jaw_c := Vector2(head_c.x, head_c.y + head_h * 0.38)
	var pupil_r := eye_r * 0.46

	# Body is the whole creature with BLANK eyes: the pupils live in their own layers, and if the
	# body kept its pupils they would show through whenever the tracking pupils moved.
	var body := _body_image(skin, head_c, head_w, head_h, ear_kind, eye_l_c, eye_r_c, eye_r,
			jaw_c, false, "")
	var blink := _body_image(skin, head_c, head_w, head_h, ear_kind, eye_l_c, eye_r_c, eye_r,
			jaw_c, true, "")
	var mouth := _body_image(skin, head_c, head_w, head_h, ear_kind, eye_l_c, eye_r_c, eye_r,
			jaw_c, false, "mouth_open")

	var pl := _canvas()
	_blob(pl, eye_l_c + Vector2(0, 3), Vector2(pupil_r, pupil_r * 1.08), Color(0.06, 0.05, 0.09))
	var pr := _canvas()
	_blob(pr, eye_r_c + Vector2(0, 3), Vector2(pupil_r, pupil_r * 1.08), Color(0.06, 0.05, 0.09))

	return {
		"id": species + "_ph",
		"species": species,
		"pack": "core",
		"name_pool": _names(rng),
		"layers": {
			"body": _tex(body),
			"pupil_l": _tex(pl),
			"pupil_r": _tex(pr),
		},
		"frames": {"blink": _tex(blink), "mouth_open": _tex(mouth)},
		"rig": {
			"pupils": [[eye_l_c.x, eye_l_c.y], [eye_r_c.x, eye_r_c.y]],
			"pupil_radius": pupil_r,
			"pupil_travel": pupil_r * 0.55,
		},
		"anomalies": _anomalies(species, anomaly_ids, skin, head_c, head_w, head_h, ear_kind,
				eye_l_c, eye_r_c, eye_r, pupil_r, jaw_c),
		"xray": xray(species),
		"chart": {
			"species_label": species.capitalize(),
			"marks": "Placeholder markings",
			"notes_pool": ["Placeholder note", "Seems calm", "Ate this morning"],
		},
		"handbook": {
			"heart": "A steady, even double thump with calm breathing underneath.",
			"features": [
				"Exactly two eyes, both the same size",
				"Round pupils, one per eye",
				["Side frills", "Upright pointed ears", "Small round ears"][ear_kind],
				"A closed, even mouth with no visible teeth",
				"Breathes slowly and evenly",
				"Blinks every few seconds and follows movement",
			],
		},
		"_placeholder": true,
	}


## One composited creature: shadow, body, head, blank sclera, mouth. `variant` selects an
## alternate frame ("mouth_open") and `eyes_closed` draws lids instead of sclera.
static func _body_image(skin: Color, head_c: Vector2, hw: float, hh: float, ear_kind: int,
		eye_l_c: Vector2, eye_r_c: Vector2, eye_r: float, jaw_c: Vector2,
		eyes_closed: bool, variant: String) -> Image:
	var img := _canvas()
	_blob(img, Vector2(512, 878), Vector2(hw * 1.15, 44), Color(0, 0, 0, 0.34))
	_blob(img, Vector2(512, 762), Vector2(hw * 0.86, 190), skin.darkened(0.06))
	_paint_head_into(img, skin, head_c, hw, hh, ear_kind, false)

	if eyes_closed:
		_blob(img, eye_l_c, Vector2(eye_r * 1.04, eye_r * 1.08), skin.darkened(0.05))
		_blob(img, eye_r_c, Vector2(eye_r * 1.04, eye_r * 1.08), skin.darkened(0.05))
	else:
		_blob(img, eye_l_c, Vector2(eye_r, eye_r * 1.04), Color(0.98, 0.98, 0.99))
		_blob(img, eye_r_c, Vector2(eye_r, eye_r * 1.04), Color(0.98, 0.98, 0.99))

	if variant == "mouth_open":
		_blob(img, jaw_c + Vector2(0, 6), Vector2(58, 26), Color(0.36, 0.18, 0.22))
	else:
		_blob(img, jaw_c, Vector2(44, 11), skin.darkened(0.45))
	return img


static func _anomalies(species: String, ids: Array, skin: Color, head_c: Vector2, hw: float, hh: float,
		ear_kind: int, el: Vector2, er: Vector2, eye_r: float, pupil_r: float,
		jaw_c: Vector2) -> Array:
	var out: Array = []
	for id in ids:
		match id:
			"third_eye":
				var body3 := _body_image(skin, head_c, hw, hh, ear_kind, el, er, eye_r, jaw_c,
						false, "")
				_blob(body3, head_c + Vector2(0, -hh * 0.52), Vector2(36, 38), Color(0.98, 0.98, 0.99))
				_blob(body3, head_c + Vector2(0, -hh * 0.52 + 2), Vector2(16, 18), Color(0.06, 0.05, 0.09))
				out.append({"id": id, "tier": 1, "kind": "layer_swap",
						"overrides": {"body": _tex(body3)},
						"hint_rect": [head_c.x - 46, head_c.y - hh * 0.62, 92, 96]})
			"doubled_pupils":
				var a := _canvas()
				_blob(a, el + Vector2(-pupil_r * 0.55, 3), Vector2(pupil_r * 0.72, pupil_r * 0.9), Color(0.06, 0.05, 0.09))
				_blob(a, el + Vector2(pupil_r * 0.62, 3), Vector2(pupil_r * 0.52, pupil_r * 0.7), Color(0.06, 0.05, 0.09))
				var b := _canvas()
				_blob(b, er + Vector2(pupil_r * 0.55, 3), Vector2(pupil_r * 0.72, pupil_r * 0.9), Color(0.06, 0.05, 0.09))
				_blob(b, er + Vector2(-pupil_r * 0.62, 3), Vector2(pupil_r * 0.52, pupil_r * 0.7), Color(0.06, 0.05, 0.09))
				out.append({"id": id, "tier": 2, "kind": "layer_swap",
						"overrides": {"pupil_l": _tex(a), "pupil_r": _tex(b)},
						"hint_rect": [el.x - eye_r, el.y - eye_r, (er.x - el.x) + eye_r * 2, eye_r * 2]})
			"too_many_teeth":
				var bodyt := _body_image(skin, head_c, hw, hh, ear_kind, el, er, eye_r, jaw_c,
						false, "")
				_blob(bodyt, jaw_c + Vector2(0, 8), Vector2(78, 28), Color(0.40, 0.20, 0.26))
				for i in range(9):
					_blob(bodyt, jaw_c + Vector2(-60 + i * 15, -3), Vector2(5, 9), Color(0.97, 0.97, 0.95))
				out.append({"id": id, "tier": 2, "kind": "layer_swap",
						"overrides": {"body": _tex(bodyt)},
						"hint_rect": [jaw_c.x - 84, jaw_c.y - 30, 168, 68]})
			"too_still":
				out.append({"id": id, "tier": 2, "kind": "behavior",
						"params": {"breathing_disabled": true}})
			"never_blinks":
				out.append({"id": id, "tier": 3, "kind": "behavior", "params": {"blink_disabled": true}})
			"dead_eyes":
				out.append({"id": id, "tier": 3, "kind": "behavior", "params": {"pupil_tracking_disabled": true}})
			"chart_species":
				out.append({"id": id, "tier": 3, "kind": "data", "params": {"field": "species"}})
			"chart_name":
				out.append({"id": id, "tier": 3, "kind": "data", "params": {"field": "name"}})
			# Skeleton anomalies carry their own plate; the healthy plate lives on the creature.
			"foreign_object":
				out.append({"id": id, "tier": 1, "kind": "skeleton",
						"xray": xray(species, id)})
			"second_skull":
				out.append({"id": id, "tier": 1, "kind": "skeleton",
						"xray": xray(species, id)})
			"extra_ribs":
				out.append({"id": id, "tier": 2, "kind": "skeleton",
						"xray": xray(species, id)})
			"extra_vertebra":
				out.append({"id": id, "tier": 3, "kind": "skeleton",
						"xray": xray(species, id)})
			"hollow_limb":
				out.append({"id": id, "tier": 3, "kind": "skeleton",
						"xray": xray(species, id)})
			# Sound anomalies are shared clips, so they are pure data even at final quality.
			"two_hearts":
				out.append({"id": id, "tier": 1, "kind": "sound",
						"params": {"cue": "heart_two_hearts"}})
			"clockwork":
				out.append({"id": id, "tier": 2, "kind": "sound",
						"params": {"cue": "heart_clockwork"}})
			"hollow":
				out.append({"id": id, "tier": 2, "kind": "sound",
						"params": {"cue": "heart_hollow"}})
			"whisper":
				out.append({"id": id, "tier": 3, "kind": "sound",
						"params": {"cue": "heart_whisper"}})
			"too_fast":
				out.append({"id": id, "tier": 3, "kind": "sound",
						"params": {"cue": "heart_too_fast"}})
	return out


## A crude radiograph stand-in: skull, spine, ribs, limbs in pale bone on a dark plate.
##
## Not trying to look like the real generated X-rays — it exists so the scan tool, the skeleton
## anomaly channel and the handbook's skeleton page can all be built and tested before the real
## plates are produced.
static func xray(species: String, anomaly_id: String = "") -> Texture2D:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("xray" + species)

	var img := Image.create(CANVAS, CANVAS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.04, 0.06, 0.11, 1.0))          # plate, opaque unlike the creature layers

	var bone := Color(0.82, 0.88, 0.95, 0.85)
	var faint := Color(0.55, 0.66, 0.80, 0.35)
	var cx := 512.0
	var skull_y := 400.0
	var skull_w := rng.randf_range(120.0, 165.0)
	var rib_count := rng.randi_range(6, 9)
	var spine_top := skull_y + skull_w * 0.85
	var spine_bottom := 830.0

	# Faint body outline, so the plate reads as an animal rather than loose bones.
	_blob(img, Vector2(cx, 600), Vector2(skull_w * 2.1, 300), faint)
	# Skull + eye sockets.
	_blob(img, Vector2(cx, skull_y), Vector2(skull_w, skull_w * 0.86), bone)
	_blob(img, Vector2(cx - skull_w * 0.42, skull_y), Vector2(skull_w * 0.24, skull_w * 0.26),
			Color(0.05, 0.07, 0.12, 0.95))
	_blob(img, Vector2(cx + skull_w * 0.42, skull_y), Vector2(skull_w * 0.24, skull_w * 0.26),
			Color(0.05, 0.07, 0.12, 0.95))

	if anomaly_id == "second_skull":
		_blob(img, Vector2(cx, skull_y + 14), Vector2(skull_w * 0.55, skull_w * 0.48), bone)
		_blob(img, Vector2(cx - skull_w * 0.2, skull_y + 10), Vector2(skull_w * 0.1, skull_w * 0.11),
				Color(0.05, 0.07, 0.12, 0.95))
		_blob(img, Vector2(cx + skull_w * 0.2, skull_y + 10), Vector2(skull_w * 0.1, skull_w * 0.11),
				Color(0.05, 0.07, 0.12, 0.95))

	# Spine as a stack of vertebrae; one extra for the tier-3 anomaly.
	var vertebrae := 9
	if anomaly_id == "extra_vertebra":
		vertebrae += 1
	var step := (spine_bottom - spine_top) / float(vertebrae)
	for i in range(vertebrae):
		var vy := spine_top + step * i
		var kink := 0.0
		if anomaly_id == "extra_vertebra" and i == vertebrae - 3:
			kink = 16.0
		_blob(img, Vector2(cx + kink, vy), Vector2(20, step * 0.34), bone)

	# Ribs, mirrored pairs down the upper spine.
	if anomaly_id == "extra_ribs":
		rib_count += 5
	for i in range(rib_count):
		var t := float(i) / float(maxi(1, rib_count - 1))
		var ry := spine_top + (spine_bottom - spine_top) * 0.12 + t * (spine_bottom - spine_top) * 0.5
		var span := (1.0 - absf(t - 0.4)) * skull_w * 1.5
		_blob(img, Vector2(cx - span * 0.55, ry), Vector2(span * 0.5, 8), bone)
		_blob(img, Vector2(cx + span * 0.55, ry), Vector2(span * 0.5, 8), bone)

	# Limbs.
	for side in [-1.0, 1.0]:
		var hip := Vector2(cx + side * skull_w * 0.7, spine_bottom - 40)
		var limb_bone := bone
		if anomaly_id == "hollow_limb" and side < 0.0:
			limb_bone = Color(0.42, 0.52, 0.66, 0.55)   # darker, no marrow shadow
		_blob(img, hip + Vector2(side * 60, 60), Vector2(70, 12), limb_bone)
		_blob(img, hip + Vector2(side * 110, 140), Vector2(12, 70), limb_bone)

	if anomaly_id == "foreign_object":
		# Something dense and man-made that should not be in an animal.
		_blob(img, Vector2(cx + 40, 690), Vector2(46, 16), Color(1.0, 1.0, 1.0, 0.98))
		_blob(img, Vector2(cx + 76, 690), Vector2(16, 30), Color(1.0, 1.0, 1.0, 0.98))

	return _tex(img)


static func _head(skin: Color, c: Vector2, w: float, h: float, ear_kind: int,
		third_eye: bool) -> Image:
	var img := _canvas()
	_paint_head_into(img, skin, c, w, h, ear_kind, third_eye)
	return img


static func _paint_head_into(img: Image, skin: Color, c: Vector2, w: float, h: float,
		ear_kind: int, third_eye: bool) -> void:
	_blob(img, c, Vector2(w, h), skin)
	match ear_kind:
		0:  # side frills
			_blob(img, c + Vector2(-w * 0.92, -h * 0.28), Vector2(w * 0.30, h * 0.12), skin.lightened(0.12))
			_blob(img, c + Vector2(w * 0.92, -h * 0.28), Vector2(w * 0.30, h * 0.12), skin.lightened(0.12))
		1:  # upright ears
			_blob(img, c + Vector2(-w * 0.52, -h * 0.92), Vector2(w * 0.17, h * 0.34), skin.lightened(0.06))
			_blob(img, c + Vector2(w * 0.52, -h * 0.92), Vector2(w * 0.17, h * 0.34), skin.lightened(0.06))
		2:  # round ears
			_blob(img, c + Vector2(-w * 0.78, -h * 0.66), Vector2(w * 0.24, h * 0.26), skin.lightened(0.06))
			_blob(img, c + Vector2(w * 0.78, -h * 0.66), Vector2(w * 0.24, h * 0.26), skin.lightened(0.06))
	if third_eye:
		var e := c + Vector2(0, -h * 0.52)
		_blob(img, e, Vector2(36, 38), Color(0.98, 0.98, 0.99))
		_blob(img, e + Vector2(0, 2), Vector2(16, 18), Color(0.06, 0.05, 0.09))


static func _names(rng: RandomNumberGenerator) -> Array:
	const POOL := ["Mochi", "Pip", "Bubbles", "Tono", "Sable", "Wren", "Olive", "Nub",
			"Pesto", "Juno", "Bean", "Marlow", "Fig", "Suki", "Dandy", "Moss"]
	var out: Array = []
	for _i in range(3):
		out.append(POOL[rng.randi_range(0, POOL.size() - 1)])
	return out


static func _canvas() -> Image:
	var img := Image.create(CANVAS, CANVAS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img


static func _tex(img: Image) -> Texture2D:
	return ImageTexture.create_from_image(img)


## Soft discs, cached per colour at a small fixed size.
##
## The obvious implementation — walk the blob's bounding box calling set_pixel — is
## unusably slow here: a full roster is ~260 full-canvas images, and per-pixel GDScript on
## regions up to 500x470 works out to over 100M calls (it timed out past two minutes).
## Instead each colour's disc is rasterised ONCE at 64x64, then scaled and composited with
## native `resize` + `blend_rect`. Same look, three orders of magnitude less script work.
const DISC_RES := 64

static var _disc_cache: Dictionary = {}


static func _disc(color: Color) -> Image:
	var key := color.to_rgba32()
	if _disc_cache.has(key):
		return _disc_cache[key]

	var disc := Image.create(DISC_RES, DISC_RES, false, Image.FORMAT_RGBA8)
	var half := DISC_RES * 0.5
	for y in range(DISC_RES):
		for x in range(DISC_RES):
			var dx := (x + 0.5 - half) / half
			var dy := (y + 0.5 - half) / half
			var d := dx * dx + dy * dy
			var a := 0.0
			if d <= 1.0:
				# Feather in normalised space, so the softness scales with the blob.
				a = clampf((1.0 - d) * 3.5, 0.0, 1.0) * color.a
			disc.set_pixel(x, y, Color(color.r, color.g, color.b, a))
	_disc_cache[key] = disc
	return disc


static func _blob(img: Image, centre: Vector2, radii: Vector2, color: Color) -> void:
	var w := int(maxf(2.0, radii.x * 2.0))
	var h := int(maxf(2.0, radii.y * 2.0))
	var scaled := _disc(color).duplicate() as Image
	scaled.resize(w, h, Image.INTERPOLATE_BILINEAR)
	var dst := Vector2i(int(round(centre.x - radii.x)), int(round(centre.y - radii.y)))
	img.blend_rect(scaled, Rect2i(0, 0, w, h), dst)
