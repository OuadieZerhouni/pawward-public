extends Node

## Sound. Small enough to be a flat registry rather than a system.
##
## Every cue goes through here so the reduce-scare setting and the volume sliders have exactly
## one place to apply, and so a missing file degrades to silence instead of a crash — the SFX
## are generated assets that may not all exist yet at any given moment.

const SFX := {
	"stamp": "res://assets/audio/sfx/stamp.mp3",
	"paper": "res://assets/audio/sfx/paper.mp3",
	"static": "res://assets/audio/sfx/static.mp3",
	"heartbeat": "res://assets/audio/sfx/heartbeat.mp3",
	"bell": "res://assets/audio/sfx/bell.mp3",
}

## Cues that exist to startle. Suppressed entirely when the player asks for fewer scares —
## the setting has to actually mean something or it is a lie in the options menu.
const SCARE_CUES := ["static", "heartbeat"]

const MUSIC_NIGHT := "res://assets/audio/music/night_ambient.mp3"

const POLYPHONY := 6

var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _music: AudioStreamPlayer
var _music_path := ""


func _ready() -> void:
	for key in SFX:
		var path: String = SFX[key]
		if ResourceLoader.exists(path):
			_streams[key] = load(path)
		elif OS.is_debug_build():
			print("[AudioBus] missing %s" % path)

	# A small fixed pool: overlapping stamps and paper rustles are normal, and allocating a
	# player per cue would churn nodes during the busiest moment of the loop.
	for i in range(POLYPHONY):
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)

	_music = AudioStreamPlayer.new()
	_music.bus = "Master"
	add_child(_music)


func play(cue: String, volume_db: float = 0.0, pitch_variation: float = 0.06) -> void:
	if not _streams.has(cue):
		return
	if cue in SCARE_CUES and bool(SaveGame.get_value("reduce_scare", false)):
		return

	var player := _players[_next]
	_next = (_next + 1) % _players.size()
	player.stream = _streams[cue]
	player.volume_db = volume_db + linear_to_db(maxf(0.01, float(SaveGame.get_value("sfx_volume", 1.0))))
	# A touch of pitch scatter stops the stamp from sounding like a UI beep after the twentieth
	# patient. Cheap, and it is most of what makes a repeated cue feel physical.
	player.pitch_scale = 1.0 + randf_range(-pitch_variation, pitch_variation)
	player.play()


## Heart cues are looked up lazily by name because they are content, not a fixed registry: new
## sound anomalies should be addable by dropping a heart_<id>.mp3 in and naming it in the roster.
## Never suppressed by reduce-scare: the stethoscope is a deliberate action and the cue IS the
## information, so silencing it would make those patients unwinnable.
func play_heart(cue: String) -> void:
	var path := "res://assets/audio/sfx/%s.mp3" % cue
	if not _streams.has(cue):
		if not ResourceLoader.exists(path):
			if OS.is_debug_build():
				print("[AudioBus] no heart cue %s" % path)
			return
		_streams[cue] = load(path)
	var player := _players[_next]
	_next = (_next + 1) % _players.size()
	player.stream = _streams[cue]
	player.volume_db = linear_to_db(maxf(0.01, float(SaveGame.get_value("sfx_volume", 1.0))))
	player.pitch_scale = 1.0
	player.play()


func play_music(path: String = MUSIC_NIGHT, volume_db: float = -12.0) -> void:
	if not ResourceLoader.exists(path):
		return
	# Already playing this track: leave it alone rather than restarting it on every scene
	# change. Ambience that restarts each time you stamp a patient is worse than none.
	if _music.playing and _music_path == path:
		return
	var stream := load(path)
	if stream is AudioStream:
		if stream is AudioStreamMP3:
			(stream as AudioStreamMP3).loop = true
		_music_path = path
		_music.stream = stream
		_music.volume_db = volume_db + linear_to_db(
				maxf(0.01, float(SaveGame.get_value("music_volume", 0.8))))
		_music.play()


## Re-apply the music volume without restarting the track, so the settings slider can be heard
## while it is being dragged.
func apply_music_volume(base_db: float = -12.0) -> void:
	_music.volume_db = base_db + linear_to_db(
			maxf(0.01, float(SaveGame.get_value("music_volume", 0.8))))


func stop_music() -> void:
	_music.stop()
	_music_path = ""
