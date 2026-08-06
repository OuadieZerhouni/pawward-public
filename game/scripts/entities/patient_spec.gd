class_name PatientSpec
extends RefCounted

## One patient in a shift queue: which creature, which anomaly (if any), and the chart the
## player will be shown.
##
## The chart is resolved here, at build time, rather than by the Patient at display time.
## That matters for `data` anomalies, where the chart is the thing that's wrong: the Patient
## must never know what its own chart claims, or it would be tempting to derive one from the
## other and the lie would be impossible to construct.

var creature: Dictionary = {}
var anomaly: Dictionary = {}
var chart: Dictionary = {}
var patient_name := ""

var is_anomalous: bool:
	get: return not anomaly.is_empty()

var tier: int:
	get: return int(anomaly.get("tier", 0))

var anomaly_id: String:
	get: return str(anomaly.get("id", ""))

var anomaly_kind: String:
	get: return str(anomaly.get("kind", ""))

## Which inspection channel would reveal this patient. "" for a healthy one.
var channel: String:
	get: return Roster.channel_of(anomaly) if is_anomalous else ""

## The tool the player must own and use to catch this. Empty means plain looking suffices.
var required_tool: String:
	get: return Difficulty.tool_for_channel(channel) if is_anomalous else ""

## X-ray plate to show in scan mode: the anomalous one when the skeleton is wrong, else the
## species' normal plate. Resolved here so the scan view never has to reason about anomalies.
var xray_source: Variant:
	get:
		if anomaly_kind == "skeleton" and anomaly.has("xray"):
			return anomaly["xray"]
		return creature.get("xray", "")

## Heart sound for the stethoscope, same resolution rule as the X-ray.
var heart_cue: String:
	get:
		if anomaly_kind == "sound":
			return str(anomaly.get("params", {}).get("cue", "heart_normal"))
		return "heart_normal"


## The region to highlight when the player spends a "second opinion" hint. Data anomalies
## point at the chart instead of the creature, which is the honest answer for them.
var hint_rect: Rect2:
	get:
		var r: Array = anomaly.get("hint_rect", [])
		if r.size() == 4:
			return Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
		return Rect2()

var hint_points_at_chart: bool:
	get: return anomaly_kind == "data"


func _to_string() -> String:
	var what := anomaly_id if is_anomalous else "healthy"
	return "%s/%s (%s)" % [creature.get("species", "?"), patient_name, what]
