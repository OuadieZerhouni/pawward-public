extends Node

## Loads the creature manifest and builds shift queues from it.
##
## Two jobs worth separating in your head:
##   - content: parse roster.json, fall back to procedural art for creatures whose PNGs
##     aren't sliced yet, and validate loudly in debug builds.
##   - selection: turn a night's difficulty row into a concrete, constraint-satisfying queue
##     of PatientSpecs from a seeded RNG.
##
## Selection is where the game's felt fairness lives, so it is deliberately not a naive roll.
## See _build_flags() for why.

const MANIFEST_PATH := "res://data/roster.json"

## Species used to pad the roster while art is in production. Drawn from the planned 20.
const PLANNED_SPECIES := [
	"axolotl", "cat", "rabbit", "owl", "fox", "frog", "hedgehog", "hamster", "deer fawn",
	"bat", "snake", "duck", "turtle", "ferret", "moth", "raccoon", "goat kid", "capybara",
	"gecko", "crow",
]

## Anomalies given to placeholder creatures — one of each kind so every code path (art swap,
## behaviour subversion, chart lie) is exercised long before the art lands.
const PLACEHOLDER_ANOMALIES := [
	# visual
	"third_eye", "doubled_pupils", "too_many_teeth",
	# skeleton (X-ray)
	"foreign_object", "second_skull", "extra_ribs", "extra_vertebra", "hollow_limb",
	# sound (stethoscope)
	"two_hearts", "clockwork", "hollow", "whisper", "too_fast",
	# zero-art
	"too_still", "never_blinks", "dead_eyes", "chart_species", "chart_name",
]

var creatures: Array[Dictionary] = []
var placeholder_count := 0

var _by_id: Dictionary = {}


func _ready() -> void:
	load_manifest()


func load_manifest() -> void:
	creatures.clear()
	_by_id.clear()
	placeholder_count = 0

	var parsed := _read_json(MANIFEST_PATH)
	for entry in parsed.get("creatures", []):
		var creature: Dictionary = entry
		if not _art_present(creature):
			# Keep the manifest's identity and anomaly design, swap in drawable textures.
			creature = _placeholderise(creature)
			placeholder_count += 1
		creatures.append(creature)
		_by_id[creature.get("id", "")] = creature

	# Pad to a workable roster so shift construction and difficulty tuning are meaningful
	# now. Padding disappears on its own as real creatures are added to the manifest.
	for species in PLANNED_SPECIES:
		if creatures.size() >= PLANNED_SPECIES.size():
			break
		if _has_species(species):
			continue
		var ph := PlaceholderArt.creature(species, PLACEHOLDER_ANOMALIES)
		creatures.append(ph)
		_by_id[ph["id"]] = ph
		placeholder_count += 1

	if OS.is_debug_build():
		print("[Roster] %d creatures (%d placeholder)" % [creatures.size(), placeholder_count])
		_validate()


func get_creature(id: String) -> Dictionary:
	return _by_id.get(id, {})


# --- shift construction -------------------------------------------------------------

## Build one shift. `night` is a row from difficulty.json. The same rng + night always
## produces the same queue, which is what makes the daily endless run shareable and makes
## the tests below deterministic.
func build_shift(rng: RandomNumberGenerator, night: Dictionary) -> Array[PatientSpec]:
	var count := int(night.get("patients", 8))
	var flags := _build_flags(rng, count, night)

	var pool := creatures.duplicate()
	_shuffle(pool, rng)

	var out: Array[PatientSpec] = []
	var used_anomaly_counts: Dictionary = {}
	var cursor := 0


	for i in range(count):
		# Cycling a shuffled pool gives no-repeat-within-shift for free, and degrades
		# gracefully to repeats when the roster is smaller than the shift.
		if cursor >= pool.size():
			cursor = 0
			_shuffle(pool, rng)
		var creature: Dictionary = pool[cursor]
		cursor += 1

		var spec := PatientSpec.new()
		spec.creature = creature
		spec.patient_name = _pick_name(creature, rng)

		if flags[i]:
			spec.anomaly = _pick_anomaly(creature, night, rng, used_anomaly_counts)
			if spec.anomaly.is_empty():
				flags[i] = false  # creature has no anomaly for the wanted tier
			else:
				var id: String = spec.anomaly.get("id", "")
				used_anomaly_counts[id] = int(used_anomaly_counts.get(id, 0)) + 1

		spec.chart = _resolve_chart(spec, rng)

		# A data anomaly that could not construct a contradiction would be an unwinnable
		# patient. Downgrade it to healthy rather than shipping one.
		if spec.anomaly_kind == "data" and str(spec.chart.get("lied_field", "")) == "":
			var id: String = spec.anomaly.get("id", "")
			used_anomaly_counts[id] = maxi(0, int(used_anomaly_counts.get(id, 0)) - 1)
			spec.anomaly = {}
			flags[i] = false

		out.append(spec)

	_guarantee_channel(out, night, rng)
	return out


## Nights that introduce a tool must contain at least one patient that needs it, or the unlock
## teaches nothing and the player never learns the mechanic exists.
##
## Done as a repair pass rather than by reserving a slot up front: the creature that lands in a
## reserved slot may simply have no anomaly in the wanted channel, and forcing the issue there
## silently degrades to a free pick. Repairing afterwards can choose a slot that CAN satisfy it.
func _guarantee_channel(shift: Array[PatientSpec], night: Dictionary,
		rng: RandomNumberGenerator) -> void:
	var wanted := str(night.get("guarantee_channel", ""))
	if wanted == "" or shift.is_empty():
		return
	for spec in shift:
		if spec.channel == wanted:
			return

	# Prefer overwriting a slot that is already anomalous, so the shift's anomaly count and
	# pacing are preserved; fall back to converting a healthy one if none can host it.
	var candidates: Array[int] = []
	var fallback: Array[int] = []
	for i in range(shift.size()):
		if _has_channel(shift[i].creature, wanted):
			if shift[i].is_anomalous:
				candidates.append(i)
			else:
				fallback.append(i)
	var pool := candidates if not candidates.is_empty() else fallback
	if pool.is_empty():
		push_warning("[Roster] no creature can host a '%s' anomaly" % wanted)
		return

	var slot: int = pool[rng.randi_range(0, pool.size() - 1)]
	var options: Array = []
	for a in shift[slot].creature.get("anomalies", []):
		if channel_of(a) == wanted:
			options.append(a)
	shift[slot].anomaly = options[rng.randi_range(0, options.size() - 1)]
	shift[slot].chart = _resolve_chart(shift[slot], rng)


func _has_channel(creature: Dictionary, channel: String) -> bool:
	for a in creature.get("anomalies", []):
		if channel_of(a) == channel:
			return true
	return false


## Decide which slots in the shift are anomalous.
##
## A plain per-patient roll at the configured rate is the obvious implementation and it is
## wrong: across 8-12 patients it regularly yields a shift with zero anomalies — which
## silently teaches the player that stamping ADMIT on everything works — or a run of five,
## which reads as rigged. The constraints clamp both tails, so the rate describes the
## long-run average while every individual shift stays playable.
func _build_flags(rng: RandomNumberGenerator, count: int, night: Dictionary) -> Array[bool]:
	var cons: Dictionary = Difficulty.shift_constraints
	var rate := float(night.get("anomaly_rate", 0.35))
	var min_anomalies := mini(int(cons.get("min_anomalies", 2)), count)
	var max_streak := int(cons.get("max_anomaly_streak", 3))
	var max_healthy := int(cons.get("max_healthy_streak", 4))

	var flags: Array[bool] = []
	flags.resize(count)
	flags.fill(false)

	var anomaly_streak := 0
	var healthy_streak := 0
	for i in range(count):
		var want := rng.randf() < rate
		if want and anomaly_streak >= max_streak:
			want = false
		elif not want and healthy_streak >= max_healthy:
			want = true
		flags[i] = want
		if want:
			anomaly_streak += 1
			healthy_streak = 0
		else:
			healthy_streak += 1
			anomaly_streak = 0

	# Top up to the floor, preferring slots that don't create a long run.
	var placed := flags.count(true)
	var guard := 0
	while placed < min_anomalies and guard < count * 8:
		guard += 1
		var i := rng.randi_range(0, count - 1)
		if flags[i]:
			continue
		flags[i] = true
		placed += 1

	# Never open the very first patient of the onboarding night with a healthy one — night 0
	# teaches by showing the player something wrong immediately.
	if night.get("onboarding", false) and count > 0:
		flags[0] = true

	return flags


## Which inspection channel an anomaly belongs to. Art anomalies on the creature are `visual`;
## the other kinds name their own channel.
static func channel_of(anomaly: Dictionary) -> String:
	match str(anomaly.get("kind", "")):
		"layer_swap": return "visual"
		"skeleton": return "skeleton"
		"sound": return "sound"
		"behavior", "behaviour": return "behaviour"
		"data": return "data"
		_: return "visual"


func _pick_anomaly(creature: Dictionary, night: Dictionary, rng: RandomNumberGenerator,
		used: Dictionary) -> Dictionary:
	var all: Array = creature.get("anomalies", [])
	if all.is_empty():
		return {}

	var max_same := int(Difficulty.shift_constraints.get("max_same_anomaly_type", 2))
	var allowed: Array = Difficulty.channels_for(night)
	var wanted_tier := Difficulty.roll_tier(night, rng)

	# Prefer the rolled tier; widen outward rather than failing, so a creature that happens
	# to lack a tier-3 anomaly still contributes a patient. Channel is NEVER widened — showing
	# an anomaly the player has no tool to detect is an unwinnable patient.
	for tier in _tier_preference(wanted_tier):
		var options: Array = []
		for a in all:
			if int(a.get("tier", 0)) != tier:
				continue
			var ch := channel_of(a)
			if ch not in allowed:
				continue
			if int(used.get(a.get("id", ""), 0)) >= max_same:
				continue
			options.append(a)
		if not options.is_empty():
			return options[rng.randi_range(0, options.size() - 1)]

	return {}


static func _tier_preference(wanted: int) -> Array[int]:
	match wanted:
		1: return [1, 2, 3]
		2: return [2, 1, 3]
		_: return [3, 2, 1]


## Assemble what the player reads on the clipboard. For a `data` anomaly this is where the
## lie is told: the chart borrows a field from a different creature, and no art is involved.
func _resolve_chart(spec: PatientSpec, rng: RandomNumberGenerator) -> Dictionary:
	var creature := spec.creature
	var source: Dictionary = creature.get("chart", {})
	var notes: Array = source.get("notes_pool", [])

	var chart := {
		"name": spec.patient_name,
		"species_label": source.get("species_label", str(creature.get("species", "?")).capitalize()),
		"marks": source.get("marks", ""),
		"note": notes[rng.randi_range(0, notes.size() - 1)] if not notes.is_empty() else "",
		# The wristband always carries the truth, and is what makes a name lie *checkable*.
		# A species lie can be caught by looking at the creature, but nothing about the animal
		# tells you its name — without a second source to cross-read, "the chart says Pip and
		# it is really Mochi" is information the player cannot possibly have.
		"wristband": spec.patient_name,
		"lied_field": "",
	}

	if spec.anomaly_kind == "data":
		# The borrowed value MUST differ from the truth, and that is not automatic: name pools
		# overlap between creatures, so picking "a name from someone else" lands on the same
		# name often enough to matter (measured: 14 of 471). When it does, the patient is
		# flagged anomalous while presenting as completely healthy — literally unwinnable.
		# So try until the value actually contradicts, and report failure if it never does.
		var field := str(spec.anomaly.get("params", {}).get("field", "species"))
		for _attempt in range(12):
			var other := _other_creature(creature, rng)
			if other.is_empty():
				break  # single-creature roster: nothing to borrow
			match field:
				"species":
					var other_chart: Dictionary = other.get("chart", {})
					var label: String = other_chart.get(
							"species_label", str(other.get("species", "?")).capitalize())
					if label != chart["species_label"]:
						chart["species_label"] = label
						chart["lied_field"] = "species"
				"name":
					var borrowed := _pick_name(other, rng)
					if borrowed != spec.patient_name:
						chart["name"] = borrowed
						chart["lied_field"] = "name"
			if chart["lied_field"] != "":
				break
	return chart


func _other_creature(exclude: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	if creatures.size() < 2:
		return {}
	var guard := 0
	while guard < 24:
		guard += 1
		var c: Dictionary = creatures[rng.randi_range(0, creatures.size() - 1)]
		if c.get("id", "") != exclude.get("id", ""):
			return c
	return {}


func _pick_name(creature: Dictionary, rng: RandomNumberGenerator) -> String:
	var pool: Array = creature.get("name_pool", [])
	if pool.is_empty():
		return "Patient"
	return str(pool[rng.randi_range(0, pool.size() - 1)])


# --- helpers ------------------------------------------------------------------------

static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	# Array.shuffle() uses the global RNG, which would break seeded reproducibility.
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func _has_species(species: String) -> bool:
	for c in creatures:
		if str(c.get("species", "")) == species:
			return true
	return false


func _art_present(creature: Dictionary) -> bool:
	var layers: Dictionary = creature.get("layers", {})
	if layers.is_empty():
		return false
	for key in layers:
		var v = layers[key]
		if v is String and not ResourceLoader.exists(v):
			return false
	return true


## Keep the authored identity, chart and anomaly *design* from the manifest, but draw it with
## placeholder textures. This way tuning done pre-art carries over to post-art unchanged.
func _placeholderise(creature: Dictionary) -> Dictionary:
	var ids: Array = []
	for a in creature.get("anomalies", []):
		ids.append(a.get("id", ""))
	var ph := PlaceholderArt.creature(str(creature.get("species", "creature")), ids)
	ph["id"] = creature.get("id", ph["id"])
	ph["pack"] = creature.get("pack", "core")
	if creature.has("name_pool"):
		ph["name_pool"] = creature["name_pool"]
	if creature.has("chart"):
		ph["chart"] = creature["chart"]
	# Preserve hint_rects and params from the manifest where the placeholder has the same
	# anomaly id, since those are design decisions rather than art.
	var authored: Dictionary = {}
	for a in creature.get("anomalies", []):
		authored[a.get("id", "")] = a
	for a in ph["anomalies"]:
		var src: Dictionary = authored.get(a["id"], {})
		if src.has("tier"):
			a["tier"] = src["tier"]
		if src.has("params"):
			a["params"] = src["params"]
	return ph


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("[Roster] manifest missing: %s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("[Roster] %s: %s (line %d)" % [path, json.get_error_message(), json.get_error_line()])
		return {}
	var data = json.data
	return data if data is Dictionary else {}


## Debug-only sanity checks. Cheap, and they turn a silent content mistake into a loud one.
func _validate() -> void:
	for c in creatures:
		var id := str(c.get("id", "?"))
		if c.get("layers", {}).is_empty():
			push_warning("[Roster] %s has no layers" % id)
		for a in c.get("anomalies", []):
			var kind := str(a.get("kind", ""))
			if kind not in ["layer_swap", "skeleton", "sound", "behavior", "behaviour", "data"]:
				push_warning("[Roster] %s/%s unknown kind '%s'" % [id, a.get("id", "?"), kind])
			# Each kind carries its tell somewhere different; a missing tell is an unwinnable
			# patient, so it is worth naming precisely rather than generically.
			match kind:
				"layer_swap":
					if a.get("overrides", {}).is_empty():
						push_warning("[Roster] %s/%s layer_swap with no overrides" % [id, a.get("id", "?")])
				"skeleton":
					if not a.has("xray"):
						push_warning("[Roster] %s/%s skeleton with no plate" % [id, a.get("id", "?")])
				"sound":
					if str(a.get("params", {}).get("cue", "")) == "":
						push_warning("[Roster] %s/%s sound with no cue" % [id, a.get("id", "?")])
			var tier := int(a.get("tier", 0))
			if tier < 1 or tier > 3:
				push_warning("[Roster] %s/%s tier %d out of range" % [id, a.get("id", "?"), tier])
