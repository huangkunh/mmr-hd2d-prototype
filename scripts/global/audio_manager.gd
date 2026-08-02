## AudioManager: Global audio singleton (Autoload)
## Manages background music (BGM) and sound effects (SFX).
## Since this prototype has no actual audio files, it uses procedural
## AudioStreamGenerator for simple BGM and AudioStreamPlayer for SFX beeps.
extends Node

# --- Signals ---
signal bgm_changed(track_name: String)
signal sfx_played(sfx_name: String)

# --- BGM Player ---
var _bgm_player: AudioStreamPlayer
var _bgm_volume: float = -6.0  # dB
var _bgm_tween: Tween

# --- SFX Player pool (for overlapping sounds) ---
var _sfx_players: Array[AudioStreamPlayer] = []
const SFX_POOL_SIZE: int = 8
var _sfx_index: int = 0

# --- Settings ---
var bgm_enabled: bool = true
var sfx_enabled: bool = true
var sfx_volume: float = -3.0  # dB

# --- BGM track definitions (frequencies for procedural generation) ---
# Each track is a set of note frequencies that loop to create a simple melody.
var _bgm_tracks: Dictionary = {
    "wasteland_theme": {
        "tempo": 0.4,
        "notes": [110.0, 110.0, 146.83, 130.81, 110.0, 98.0, 110.0, 0.0],
        "wave": "sine"
    },
    "town_theme": {
        "tempo": 0.3,
        "notes": [130.81, 164.81, 196.0, 164.81, 130.81, 98.0, 130.81, 0.0],
        "wave": "triangle"
    },
    "ruins_theme": {
        "tempo": 0.5,
        "notes": [82.41, 82.41, 98.0, 110.0, 98.0, 82.41, 73.42, 0.0],
        "wave": "sawtooth"
    },
    "desert_theme": {
        "tempo": 0.35,
        "notes": [146.83, 130.81, 146.83, 174.61, 146.83, 130.81, 110.0, 0.0],
        "wave": "triangle"
    },
    "battle_theme": {
        "tempo": 0.2,
        "notes": [220.0, 220.0, 261.63, 220.0, 196.0, 220.0, 261.63, 293.66],
        "wave": "square"
    },
    "boss_theme": {
        "tempo": 0.18,
        "notes": [110.0, 146.83, 110.0, 146.83, 174.61, 146.83, 110.0, 87.31],
        "wave": "sawtooth"
    },
    "victory_theme": {
        "tempo": 0.25,
        "notes": [261.63, 329.63, 392.0, 523.25, 392.0, 329.63, 261.63, 0.0],
        "wave": "triangle"
    },
    "game_over_theme": {
        "tempo": 0.6,
        "notes": [196.0, 174.61, 155.56, 146.83, 130.81, 116.54, 98.0, 0.0],
        "wave": "sine"
    },
    "menu_theme": {
        "tempo": 0.3,
        "notes": [196.0, 261.63, 196.0, 261.63, 329.63, 261.63, 196.0, 0.0],
        "wave": "sine"
    }
}

var _current_track: String = ""
var _note_index: int = 0
var _note_timer: float = 0.0
var _is_playing_bgm: bool = false

# --- SFX definitions (simple beep frequencies) ---
var _sfx_definitions: Dictionary = {
    "select": {"freq": 880.0, "duration": 0.05, "wave": "square"},
    "confirm": {"freq": 1320.0, "duration": 0.08, "wave": "square"},
    "cancel": {"freq": 440.0, "duration": 0.06, "wave": "square"},
    "cursor": {"freq": 660.0, "duration": 0.03, "wave": "square"},
    "hit": {"freq": 200.0, "duration": 0.1, "wave": "sawtooth"},
    "critical": {"freq": 150.0, "duration": 0.15, "wave": "sawtooth"},
    "miss": {"freq": 300.0, "duration": 0.08, "wave": "sine"},
    "heal": {"freq": 800.0, "duration": 0.2, "wave": "sine"},
    "victory": {"freq": 1046.0, "duration": 0.3, "wave": "triangle"},
    "defeat": {"freq": 100.0, "duration": 0.5, "wave": "sawtooth"},
    "level_up": {"freq": 1200.0, "duration": 0.3, "wave": "triangle"},
    "coin": {"freq": 988.0, "duration": 0.1, "wave": "square"},
    "explosion": {"freq": 80.0, "duration": 0.3, "wave": "sawtooth"},
    "door": {"freq": 300.0, "duration": 0.15, "wave": "sine"},
    "save": {"freq": 700.0, "duration": 0.2, "wave": "sine"},
    "skill": {"freq": 500.0, "duration": 0.15, "wave": "triangle"},
    "flee": {"freq": 400.0, "duration": 0.2, "wave": "sine"},
}

func _ready() -> void:
    # Create BGM player
    _bgm_player = AudioStreamPlayer.new()
    _bgm_player.name = "BGMPlayer"
    _bgm_player.volume_db = _bgm_volume
    add_child(_bgm_player)
    
    # Create SFX player pool
    for i in SFX_POOL_SIZE:
        var player = AudioStreamPlayer.new()
        player.name = "SFXPlayer_%d" % i
        player.volume_db = sfx_volume
        add_child(player)
        _sfx_players.append(player)

func _process(delta: float) -> void:
    if not _is_playing_bgm or not bgm_enabled:
        return
    if _current_track.is_empty():
        return
    
    var track = _bgm_tracks.get(_current_track, {})
    if track.is_empty():
        return
    
    _note_timer += delta
    var tempo = float(track.get("tempo", 0.4))
    
    if _note_timer >= tempo:
        _note_timer = 0.0
        _play_next_note()

func _play_next_note() -> void:
    var track = _bgm_tracks.get(_current_track, {})
    if track.is_empty():
        return
    
    var notes: Array = track.get("notes", [])
    if notes.is_empty():
        return
    
    var freq = float(notes[_note_index])
    _note_index = (_note_index + 1) % notes.size()
    
    if freq <= 0.0:
        _bgm_player.stream = null
        return
    
    var wave_type = String(track.get("wave", "sine"))
    _bgm_player.stream = _generate_tone(freq, float(track.get("tempo", 0.4)) * 0.9, wave_type)
    _bgm_player.play()

func _generate_tone(freq: float, duration: float, wave_type: String) -> AudioStream:
    var sample_rate = 22050
    var num_samples = int(duration * sample_rate)
    var stream = AudioStreamWAV.new()
    stream.format = AudioStreamWAV.FORMAT_16_BITS
    stream.mix_rate = sample_rate
    stream.stereo = false
    
    var data = PackedByteArray()
    data.resize(num_samples * 2)
    
    for i in num_samples:
        var t = float(i) / float(sample_rate)
        var sample_val = 0.0
        
        match wave_type:
            "sine":
                sample_val = sin(t * freq * TAU)
            "square":
                sample_val = 1.0 if sin(t * freq * TAU) >= 0.0 else -1.0
            "sawtooth":
                sample_val = 2.0 * fmod(t * freq, 1.0) - 1.0
            "triangle":
                var phase = fmod(t * freq, 1.0)
                sample_val = 2.0 * abs(2.0 * phase - 1.0) - 1.0
            _:
                sample_val = sin(t * freq * TAU)
        
        # Apply fade-out envelope to avoid clicks
        var fade_samples = min(int(sample_rate * 0.01), num_samples / 4)
        if i < fade_samples:
            sample_val *= float(i) / float(fade_samples)
        elif i > num_samples - fade_samples:
            sample_val *= float(num_samples - i) / float(fade_samples)
        
        # Reduce volume
        sample_val *= 0.15
        
        var int_val = int(sample_val * 32767)
        # Clamp
        int_val = clamp(int_val, -32768, 32767)
        
        # Write as little-endian 16-bit
        data[i * 2] = int_val & 0xFF
        data[i * 2 + 1] = (int_val >> 8) & 0xFF
    
    stream.data = data
    return stream

# --- BGM API ---

func play_bgm(track_name: String) -> void:
    if track_name == _current_track and _is_playing_bgm:
        return
    if not _bgm_tracks.has(track_name):
        push_warning("[AudioManager] Unknown BGM track: %s" % track_name)
        return
    _current_track = track_name
    _note_index = 0
    _note_timer = 0.0
    _is_playing_bgm = true
    if not bgm_enabled:
        _bgm_player.stream = null
    bgm_changed.emit(track_name)
    print("[AudioManager] Playing BGM: %s" % track_name)

func stop_bgm() -> void:
    _is_playing_bgm = false
    _bgm_player.stop()
    _bgm_player.stream = null
    _current_track = ""

func pause_bgm() -> void:
    _is_playing_bgm = false
    _bgm_player.stream = null

func resume_bgm() -> void:
    if not _current_track.is_empty():
        _is_playing_bgm = true

func set_bgm_volume(volume_db: float) -> void:
    _bgm_volume = volume_db
    _bgm_player.volume_db = volume_db

# --- SFX API ---

func play_sfx(sfx_name: String) -> void:
    if not sfx_enabled:
        return
    if not _sfx_definitions.has(sfx_name):
        push_warning("[AudioManager] Unknown SFX: %s" % sfx_name)
        return
    
    var def = _sfx_definitions[sfx_name]
    var freq = float(def.get("freq", 440.0))
    var duration = float(def.get("duration", 0.1))
    var wave_type = String(def.get("wave", "sine"))
    
    var player = _sfx_players[_sfx_index]
    _sfx_index = (_sfx_index + 1) % SFX_POOL_SIZE
    
    player.stream = _generate_tone(freq, duration, wave_type)
    player.volume_db = sfx_volume
    player.play()
    sfx_played.emit(sfx_name)

func set_sfx_volume(volume_db: float) -> void:
    sfx_volume = volume_db
    for player in _sfx_players:
        player.volume_db = volume_db

func toggle_bgm() -> void:
    bgm_enabled = not bgm_enabled
    if not bgm_enabled:
        pause_bgm()
    else:
        resume_bgm()

func toggle_sfx() -> void:
    sfx_enabled = not sfx_enabled
