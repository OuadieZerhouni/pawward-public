extends Node

## The run's state and the single source of truth for verdicts.
##
## Scenes ask this to judge a stamp and then react to its signals, rather than working out
## right/wrong themselves. One place decides, so the strike rules, scoring and the fail
## condition can't drift apart between the campaign and endless modes.

signal verdict_registered(correct: bool, spec: PatientSpec)
signal strike_added(strikes: int)
signal score_changed(score: int)
signal shift_over(passed: bool, stats: Dictionary)

enum Mode { CAMPAIGN, ENDLESS }

var mode: Mode = Mode.CAMPAIGN
var night := 1
var wave := 0
var strikes := 0
var score := 0
var streak := 0
var queue: Array[PatientSpec] = []
var index := 0
var hints_left := 0
var continues_used := 0

## Outcome of the shift that just ended, read by ShiftEnd after the scene change. Kept here
## rather than in its own autoload because it is run state like everything else above.
var last_passed := false
var last_stats: Dictionary = {}

var _rng := RandomNumberGenerator.new()
var _correct := 0
var _wrong := 0
var _patient_shown_at := 0.0


var current: PatientSpec:
	get:
		if index >= 0 and index < queue.size():
			return queue[index]
		return null

var patients_remaining: int:
	get: return maxi(0, queue.size() - index)

var max_strikes: int:
	get: return int(Difficulty.strikes.get("max", 3))


func start_campaign_night(target_night: int) -> void:
	mode = Mode.CAMPAIGN
	night = target_night
	wave = 0
	# A fresh seed per attempt: retrying a failed night must not replay the same patients, or
	# memorisation replaces observation.
	_rng.seed = randi()
	_begin(Difficulty.night_config(target_night))


func start_endless(daily: bool = true) -> void:
	mode = Mode.ENDLESS
	night = int(Difficulty.endless.get("entry_night_equivalent", 4))
	wave = 0
	_rng.seed = Difficulty.daily_seed() if daily else randi()
	_begin(Difficulty.endless_config(0))


## Next endless wave, keeping score and strikes.
func next_wave() -> void:
	wave += 1
	queue = Roster.build_shift(_rng, Difficulty.endless_config(wave))
	index = 0
	_refresh_hints()
	mark_patient_shown()


func _begin(config: Dictionary) -> void:
	strikes = 0
	score = 0
	streak = 0
	index = 0
	continues_used = 0
	_correct = 0
	_wrong = 0
	queue = Roster.build_shift(_rng, config)
	_refresh_hints()
	score_changed.emit(score)
	mark_patient_shown()


func _refresh_hints() -> void:
	hints_left = int(Difficulty.hints.get("second_opinion_per_shift", 2))


## Start the clock for the speed bonus. Called when the patient finishes sliding in, not when
## it is created, so the entrance animation isn't scored against the player.
func mark_patient_shown() -> void:
	_patient_shown_at = Time.get_ticks_msec() / 1000.0


## Judge a stamp. `admit` is what the player chose; a patient should be admitted exactly when
## it is not anomalous.
func register_verdict(admit: bool) -> bool:
	var spec := current
	if spec == null:
		return false

	var correct := admit != spec.is_anomalous
	if correct:
		_correct += 1
		streak += 1
		var taken := Time.get_ticks_msec() / 1000.0 - _patient_shown_at
		score += Difficulty.score_for(streak - 1, taken)
		score_changed.emit(score)
	else:
		_wrong += 1
		streak = 0
		strikes += 1
		strike_added.emit(strikes)

	verdict_registered.emit(correct, spec)
	return correct


## Advance past the judged patient. Returns false when the shift is over, having emitted
## shift_over with the reason baked into `passed`.
func advance() -> bool:
	if strikes >= max_strikes:
		_finish(false)
		return false
	index += 1
	if index >= queue.size():
		_finish(true)
		return false
	mark_patient_shown()
	return true


## Spend a hint. Returns the region to highlight, or an empty Rect2 if none is available.
func use_hint() -> Dictionary:
	var spec := current
	if spec == null or hints_left <= 0:
		return {}
	hints_left -= 1
	return {
		"rect": spec.hint_rect,
		"on_chart": spec.hint_points_at_chart,
		"has_target": spec.is_anomalous,
	}


## Rewarded-ad continue: clears strikes back under the limit so the run can go on. Allowed
## once per run, and only from the fail screen — never mid-shift.
func can_continue() -> bool:
	return continues_used < int(Difficulty.strikes.get("rewarded_continue_per_run", 1))


func consume_continue() -> bool:
	if not can_continue():
		return false
	continues_used += 1
	strikes = maxi(0, strikes - int(Difficulty.strikes.get("continue_clears_strikes", 1)))
	return true


func stats() -> Dictionary:
	return {
		"mode": mode,
		"night": night,
		"wave": wave,
		"score": score,
		"correct": _correct,
		"wrong": _wrong,
		"strikes": strikes,
		"patients": queue.size(),
	}


func _finish(passed: bool) -> void:
	var s := stats()
	s["passed"] = passed
	if passed:
		SaveGame.note_shift_finished()
		if mode == Mode.CAMPAIGN:
			if night >= Difficulty.last_campaign_night:
				SaveGame.set_value("campaign_complete", true)
			else:
				SaveGame.unlock_night(night + 1)
	if mode == Mode.ENDLESS:
		s["new_best"] = SaveGame.record_endless(score, wave)
	shift_over.emit(passed, s)
