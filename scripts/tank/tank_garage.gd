## TankGarage
## Control node driving the tank customisation garage UI.
##
## Layout (defined in scenes/tank_garage.tscn):
##   - Left panel: 6 slot buttons (Chassis, Main Cannon, Sub Cannon, SE Unit,
##     C-Unit, Engine). Navigate with Up/Down, press Confirm to open the part
##     list for that slot.
##   - Right panel: an ItemList of every equipment available for the selected
##     slot (loaded from DataLoader.get_equipment_by_slot), plus a live
##     current-vs-new stat comparison.
##   - Bottom bar: Weight/Power gauge (turns red when overweight), total
##     Attack/Defense, and the current Gold counter.
##
## Purchasing model:
##   - Free parts (price <= 0) are always available to equip.
##   - Paid parts must be bought with gold (GameState.spend_gold). Bought parts
##     are stored in GameState.inventory (keyed by equipment id) so purchases
##     persist across garage visits and across save/load. Unequipping a paid
##     part returns it to inventory; equipping it consumes it from inventory.
##   - Equipped parts are implicitly "owned" (they live in GameState.tank_parts).
extends Control

# --- Signals ----------------------------------------------------------------
## Emitted whenever a slot's equipped part changes. part_id is "" on unequip.
signal part_equipped(slot: String, part_id: String)

## Emitted when the player requests to leave the garage.
signal back_requested

# --- Constants --------------------------------------------------------------
## Scene to return to when the player leaves the garage.
const BACK_SCENE: String = "res://scenes/world.tscn"

## UI colours for slot highlighting.
const COLOR_NORMAL: Color = Color.WHITE
const COLOR_SELECTED: Color = Color(1.0, 0.92, 0.23)  # yellow
const COLOR_ACTIVE_SLOT: Color = Color(1.0, 0.55, 0.0) # orange (part list open)
const COLOR_GOOD: Color = Color(0.45, 1.0, 0.45)
const COLOR_BAD: Color = Color(1.0, 0.35, 0.35)
const COLOR_WARN: Color = Color(1.0, 0.55, 0.0)

# --- State ------------------------------------------------------------------
## The tank configuration we are editing. Synced to GameState on every change.
var tank: TankSystem = null

## Currently highlighted slot index (0..5).
var selected_slot: int = 0

## True while the right-hand part list is open and capturing Up/Down/Confirm.
var in_part_list: bool = false

## Equipment IDs shown in the part list (parallel to the ItemList rows).
## Element "" represents the synthetic "(None)" unequip entry at index 0.
var part_ids: Array[String] = []

## Highlighted row in the part list.
var part_index: int = 0

# --- Scene references (set via % unique names in tank_garage.tscn) -----------
@onready var title_label: Label = %TitleLabel
@onready var slot_container: VBoxContainer = %LeftVBox
@onready var part_list: ItemList = %PartList
@onready var part_list_title: Label = %PartListTitle
@onready var compare_label: RichTextLabel = %CompareLabel
@onready var hint_label: Label = %HintLabel
@onready var weight_power_bar: ProgressBar = %WeightPowerBar
@onready var weight_power_label: Label = %WeightPowerLabel
@onready var stats_label: Label = %StatsLabel
@onready var gold_label: Label = %GoldLabel
@onready var back_button: Button = %BackButton

## Slot buttons collected from the slot container (kept in slot order).
var slot_buttons: Array = []


# --- Lifecycle --------------------------------------------------------------

func _ready() -> void:
	tank = TankSystem.new()
	tank.load_from_game_state()
	_collect_slot_buttons()

	# Wire the Back button and the gold counter to the live GameState signal.
	back_button.pressed.connect(_on_back)
	if not GameState.gold_changed.is_connected(_update_gold):
		GameState.gold_changed.connect(_update_gold)

	# Allow mouse double-click to act as Confirm on the part list.
	part_list.item_activated.connect(_on_part_activated)
	part_list.item_selected.connect(_on_part_selected)

	# Disable the ItemList / buttons' built-in focus navigation so the keyboard
	# is driven solely from _unhandled_input (avoids double-stepping on arrows).
	part_list.focus_mode = Control.FOCUS_NONE
	back_button.focus_mode = Control.FOCUS_NONE

	# Make sure the comparison label parses BBCode (color/bold) for stat diffs.
	compare_label.bbcode_enabled = true

	# Title is static, but we set it here so it survives scene reloads / tweaks.
	title_label.text = "战车车库"

	# Seed the right panel with an idle message.
	part_list_title.text = "选择一个槽位(↑↓)然后按Z"
	hint_label.text = "Z:选择槽位  X:返回"

	_refresh_all()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("cancel"):
		if in_part_list:
			_close_part_list()
		else:
			_on_back()
		get_viewport().set_input_as_handled()
		return

	if in_part_list:
		if event.is_action_pressed("move_up"):
			_change_part_index(-1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("move_down"):
			_change_part_index(1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("confirm"):
			_select_part()
			get_viewport().set_input_as_handled()
	else:
		if event.is_action_pressed("move_up"):
			_change_slot(-1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("move_down"):
			_change_slot(1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("confirm"):
			_open_part_list()
			get_viewport().set_input_as_handled()


# --- Slot panel --------------------------------------------------------------

## Gathers the slot Buttons from the container, preserving their visual order
## (which must match TankSystem.SLOTS). Also disables Godot's built-in focus
## navigation so the keyboard is driven solely from _unhandled_input, and wires
## mouse clicks to open the clicked slot's part list.
func _collect_slot_buttons() -> void:
	slot_buttons.clear()
	var i: int = 0
	for child in slot_container.get_children():
		if child is Button:
			var btn: Button = child
			btn.focus_mode = Control.FOCUS_NONE
			btn.pressed.connect(_open_slot_at.bind(i))
			slot_buttons.append(btn)
			i += 1


## Mouse helper: jump straight to a slot's part list.
func _open_slot_at(index: int) -> void:
	if index < 0 or index >= slot_buttons.size():
		return
	if in_part_list:
		_close_part_list()
	selected_slot = index
	_update_slot_highlight()
	_open_part_list()


func _change_slot(direction: int) -> void:
	if slot_buttons.is_empty():
		return
	selected_slot = posmod(selected_slot + direction, slot_buttons.size())
	_update_slot_highlight()


func _update_slot_highlight() -> void:
	for i in slot_buttons.size():
		var btn: Button = slot_buttons[i]
		var color: Color = COLOR_NORMAL
		if i == selected_slot:
			color = COLOR_ACTIVE_SLOT if in_part_list else COLOR_SELECTED
		btn.add_theme_color_override("font_color", color)


func _update_slots() -> void:
	for i in slot_buttons.size():
		var btn: Button = slot_buttons[i]
		var slot_key: String = TankSystem.SLOTS[i]
		var label: String = String(TankSystem.SLOT_LABELS[slot_key])
		var id: String = tank.get_slot_id(slot_key)
		var part_name: String = "— Empty —"
		if not id.is_empty():
			part_name = String(DataLoader.get_equipment(id).get("name", id))
		btn.text = "%s\n%s" % [label, part_name]
	_update_slot_highlight()


# --- Part list panel ---------------------------------------------------------

func _open_part_list() -> void:
	var slot_key: String = TankSystem.SLOTS[selected_slot]
	var slot_label: String = String(TankSystem.SLOT_LABELS[slot_key])

	# Build the parallel id array: a synthetic "None" entry first, then every
	# equipment available for this slot from the data table.
	part_ids.clear()
	part_ids.append("")  # "(None)" / unequip entry
	var available: Array = DataLoader.get_equipment_by_slot(slot_key)
	for id in available:
		part_ids.append(String(id))

	# Populate the ItemList.
	part_list.clear()
	part_list.add_item("(None) — Unequip")
	for id in available:
		var eq: Dictionary = DataLoader.get_equipment(String(id))
		var part_name: String = String(eq.get("name", String(id)))
		part_list.add_item("%s  %s" % [part_name, _part_status_string(String(id))])

	# Default highlight: the currently equipped part if any, else the None row.
	var current_id: String = tank.get_slot_id(slot_key)
	var idx: int = part_ids.find(current_id)
	part_index = idx if idx >= 0 else 0
	part_list.select(part_index)
	part_list.ensure_current_is_visible()

	in_part_list = true
	part_list_title.text = "选择%s" % slot_label
	hint_label.text = "Z:购买/装备  X:返回"
	_update_slot_highlight()
	_update_comparison()


func _close_part_list() -> void:
	in_part_list = false
	part_list.clear()
	part_ids.clear()
	part_list_title.text = "选择一个槽位(↑↓)然后按Z"
	hint_label.text = "Z:选择槽位  X:返回"
	compare_label.text = ""
	_update_slot_highlight()


func _change_part_index(direction: int) -> void:
	var count: int = part_list.item_count
	if count <= 0:
		return
	var new_idx: int = posmod(part_index + direction, count)
	part_list.select(new_idx)  # fires _on_part_selected -> updates comparison
	part_list.ensure_current_is_visible()


func _on_part_selected(idx: int) -> void:
	part_index = idx
	_update_comparison()


func _on_part_activated(idx: int) -> void:
	part_index = idx
	_select_part()


## Buy (if necessary) and equip the highlighted part, or unequip the slot when
## the "(None)" entry is selected.
func _select_part() -> void:
	if part_ids.is_empty() or part_index < 0 or part_index >= part_ids.size():
		return
	var slot_key: String = TankSystem.SLOTS[selected_slot]
	var part_id: String = part_ids[part_index]

	# --- "(None)" -> unequip -------------------------------------------------
	if part_id.is_empty():
		_perform_unequip(slot_key)
		return

	var eq: Dictionary = DataLoader.get_equipment(part_id)
	if eq.is_empty():
		push_warning("[TankGarage] Selected unknown part: %s" % part_id)
		return
	var price: int = int(eq.get("price", 0))

	# --- Already equipped -> unequip it --------------------------------------
	if _is_equipped(part_id):
		_perform_unequip(slot_key)
		return

	# --- Need to own it ------------------------------------------------------
	if not _is_owned(part_id):
		if price > GameState.gold:
			hint_label.text = "金币不足！(需%dG)" % price
			return
		if not GameState.spend_gold(price):
			hint_label.text = "购买失败！"
			return
		# Record the purchase so it persists (saved with GameState.inventory).
		if price > 0:
			GameState.inventory[part_id] = int(GameState.inventory.get(part_id, 0)) + 1

	# Consume one copy from inventory (it is now fitted to the tank).
	_consume_from_inventory(part_id)

	# Return the previously equipped paid part to inventory.
	var old_id: String = tank.get_slot_id(slot_key)
	if not old_id.is_empty() and old_id != part_id:
		_return_to_inventory(old_id)

	# Apply the new loadout.
	tank.set_slot_id(slot_key, part_id)
	_commit_change(slot_key, part_id)


## Unequip helper: returns the fitted paid part to inventory and clears the slot.
func _perform_unequip(slot_key: String) -> void:
	var old_id: String = tank.get_slot_id(slot_key)
	if old_id.is_empty():
		# Nothing to unequip; just refresh.
		_refresh_all()
		_update_comparison()
		return
	_return_to_inventory(old_id)
	tank.unequip(slot_key)
	_commit_change(slot_key, "")


## Finalises a change: sync GameState, refresh UI, emit signal, keep part list.
func _commit_change(slot_key: String, part_id: String) -> void:
	tank.apply_to_game_state()
	part_equipped.emit(slot_key, part_id)
	_refresh_all()
	# Re-label the part rows so EQUIPPED/OWNED statuses stay accurate.
	_relabel_part_list()
	_update_comparison()


# --- Inventory bookkeeping --------------------------------------------------
# Equipment is stored in GameState.inventory alongside items (equipment ids and
# item ids never overlap in the default data). This keeps purchases persistent
# without modifying GameState, and the menu_system filters equipment out of
# the item inventory view via DataLoader.get_item().

func _is_equipped(part_id: String) -> bool:
	for slot in TankSystem.SLOTS:
		if tank.get_slot_id(slot) == part_id:
			return true
	return false


func _is_owned(part_id: String) -> bool:
	if part_id.is_empty():
		return false
	if int(DataLoader.get_equipment(part_id).get("price", 0)) <= 0:
		return true  # free starter parts are always available
	if GameState.inventory.has(part_id):
		return true
	if _is_equipped(part_id):
		return true
	return false


func _consume_from_inventory(part_id: String) -> void:
	if not GameState.inventory.has(part_id):
		return
	var remaining: int = int(GameState.inventory[part_id]) - 1
	if remaining <= 0:
		GameState.inventory.erase(part_id)
	else:
		GameState.inventory[part_id] = remaining


func _return_to_inventory(part_id: String) -> void:
	if part_id.is_empty():
		return
	# Free parts don't need inventory tracking — they are always available.
	if int(DataLoader.get_equipment(part_id).get("price", 0)) <= 0:
		return
	GameState.inventory[part_id] = int(GameState.inventory.get(part_id, 0)) + 1


# --- UI rendering -----------------------------------------------------------

func _part_status_string(part_id: String) -> String:
	if _is_equipped(part_id):
		return "[EQUIPPED]"
	if _is_owned(part_id):
		return "[OWNED]"
	var price: int = int(DataLoader.get_equipment(part_id).get("price", 0))
	if price <= 0:
		return "[FREE]"
	return "%d G" % price


## Re-labels every part row's status suffix after a purchase/equip/unequip.
func _relabel_part_list() -> void:
	for i in part_ids.size():
		var id: String = part_ids[i]
		if id.is_empty():
			part_list.set_item_text(i, "(None) — Unequip")
			continue
		var eq: Dictionary = DataLoader.get_equipment(id)
		var part_name: String = String(eq.get("name", id))
		part_list.set_item_text(i, "%s  %s" % [part_name, _part_status_string(id)])


func _update_comparison() -> void:
	if part_ids.is_empty() or part_index < 0 or part_index >= part_ids.size():
		compare_label.text = ""
		return

	var slot_key: String = TankSystem.SLOTS[selected_slot]
	var part_id: String = part_ids[part_index]
	var current: Dictionary = tank.get_stats()
	var preview: Dictionary = tank.stats_if_slot_set(slot_key, part_id)

	var text: String = ""
	if part_id.is_empty():
		text = "[b]Unequip %s[/b]\n" % String(TankSystem.SLOT_LABELS[slot_key])
		text += "Remove the current part from this slot.\n\n"
	else:
		var eq: Dictionary = DataLoader.get_equipment(part_id)
		text = "[b]%s[/b]\n" % String(eq.get("name", part_id))
		text += String(eq.get("description", "")) + "\n\n"

	text += _compare_line("ATK", int(current.attack), int(preview.attack))
	text += _compare_line("DEF", int(current.defense), int(preview.defense))
	text += _compare_line("WGT", int(current.weight), int(preview.weight))
	text += _compare_line("PWR", int(current.power), int(preview.power))

	if int(preview.weight) > int(preview.power):
		text += "\n[color=red][b]OVERWEIGHT![/b] Tank cannot move![/color]"
	elif int(preview.power) > 0 and int(preview.weight) == int(preview.power):
		text += "\n[color=orange]At weight capacity.[/color]"

	# Action hint tailored to the part's ownership status.
	if not part_id.is_empty():
		if _is_equipped(part_id):
			text += "\n\n[b]Status:[/b] Equipped — Z to unequip"
		elif _is_owned(part_id):
			text += "\n\n[b]Status:[/b] Owned — Z to equip"
		else:
			var price: int = int(DataLoader.get_equipment(part_id).get("price", 0))
			if price <= 0:
				text += "\n\n[b]Price:[/b] Free — Z to equip"
			else:
				text += "\n\n[b]Price:[/b] %d G — Z to buy & equip" % price

	compare_label.text = text


func _compare_line(label: String, old: int, new: int) -> String:
	var delta: int = new - old
	var delta_str: String = ""
	if delta > 0:
		delta_str = "  [color=green](+%d)[/color]" % delta
	elif delta < 0:
		delta_str = "  [color=red](%d)[/color]" % delta
	return "[b]%s[/b]  %d -> %d%s\n" % [label, old, new, delta_str]


func _update_stats() -> void:
	var weight: int = tank.get_weight()
	var power: int = tank.get_power()
	var cap: int = maxi(power, maxi(weight, 1))
	weight_power_bar.max_value = cap
	weight_power_bar.value = clampi(weight, 0, cap)

	if tank.is_overweight():
		weight_power_label.text = "重量 %d / 动力 %d   超重！" % [weight, power]
		weight_power_label.add_theme_color_override("font_color", COLOR_BAD)
		weight_power_bar.modulate = COLOR_BAD
	else:
		weight_power_label.text = "重量 %d / 动力 %d" % [weight, power]
		weight_power_label.add_theme_color_override("font_color", COLOR_NORMAL)
		weight_power_bar.modulate = Color.WHITE

	stats_label.text = "攻击 %d   |   防御 %d" % [tank.get_total_attack(), tank.get_total_defense()]


func _update_gold(amount: int) -> void:
	gold_label.text = "金币: %dG" % amount


func _refresh_all() -> void:
	_update_slots()
	_update_stats()
	_update_gold(GameState.gold)


# --- Navigation out ---------------------------------------------------------

func _on_back() -> void:
	back_requested.emit()
	if ResourceLoader.exists(BACK_SCENE):
		GameState.change_scene(BACK_SCENE)
	else:
		# Fallback: drop the garage (useful when the garage is an overlay).
		queue_free()
