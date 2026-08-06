extends Node

## Headless tests for the shift builder, difficulty tables and verdict rules.
##
## Deliberately not GUT: these are plain assertions over pure-ish logic, and a dependency
## would cost more than it returns. Run with:
##   Godot_console.exe --headless --path game res://tests/TestRunner.tscn
##
## Runs as a SCENE, not --script, so the real autoloads (Difficulty, Roster, SaveGame) are
## live and their wiring is covered too. Under --script there is no autoload registration and
## Roster's reference to Difficulty would not even compile.
##
## Exits non-zero on failure so this can gate a commit.

var _passed := 0
var _failed := 0


func _ready() -> void:
	var difficulty := Difficulty
	var roster := Roster

	print("")
	test_tables_loaded(difficulty)
	test_roster_loaded(roster)
	test_shift_size(roster, difficulty)
	test_min_anomalies_floor(roster, difficulty)
	test_streak_cap(roster, difficulty)
	test_no_repeat_within_shift(roster, difficulty)
	test_seed_reproducibility(roster, difficulty)
	test_tier_escalation(roster, difficulty)
	test_onboarding_opens_anomalous(roster, difficulty)
	test_data_anomaly_lies(roster, difficulty)
	test_endless_ramp(difficulty)
	test_scoring(difficulty)
	test_channel_gating(roster, difficulty)
	test_tool_unlock_guarantee(roster, difficulty)
	test_every_anomaly_is_detectable(roster, difficulty)
	test_xray_and_heart_resolve(roster, difficulty)

	print("\n%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


# --- tests --------------------------------------------------------------------------

func test_tables_loaded(d) -> void:
	check("difficulty: nights loaded", d.nights.size() >= 8)
	check("difficulty: constraints loaded", not d.shift_constraints.is_empty())
	check("difficulty: last campaign night is 7", d.last_campaign_night == 7,
			"got %d" % d.last_campaign_night)
	check("difficulty: night_config(3) resolves", int(d.night_config(3).get("night", -1)) == 3)


func test_roster_loaded(r) -> void:
	check("roster: creatures loaded", r.creatures.size() >= 8, "got %d" % r.creatures.size())
	var with_anomalies := 0
	for c in r.creatures:
		if not c.get("anomalies", []).is_empty():
			with_anomalies += 1
	check("roster: every creature has anomalies", with_anomalies == r.creatures.size(),
			"%d/%d" % [with_anomalies, r.creatures.size()])


func test_shift_size(r, d) -> void:
	for night in range(1, 8):
		var cfg: Dictionary = d.night_config(night)
		var shift = r.build_shift(_rng(night), cfg)
		if not check("shift size night %d" % night, shift.size() == int(cfg["patients"]),
				"want %d got %d" % [cfg["patients"], shift.size()]):
			return


## The floor is the whole reason flags aren't a plain per-patient roll: a zero-anomaly shift
## teaches the player that stamping ADMIT on everything works.
func test_min_anomalies_floor(r, d) -> void:
	var floor_want := int(d.shift_constraints.get("min_anomalies", 2))
	var worst := 999
	for seed_i in range(300):
		var shift = r.build_shift(_rng(seed_i), d.night_config(1))
		var n := 0
		for s in shift:
			if s.is_anomalous:
				n += 1
		worst = mini(worst, n)
	check("min anomalies over 300 shifts >= %d" % floor_want, worst >= floor_want,
			"worst was %d" % worst)


func test_streak_cap(r, d) -> void:
	var cap := int(d.shift_constraints.get("max_anomaly_streak", 3))
	var longest := 0
	for seed_i in range(300):
		for night in [1, 4, 7]:
			var shift = r.build_shift(_rng(seed_i * 10 + night), d.night_config(night))
			var run := 0
			for s in shift:
				run = run + 1 if s.is_anomalous else 0
				longest = maxi(longest, run)
	# The top-up pass can exceed the cap when it has to hit the floor; allow one over, which
	# is the documented trade (a hard cap could make the floor unreachable on short shifts).
	check("anomaly streak <= cap+1 (%d)" % (cap + 1), longest <= cap + 1,
			"longest was %d" % longest)


func test_no_repeat_within_shift(r, d) -> void:
	if r.creatures.size() < 12:
		skip("no-repeat within shift", "roster smaller than max shift size")
		return
	var violations := 0
	for seed_i in range(120):
		var shift = r.build_shift(_rng(seed_i), d.night_config(7))
		var seen := {}
		for s in shift:
			var id = s.creature.get("id", "")
			if seen.has(id):
				violations += 1
			seen[id] = true
	check("no creature repeats within a shift", violations == 0, "%d violations" % violations)


func test_seed_reproducibility(r, d) -> void:
	var a = r.build_shift(_rng(4242), d.night_config(5))
	var b = r.build_shift(_rng(4242), d.night_config(5))
	var same: bool = a.size() == b.size()
	if same:
		for i in range(a.size()):
			if a[i].creature.get("id") != b[i].creature.get("id") \
					or a[i].anomaly_id != b[i].anomaly_id \
					or a[i].patient_name != b[i].patient_name \
					or a[i].chart.get("species_label") != b[i].chart.get("species_label"):
				same = false
				break
	check("same seed reproduces the same shift", same)

	var c = r.build_shift(_rng(9999), d.night_config(5))
	var differs := false
	for i in range(mini(a.size(), c.size())):
		if a[i].creature.get("id") != c[i].creature.get("id") or a[i].anomaly_id != c[i].anomaly_id:
			differs = true
			break
	check("different seed produces a different shift", differs)


## Late nights should lean on tier 3; early nights should not use it at all.
func test_tier_escalation(r, d) -> void:
	var early_t3 := 0
	var late_t3 := 0
	var late_total := 0
	for seed_i in range(200):
		for s in r.build_shift(_rng(seed_i), d.night_config(1)):
			if s.is_anomalous and s.tier == 3:
				early_t3 += 1
		for s in r.build_shift(_rng(seed_i + 5000), d.night_config(7)):
			if s.is_anomalous:
				late_total += 1
				if s.tier == 3:
					late_t3 += 1
	check("night 1 never uses tier 3", early_t3 == 0, "saw %d" % early_t3)
	var share := float(late_t3) / maxf(1.0, float(late_total))
	check("night 7 is tier-3 heavy (>25%)", share > 0.25, "share %.2f" % share)


func test_onboarding_opens_anomalous(r, d) -> void:
	var ok := true
	for seed_i in range(60):
		var shift = r.build_shift(_rng(seed_i), d.night_config(0))
		if shift.is_empty() or not shift[0].is_anomalous:
			ok = false
			break
	check("onboarding night opens with an anomaly", ok)


## A data anomaly must actually produce a chart that contradicts the patient, otherwise it is
## an unwinnable patient that looks healthy and is marked anomalous.
func test_data_anomaly_lies(r, d) -> void:
	var found := 0
	var lying := 0
	for seed_i in range(400):
		for s in r.build_shift(_rng(seed_i), d.night_config(7)):
			if s.anomaly_kind != "data":
				continue
			found += 1
			var field := str(s.chart.get("lied_field", ""))
			if field == "":
				continue
			var truth: Dictionary = s.creature.get("chart", {})
			match field:
				"species":
					if s.chart.get("species_label") != truth.get("species_label"):
						lying += 1
				"name":
					if s.chart.get("name") != s.patient_name:
						lying += 1
	check("data anomalies occur", found > 0, "found %d" % found)
	check("every data anomaly contradicts the patient", found > 0 and lying == found,
			"%d/%d actually lied" % [lying, found])


func test_endless_ramp(d) -> void:
	var w0: Array = d.endless_config(0).get("tiers", [])
	var w12: Array = d.endless_config(12).get("tiers", [])
	check("endless ramps tier 3", float(w12[2]) > float(w0[2]),
			"%.2f -> %.2f" % [w0[2], w12[2]])
	check("endless caps tier 3", float(w12[2]) <= float(d.endless.get("tier3_cap", 0.65)) + 0.001,
			"got %.2f" % w12[2])
	var total := 0.0
	for w in w12:
		total += float(w)
	check("endless weights stay normalised", absf(total - 1.0) < 0.001, "sum %.3f" % total)


func test_scoring(d) -> void:
	var fast: int = d.score_for(0, 1.0)
	var slow: int = d.score_for(0, 30.0)
	check("speed bonus applies", fast > slow, "%d vs %d" % [fast, slow])
	check("streak increases score", d.score_for(5, 30.0) > slow)
	check("streak is capped", d.score_for(99, 30.0) == d.score_for(int(d.scoring["streak_cap"]), 30.0))


# --- harness ------------------------------------------------------------------------

func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


func check(label: String, condition: bool, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		var suffix := "  (%s)" % detail if detail != "" else ""
		print("  FAIL  %s%s" % [label, suffix])
	return condition


func skip(label: String, why: String) -> void:
	print("  skip  %s  (%s)" % [label, why])


## No patient may carry an anomaly whose revealing tool the player does not own yet. This is the
## unwinnable-patient failure mode, and it is the single most important invariant in the game.
func test_channel_gating(r, d) -> void:
	var violations: Array[String] = []
	for night in range(0, 8):
		var cfg: Dictionary = d.night_config(night)
		var allowed: Array = d.channels_for(cfg)
		for seed_i in range(120):
			for s in r.build_shift(_rng(seed_i * 100 + night), cfg):
				if not s.is_anomalous:
					continue
				if s.channel not in allowed:
					violations.append("night %d: %s (%s)" % [night, s.anomaly_id, s.channel])
					break
	check("anomaly channels never precede their tool", violations.is_empty(),
			"; ".join(violations.slice(0, 3)))


## A night that introduces a tool must actually make the player use it, or the unlock teaches
## nothing and the player never discovers the mechanic.
func test_tool_unlock_guarantee(r, d) -> void:
	for night in [3, 4, 5]:
		var cfg: Dictionary = d.night_config(night)
		var want := str(cfg.get("guarantee_channel", ""))
		if want == "":
			skip("night %d guarantees a channel" % night, "no guarantee configured")
			continue
		var misses := 0
		for seed_i in range(80):
			var found := false
			for s in r.build_shift(_rng(seed_i * 7 + night), cfg):
				if s.is_anomalous and s.channel == want:
					found = true
					break
			if not found:
				misses += 1
		check("night %d always needs its new tool (%s)" % [night, want], misses == 0,
				"%d/80 shifts had none" % misses)


## Every anomaly must be catchable by SOME means. An anomaly with no channel, or a skeleton
## anomaly with no plate, or a sound anomaly with no cue, is a patient the player cannot judge.
func test_every_anomaly_is_detectable(r, _d) -> void:
	var bad: Array[String] = []
	const KNOWN := ["visual", "skeleton", "sound", "behaviour", "data"]
	for c in r.creatures:
		for a in c.get("anomalies", []):
			var ch: String = r.channel_of(a)
			if ch not in KNOWN:
				bad.append("%s/%s unknown channel" % [c.get("id"), a.get("id")])
			if ch == "skeleton" and not a.has("xray"):
				bad.append("%s/%s skeleton without a plate" % [c.get("id"), a.get("id")])
			if ch == "sound" and str(a.get("params", {}).get("cue", "")) == "":
				bad.append("%s/%s sound without a cue" % [c.get("id"), a.get("id")])
	check("every anomaly has a detection channel", bad.is_empty(),
			"; ".join(bad.slice(0, 3)))


## The scan and stethoscope views ask PatientSpec for what to show/play. A skeleton anomaly must
## resolve to a DIFFERENT plate than the healthy one, or scanning it reveals nothing.
func test_xray_and_heart_resolve(r, d) -> void:
	var checked_skeleton := 0
	var same_plate := 0
	var checked_sound := 0
	var normal_cue := 0
	for seed_i in range(200):
		for s in r.build_shift(_rng(seed_i + 31), d.night_config(7)):
			if s.channel == "skeleton":
				checked_skeleton += 1
				if s.xray_source == s.creature.get("xray", ""):
					same_plate += 1
			elif s.channel == "sound":
				checked_sound += 1
				if s.heart_cue == "heart_normal":
					normal_cue += 1
			elif not s.is_anomalous:
				if s.xray_source != s.creature.get("xray", "") or s.heart_cue != "heart_normal":
					same_plate += 1  # a healthy patient must look and sound normal
	check("skeleton anomalies show a different plate", checked_skeleton > 0 and same_plate == 0,
			"%d/%d wrong" % [same_plate, checked_skeleton])
	check("sound anomalies play a non-normal cue", checked_sound > 0 and normal_cue == 0,
			"%d/%d normal" % [normal_cue, checked_sound])
