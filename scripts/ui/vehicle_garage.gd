## VehicleGarage
## A full-screen overlay showing all owned vehicles in the garage.
## Players can switch between vehicles, view their stats, and purchase new ones.
## This mimics the Metal Max vehicle switching system where you can own
## multiple tanks and choose which one to use.
extends Control

signal garage_closed()
signal vehicle_switched(index: int)

# --- Palette ---
const COL_BG := Color(0.06, 0.05, 0.09, 0.92)
const COL_PANEL := Color(0.10, 0.09, 0.14, 0.95)
const COL_BORDER := Color(0.34, 0.30, 0.46, 1.0)
const COL_ACCENT := Color(0.92, 0.76, 0.34, 1.0)
const COL_TEXT := Color(0.93, 0.93, 0.96, 1.0)
const COL_TEXT_DIM := Color(0.66, 0.64, 0.72, 1.0)
const COL_ACTIVE := Color(0.30, 0.70, 0.35, 1.0)
const COL_HP := Color(0.22, 0.80, 0.34, 1.0)
const COL_SP := Color(0.30, 0.50, 0.90, 1.0)
const COL_FUEL := Color(0.90, 0.70, 0.20, 1.0)
const COL_BAD := Color(1.0, 0.35, 0.35, 1.0)

const VEHICLE_PRICE := 3000
const SLOT_NAMES := ["Chassis", "Main Cannon", "Sub Cannon", "SE Unit", "C-Unit", "Engine"]

var _vp_size: Vector2
var _selected_index: int = 0
var _vehicle_labels: Array = []
var _detail_label: RichTextLabel
var _status_label: Label
var _buy_button: Button
var _switch_button: Button
var _close_button: Button
var _has_focus: bool = true

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vp_size = get_viewport_rect().size
	_selected_index = GameState.active_vehicle_index
	_build_ui()
	_refresh()

func _unhandled_input(event: InputEvent) -> void:
	if not _has_focus:
		return
	if event.is_action_pressed("cancel") or event.is_action_pressed("world_map"):
		_close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_up"):
		_navigate(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_down"):
		_navigate(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("confirm"):
		_switch_to_selected()
		get_viewport().set_input_as_handled()

func _build_ui() -> void:
	# Full-screen dark background
	var bg := ColorRect.new()
	bg.color = COL_BG
	bg.size = _vp_size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Title
	var title := Label.new()
	title.text = "VEHICLE GARAGE"
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", COL_ACCENT)
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_outline_size_override("outline_size", 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(0, 20)
	title.size = Vector2(_vp_size.x, 50)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)

	# Vehicle list (left side)
	var list_x: float = 40
	var list_y: float = 90
	var list_w: float = 500
	var list_h: float = 500

	var list_panel := Panel.new()
	list_panel.position = Vector2(list_x, list_y)
	list_panel.size = Vector2(list_w, list_h)
	var list_style := StyleBoxFlat.new()
	list_style.bg_color = COL_PANEL
	list_style.border_color = COL_BORDER
	list_style.set_border_width_all(2)
	list_style.set_corner_radius_all(8)
	list_panel.add_theme_stylebox_override("panel", list_style)
	add_child(list_panel)

	var list_title := Label.new()
	list_title.text = "VEHICLES"
	list_title.add_theme_font_size_override("font_size", 18)
	list_title.add_theme_color_override("font_color", COL_ACCENT)
	list_title.position = Vector2(16, 10)
	list_title.size = Vector2(list_w - 32, 28)
	list_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list_panel.add_child(list_title)

	# Vehicle entries will be created in _refresh()
	# Use a VBoxContainer for the list
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_top = 44
	vbox.offset_right = -16
	vbox.offset_bottom = -60
	vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	vbox.add_theme_constant_override("separation", 6)
	vbox.name = "VehicleList"
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list_panel.add_child(vbox)

	# Detail panel (right side)
	var detail_x: float = list_x + list_w + 20
	var detail_w: float = _vp_size.x - detail_x - 40
	var detail_h: float = 400

	var detail_panel := Panel.new()
	detail_panel.position = Vector2(detail_x, list_y)
	detail_panel.size = Vector2(detail_w, detail_h)
	var detail_style := StyleBoxFlat.new()
	detail_style.bg_color = COL_PANEL
	detail_style.border_color = COL_BORDER
	detail_style.set_border_width_all(2)
	detail_style.set_corner_radius_all(8)
	detail_panel.add_theme_stylebox_override("panel", detail_style)
	add_child(detail_panel)

	_detail_label = RichTextLabel.new()
	_detail_label.position = Vector2(16, 12)
	_detail_label.size = Vector2(detail_w - 32, detail_h - 24)
	_detail_label.bbcode_enabled = true
	_detail_label.add_theme_font_size_override("normal_font_size", 16)
	_detail_label.add_theme_color_override("default_color", COL_TEXT)
	_detail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail_panel.add_child(_detail_label)

	# Buttons (bottom right)
	var btn_y: float = list_y + detail_h + 20
	var btn_w: float = 180
	var btn_h: float = 44
	var btn_gap: float = 12

	_switch_button = Button.new()
	_switch_button.text = "Switch (Z)"
	_switch_button.position = Vector2(detail_x, btn_y)
	_switch_button.size = Vector2(btn_w, btn_h)
	_switch_button.add_theme_font_size_override("font_size", 18)
	_switch_button.pressed.connect(_switch_to_selected)
	add_child(_switch_button)

	_buy_button = Button.new()
	_buy_button.text = "Buy New (%dG)" % VEHICLE_PRICE
	_buy_button.position = Vector2(detail_x + btn_w + btn_gap, btn_y)
	_buy_button.size = Vector2(btn_w + 40, btn_h)
	_buy_button.add_theme_font_size_override("font_size", 18)
	_buy_button.pressed.connect(_buy_new_vehicle)
	add_child(_buy_button)

	_close_button = Button.new()
	_close_button.text = "Close (X)"
	_close_button.position = Vector2(detail_x + (btn_w + btn_gap) * 2 + btn_gap, btn_y)
	_close_button.size = Vector2(btn_w, btn_h)
	_close_button.add_theme_font_size_override("font_size", 18)
	_close_button.pressed.connect(_close)
	add_child(_close_button)

	# Status label
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_color", COL_TEXT_DIM)
	_status_label.position = Vector2(list_x, btn_y + 6)
	_status_label.size = Vector2(list_w, btn_h)
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status_label)

	# Hint
	var hint := Label.new()
	hint.text = "Up/Down: Select   Z: Switch   X: Close"
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", COL_TEXT_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.position = Vector2(0, _vp_size.y - 30)
	hint.size = Vector2(_vp_size.x, 24)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)

func _refresh() -> void:
	# Rebuild vehicle list
	var vbox: VBoxContainer = null
	for child in get_children():
		if child is Panel:
			for sub in child.get_children():
				if sub is VBoxContainer and sub.name == "VehicleList":
					vbox = sub
					break
			if vbox:
				break

	if not vbox:
		return

	for child in vbox.get_children():
		child.queue_free()
	_vehicle_labels.clear()

	var summary := GameState.get_garage_summary()
	if summary.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No vehicles in garage."
		empty_label.add_theme_color_override("font_color", COL_TEXT_DIM)
		empty_label.add_theme_font_size_override("font_size", 18)
		vbox.add_child(empty_label)
		_vehicle_labels.append(empty_label)
		return

	for i in range(summary.size()):
		var v: Dictionary = summary[i]
		var entry := _make_vehicle_entry(v, i)
		vbox.add_child(entry)
		_vehicle_labels.append(entry)

	_show_detail(_selected_index)

func _make_vehicle_entry(v: Dictionary, index: int) -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(0, 80)
	panel.mouse_filter = Control.MOUSE_FILTER_PASS

	var style := StyleBoxFlat.new()
	var is_active: bool = bool(v.get("active", false))
	var is_selected: bool = index == _selected_index
	if is_active:
		style.bg_color = Color(0.12, 0.20, 0.12, 0.95)
		style.border_color = COL_ACTIVE
	elif is_selected:
		style.bg_color = Color(0.18, 0.16, 0.10, 0.95)
		style.border_color = COL_ACCENT
	else:
		style.bg_color = COL_PANEL
		style.border_color = COL_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)

	var name_text: String = String(v.get("name", "Tank"))
	if is_active:
		name_text += " [ACTIVE]"
	var name_label := Label.new()
	name_label.text = name_text
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", COL_ACCENT if is_selected else COL_TEXT)
	name_label.add_theme_color_override("font_outline_color", Color.BLACK)
	name_label.add_theme_outline_size_override("outline_size", 3)
	name_label.position = Vector2(12, 8)
	name_label.size = Vector2(440, 28)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(name_label)

	var hp: int = int(v.get("hp", 0))
	var max_hp: int = int(v.get("max_hp", 0))
	var sp: int = int(v.get("sp", 0))
	var max_sp: int = int(v.get("max_sp", 0))
	var fuel: int = int(v.get("fuel", 0))
	var max_fuel: int = int(v.get("max_fuel", 0))
	var parts: int = int(v.get("parts_count", 0))

	var stats_label := Label.new()
	stats_label.text = "HP %d/%d  |  SP %d/%d  |  Fuel %d/%d  |  Parts %d/6" % [hp, max_hp, sp, max_sp, fuel, max_fuel, parts]
	stats_label.add_theme_font_size_override("font_size", 14)
	stats_label.add_theme_color_override("font_color", COL_TEXT_DIM)
	stats_label.position = Vector2(12, 38)
	stats_label.size = Vector2(440, 22)
	stats_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(stats_label)

	# HP bar
	var hp_bar := ProgressBar.new()
	hp_bar.position = Vector2(12, 62)
	hp_bar.size = Vector2(300, 12)
	hp_bar.max_value = max(max_hp, 1)
	hp_bar.value = hp
	hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hp_style := StyleBoxFlat.new()
	hp_style.bg_color = Color(0.09, 0.08, 0.12, 1.0)
	hp_bar.add_theme_stylebox_override("background", hp_style)
	var hp_fill := StyleBoxFlat.new()
	hp_fill.bg_color = COL_HP
	hp_bar.add_theme_stylebox_override("fill", hp_fill)
	panel.add_child(hp_bar)

	return panel

func _show_detail(index: int) -> void:
	if index < 0 or index >= GameState.get_vehicle_count():
		_detail_label.text = "[color=dim]Select a vehicle to view details.[/color]"
		return

	# Save current state before reading garage
	GameState._save_active_to_garage()
	var summary := GameState.get_garage_summary()
	if index >= summary.size():
		_detail_label.text = ""
		return

	var v: Dictionary = summary[index]
	var text: String = ""
	text += "[b][color=%s]%s[/color][/b]" % [COL_ACCENT.to_html(), String(v.get("name", "Tank"))]
	if bool(v.get("active", false)):
		text += "  [color=green][ACTIVE][/color]"
	text += "\n\n"

	text += "[b]HP:[/b] %d / %d\n" % [int(v.get("hp", 0)), int(v.get("max_hp", 0))]
	text += "[b]SP:[/b] %d / %d\n" % [int(v.get("sp", 0)), int(v.get("max_sp", 0))]
	text += "[b]Fuel:[/b] %d / %d\n" % [int(v.get("fuel", 0)), int(v.get("max_fuel", 0))]
	text += "[b]Parts Equipped:[/b] %d / 6\n\n" % int(v.get("parts_count", 0))

	# Show equipped parts
	var vehicle: Dictionary = GameState.vehicle_garage[index]
	var parts: Dictionary = vehicle.get("parts", {})
	text += "[b]Equipment:[/b]\n"
	for slot_key in ["chassis", "main_cannon", "sub_cannon", "se_unit", "c_unit", "engine"]:
		var slot_label := slot_key.replace("_", " ").capitalize()
		var part_id = parts.get(slot_key)
		if part_id != null and not String(part_id).is_empty():
			var eq := DataLoader.get_equipment(String(part_id))
			var part_name: String = String(eq.get("name", String(part_id)))
			text += "  %s: %s\n" % [slot_label, part_name]
		else:
			text += "  %s: [color=dim]— Empty —[/color]\n" % slot_label

	# Action hint
	if not bool(v.get("active", false)):
		text += "\n[color=%s]Press Z to switch to this vehicle.[/color]" % COL_ACCENT.to_html()
	else:
		text += "\n[color=green]This is your current vehicle.[/color]"

	_detail_label.text = text

func _navigate(dir: int) -> void:
	var count := GameState.get_vehicle_count()
	if count <= 0:
		return
	_selected_index = posmod(_selected_index + dir, count)
	_refresh()
	AudioManager.play_sfx("cursor")

func _switch_to_selected() -> void:
	if _selected_index < 0 or _selected_index >= GameState.get_vehicle_count():
		return
	if _selected_index == GameState.active_vehicle_index:
		_status_label.text = "This vehicle is already active."
		_status_label.add_theme_color_override("font_color", COL_TEXT_DIM)
		return
	# Save current state, switch, and load the new one
	GameState._save_active_to_garage()
	if GameState.switch_vehicle(_selected_index):
		_status_label.text = "Switched to %s!" % GameState.get_active_vehicle_name()
		_status_label.add_theme_color_override("font_color", COL_ACTIVE)
		AudioManager.play_sfx("confirm")
		vehicle_switched.emit(_selected_index)
		_refresh()
	else:
		_status_label.text = "Cannot switch vehicles."
		_status_label.add_theme_color_override("font_color", COL_BAD)

func _buy_new_vehicle() -> void:
	if GameState.get_vehicle_count() >= GameState.MAX_VEHICLES:
		_status_label.text = "Garage is full! (max %d)" % GameState.MAX_VEHICLES
		_status_label.add_theme_color_override("font_color", COL_BAD)
		AudioManager.play_sfx("cancel")
		return
	if GameState.gold < VEHICLE_PRICE:
		_status_label.text = "Not enough gold! (need %d G)" % VEHICLE_PRICE
		_status_label.add_theme_color_override("font_color", COL_BAD)
		AudioManager.play_sfx("cancel")
		return
	GameState.spend_gold(VEHICLE_PRICE)
	GameState.add_vehicle()
	_status_label.text = "Purchased a new vehicle!"
	_status_label.add_theme_color_override("font_color", COL_ACTIVE)
	AudioManager.play_sfx("coin")
	_refresh()

func _close() -> void:
	AudioManager.play_sfx("cancel")
	garage_closed.emit()
	queue_free()

func open() -> void:
	visible = true
