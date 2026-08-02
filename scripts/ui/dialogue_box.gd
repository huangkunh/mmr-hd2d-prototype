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
## Emitted when the player selects a branching choice (carries the index).
signal choice_made(choice_index: int)

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

# --- Branching choices ------------------------------------------------------
## Choices offered after the last line (empty = no choices).
var _choices: Array[String] = []
## Currently highlighted choice index.
var _choice_index: int = 0
## True while the choice list is on screen awaiting input.
var _showing_choices: bool = false
## Label nodes for each choice (kept for highlight updates).
var _choice_labels: Array[Label] = []
## Container that holds the choice labels (hidden until needed).
var _choice_container: VBoxContainer

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
	# Create choice container (hidden by default)
	_choice_container = VBoxContainer.new()
	_choice_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_choice_container.offset_left = 40
	_choice_container.offset_top = -120
	_choice_container.offset_right = -40
	_choice_container.offset_bottom = -20
	_choice_container.alignment = BoxContainer.ALIGNMENT_END
	_choice_container.add_theme_constant_override("separation", 4)
	_choice_container.visible = false
	add_child(_choice_container)


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
	if _showing_choices:
		if event.is_action_pressed("move_up"):
			_move_choice(-1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("move_down"):
			_move_choice(1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("confirm") or event.is_action_pressed("interact"):
			_select_choice()
			get_viewport().set_input_as_handled()
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
	var raw_choices = data.get("choices", [])
	var parsed_choices: Array[String] = []
	for c in raw_choices:
		parsed_choices.append(String(c))
	if not parsed_choices.is_empty():
		start_with_choices(String(data.get("name", "")), parsed, parsed_choices)
	else:
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


## Starts a dialogue with branching choices at the end.
## After all lines are shown, the choices appear for selection.
func start_with_choices(speaker: String, raw_lines: Array[String], choices: Array[String]) -> void:
	_choices = choices
	start_with(speaker, raw_lines)


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
	if not _choices.is_empty():
		_show_choices()
		return
	active = false
	visible = false
	continue_arrow.visible = false
	dialogue_text.text = ""
	speaker_label.text = ""
	dialogue_finished.emit()


# --- Branching choices -------------------------------------------------------

func _show_choices() -> void:
	_showing_choices = true
	continue_arrow.visible = false
	_choice_container.visible = true
	# Clear old labels
	for label in _choice_labels:
		label.queue_free()
	_choice_labels.clear()
	# Create labels for each choice
	for i in _choices.size():
		var l := Label.new()
		l.text = _choices[i]
		l.add_theme_font_size_override("font_size", 18)
		l.add_theme_color_override("font_color", Color.WHITE if i != _choice_index else Color(1.0, 0.92, 0.23))
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_outline_size_override("outline_size", 3)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_choice_container.add_child(l)
		_choice_labels.append(l)

func _select_choice() -> void:
	if not _showing_choices:
		return
	var chosen: int = _choice_index
	_showing_choices = false
	_choice_container.visible = false
	_choices = []
	active = false
	visible = false
	dialogue_text.text = ""
	speaker_label.text = ""
	choice_made.emit(chosen)
	dialogue_finished.emit()

func _move_choice(direction: int) -> void:
	if _choice_labels.is_empty():
		return
	_choice_index = posmod(_choice_index + direction, _choice_labels.size())
	for i in _choice_labels.size():
		_choice_labels[i].add_theme_color_override(
			"font_color",
			Color(1.0, 0.92, 0.23) if i == _choice_index else Color.WHITE
		)
	AudioManager.play_sfx("cursor")


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
