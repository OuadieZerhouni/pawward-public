extends Node

## Command-line hooks for driving the game without a human. Debug builds only — everything
## here early-returns in a release export.
##
## Why this exists: the dev machine is Windows and the target is iOS, so being able to jump
## straight into a given state and capture what it looks like is the main way visual changes
## get verified at all. It is also the harness the App Store screenshots will come from.
##
## Flags go after a bare `--`, e.g.
##   godot --path game -- --play 3 --shot C:/out.png --shot-frame 90
##   godot --path game -- --autoplay 3          # stamp through a whole shift, print the log
##
##   --play N       start campaign night N immediately (0 = onboarding)
##   --endless      start an endless run immediately
##   --shot PATH    write a PNG then quit (needs a real GL context, so no --headless)
##   --shot-frame N which frame to capture on (default 60)
##   --autoplay N   play night N automatically with perfect judgement, then quit
##   --force-channel C  make the first patient carry a `visual|skeleton|sound|behaviour|data` anomaly
##   --auto-tool T  press tool `xray|stethoscope|handbook` once the patient is inspectable

const DEFAULT_SHOT_FRAME := 60

var _shot_path := ""
var _shot_frame := DEFAULT_SHOT_FRAME
var _frames := 0
var _autoplay := false
var _autoplay_log: Array[String] = []
var _force_channel := ""
var _auto_tool := ""
var _auto_pause := false
var _auto_tool_done := false


func _ready() -> void:
	if not OS.is_debug_build():
		return
	# Keep processing while the tree is paused, otherwise capturing the pause menu is impossible:
	# pausing stops the very hook that would take the screenshot.
	process_mode = Node.PROCESS_MODE_ALWAYS

	var args := OS.get_cmdline_user_args()
	_shot_path = _flag_value(args, "--shot")
	var frame := _flag_value(args, "--shot-frame")
	if frame != "":
		_shot_frame = maxi(1, int(frame))

	var autoplay_night := _flag_value(args, "--autoplay")
	if autoplay_night != "":
		_autoplay = true
		GameState.shift_over.connect(_on_autoplay_shift_over)
		_start_shift(int(autoplay_night), false)
		return

	# --force-channel lets a screenshot land on a specific anomaly kind, which is the only way
	# to verify the scan or stethoscope views without playing until one happens to appear.
	var forced := _flag_value(args, "--force-channel")
	if forced != "":
		_force_channel = forced

	_auto_tool = _flag_value(args, "--auto-tool")
	_auto_pause = args.has("--auto-pause")

	var play_night := _flag_value(args, "--play")
	if play_night != "":
		_start_shift(int(play_night), false)
	elif args.has("--endless"):
		_start_shift(0, true)


func _start_shift(night: int, endless: bool) -> void:
	# Defer so the autoloads finish _ready and the initial scene is in the tree first.
	await get_tree().process_frame
	if endless:
		GameState.start_endless(false)
	else:
		GameState.start_campaign_night(night)
	if _force_channel != "":
		_apply_force_channel()
	get_tree().change_scene_to_file("res://scenes/Shift.tscn")


## Rewrite the queue so the first patient carries the wanted channel. Debug only.
func _apply_force_channel() -> void:
	for spec in GameState.queue:
		for a in spec.creature.get("anomalies", []):
			if Roster.channel_of(a) == _force_channel:
				spec.anomaly = a
				GameState.queue[0] = spec
				print("[DevTools] forced %s -> %s" % [_force_channel, a.get("id")])
				return
	push_warning("[DevTools] no creature has a '%s' anomaly" % _force_channel)


func _process(_delta: float) -> void:
	if not OS.is_debug_build():
		return
	if _autoplay:
		_step_autoplay()
	if _auto_tool != "" and not _auto_tool_done:
		_press_auto_tool()
	if _auto_pause and not _auto_tool_done:
		var sc := get_tree().current_scene
		if sc != null and "state" in sc and sc.state == sc.State.INSPECT:
			_auto_tool_done = true
			sc._open_pause()
	if _shot_path != "":
		_service_shot()


## Activate a tool as soon as the patient is inspectable, so a capture can show the scan view
## or the handbook rather than only the default state.
func _press_auto_tool() -> void:
	var shift := get_tree().current_scene
	if shift == null or not "state" in shift or shift.state != shift.State.INSPECT:
		return
	_auto_tool_done = true
	shift._on_tool_pressed(_auto_tool)


## Judge every patient correctly and walk the whole shift. Catches loop bugs that a unit test
## on the shift builder cannot see — stuck states, verdicts that never advance, a shift that
## never terminates — and prints a transcript so the sequencing is inspectable.
func _step_autoplay() -> void:
	var shift := get_tree().current_scene
	if shift == null or not "state" in shift:
		return
	if shift.state != shift.State.INSPECT:
		return

	var spec: PatientSpec = GameState.current
	if spec == null:
		return
	_autoplay_log.append("  %-42s -> %s" % [
		str(spec), "REJECT" if spec.is_anomalous else "ADMIT"])
	# Correct answer: admit exactly when the patient is not anomalous.
	shift._stamp(not spec.is_anomalous)

	if _autoplay_log.size() > 400:
		push_error("[DevTools] autoplay ran away; aborting")
		_finish_autoplay(false)


func _on_autoplay_shift_over(passed: bool, stats: Dictionary) -> void:
	_autoplay = false
	print("\n[autoplay] %d patients judged, passed=%s, score=%d, mistakes=%d" % [
		_autoplay_log.size(), passed, int(stats.get("score", 0)), int(stats.get("wrong", 0))])
	for line in _autoplay_log:
		print(line)
	# Perfect play must clear the shift. A failure here means the verdict rules disagree with
	# PatientSpec.is_anomalous, which would make the game unwinnable.
	var expected: int = int(stats.get("patients", 0))
	if not passed or int(stats.get("wrong", 0)) != 0 or _autoplay_log.size() != expected:
		push_error("[autoplay] expected a clean sweep of %d patients" % expected)
		get_tree().quit(1)
	else:
		print("[autoplay] clean sweep")
		get_tree().quit(0)


func _finish_autoplay(passed: bool) -> void:
	_autoplay = false
	push_error("[autoplay] aborted after %d patients" % _autoplay_log.size())
	get_tree().quit(1)


func _service_shot() -> void:
	_frames += 1
	if _frames < _shot_frame:
		return
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_shot_path)
	if err == OK:
		print("captured -> ", _shot_path)
	else:
		push_error("[DevTools] capture failed (%d) -> %s" % [err, _shot_path])
	get_tree().quit(0 if err == OK else 1)


static func _flag_value(args: PackedStringArray, flag: String) -> String:
	var i := args.find(flag)
	if i != -1 and i + 1 < args.size():
		return args[i + 1]
	return ""
