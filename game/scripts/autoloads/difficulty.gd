extends Node

## Balance tables, loaded from data/difficulty.json. Pure lookups — this node holds no run
## state, so it is safe to read from anywhere.

const PATH := "res://data/difficulty.json"

var nights: Array = []
var shift_constraints: Dictionary = {}
var strikes: Dictionary = {}
var hints: Dictionary = {}
var scoring: Dictionary = {}
var endless: Dictionary = {}
var ads: Dictionary = {}
var tools: Dictionary = {}


func _ready() -> void:
	var data := _read()
	nights = data.get("nights", [])
	shift_constraints = data.get("shift_constraints", {})
	strikes = data.get("strikes", {})
	hints = data.get("hints", {})
	scoring = data.get("scoring", {})
	endless = data.get("endless", {})
	ads = data.get("ads", {})
	tools = data.get("tools", {})


var last_campaign_night: int:
	get:
		var top := 0
		for n in nights:
			top = maxi(top, int(n.get("night", 0)))
		return top


func night_config(night: int) -> Dictionary:
	for n in nights:
		if int(n.get("night", -1)) == night:
			return n
	return nights[-1] if not nights.is_empty() else {}


## Endless waves reuse a mid-campaign night as their base and push tier 3 upward each wave,
## so difficulty keeps climbing without needing more authored rows.
func endless_config(wave: int) -> Dictionary:
	var base := night_config(int(endless.get("entry_night_equivalent", 4))).duplicate(true)
	base["patients"] = int(endless.get("wave_size", 10))
	base["anomaly_rate"] = float(endless.get("anomaly_rate", 0.38))
	base["onboarding"] = false

	var tiers: Array = base.get("tiers", [0.3, 0.5, 0.2]).duplicate()
	if tiers.size() == 3:
		var ramp := float(endless.get("tier3_ramp_per_wave", 0.05)) * float(wave)
		var cap := float(endless.get("tier3_cap", 0.65))
		var t3: float = minf(float(tiers[2]) + ramp, cap)
		# Take the increase out of tier 1 first — easy anomalies should thin out before the
		# mid-tier ones do, or late waves become all-or-nothing.
		var need: float = t3 - float(tiers[2])
		var from_t1: float = minf(need, float(tiers[0]))
		tiers[0] = float(tiers[0]) - from_t1
		tiers[1] = maxf(0.0, float(tiers[1]) - (need - from_t1))
		tiers[2] = t3
		base["tiers"] = tiers
	return base


## Pick an anomaly tier from a night's weights.
func roll_tier(night: Dictionary, rng: RandomNumberGenerator) -> int:
	var weights: Array = night.get("tiers", [1.0, 0.0, 0.0])
	var total := 0.0
	for w in weights:
		total += float(w)
	if total <= 0.0:
		return 1
	var roll := rng.randf() * total
	var acc := 0.0
	for i in range(weights.size()):
		acc += float(weights[i])
		if roll <= acc:
			return i + 1
	return weights.size()


## Tools the player has on a given night, and therefore which anomaly channels may appear.
## Gating selection on this is what stops an unwinnable patient: a skeleton anomaly shown before
## the X-ray exists is invisible, exactly the trap the chart-name lie fell into.
func tools_for(night: Dictionary) -> Array:
	return night.get("tools", ["chart"])


func channels_for(night: Dictionary) -> Array:
	return night.get("channels", ["visual"])


func has_tool(night: Dictionary, tool: String) -> bool:
	return tool in tools_for(night)


func tool_label(tool: String) -> String:
	return str(tools.get(tool, {}).get("label", tool.capitalize()))


## Which inspection tool reveals a given anomaly kind. `visual` needs no tool beyond looking.
static func tool_for_channel(channel: String) -> String:
	match channel:
		"skeleton": return "xray"
		"sound": return "stethoscope"
		"data": return "chart"
		_: return ""


func score_for(streak: int, seconds_taken: float) -> int:
	var base := int(scoring.get("correct", 100))
	var step := int(scoring.get("streak_step", 25))
	var cap := int(scoring.get("streak_cap", 10))
	var total := base + step * mini(streak, cap)
	if seconds_taken <= float(scoring.get("speed_under_s", 6.0)):
		total += int(scoring.get("speed_bonus", 50))
	return total


## Everyone gets the same endless run on a given local date, which is what makes a score
## worth sharing. Local date on purpose: players expect "today" to mean their today.
func daily_seed() -> int:
	var d := Time.get_date_dict_from_system(false)
	var prefix := str(endless.get("daily_seed_prefix", "pawward-"))
	return hash("%s%04d-%02d-%02d" % [prefix, d.year, d.month, d.day])


func _read() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		push_error("[Difficulty] missing %s" % PATH)
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(PATH)) != OK:
		push_error("[Difficulty] %s: %s" % [PATH, json.get_error_message()])
		return {}
	return json.data if json.data is Dictionary else {}
