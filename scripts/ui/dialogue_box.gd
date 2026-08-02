## DialogueBox
## Control node that displays a multi-line dialogue with a typewriter effect.
##
## Usage:
##   var box := preload("res://scenes/dialogue.tscn").instantiate()
##   add_child(box)
##   box.dialogue_finished.connect(_on_done)
##   box.start("intro_npc")              # by dialogue id (DataLoader)
##   # or supply raw data:
##   box.start_with("Shopkeeper", ["Hi!", "Buy something?"])
##
## Input (consumed via _unhandled_input):
##   - confirm / interact: if the line is still typing, skip to the end; if the
##     line is fully shown, advance to the next line (or finish).
##   - cancel: same as confirm (handy when Esc is also mapped to cancel).
extends Control

# --- Signals ----------------------------------------------------------------
## Emitted after the last line has been advanced past.
signal dialogue_finished()

# --- Exports ----------------------------------------------------------------
## Typewriter speed in revealed characters per second.
@export var text_speed: float = 45.0
## When true, the box auto-advances to the next line a moment after the current
## one finishes typing (still skippable with confirm).
@export var auto_advance: bool = false
## Delay (seconds) before auto-advancing a completed line.
@export_range(0.0, 5.0, 0.05) var auto_advance_delay: float = 1.5
## Optional audio stream played per character during the typewriter.
@export var blip_sound: AudioStream = null

# --- State ------------------------------------------------------------------
## Lines to display (populated by start()).
var lines: Array[String] = []
## Speaker name shown in the header.
var speaker_name: String = ""
## Index of the line currently being shown.
var current_line: int = 0
## Fractional character reveal counter (accumulates text_speed * delta).
var revealed: float = 0.0
## True when the current line has been fully revealed.
var line_done: bool = false
## True while the box is actively running a dialogue.
var active: bool = false
## Time since the current line finished typing (for auto-advance).
var since_done: float = 0.0
## Cooldown after a character blip so SFX don't stack every frame.
var _blip_accum: float = 0.0

# --- Scene references (set via % unique names in dialogue.tscn) -------------
@onready var speaker_label: Label = %SpeakerLabel
@onready var dialogue_text: RichTextLabel = %DialogueText
@onready var continue_arrow: Control = %ContinueArrow


# --- Lifecycle --------------------------------------------------------------

func _ready() -> void:
	# Start hidden; the caller reveals us via start().
	visible = false
	continue_arrow.visible = false
	dialogue_text.bbcode_enabled = true
	# Mouse input on the box itself should not steal focus from the game.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if not active:
		return

	if not line_done:
		# Reveal more characters of the current line.
		var prev_chars: int = int(revealed)
		revealed += text_speed * delta
		dialogue_text.visible_characters = int(revealed)
		# Play a blip for each newly revealed character.
		_play_blips(prev_chars, int(revealed))
		if dialogue_text.visible_characters >= dialogue_text.get_total_character_count():
			_complete_line()
	else:
		# Blink the continue arrow with a cheap sine pulse.
		var t: float = Time.get_ticks_msec() * 0.006
		continue_arrow.modulate.a = 0.35 + 0.65 * (0.5 + 0.5 * sin(t))

		if auto_advance:
			since_done += delta
			if since_done >= auto_advance_delay:
				_advance()


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event.is_action_pressed("confirm") or event.is_action_pressed("interact") or event.is_action_pressed("cancel"):
		# While a line is still typing, confirm instantly completes it.
		# Once complete, confirm advances to the next line (or ends).
		if not line_done:
			_complete_line()
		else:
			_advance()
		get_viewport().set_input_as_handled()


# --- Public API --------------------------------------------------------------

## Starts a dialogue by id, loading speaker + lines from DataLoader.
func start(dialogue_id: String) -> void:
	var data: Dictionary = DataLoader.get_dialogue(dialogue_id)
	if data.is_empty():
		push_warning("[DialogueBox] Unknown dialogue id: %s" % dialogue_id)
		dialogue_finished.emit()
		return
	var raw_lines = data.get("lines", [])
	var parsed: Array[String] = []
	for l in raw_lines:
		parsed.append(String(l))
	start_with(String(data.get("name", "")), parsed)


## Starts a dialogue from explicit speaker + lines (bypasses DataLoader).
func start_with(speaker: String, raw_lines: Array[String]) -> void:
	if raw_lines.is_empty():
		dialogue_finished.emit()
		return
	speaker_name = speaker
	lines = raw_lines
	current_line = 0
	active = true
	visible = true
	since_done = 0.0
	_show_line()


## Forcefully closes the dialogue immediately (e.g. scene change).
func stop() -> void:
	_end()


## True while the box is mid-dialogue.
func is_active() -> bool:
	return active


# --- Internal ---------------------------------------------------------------

func _show_line() -> void:
	speaker_label.text = speaker_name
	dialogue_text.text = lines[current_line]
	dialogue_text.visible_characters = 0
	revealed = 0.0
	line_done = false
	since_done = 0.0
	continue_arrow.visible = false
	_blip_accum = 0.0


func _complete_line() -> void:
	if line_done:
		return
	line_done = true
	dialogue_text.visible_characters = -1  # -1 reveals everything
	continue_arrow.visible = true


func _advance() -> void:
	current_line += 1
	if current_line >= lines.size():
		_end()
	else:
		_show_line()


func _end() -> void:
	active = false
	visible = false
	continue_arrow.visible = false
	dialogue_text.text = ""
	speaker_label.text = ""
	dialogue_finished.emit()


# --- Audio -------------------------------------------------------------------

func _play_blips(from_char: int, to_char: int) -> void:
	if blip_sound == null:
		return
	if to_char <= from_char:
		return
	# Throttle: only play roughly every other character so it's not a buzz.
	_blip_accum += (to_char - from_char)
	if _blip_accum < 2.0:
		return
	_blip_accum = 0.0
	var player := AudioStreamPlayer.new()
	add_child(player)
	player.stream = blip_sound
	player.pitch_scale = 0.9 + randf() * 0.2
	player.finished.connect(player.queue_free)
	player.play()
