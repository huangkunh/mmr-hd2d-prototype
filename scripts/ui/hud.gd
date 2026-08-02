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
var level_label: Label
var exp_bar: ProgressBar
var exp_label: Label
var fuel_bar: ProgressBar
var fuel_label: Label
var tank_hp_bar: ProgressBar
var tank_hp_label: Label
var tank_sp_bar: ProgressBar
var tank_sp_label: Label
var quest_label: Label
var mode_label: Label
var minimap_grid: GridContainer

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
	_on_exp_changed(GameState.player_exp, GameState.player_exp_next)
	_on_fuel_changed(GameState.tank_fuel, GameState.tank_max_fuel)
	_on_tank_hp_changed(GameState.tank_hp, GameState.tank_max_hp)
	_on_tank_sp_changed(GameState.tank_sp, GameState.tank_max_sp)
	_on_level_up(GameState.player_level)
	_refresh_quest_count()
	_refresh_mode()


func _wire_signals() -> void:
	if not GameState.hp_changed.is_connected(_on_hp_changed):
		GameState.hp_changed.connect(_on_hp_changed)
	if not GameState.gold_changed.is_connected(_on_gold_changed):
		GameState.gold_changed.connect(_on_gold_changed)
	if not GameState.exp_changed.is_connected(_on_exp_changed):
		GameState.exp_changed.connect(_on_exp_changed)
	if not GameState.fuel_changed.is_connected(_on_fuel_changed):
		GameState.fuel_changed.connect(_on_fuel_changed)
	if not GameState.tank_hp_changed.is_connected(_on_tank_hp_changed):
		GameState.tank_hp_changed.connect(_on_tank_hp_changed)
	if not GameState.tank_sp_changed.is_connected(_on_tank_sp_changed):
		GameState.tank_sp_changed.connect(_on_tank_sp_changed)
	if not GameState.level_up.is_connected(_on_level_up):
		GameState.level_up.connect(_on_level_up)
	if not GameState.quest_updated.is_connected(_on_quest_updated):
		GameState.quest_updated.connect(_on_quest_updated)


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
	_on_exp_changed(GameState.player_exp, GameState.player_exp_next)
	_on_fuel_changed(GameState.tank_fuel, GameState.tank_max_fuel)
	_on_tank_hp_changed(GameState.tank_hp, GameState.tank_max_hp)
	_on_tank_sp_changed(GameState.tank_sp, GameState.tank_max_sp)
	_on_level_up(GameState.player_level)
	_refresh_quest_count()
	_refresh_mode()
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


func _on_exp_changed(current: int, next: int) -> void:
	if exp_bar:
		exp_bar.max_value = maxi(next, 1)
		exp_bar.value = clampi(current, 0, next)
	if exp_label:
		exp_label.text = "EXP %d / %d" % [current, next]


func _on_fuel_changed(current: int, maximum: int) -> void:
	if fuel_bar:
		fuel_bar.max_value = maxi(maximum, 1)
		fuel_bar.value = clampi(current, 0, maximum)
		# Red when low
		var ratio := float(current) / float(maxi(maximum, 1))
		fuel_bar.modulate = Color(0.9, 0.25, 0.25) if ratio < 0.25 else Color(0.35, 0.85, 0.35)
	if fuel_label:
		fuel_label.text = "Fuel %d / %d" % [current, maximum]


func _on_tank_hp_changed(current: int, maximum: int) -> void:
	if tank_hp_bar:
		tank_hp_bar.max_value = maxi(maximum, 1)
		tank_hp_bar.value = clampi(current, 0, maximum)
		tank_hp_bar.visible = GameState.tank_owned
	if tank_hp_label:
		tank_hp_label.text = "Tank HP %d / %d" % [current, maximum]
		tank_hp_label.visible = GameState.tank_owned


func _on_tank_sp_changed(current: int, maximum: int) -> void:
	if tank_sp_bar:
		tank_sp_bar.max_value = maxi(maximum, 1)
		tank_sp_bar.value = clampi(current, 0, maximum)
		tank_sp_bar.visible = GameState.tank_owned
	if tank_sp_label:
		tank_sp_label.text = "Tank SP %d / %d" % [current, maximum]
		tank_sp_label.visible = GameState.tank_owned


func _on_level_up(new_level: int) -> void:
	if level_label:
		level_label.text = "Lv. %d" % new_level


func _on_quest_updated(_quest_id: String, _status: String) -> void:
	_refresh_quest_count()


func _refresh_quest_count() -> void:
	if quest_label:
		var active: int = GameState.active_quests.size()
		var completed: int = GameState.completed_quests.size()
		quest_label.text = "Quests: %d active / %d done" % [active, completed]


func _refresh_mode() -> void:
	if mode_label:
		if GameState.tank_owned:
			mode_label.text = "[TAB] Toggle Tank/On-Foot"
			mode_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
		else:
			mode_label.text = ""


func _update_map_name() -> void:
	if map_label == null:
		return
	var map_data: Dictionary = DataLoader.get_map_data(GameState.current_map)
	var display_name: String = String(map_data.get("name", GameState.current_map))
	map_label.text = display_name
	# Update minimap with connections
	if minimap_label:
		var text := "Location: %s\n" % display_name
		var connections: Dictionary = map_data.get("connections", {})
		if not connections.is_empty():
			text += "Routes:\n"
			for direction in connections:
				var dest_id: String = String(connections[direction])
				var dest: Dictionary = DataLoader.get_map_data(dest_id)
				text += "  %s -> %s\n" % [String(direction).capitalize(), String(dest.get("name", dest_id))]
		minimap_label.text = text


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
	var panel := _make_panel(Color(0, 0, 0, 0.6))
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(16, 16)
	panel.size = Vector2(340, 210)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 10
	vbox.offset_top = 6
	vbox.offset_right = -10
	vbox.offset_bottom = -6
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 3)
	panel.add_child(vbox)

	# Level + EXP row
	var level_row := HBoxContainer.new()
	level_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(level_row)
	level_label = _make_label("Lv. 1", 14)
	level_label.custom_minimum_size = Vector2(60, 0)
	level_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.23))
	level_row.add_child(level_label)
	exp_bar = ProgressBar.new()
	exp_bar.min_value = 0
	exp_bar.max_value = 50
	exp_bar.value = 0
	exp_bar.custom_minimum_size = Vector2(160, 14)
	exp_bar.show_percentage = false
	level_row.add_child(exp_bar)
	exp_label = _make_label("", 11)
	exp_label.custom_minimum_size = Vector2(90, 0)
	level_row.add_child(exp_label)

	# HP row
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
	hp_bar.custom_minimum_size = Vector2(190, 16)
	hp_bar.show_percentage = false
	hp_row.add_child(hp_bar)

	# Gold row
	gold_label = _make_label("0 G", 14)
	gold_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vbox.add_child(gold_label)

	# Map name
	map_label = _make_label("Map", 12)
	map_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.7))
	vbox.add_child(map_label)

	# Separator
	var sep := HSeparator.new()
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(sep)

	# Tank HP row (hidden if no tank)
	var tank_hp_row := HBoxContainer.new()
	tank_hp_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(tank_hp_row)
	tank_hp_label = _make_label("Tank HP 200 / 200", 12)
	tank_hp_label.custom_minimum_size = Vector2(140, 0)
	tank_hp_row.add_child(tank_hp_label)
	tank_hp_bar = ProgressBar.new()
	tank_hp_bar.min_value = 0
	tank_hp_bar.max_value = 200
	tank_hp_bar.value = 200
	tank_hp_bar.custom_minimum_size = Vector2(170, 14)
	tank_hp_bar.show_percentage = false
	tank_hp_row.add_child(tank_hp_bar)

	# Tank SP row
	var tank_sp_row := HBoxContainer.new()
	tank_sp_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(tank_sp_row)
	tank_sp_label = _make_label("Tank SP 100 / 100", 12)
	tank_sp_label.custom_minimum_size = Vector2(140, 0)
	tank_sp_row.add_child(tank_sp_label)
	tank_sp_bar = ProgressBar.new()
	tank_sp_bar.min_value = 0
	tank_sp_bar.max_value = 100
	tank_sp_bar.value = 100
	tank_sp_bar.custom_minimum_size = Vector2(170, 14)
	tank_sp_bar.show_percentage = false
	tank_sp_row.add_child(tank_sp_bar)

	# Fuel row
	var fuel_row := HBoxContainer.new()
	fuel_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(fuel_row)
	fuel_label = _make_label("Fuel 100 / 100", 12)
	fuel_label.custom_minimum_size = Vector2(140, 0)
	fuel_row.add_child(fuel_label)
	fuel_bar = ProgressBar.new()
	fuel_bar.min_value = 0
	fuel_bar.max_value = 100
	fuel_bar.value = 100
	fuel_bar.custom_minimum_size = Vector2(170, 14)
	fuel_bar.show_percentage = false
	fuel_row.add_child(fuel_bar)

	# Initially hide tank stats
	tank_hp_bar.visible = false
	tank_hp_label.visible = false
	tank_sp_bar.visible = false
	tank_sp_label.visible = false


func _build_top_right() -> void:
	minimap_box = _make_panel(Color(0, 0, 0, 0.6))
	minimap_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	minimap_box.offset_left = -196.0
	minimap_box.offset_top = 16.0
	minimap_box.offset_right = -16.0
	minimap_box.offset_bottom = 176.0
	minimap_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(minimap_box)

	var title := _make_label("MAP", 12)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 4
	title.offset_bottom = 20
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.23))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	minimap_box.add_child(title)

	# Build a minimap using labels in a VBox
	var container := VBoxContainer.new()
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.offset_left = 8
	container.offset_top = 24
	container.offset_right = -8
	container.offset_bottom = -8
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_theme_constant_override("separation", 2)
	minimap_box.add_child(container)

	minimap_label = _make_label("", 11)
	minimap_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(minimap_label)

	quest_label = _make_label("", 11)
	quest_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	quest_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	container.add_child(quest_label)

	mode_label = _make_label("", 11)
	mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mode_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.3))
	container.add_child(mode_label)


func _build_bottom_hint() -> void:
	menu_hint = _make_label("Esc: Menu  M: Map", 13)
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
