## HUD
## CanvasLayer that renders the in-game heads-up display and a pause menu.
##
## Attach this script to a CanvasLayer node (or a plain Node — _ready promotes
## the UI into a Control child). The UI is built programmatically so the HUD is
## fully self-contained: no companion .tscn is required.
##
## Displayed elements:
##   - Player HP bar (listens to GameState.hp_changed)
##   - Gold counter (listens to GameState.gold_changed)
##   - Current map name (read from GameState.current_map via DataLoader)
##   - Minimap placeholder box
##   - "Esc: Menu" hint label
##
## Pause overlay (toggled with the "menu" action / Esc):
##   Resume / Save / Load / Settings / Quit
extends CanvasLayer

# --- Signals ----------------------------------------------------------------
signal pause_toggled(is_paused: bool)
signal save_requested()
signal load_requested()
signal settings_requested()
signal quit_requested()

# --- Exports ----------------------------------------------------------------
## When true, opening the pause menu also pauses the SceneTree.
@export var pause_tree_on_menu: bool = true
## Colour of the HP bar fill when HP is healthy / low.
@export var hp_color_full: Color = Color(0.35, 0.85, 0.35)
@export var hp_color_low: Color = Color(0.9, 0.25, 0.25)

# --- State ------------------------------------------------------------------
var _paused: bool = false
var _pause_index: int = 0

# --- UI handles (built in _ready) -------------------------------------------
var root: Control
var hp_bar: ProgressBar
var hp_label: Label
var gold_label: Label
var map_label: Label
var minimap_box: Panel
var minimap_label: Label
var menu_hint: Label

var pause_overlay: Control
var pause_panel: Panel
var pause_buttons: Array[Button] = []


# --- Lifecycle --------------------------------------------------------------

func _ready() -> void:
	# Keep processing while the tree is paused so the pause menu still works.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build_ui()
	_wire_signals()

	# Seed display from the current GameState.
	_on_hp_changed(GameState.player_hp, GameState.player_max_hp)
	_on_gold_changed(GameState.gold)
	_update_map_name()


func _wire_signals() -> void:
	if not GameState.hp_changed.is_connected(_on_hp_changed):
		GameState.hp_changed.connect(_on_hp_changed)
	if not GameState.gold_changed.is_connected(_on_gold_changed):
		GameState.gold_changed.connect(_on_gold_changed)


func _exit_tree() -> void:
	# Defensive: make sure we don't leave the whole tree paused if the HUD is
	# removed while its pause menu is open.
	if pause_tree_on_menu and get_tree():
		get_tree().paused = false


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		# If another modal (e.g. MenuSystem) already paused the tree and we are
		# not the one that owns that pause, do nothing and let it handle Esc.
		if get_tree().paused and not _paused:
			return
		toggle_pause()
		get_viewport().set_input_as_handled()
		return

	if _paused:
		# Arrow-key / confirm navigation of the pause menu.
		if event.is_action_pressed("move_up"):
			_move_pause_selection(-1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("move_down"):
			_move_pause_selection(1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("confirm"):
			_activate_pause_selection()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("cancel"):
			set_paused(false)
			get_viewport().set_input_as_handled()


# --- Pause menu --------------------------------------------------------------

func toggle_pause() -> void:
	set_paused(not _paused)


func set_paused(value: bool) -> void:
	_paused = value
	pause_overlay.visible = _paused
	if pause_tree_on_menu:
		get_tree().paused = _paused
	if _paused and not pause_buttons.is_empty():
		_pause_index = 0
		_highlight_pause()
	pause_toggled.emit(_paused)


func _move_pause_selection(direction: int) -> void:
	if pause_buttons.is_empty():
		return
	var count: int = pause_buttons.size()
	_pause_index = posmod(_pause_index + direction, count)
	_highlight_pause()


func _highlight_pause() -> void:
	for i in pause_buttons.size():
		var selected: bool = (i == _pause_index)
		pause_buttons[i].add_theme_color_override(
			"font_color",
			Color(1.0, 0.92, 0.23) if selected else Color.WHITE
		)


func _activate_pause_index(idx: int) -> void:
	match idx:
		0: _on_resume()
		1: _on_save()
		2: _on_load()
		3: _on_settings()
		4: _on_quit()


func _activate_pause_selection() -> void:
	if pause_buttons.is_empty():
		return
	_activate_pause_index(_pause_index)


# --- Pause button handlers --------------------------------------------------

func _on_resume() -> void:
	set_paused(false)


func _on_save() -> void:
	GameState.save_game()
	save_requested.emit()
	# Briefly flash the button text as feedback.
	_flash_button(pause_buttons[1], "Saved!")


func _on_load() -> void:
	if not GameState.has_save():
		_flash_button(pause_buttons[2], "No save!")
		return
	GameState.load_game()
	# GameState.load_game() only emits hp_changed, so refresh the other HUD
	# fields (gold / map) that may have changed on disk manually.
	_on_gold_changed(GameState.gold)
	_update_map_name()
	load_requested.emit()
	_flash_button(pause_buttons[2], "Loaded!")


func _on_settings() -> void:
	settings_requested.emit()
	_flash_button(pause_buttons[3], "(stub)")


func _on_quit() -> void:
	quit_requested.emit()
	# Leave the tree unpaused so quit can proceed cleanly.
	if pause_tree_on_menu:
		get_tree().paused = false
	get_tree().quit()


func _flash_button(btn: Button, message: String) -> void:
	if btn == null:
		return
	var original: String = btn.text
	btn.text = message
	await get_tree().create_timer(1.0).timeout
	if is_instance_valid(btn):
		btn.text = original


# --- GameState signal handlers ----------------------------------------------

func _on_hp_changed(current: int, maximum: int) -> void:
	if hp_bar:
		hp_bar.max_value = maxi(maximum, 1)
		hp_bar.value = clampi(current, 0, maximum)
		var ratio: float = float(current) / float(maxi(maximum, 1))
		# Tint the bar red when critical, otherwise a healthy green.
		hp_bar.modulate = hp_color_low if ratio < 0.33 else hp_color_full
	if hp_label:
		hp_label.text = "HP %d / %d" % [current, maximum]


func _on_gold_changed(amount: int) -> void:
	if gold_label:
		gold_label.text = "%d G" % amount


func _update_map_name() -> void:
	if map_label == null:
		return
	var map_data: Dictionary = DataLoader.get_map_data(GameState.current_map)
	var display_name: String = String(map_data.get("name", GameState.current_map))
	map_label.text = display_name


## Public hook: call this when GameState.current_map changes so the HUD label
## updates (the autoload doesn't emit a map-changed signal).
func notify_map_changed() -> void:
	_update_map_name()


# --- UI construction --------------------------------------------------------
# Everything below builds the HUD from code so the script is drop-in: just
# attach it to a CanvasLayer in any world scene.

func _build_ui() -> void:
	root = Control.new()
	root.name = "HUDRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	_build_top_left()
	_build_top_right()
	_build_bottom_hint()
	_build_pause_overlay()


func _build_top_left() -> void:
	# A semi-transparent panel holding HP bar + gold + map name.
	var panel := _make_panel(Color(0, 0, 0, 0.55))
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(16, 16)
	panel.size = Vector2(330, 92)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 10
	vbox.offset_top = 8
	vbox.offset_right = -10
	vbox.offset_bottom = -8
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var hp_row := HBoxContainer.new()
	hp_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hp_row)

	hp_label = _make_label("HP 100 / 100", 14)
	hp_label.custom_minimum_size = Vector2(120, 0)
	hp_row.add_child(hp_label)

	hp_bar = ProgressBar.new()
	hp_bar.min_value = 0
	hp_bar.max_value = 100
	hp_bar.value = 100
	hp_bar.custom_minimum_size = Vector2(170, 18)
	hp_bar.show_percentage = false
	hp_row.add_child(hp_bar)

	gold_label = _make_label("0 G", 14)
	vbox.add_child(gold_label)

	map_label = _make_label("Map", 13)
	map_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.7))
	vbox.add_child(map_label)


func _build_top_right() -> void:
	# Minimap placeholder in the top-right corner. Anchored to the right edge so
	# it stays put at any window size (PRESET_TOP_RIGHT pins to top-right).
	minimap_box = _make_panel(Color(0, 0, 0, 0.55))
	minimap_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	minimap_box.offset_left = -176.0
	minimap_box.offset_top = 16.0
	minimap_box.offset_right = -16.0
	minimap_box.offset_bottom = 136.0
	minimap_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(minimap_box)

	minimap_label = _make_label("MINIMAP\n(placeholder)", 12)
	minimap_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	minimap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	minimap_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	minimap_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	minimap_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	minimap_box.add_child(minimap_label)


func _build_bottom_hint() -> void:
	menu_hint = _make_label("Esc: Menu", 13)
	menu_hint.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	menu_hint.anchor_left = 1.0
	menu_hint.anchor_right = 1.0
	menu_hint.anchor_top = 1.0
	menu_hint.anchor_bottom = 1.0
	menu_hint.offset_left = -160
	menu_hint.offset_top = -32
	menu_hint.offset_right = -16
	menu_hint.offset_bottom = -12
	menu_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	menu_hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	menu_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(menu_hint)


func _build_pause_overlay() -> void:
	pause_overlay = Control.new()
	pause_overlay.name = "PauseOverlay"
	pause_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_overlay.visible = false
	root.add_child(pause_overlay)

	# Dim background.
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_overlay.add_child(dim)

	# Centered menu panel (320x300 around the screen center).
	pause_panel = _make_panel(Color(0.08, 0.08, 0.12, 0.95))
	pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	pause_panel.offset_left = -160.0
	pause_panel.offset_top = -150.0
	pause_panel.offset_right = 160.0
	pause_panel.offset_bottom = 150.0
	pause_overlay.add_child(pause_panel)

	var title := _make_label("PAUSED", 22)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_left = 0
	title.offset_top = 16
	title.offset_right = 0
	title.offset_bottom = 44
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.23))
	pause_panel.add_child(title)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 30
	vbox.offset_top = 56
	vbox.offset_right = -30
	vbox.offset_bottom = -20
	vbox.add_theme_constant_override("separation", 8)
	pause_panel.add_child(vbox)

	var labels: Array[String] = ["Resume", "Save", "Load", "Settings", "Quit"]
	pause_buttons.clear()
	for i in labels.size():
		var btn := Button.new()
		btn.text = labels[i]
		btn.custom_minimum_size = Vector2(0, 36)
		# Disable the editor/Ui-accept auto-press so the Enter key (which is in
		# both "confirm" and ui_accept) doesn't double-trigger alongside our
		# own _unhandled_input. Mouse clicks still fire "pressed" normally.
		btn.focus_mode = Control.FOCUS_NONE
		# Route mouse clicks through the same index-based activator as keyboard.
		btn.pressed.connect(_activate_pause_index.bind(i))
		vbox.add_child(btn)
		pause_buttons.append(btn)


# --- UI factory helpers -----------------------------------------------------

func _make_panel(bg: Color) -> Panel:
	var p := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.15)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 4.0
	style.content_margin_top = 4.0
	style.content_margin_right = 4.0
	style.content_margin_bottom = 4.0
	p.add_theme_stylebox_override("panel", style)
	return p


func _make_label(text: String, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	return l
