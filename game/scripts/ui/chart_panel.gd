class_name ChartPanel
extends Control

## The clipboard the player reads to judge a patient.
##
## Two kinds of check live here, and the layout exists to make both possible:
##   SPECIES  is checked against the creature you can see.
##   NAME     is checked against the WRISTBAND line, because nothing about an animal tells
##            you its name — a name lie needs a second source or it is unguessable.
##
## Highlight is used by the rewarded "second opinion" hint when the anomaly is a chart lie.

const ROW_LABELS := {
	"name": "NAME",
	"species_label": "SPECIES",
	"marks": "MARKS",
	"note": "NOTE",
	"wristband": "WRISTBAND",
}
const ROW_ORDER := ["name", "species_label", "marks", "note"]

## Tall enough for four rows, the wristband below its own rule, AND the sad-note line. Sized
## as a constant because the Shift screen packs the toolbar above it and the stamps below, and
## the space between the hatch and the bottom of the screen is fully committed.
const PANEL_SIZE := Vector2(940, 400)

## Row pitch. Tight enough that four rows plus the wristband fit in PANEL_SIZE.
const ROW_PITCH := 50.0
const FIRST_ROW_Y := 84.0

const PAPER := Color(0.90, 0.877, 0.815)
const INK := Color(0.16, 0.15, 0.17)
const INK_DIM := Color(0.42, 0.40, 0.40)
const HIGHLIGHT := Color(1.0, 0.85, 0.30, 0.55)

var _rows: Dictionary = {}
var _wristband_value: Label
var _highlight: ColorRect
var _sad_note: Label


func _ready() -> void:
	custom_minimum_size = PANEL_SIZE
	_build()


func _build() -> void:
	var paper := ColorRect.new()
	paper.color = PAPER
	paper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(paper)

	# Clipboard clip, so the panel reads as a physical object rather than a UI box.
	var clip := ColorRect.new()
	clip.color = Color(0.28, 0.29, 0.32)
	clip.size = Vector2(200, 26)
	clip.position = Vector2(370, -13)
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(clip)

	_highlight = ColorRect.new()
	_highlight.color = HIGHLIGHT
	_highlight.visible = false
	_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_highlight)

	var title := Label.new()
	title.text = "NIGHT INTAKE CHART"
	title.position = Vector2(34, 22)
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", INK_DIM)
	add_child(title)

	var rule := ColorRect.new()
	rule.color = Color(INK_DIM, 0.4)
	rule.size = Vector2(872, 2)
	rule.position = Vector2(34, 68)
	add_child(rule)

	var y := FIRST_ROW_Y
	for key in ROW_ORDER:
		_rows[key] = _add_row(ROW_LABELS[key], y)
		y += ROW_PITCH

	# The wristband sits apart, below a second rule: it is a different physical source from
	# the chart, and the layout should say so.
	var rule2 := ColorRect.new()
	rule2.color = Color(INK_DIM, 0.4)
	rule2.size = Vector2(872, 2)
	rule2.position = Vector2(34, y + 6)
	add_child(rule2)

	_wristband_value = _add_row(ROW_LABELS["wristband"], y + 22.0)

	_sad_note = Label.new()
	_sad_note.text = ""
	_sad_note.position = Vector2(34, y + 76.0)
	_sad_note.add_theme_font_size_override("font_size", 26)
	_sad_note.add_theme_color_override("font_color", Color(0.55, 0.22, 0.24))
	add_child(_sad_note)


func _add_row(label_text: String, y: float) -> Label:
	var key := Label.new()
	key.text = label_text
	key.position = Vector2(34, y)
	key.add_theme_font_size_override("font_size", 26)
	key.add_theme_color_override("font_color", INK_DIM)
	add_child(key)

	var value := Label.new()
	value.position = Vector2(280, y - 4)
	value.size = Vector2(626, 44)
	# Clip rather than overflow: a long marks line used to run off the paper and over the wall.
	value.clip_text = true
	value.add_theme_font_size_override("font_size", 32)
	value.add_theme_color_override("font_color", INK)
	add_child(value)
	return value


func show_spec(spec: PatientSpec) -> void:
	clear_highlight()
	_sad_note.text = ""
	for key in ROW_ORDER:
		_rows[key].text = str(spec.chart.get(key, ""))
	# Markings are descriptive and the longest field by far, so it gets a smaller face to fit.
	_rows["marks"].add_theme_font_size_override("font_size", 27)
	_wristband_value.text = str(spec.chart.get("wristband", ""))


## Flash the row the hint points at. Only ever called for `data` anomalies; art anomalies
## highlight on the creature instead.
func highlight_field(field: String) -> void:
	var target: Label = _rows.get(field if field != "species" else "species_label", null)
	if field == "name":
		target = _rows["name"]
	if target == null:
		return
	_highlight.position = Vector2(28, target.position.y - 2)
	_highlight.size = Vector2(884, 44)
	_highlight.visible = true


func clear_highlight() -> void:
	_highlight.visible = false


## Shown when the player rejects a healthy patient — the consequence should land on the
## paperwork rather than on the animal, which keeps the tone sad instead of violent.
func show_sad_note(text: String) -> void:
	_sad_note.text = text
