class_name HandbookPanel
extends Control

## The clinic handbook: what a HEALTHY animal of this species should look like.
##
## This is the piece that makes subtle anomalies fair rather than cruel. "One rib too many" or
## "pupils are slits" is only a fair call if the player can find out what the normal count and
## shape are. Without a reference, tier-3 anomalies are guesswork — the same trap the chart-name
## lie fell into before the wristband existed.
##
## It opens on the current patient's species. Making the player hunt for the right page is
## authentic to the genre but it is friction that costs nothing to remove on a phone, and the
## comparison is the interesting part, not the page-turning.

const PAPER := Color(0.93, 0.90, 0.83)
const INK := Color(0.15, 0.14, 0.16)
const INK_DIM := Color(0.44, 0.42, 0.42)
const PANEL_SIZE := Vector2(960, 1180)

var _title: Label
var _plate: TextureRect
var _heart: Label
var _features: VBoxContainer
var _closed := true

signal closed


func _ready() -> void:
	custom_minimum_size = PANEL_SIZE
	size = PANEL_SIZE
	_build()
	visible = false


func _build() -> void:
	var paper := ColorRect.new()
	paper.color = PAPER
	paper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(paper)

	var header := Label.new()
	header.text = "CLINIC HANDBOOK"
	header.position = Vector2(34, 24)
	header.add_theme_font_size_override("font_size", 28)
	header.add_theme_color_override("font_color", INK_DIM)
	add_child(header)

	_title = Label.new()
	_title.position = Vector2(34, 60)
	_title.add_theme_font_size_override("font_size", 52)
	_title.add_theme_color_override("font_color", INK)
	add_child(_title)

	var rule := ColorRect.new()
	rule.color = Color(INK_DIM, 0.45)
	rule.size = Vector2(892, 2)
	rule.position = Vector2(34, 130)
	add_child(rule)

	var plate_label := Label.new()
	plate_label.text = "NORMAL SKELETON"
	plate_label.position = Vector2(34, 152)
	plate_label.add_theme_font_size_override("font_size", 24)
	plate_label.add_theme_color_override("font_color", INK_DIM)
	add_child(plate_label)

	# The reference plate is the species' healthy X-ray, shown at a size you can actually
	# compare against the scan.
	var frame := ColorRect.new()
	frame.color = Color(0.06, 0.08, 0.13)
	frame.position = Vector2(34, 186)
	frame.size = Vector2(560, 560)
	add_child(frame)

	_plate = TextureRect.new()
	_plate.position = frame.position
	_plate.size = frame.size
	_plate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_plate.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_plate)

	var heart_label := Label.new()
	heart_label.text = "NORMAL HEART"
	heart_label.position = Vector2(624, 152)
	heart_label.add_theme_font_size_override("font_size", 24)
	heart_label.add_theme_color_override("font_color", INK_DIM)
	add_child(heart_label)

	_heart = Label.new()
	_heart.position = Vector2(624, 186)
	_heart.size = Vector2(302, 200)
	_heart.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_heart.add_theme_font_size_override("font_size", 27)
	_heart.add_theme_color_override("font_color", INK)
	add_child(_heart)

	var feat_label := Label.new()
	feat_label.text = "SHOULD HAVE"
	feat_label.position = Vector2(34, 772)
	feat_label.add_theme_font_size_override("font_size", 24)
	feat_label.add_theme_color_override("font_color", INK_DIM)
	add_child(feat_label)

	_features = VBoxContainer.new()
	_features.position = Vector2(34, 808)
	_features.size = Vector2(892, 280)
	add_child(_features)

	var close := Button.new()
	close.text = "Close"
	close.position = Vector2(PANEL_SIZE.x - 240, PANEL_SIZE.y - 100)
	close.size = Vector2(200, 70)
	close.add_theme_font_size_override("font_size", 30)
	close.pressed.connect(close_book)
	add_child(close)


func show_for(spec: PatientSpec) -> void:
	var creature := spec.creature
	var book: Dictionary = creature.get("handbook", {})
	var chart: Dictionary = creature.get("chart", {})

	# The species named on the CHART, not the true species. If the chart is lying about the
	# species, the handbook must show the page the paperwork claims — that is precisely how the
	# player catches a species lie: the reference will not match the animal in front of them.
	_title.text = str(spec.chart.get("species_label", chart.get("species_label", "Unknown")))

	var plate = _reference_plate(spec)
	_plate.texture = plate if plate is Texture2D else null

	_heart.text = str(book.get("heart", "A steady, even double thump. Calm breathing underneath."))

	for child in _features.get_children():
		child.queue_free()
	var features: Array = book.get("features", [])
	if features.is_empty():
		features = ["Two eyes, round pupils", "A closed, even mouth", "One shadow, cast to match the lamp"]
	for line in features:
		var l := Label.new()
		l.text = "  -  " + str(line)
		l.add_theme_font_size_override("font_size", 28)
		l.add_theme_color_override("font_color", INK)
		_features.add_child(l)

	visible = true
	_closed = false


## Resolve the reference plate for the species the CHART claims. Looking it up by the claimed
## label (rather than using the patient's own creature) is what lets a species lie be caught by
## the handbook as well as by eye.
func _reference_plate(spec: PatientSpec) -> Variant:
	var claimed := str(spec.chart.get("species_label", ""))
	var true_label := str(spec.creature.get("chart", {}).get("species_label", ""))
	if claimed != "" and claimed != true_label:
		for c in Roster.creatures:
			if str(c.get("chart", {}).get("species_label", "")) == claimed:
				return c.get("xray", "")
	return spec.creature.get("xray", "")


func close_book() -> void:
	if _closed:
		return
	_closed = true
	visible = false
	closed.emit()
