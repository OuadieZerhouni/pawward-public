extends Node

## Persistent player state. Small enough that a single JSON blob beats any structure.

const PATH := "user://save.json"

const DEFAULTS := {
	"night_reached": 1,
	"campaign_complete": false,
	"best_endless": 0,
	"best_endless_wave": 0,
	"onboarding_done": false,
	"pro": false,
	"reduce_scare": false,
	"music_volume": 0.8,
	"sfx_volume": 1.0,
	"shifts_finished": 0,
	"reviewed": false,
}

var data: Dictionary = DEFAULTS.duplicate(true)


func _ready() -> void:
	load_save()


func load_save() -> void:
	data = DEFAULTS.duplicate(true)
	if not FileAccess.file_exists(PATH):
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(PATH)) != OK:
		push_warning("[SaveGame] corrupt save, starting fresh")
		return
	if json.data is Dictionary:
		# Merge rather than replace, so a save written by an older build gains new keys
		# instead of losing them.
		for key in json.data:
			data[key] = json.data[key]


func save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_error("[SaveGame] cannot write %s" % PATH)
		return
	f.store_string(JSON.stringify(data, "  "))


func get_value(key: String, fallback = null):
	return data.get(key, DEFAULTS.get(key, fallback))


func set_value(key: String, value) -> void:
	data[key] = value
	save()


func note_shift_finished() -> void:
	data["shifts_finished"] = int(data.get("shifts_finished", 0)) + 1
	save()


func unlock_night(night: int) -> void:
	if night > int(data.get("night_reached", 1)):
		data["night_reached"] = night
		save()


func record_endless(score: int, wave: int) -> bool:
	var best := int(data.get("best_endless", 0))
	if score <= best:
		return false
	data["best_endless"] = score
	data["best_endless_wave"] = wave
	save()
	return true
