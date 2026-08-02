## MenuSystem
## Control node for the main in-game menu, opened with the "menu" action (Esc).
##
## Attach this script to a Control node placed in a CanvasLayer above the world.
## The UI is built programmatically, so no companion .tscn is required.
##
## Tabs (left/right to switch, up/down + confirm to interact):
##   - Status   : player level, HP, ATK, DEF, SPD, EXP.
##   - Inventory: usable items from GameState.inventory (equipment ids are
##                filtered out via DataLoader.get_item()).
##   - Tank     : shortcut that opens the tank garage scene.
##   - Map      : current location + its connections (from maps.json).
##   - Save     : calls GameState.save_game().
##
## NOTE on the Esc key: both this menu and the HUD pause overlay bind the
## "menu" action. They are intentionally separate systems; in a real game you
## would either instantiate only one, or wire them (e.g. let the pause overlay
## open this menu). Each consumes the input when it toggles.
extends Control

# --- Signals ----------------------------------------------------------------
signal menu_opened()
signal menu_closed()
signal open_tank_requested()

# --- Constants --------------------------------------------------------------
const TAB_STATUS: int = 0
const TAB_INVENTORY: int = 1
const TAB_TANK: int = 2
const TAB_MAP: int = 3
const TAB_SAVE: int = 4
const TAB_LABELS: Array[String] = ["Status", "Inventory", "Tank", "Map", "Save"]

const GARAGE_SCENE: String = "res://scenes/tank_garage.tscn"

# --- Exports ----------------------------------------------------------------
## When true, opening the menu pauses the SceneTree.
@export var pause_tree_on_open: bool = true

# --- State ------------------------------------------------------------------
var is_open: bool = false
var current_tab: int = TAB_STATUS
var inventory_index: int = 0
var _item_ids: Array[String] = []  # parallel to the inventory ItemList rows

# --- UI handles -------------------------------------------------------------
var dim: ColorRect
var main_panel: Panel
var tab_buttons: Array[Button] = []
var status_label: RichTextLabel
var inventory_list: ItemList
var item_info_label: RichTextLabel
var tank_label: RichTextLabel
var open_garage_button: Button
var map_label: RichTextLabel
var save_button: Button
var save_status_label: Label
var hint_label: Label


# --- Lifecycle --------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_refresh_status()
	_refresh_inventory()
	_refresh_map()
	_select_tab(TAB_STATUS)
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		# If another modal (e.g. the HUD pause overlay) already paused the tree
		# and we are not open, do nothing and let it handle Esc.
		if get_tree().paused and not is_open:
			return
		if is_open:
			close()
		else:
			open()
		get_viewport().set_input_as_handled()
		return

	if not is_open:
		return

	if event.is_action_pressed("cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_left"):
		_change_tab(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_right"):
		_change_tab(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("confirm"):
		_confirm_tab()
		get_viewport().set_input_as_handled()
	else:
		# Per-tab vertical navigation (currently only Inventory uses it).
		if current_tab == TAB_INVENTORY:
			if event.is_action_pressed("move_up"):
				_move_inventory(-1)
				get_viewport().set_input_as_handled()
			elif event.is_action_pressed("move_down"):
				_move_inventory(1)
				get_viewport().set_input_as_handled()


# --- Open / close -----------------------------------------------------------

func open() -> void:
	is_open = true
	visible = true
	if pause_tree_on_open:
		get_tree().paused = true
	# Refresh dynamic tabs in case the state changed since last open.
	_refresh_status()
	_refresh_inventory()
	_refresh_map()
	_select_tab(current_tab)
	menu_opened.emit()


func close() -> void:
	is_open = false
	visible = false
	if pause_tree_on_open:
		get_tree().paused = false
	menu_closed.emit()


# --- Tab navigation ---------------------------------------------------------

func _change_tab(direction: int) -> void:
	var count: int = TAB_LABELS.size()
	current_tab = posmod(current_tab + direction, count)
	_select_tab(current_tab)


func _select_tab(tab: int) -> void:
	current_tab = clampi(tab, 0, TAB_LABELS.size() - 1)
	for i in tab_buttons.size():
		var selected: bool = (i == current_tab)
		# Active tab is highlighted yellow; others white. (We don't disable the
		# active button — re-clicking the same tab just refreshes, harmlessly.)
		tab_buttons[i].add_theme_color_override(
			"font_color",
			Color(1.0, 0.92, 0.23) if selected else Color.WHITE
		)
	# Show the matching content panel.
	status_label.visible = (current_tab == TAB_STATUS)
	inventory_list.visible = (current_tab == TAB_INVENTORY)
	item_info_label.visible = (current_tab == TAB_INVENTORY)
	tank_label.visible = (current_tab == TAB_TANK)
	open_garage_button.visible = (current_tab == TAB_TANK)
	map_label.visible = (current_tab == TAB_MAP)
	save_button.visible = (current_tab == TAB_SAVE)
	save_status_label.visible = (current_tab == TAB_SAVE)
	_update_hint()


func _confirm_tab() -> void:
	match current_tab:
		TAB_STATUS:
			pass  # nothing to confirm
		TAB_INVENTORY:
			_use_selected_item()
		TAB_TANK:
			_open_garage()
		TAB_MAP:
			pass
		TAB_SAVE:
			_do_save()


func _update_hint() -> void:
	match current_tab:
		TAB_INVENTORY:
			hint_label.text = "Up/Down: Select    Z: Use    Esc/X: Close"
		TAB_TANK:
			hint_label.text = "Z: Open Garage    Esc/X: Close"
		TAB_SAVE:
			hint_label.text = "Z: Save Game    Esc/X: Close"
		_:
			hint_label.text = "<-/->: Switch Tab    Esc/X: Close"


# --- Status tab -------------------------------------------------------------

func _refresh_status() -> void:
	if status_label == null:
		return
	var s := GameState
	var text := "[b]STATUS[/b]\n\n"
	text += "Name     : %s\n" % s.player_name
	text += "Level    : %d\n" % s.player_level
	text += "HP       : %d / %d\n" % [s.player_hp, s.player_max_hp]
	text += "Attack   : %d\n" % s.player_attack
	text += "Defense  : %d\n" % s.player_defense
	text += "Speed    : %d\n" % s.player_speed
	text += "EXP      : %d / %d\n" % [s.player_exp, s.player_exp_next]
	text += "Gold     : %d G\n" % s.gold
	text += "\nTank owned : %s" % ("Yes" if s.tank_owned else "No")
	status_label.text = text


# --- Inventory tab ----------------------------------------------------------

func _refresh_inventory() -> void:
	if inventory_list == null:
		return
	_item_ids.clear()
	inventory_list.clear()
	# Only show real consumable items, not tank equipment ids that share the
	# inventory dict (see tank_garage.gd).
	for id in GameState.inventory.keys():
		if DataLoader.get_item(String(id)).is_empty():
			continue
		_item_ids.append(String(id))
		var data: Dictionary = DataLoader.get_item(String(id))
		var count: int = int(GameState.inventory[id])
		var item_name: String = String(data.get("name", String(id)))
		inventory_list.add_item("%s x%d" % [item_name, count])
	if _item_ids.is_empty():
		inventory_list.add_item("(No items)")
		inventory_list.set_item_selectable(0, false)
		item_info_label.text = "[i]Your inventory is empty.[/i]"
		inventory_index = -1
	else:
		inventory_index = clampi(inventory_index, 0, _item_ids.size() - 1)
		inventory_list.select(inventory_index)
		_show_item_info(inventory_index)


func _move_inventory(direction: int) -> void:
	if _item_ids.is_empty():
		return
	inventory_index = posmod(inventory_index + direction, _item_ids.size())
	inventory_list.select(inventory_index)
	inventory_list.ensure_current_is_visible()
	_show_item_info(inventory_index)


## ItemList signal: a row was selected (mouse click or programmatic select).
func _on_inventory_item_selected(idx: int) -> void:
	inventory_index = idx
	_show_item_info(idx)


## ItemList signal: a row was double-clicked / activated.
func _on_inventory_item_activated(_idx: int) -> void:
	_use_selected_item()


func _show_item_info(idx: int) -> void:
	if idx < 0 or idx >= _item_ids.size():
		item_info_label.text = ""
		return
	var id: String = _item_ids[idx]
	var data: Dictionary = DataLoader.get_item(id)
	var text := "[b]%s[/b]\n" % String(data.get("name", id))
	text += String(data.get("description", "")) + "\n\n"
	text += "Type : %s\n" % String(data.get("type", "misc"))
	if data.has("hp_restore"):
		text += "Restores %d HP\n" % int(data.hp_restore)
	if data.has("fuel_restore"):
		text += "Refuels %d\n" % int(data.fuel_restore)
	if data.has("repair_amount"):
		text += "Repairs %d SP\n" % int(data.repair_amount)
	text += "Owned: %d" % int(GameState.inventory.get(id, 0))
	item_info_label.text = text


func _use_selected_item() -> void:
	if inventory_index < 0 or inventory_index >= _item_ids.size():
		return
	var id: String = _item_ids[inventory_index]
	var data: Dictionary = DataLoader.get_item(id)
	var type: String = String(data.get("type", ""))
	var feedback: String = ""

	match type:
		"heal":
			var amount: int = int(data.get("hp_restore", 0))
			GameState.heal(amount)
			feedback = "Recovered %d HP!" % amount
		"fuel":
			feedback = "Refueled %d units." % int(data.get("fuel_restore", 0))
		"repair":
			feedback = "Repaired %d SP." % int(data.get("repair_amount", 0))
		"escape":
			feedback = "Smoke Grenade — use in battle to flee."
		_:
			feedback = "Nothing happens."

	# Consume one copy.
	var remaining: int = int(GameState.inventory.get(id, 0)) - 1
	if remaining <= 0:
		GameState.inventory.erase(id)
	else:
		GameState.inventory[id] = remaining

	_refresh_inventory()
	# _refresh_inventory() already wrote the "empty" message if applicable, so
	# only refresh the info panel when there is still something to show.
	if not _item_ids.is_empty():
		inventory_index = clampi(inventory_index, 0, _item_ids.size() - 1)
		_show_item_info(inventory_index)
	item_info_label.text += "\n\n[color=green]%s[/color]" % feedback


# --- Tank tab --------------------------------------------------------------

func _open_garage() -> void:
	open_tank_requested.emit()
	if pause_tree_on_open:
		get_tree().paused = false
	if ResourceLoader.exists(GARAGE_SCENE):
		GameState.change_scene(GARAGE_SCENE)
	else:
		push_warning("[MenuSystem] Garage scene not found: %s" % GARAGE_SCENE)


# --- Map tab ---------------------------------------------------------------

func _refresh_map() -> void:
	if map_label == null:
		return
	var map_id: String = GameState.current_map
	var data: Dictionary = DataLoader.get_map_data(map_id)
	var text := "[b]MAP[/b]\n\n"
	text += "Current location: [b]%s[/b] (%s)\n\n" % [
		String(data.get("name", map_id)), map_id
	]
	text += "Connections:\n"
	var connections: Dictionary = data.get("connections", {})
	if connections.is_empty():
		text += "  (none — end of the road)\n"
	else:
		for direction in connections:
			var dest_id: String = String(connections[direction])
			var dest: Dictionary = DataLoader.get_map_data(dest_id)
			text += "  %-6s -> %s\n" % [String(direction), String(dest.get("name", dest_id))]
	map_label.text = text


# --- Save tab --------------------------------------------------------------

func _do_save() -> void:
	GameState.save_game()
	save_status_label.text = "Game saved successfully!"
	save_status_label.add_theme_color_override("font_color", Color(0.45, 1.0, 0.45))


# --- UI construction --------------------------------------------------------

func _build_ui() -> void:
	# Root fills the screen.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	dim = ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.65)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	main_panel = _make_panel(Color(0.08, 0.08, 0.12, 0.97))
	main_panel.set_anchors_preset(Control.PRESET_CENTER)
	main_panel.offset_left = -460.0
	main_panel.offset_top = -300.0
	main_panel.offset_right = 460.0
	main_panel.offset_bottom = 300.0
	add_child(main_panel)

	# Title.
	var title := _make_label("MENU", 24)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 12
	title.offset_bottom = 40
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.23))
	main_panel.add_child(title)

	# Tab bar.
	var tab_bar := HBoxContainer.new()
	tab_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	tab_bar.offset_left = 16
	tab_bar.offset_top = 48
	tab_bar.offset_right = -16
	tab_bar.offset_bottom = 84
	tab_bar.add_theme_constant_override("separation", 6)
	main_panel.add_child(tab_bar)
	tab_buttons.clear()
	for i in TAB_LABELS.size():
		var btn := Button.new()
		btn.text = TAB_LABELS[i]
		btn.custom_minimum_size = Vector2(150, 36)
		btn.toggle_mode = false
		# No focus navigation: tab switching is driven from _unhandled_input
		# (move_left/right) and via mouse click below.
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_select_tab.bind(i))
		tab_bar.add_child(btn)
		tab_buttons.append(btn)

	# Content area.
	var content := Control.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 16
	content.offset_top = 92
	content.offset_right = -16
	content.offset_bottom = -44
	main_panel.add_child(content)

	# --- Status panel ---
	status_label = _make_rich_label()
	status_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_child(status_label)

	# --- Inventory panel (list + info side by side) ---
	var inv_hbox := HBoxContainer.new()
	inv_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	inv_hbox.add_theme_constant_override("separation", 12)
	content.add_child(inv_hbox)

	inventory_list = ItemList.new()
	inventory_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inventory_list.custom_minimum_size = Vector2(360, 0)
	# Disable the ItemList's built-in arrow-key navigation so our own
	# _unhandled_input (move_up/down) is the single source of selection change.
	inventory_list.focus_mode = Control.FOCUS_NONE
	inventory_list.item_selected.connect(_on_inventory_item_selected)
	inventory_list.item_activated.connect(_on_inventory_item_activated)
	inv_hbox.add_child(inventory_list)

	item_info_label = _make_rich_label()
	item_info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inv_hbox.add_child(item_info_label)

	# --- Tank panel ---
	tank_label = _make_rich_label()
	tank_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	tank_label.offset_top = 0
	tank_label.offset_bottom = 180
	content.add_child(tank_label)
	tank_label.text = (
		"[b]TANK[/b]\n\n"
		"Visit the garage to swap chassis, weapons, SE units, C-units and engines.\n\n"
		"Keep an eye on the Weight/Power gauge — an overweight tank cannot move!"
	)

	open_garage_button = Button.new()
	open_garage_button.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	open_garage_button.offset_top = -56
	open_garage_button.offset_bottom = -20
	open_garage_button.text = "Open Garage"
	open_garage_button.custom_minimum_size = Vector2(0, 40)
	open_garage_button.focus_mode = Control.FOCUS_NONE
	open_garage_button.pressed.connect(_open_garage)
	content.add_child(open_garage_button)

	# --- Map panel ---
	map_label = _make_rich_label()
	map_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_child(map_label)

	# --- Save panel ---
	var save_vbox := VBoxContainer.new()
	save_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	save_vbox.add_theme_constant_override("separation", 12)
	content.add_child(save_vbox)

	var save_desc := _make_rich_label()
	save_desc.text = (
		"[b]SAVE[/b]\n\n"
		"Write your progress to user://savegame.json.\n"
		"This overwrites the previous save file."
	)
	save_vbox.add_child(save_desc)

	save_button = Button.new()
	save_button.text = "Save Game"
	save_button.custom_minimum_size = Vector2(0, 44)
	save_button.focus_mode = Control.FOCUS_NONE
	save_button.pressed.connect(_do_save)
	save_vbox.add_child(save_button)

	save_status_label = _make_label("", 16)
	save_vbox.add_child(save_status_label)

	# --- Bottom hint ---
	hint_label = _make_label("", 13)
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint_label.offset_top = -28
	hint_label.offset_bottom = -8
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	main_panel.add_child(hint_label)


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
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 6.0
	style.content_margin_top = 6.0
	style.content_margin_right = 6.0
	style.content_margin_bottom = 6.0
	p.add_theme_stylebox_override("panel", style)
	return p


func _make_label(text: String, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	return l


func _make_rich_label() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = false
	r.text = ""
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r
