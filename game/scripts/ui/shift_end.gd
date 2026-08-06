extends Node2D

## Between-shift screen: the result, and the only place in the game an interstitial ad is
## allowed to appear. Never mid-shift — that is a scope law, not a preference.
##
## It also hosts the rewarded "continue" offer after a failed shift, which is user-initiated
## and therefore compliant, unlike an ad that interrupts play.

const CANVAS := Vector2(1080, 1920)

var _passed := false
var _stats: Dictionary = {}


func _ready() -> void:
	_passed = GameState.last_passed
	_stats = GameState.last_stats
	_build()
	# Placeholder for the AdMob call. Deliberately a no-op seam rather than a TODO comment:
	# the frequency rules live in data, so wiring the real SDK in week 3 is a one-line change
	# here and nothing else in the game needs to know ads exist.
	_maybe_show_interstitial()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.048, 0.054, 0.068)
	bg.size = CANVAS
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

	var is_endless: bool = _stats.get("mode", GameState.Mode.CAMPAIGN) == GameState.Mode.ENDLESS

	var heading := Label.new()
	heading.size = Vector2(CANVAS.x, 120)
	heading.position = Vector2(0, 260)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 76)
	if _passed:
		heading.text = "SHIFT COMPLETE"
		heading.add_theme_color_override("font_color", Color(0.52, 0.76, 0.56))
	else:
		heading.text = "SHIFT FAILED"
		heading.add_theme_color_override("font_color", Color(0.78, 0.36, 0.38))
	layer.add_child(heading)

	var lines := [
		"Correct        %d" % int(_stats.get("correct", 0)),
		"Mistakes       %d" % int(_stats.get("wrong", 0)),
		"Score          %d" % int(_stats.get("score", 0)),
	]
	if is_endless:
		lines.append("Waves cleared  %d" % int(_stats.get("wave", 0)))
		if bool(_stats.get("new_best", false)):
			lines.append("NEW BEST")

	var y := 470.0
	for line in lines:
		var l := Label.new()
		l.text = line
		l.position = Vector2(300, y)
		l.add_theme_font_size_override("font_size", 38)
		l.add_theme_color_override("font_color", Color(0.76, 0.78, 0.82))
		layer.add_child(l)
		y += 62.0

	var by := 1180.0

	if _passed:
		if is_endless:
			_button(layer, "Next Wave", Vector2(240, by), func():
				GameState.next_wave()
				get_tree().change_scene_to_file("res://scenes/Shift.tscn"))
			by += 170.0
		else:
			var night := int(_stats.get("night", 1))
			if night == 0:
				SaveGame.set_value("onboarding_done", true)
			if night < Difficulty.last_campaign_night:
				_button(layer, "Next Night", Vector2(240, by), func():
					GameState.start_campaign_night(night + 1)
					get_tree().change_scene_to_file("res://scenes/Shift.tscn"))
				by += 170.0
			else:
				var done := Label.new()
				done.text = "You survived the week."
				done.size = Vector2(CANVAS.x, 60)
				done.position = Vector2(0, by)
				done.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				done.add_theme_font_size_override("font_size", 40)
				done.add_theme_color_override("font_color", Color(0.80, 0.76, 0.60))
				layer.add_child(done)
				by += 120.0
	else:
		# Rewarded continue, once per run. Offered here, on a screen the player reached by
		# failing, so accepting it is a choice rather than an interruption.
		if GameState.can_continue():
			_button(layer, "Continue  (watch ad)", Vector2(240, by), func():
				if GameState.consume_continue():
					get_tree().change_scene_to_file("res://scenes/Shift.tscn"))
			by += 170.0
		_button(layer, "Retry", Vector2(240, by), func():
			if _stats.get("mode", GameState.Mode.CAMPAIGN) == GameState.Mode.ENDLESS:
				GameState.start_endless(true)
			else:
				GameState.start_campaign_night(int(_stats.get("night", 1)))
			get_tree().change_scene_to_file("res://scenes/Shift.tscn"))
		by += 170.0

	_button(layer, "Clinic Door", Vector2(240, by), func():
		get_tree().change_scene_to_file("res://scenes/Title.tscn"))


func _button(parent: Node, text: String, pos: Vector2, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(600, 130)
	b.add_theme_font_size_override("font_size", 38)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.16, 0.19)
	style.border_color = Color(0.32, 0.34, 0.38)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.20, 0.21, 0.25)
	b.add_theme_stylebox_override("hover", hover)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


## Frequency rules come from difficulty.json so they can be tuned without a rebuild. Pro
## owners never see an interstitial, and the first couple of nights are ad-free so a new
## player's first impression is the game rather than an ad.
func _maybe_show_interstitial() -> void:
	if bool(SaveGame.get_value("pro", false)):
		return
	var suppress_before := int(Difficulty.ads.get("suppress_before_night", 2))
	if int(_stats.get("night", 0)) < suppress_before and _stats.get("mode") != GameState.Mode.ENDLESS:
		return
	var every := maxi(1, int(Difficulty.ads.get("interstitial_min_shifts_between", 2)))
	if int(SaveGame.get_value("shifts_finished", 0)) % every != 0:
		return
	if OS.is_debug_build():
		print("[Ads] interstitial would show here")
