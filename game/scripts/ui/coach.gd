class_name Coach
extends Control

## Night 0 guidance. Teaches by doing, not by a wall of text before the game starts.
##
## The plan's rule was "night 0 teaches by doing, no text walls", and the shape that satisfies it
## is one short line at the moment it is needed, keyed to the patient actually on screen rather
## than to a fixed script. Because the shift is seeded, a scripted tutorial would eventually lie
## about what the player is looking at — so every line is derived from the real PatientSpec.
##
## It also stops early: the coach goes quiet after the first few patients so the last of the
## onboarding shift is played unaided, which is the point of it.

const COACHED_PATIENTS := 3
const LINE_COLOR := Color(0.96, 0.90, 0.62)

var _label: Label
var _plate: ColorRect
var _shown_for := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# A dark plate behind the line. Without it the text sits on painted watercolour wall and is
	# genuinely hard to read, which defeats the point of a one-line prompt.
	_plate = ColorRect.new()
	_plate.color = Color(0.04, 0.05, 0.07, 0.82)
	_plate.size = Vector2(940, 78)
	_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_plate)

	_label = Label.new()
	_label.size = Vector2(900, 70)
	_label.position = Vector2(20, 6)
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 32)
	_label.add_theme_color_override("font_color", LINE_COLOR)
	add_child(_label)
	modulate.a = 0.0


## Advice for the patient now at the window. Empty string means stay quiet.
func advise(spec: PatientSpec, index: int) -> String:
	if spec == null or index >= COACHED_PATIENTS:
		return ""

	if index == 0:
		# The onboarding shift is built to open on an anomaly, so this is reliable.
		if spec.is_anomalous:
			return "Look closely. Something about this one is wrong — REJECT it."
		return "Compare the patient with its chart. If it matches, ADMIT it."

	if index == 1:
		if spec.is_anomalous:
			return "Wrong again. Reject anything that does not match."
		return "This one is fine. ADMIT it."

	return "Three mistakes ends the shift. Take your time."


func show_for(spec: PatientSpec, index: int) -> void:
	var line := advise(spec, index)
	if line == "" or index == _shown_for:
		return
	_shown_for = index
	_label.text = line
	var t := create_tween()
	t.tween_property(self, "modulate:a", 1.0, 0.25)


## Correct a mistake immediately, while the evidence is still on screen. Only during onboarding —
## later nights let mistakes stand, because being told the answer is what stops it being a game.
func correct(admitted: bool, spec: PatientSpec) -> void:
	if spec == null:
		return
	if admitted and spec.is_anomalous:
		_flash("That one should have been rejected. Look for what does not belong.")
	elif not admitted and not spec.is_anomalous:
		_flash("That one was healthy. Only reject what is genuinely wrong.")


func _flash(line: String) -> void:
	_label.text = line
	modulate.a = 1.0
	_shown_for = -1


func hide_line() -> void:
	if modulate.a <= 0.01:
		return
	var t := create_tween()
	t.tween_property(self, "modulate:a", 0.0, 0.3)
