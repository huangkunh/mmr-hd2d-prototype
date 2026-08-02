## Shop
## Control node driving the shop UI (buy / sell) for the HD-2D RPG prototype.
##
## Attach this script to the Control root of scenes/shop.tscn. The entire UI is
## built programmatically in _build_ui(), so the .tscn only needs a Control with
## this script (plus the requested CanvasLayer wrapper) -- no child nodes are
## required in the scene file.
##
## Tabs (Left/Right to switch, Up/Down to navigate, Z to transact, X/Esc to leave):
##   - Buy : lists the shop's items and equipment, priced with buy_multiplier.
##   - Sell: lists the player's sellable inventory, priced with sell_multiplier.
##
## Transactions:
##   - Buying  : GameState.spend_gold(price) -> adds one copy to GameState.inventory.
##   - Selling : removes one copy from GameState.inventory -> GameState.gain_gold(price).
##
## Equipment ids and item ids never overlap in the data, so they share the same
## inventory dictionary (the same scheme used by the tank garage and the menu
## system). Bought equipment lands in inventory and can later be equipped via the
## garage / equipment screens; the shop itself never auto-equips anything.
##
## Runtime shop selection: the @export shop_id is used by default, but a caller
## (e.g. the world scene) can override it by stashing an id in
## GameState.flags["shop_id"] before changing to this scene.
class_name Shop
extends Control

# --- Signals ----------------------------------------------------------------
## Emitted when the player closes the shop (Esc / X), just before the scene
## transitions back to the previous scene.
signal shop_closed

# --- Constants --------------------------------------------------------------
## Default scene to return to when the shop is closed.
const BACK_SCENE: String = "res://scenes/world.tscn"

## Tab indices.
const TAB_BUY: int = 0
const TAB_SELL: int = 1
const TAB_LABELS: Array[String] = ["Buy", "Sell"]

## HD-2D dark panel colour palette.
const COL_PANEL_BG := Color(0.06, 0.05, 0.09, 0.86)
const COL_PANEL_BORDER := Color(0.34, 0.30, 0.46, 1.0)
const COL_ACCENT := Color(0.92, 0.76, 0.34, 1.0)
const COL_TEXT := Color(0.93, 0.93, 0.96, 1.0)
const COL_TEXT_DIM := Color(0.66, 0.64, 0.72, 1.0)

# --- Exports ----------------------------------------------------------------
## Shop id loaded from DataLoader (data/shops.json). At runtime this can be
## overridden by setting GameState.flags["shop_id"] before opening the scene.
@export var shop_id: String = "wasteland_shop"

## Scene loaded when the shop is closed.
@export var back_scene: String = BACK_SCENE

# --- State ------------------------------------------------------------------
var _shop_data: Dictionary = {}
var _buy_multiplier: float = 1.0
var _sell_multiplier: float = 0.5

var _current_tab: int = TAB_BUY
var _selected_index: int = 0
var _closing: bool = false

## Unified tradeable entries for the active tab. Each entry is a Dictionary:
##   id          String  item/equipment id
##   kind        String  "item" | "equipment"
##   name        String  display name
##   description String  flavour / effect text
##   price       int     buy price (Buy tab) or sell price (Sell tab)
##   count       int     copies currently owned by the player
##   stats       String  short stat summary (ATK/DEF, HP+, etc.)
var _entries: Array[Dictionary] = []

# --- UI handles (built in _ready) -------------------------------------------
var _dim: ColorRect
var _panel: Panel
var _title_label: Label
var _gold_label: Label
var _tab_buttons: Array[Button] = []
var _item_list: ItemList
var _info_label: RichTextLabel
var _hint_label: Label


# --- Lifecycle --------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Allow the caller (e.g. the world scene) to select a shop at runtime by
	# stashing its id in GameState.flags before changing to this scene.
	var override_id := String(GameState.flags.get("shop_id", ""))
	if not override_id.is_empty():
		shop_id = override_id
	_load_shop_data()
	_build_ui()
	_wire_signals()
	_select_tab(TAB_BUY)
	_update_gold(GameState.gold)


func _exit_tree() -> void:
	# Defensive: disconnect live signals so a stale reference cannot fire after
	# the shop is freed.
	if GameState and is_instance_valid(GameState):
		if GameState.gold_changed.is_connected(_update_gold):
			GameState.gold_changed.disconnect(_update_gold)
		if GameState.equipment_changed.is_connected(_on_equipment_changed):
			GameState.equipment_changed.disconnect(_on_equipment_changed)


# --- Shop data --------------------------------------------------------------

func _load_shop_data() -> void:
	_shop_data = DataLoader.get_shop(shop_id)
	if _shop_data.is_empty():
		push_warning("[Shop] Shop id not found: %s" % shop_id)
		_buy_multiplier = 1.0
		_sell_multiplier = 0.5
		return
	_buy_multiplier = float(_shop_data.get("buy_multiplier", 1.0))
	_sell_multiplier = float(_shop_data.get("sell_multiplier", 0.5))


func _wire_signals() -> void:
	if not GameState.gold_changed.is_connected(_update_gold):
		GameState.gold_changed.connect(_update_gold)
	# Refresh owned counts if equipment changes elsewhere (defensive; the shop
	# itself never changes equipped slots).
	if not GameState.equipment_changed.is_connected(_on_equipment_changed):
		GameState.equipment_changed.connect(_on_equipment_changed)


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	# Both "cancel" (X) and "menu" (Esc) close the shop.
	if event.is_action_pressed("cancel") or event.is_action_pressed("menu"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("move_left"):
		_change_tab(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_right"):
		_change_tab(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_up"):
		_move_selection(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_down"):
		_move_selection(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("confirm"):
		_confirm_selection()
		get_viewport().set_input_as_handled()


# --- Close / navigation out -------------------------------------------------

func close() -> void:
	if _closing:
		return
	_closing = true
	shop_closed.emit()
	if ResourceLoader.exists(back_scene):
		GameState.change_scene(back_scene)
	else:
		push_warning("[Shop] back_scene not found: %s" % back_scene)
		queue_free()


# --- Tab navigation ---------------------------------------------------------

func _change_tab(direction: int) -> void:
	_current_tab = posmod(_current_tab + direction, TAB_LABELS.size())
	_select_tab(_current_tab)


func _select_tab(tab: int) -> void:
	_current_tab = clampi(tab, 0, TAB_LABELS.size() - 1)
	for i in _tab_buttons.size():
		var selected: bool = (i == _current_tab)
		_tab_buttons[i].add_theme_color_override(
			"font_color",
			COL_ACCENT if selected else COL_TEXT
		)
	_rebuild_entries()
	_refresh_list()
	_update_hint()


func _update_hint() -> void:
	match _current_tab:
		TAB_BUY:
			_hint_label.text = "<- / ->: Switch Tab    Up / Down: Select    Z: Buy    Esc / X: Close"
		TAB_SELL:
			_hint_label.text = "<- / ->: Switch Tab    Up / Down: Select    Z: Sell    Esc / X: Close"


# --- Entry building ---------------------------------------------------------

## Rebuilds _entries for the active tab and resets the selection into range.
func _rebuild_entries() -> void:
	_entries.clear()
	match _current_tab:
		TAB_BUY:
			_build_buy_entries()
		TAB_SELL:
			_build_sell_entries()
	if _entries.is_empty():
		_selected_index = -1
	else:
		_selected_index = clampi(_selected_index, 0, _entries.size() - 1)


func _build_buy_entries() -> void:
	# Items the shop sells.
	for id in _shop_data.get("items", []):
		var sid := String(id)
		var data := DataLoader.get_item(sid)
		if data.is_empty():
			continue
		_entries.append({
			"id": sid,
			"kind": "item",
			"name": String(data.get("name", sid)),
			"description": String(data.get("description", "")),
			"price": _buy_price(int(data.get("price", 0))),
			"count": int(GameState.inventory.get(sid, 0)),
			"stats": _item_stats_string(data),
		})
	# Equipment the shop sells.
	for id in _shop_data.get("equipment", []):
		var sid := String(id)
		var data := DataLoader.get_equipment(sid)
		if data.is_empty():
			continue
		_entries.append({
			"id": sid,
			"kind": "equipment",
			"name": String(data.get("name", sid)),
			"description": String(data.get("description", "")),
			"price": _buy_price(int(data.get("price", 0))),
			"count": int(GameState.inventory.get(sid, 0)),
			"stats": _equipment_stats_string(data),
		})


func _build_sell_entries() -> void:
	for id in GameState.inventory.keys():
		var sid := String(id)
		var count := int(GameState.inventory[id])
		if count <= 0:
			continue
		# An id is either a consumable item or a piece of equipment (the two
		# id spaces never overlap in the default data).
		var item_data := DataLoader.get_item(sid)
		var eq_data := DataLoader.get_equipment(sid)
		var is_item: bool = not item_data.is_empty()
		var is_eq: bool = not eq_data.is_empty()
		if not is_item and not is_eq:
			continue
		var base_price: int = 0
	var display_name: String = sid
	var description: String = ""
	var stats: String = ""
	if is_item:
		base_price = int(item_data.get("price", 0))
		display_name = String(item_data.get("name", sid))
		description = String(item_data.get("description", ""))
		stats = _item_stats_string(item_data)
	else:
		base_price = int(eq_data.get("price", 0))
		display_name = String(eq_data.get("name", sid))
		description = String(eq_data.get("description", ""))
		stats = _equipment_stats_string(eq_data)
	var sell_price: int = _sell_price(base_price)
	if sell_price <= 0:
		continue  # unsellable (e.g. free starter gear worth nothing)
	_entries.append({
		"id": sid,
		"kind": "item" if is_item else "equipment",
		"name": display_name,
		"description": description,
		"price": sell_price,
		"count": count,
		"stats": stats,
	})


func _buy_price(base_price: int) -> int:
	return int(round(float(base_price) * _buy_multiplier))


func _sell_price(base_price: int) -> int:
	return int(round(float(base_price) * _sell_multiplier))


func _item_stats_string(data: Dictionary) -> String:
	var parts: Array[String] = []
	parts.append("Type: %s" % String(data.get("type", "misc")))
	if data.has("hp_restore"):
		parts.append("HP +%d" % int(data["hp_restore"]))
	if data.has("fuel_restore"):
		parts.append("Fuel +%d" % int(data["fuel_restore"]))
	if data.has("repair_amount"):
		parts.append("SP +%d" % int(data["repair_amount"]))
	return "   ".join(parts)


func _equipment_stats_string(data: Dictionary) -> String:
	var parts: Array[String] = []
	parts.append("Slot: %s" % String(data.get("slot", "")))
	if int(data.get("attack", 0)) != 0:
		parts.append("ATK %d" % int(data["attack"]))
	if int(data.get("defense", 0)) != 0:
		parts.append("DEF %d" % int(data["defense"]))
	return "   ".join(parts)


# --- List rendering ---------------------------------------------------------

func _refresh_list() -> void:
	_item_list.clear()
	if _entries.is_empty():
		_item_list.add_item("(Nothing available)")
		_item_list.set_item_selectable(0, false)
		_info_label.text = ""
		return
	for entry in _entries:
		var label: String
		if _current_tab == TAB_SELL:
			label = "%s x%d   %d G" % [String(entry["name"]), int(entry["count"]), int(entry["price"])]
		else:
			label = "%s   %d G" % [String(entry["name"]), int(entry["price"])]
		_item_list.add_item(label)
	_selected_index = clampi(_selected_index, 0, _entries.size() - 1)
	_item_list.select(_selected_index)
	_item_list.ensure_current_is_visible()
	_show_info(_selected_index)


func _move_selection(direction: int) -> void:
	if _entries.is_empty():
		return
	_selected_index = posmod(_selected_index + direction, _entries.size())
	_item_list.select(_selected_index)
	_item_list.ensure_current_is_visible()
	_show_info(_selected_index)


## ItemList signal: a row was selected (mouse click or programmatic select).
func _on_item_selected(idx: int) -> void:
	_selected_index = idx
	_show_info(idx)


## ItemList signal: a row was double-clicked / activated.
func _on_item_activated(_idx: int) -> void:
	_confirm_selection()


func _show_info(idx: int) -> void:
	if idx < 0 or idx >= _entries.size():
		_info_label.text = ""
		return
	var entry: Dictionary = _entries[idx]
	var text := "[b]%s[/b]\n" % String(entry["name"])
	text += String(entry["description"]) + "\n\n"
	var stats: String = String(entry["stats"])
	if not stats.is_empty():
		text += stats + "\n\n"
	match _current_tab:
		TAB_BUY:
			text += "[b]Price:[/b] %d G\n" % int(entry["price"])
			text += "Owned: %d\n" % int(entry["count"])
			if int(entry["price"]) > GameState.gold:
				text += "[color=red]Not enough gold![/color]"
			else:
				text += "[color=green]Press Z to buy[/color]"
		TAB_SELL:
			text += "[b]Sell price:[/b] %d G (each)\n" % int(entry["price"])
			text += "Owned: %d\n" % int(entry["count"])
			text += "[color=green]Press Z to sell one[/color]"
	_info_label.text = text


# --- Transactions -----------------------------------------------------------

func _confirm_selection() -> void:
	if _selected_index < 0 or _selected_index >= _entries.size():
		return
	var entry: Dictionary = _entries[_selected_index]
	match _current_tab:
		TAB_BUY:
			_do_buy(entry)
		TAB_SELL:
			_do_sell(entry)


func _do_buy(entry: Dictionary) -> void:
	var id: String = String(entry["id"])
	var price: int = int(entry["price"])
	var display_name: String = String(entry["name"])
	if price <= 0:
		# Free goods (rare in shop data) are simply granted.
		GameState.inventory[id] = int(GameState.inventory.get(id, 0)) + 1
		_refresh_after_trade("[color=green]Received %s![/color]" % display_name)
		return
	if not GameState.spend_gold(price):
		_refresh_after_trade("[color=red]Not enough gold![/color]")
		return
	GameState.inventory[id] = int(GameState.inventory.get(id, 0)) + 1
	_refresh_after_trade("[color=green]Bought %s for %d G![/color]" % [display_name, price])


func _do_sell(entry: Dictionary) -> void:
	var id: String = String(entry["id"])
	if int(GameState.inventory.get(id, 0)) <= 0:
		return
	var sell_price: int = int(entry["price"])
	var display_name: String = String(entry["name"])
	# Remove one copy from inventory.
	var remaining: int = int(GameState.inventory[id]) - 1
	if remaining <= 0:
		GameState.inventory.erase(id)
	else:
		GameState.inventory[id] = remaining
	GameState.gain_gold(sell_price)
	_refresh_after_trade("[color=green]Sold %s for %d G![/color]" % [display_name, sell_price])


## Rebuild entries / list / info after a transaction, then append a feedback line.
func _refresh_after_trade(message: String) -> void:
	_rebuild_entries()
	_refresh_list()
	if not message.is_empty():
		_info_label.text += "\n" + message


# --- GameState signal handlers ----------------------------------------------

func _update_gold(amount: int) -> void:
	if _gold_label:
		_gold_label.text = "GOLD: %d G" % amount
	# On the Buy tab the "Not enough gold" hint depends on the current gold, so
	# refresh the info panel whenever gold changes.
	if _current_tab == TAB_BUY and _selected_index >= 0 and _selected_index < _entries.size():
		_show_info(_selected_index)


func _on_equipment_changed() -> void:
	# Equipment slots changed elsewhere; refresh owned counts (defensive).
	_rebuild_entries()
	_refresh_list()


# --- UI construction --------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Dim background covering the whole screen.
	_dim = ColorRect.new()
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0, 0, 0, 0.65)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	# Centred main panel (960 x 620).
	_panel = _make_panel(COL_PANEL_BG, COL_PANEL_BORDER)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -480.0
	_panel.offset_top = -310.0
	_panel.offset_right = 480.0
	_panel.offset_bottom = 310.0
	add_child(_panel)

	# Title (shop name).
	var shop_name: String = String(_shop_data.get("name", shop_id))
	_title_label = _make_label("SHOP  -  %s" % shop_name, 22)
	_title_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title_label.offset_left = 16
	_title_label.offset_top = 12
	_title_label.offset_right = -16
	_title_label.offset_bottom = 42
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", COL_ACCENT)
	_panel.add_child(_title_label)

	# Gold counter (top-right of the panel).
	_gold_label = _make_label("GOLD: 0 G", 16)
	_gold_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_gold_label.offset_left = -210
	_gold_label.offset_top = 14
	_gold_label.offset_right = -16
	_gold_label.offset_bottom = 40
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_gold_label.add_theme_color_override("font_color", COL_ACCENT)
	_panel.add_child(_gold_label)

	# Tab bar (Buy / Sell).
	var tab_bar := HBoxContainer.new()
	tab_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	tab_bar.offset_left = 16
	tab_bar.offset_top = 50
	tab_bar.offset_right = -16
	tab_bar.offset_bottom = 88
	tab_bar.add_theme_constant_override("separation", 8)
	_panel.add_child(tab_bar)
	_tab_buttons.clear()
	for i in TAB_LABELS.size():
		var btn := Button.new()
		btn.text = TAB_LABELS[i]
		btn.custom_minimum_size = Vector2(160, 36)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_select_tab.bind(i))
		tab_bar.add_child(btn)
		_tab_buttons.append(btn)

	# Content area: trade list (left) + detail panel (right).
	var content := HBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 16
	content.offset_top = 96
	content.offset_right = -16
	content.offset_bottom = -44
	content.add_theme_constant_override("separation", 12)
	_panel.add_child(content)

	_item_list = ItemList.new()
	_item_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_item_list.custom_minimum_size = Vector2(440, 0)
	_item_list.focus_mode = Control.FOCUS_NONE
	_item_list.add_theme_color_override("font_color", COL_TEXT_DIM)
	_item_list.add_theme_color_override("font_selected_color", COL_ACCENT)
	_item_list.add_theme_stylebox_override("panel", _make_list_stylebox())
	_item_list.add_theme_stylebox_override("selected", _make_selected_stylebox())
	_item_list.item_selected.connect(_on_item_selected)
	_item_list.item_activated.connect(_on_item_activated)
	content.add_child(_item_list)

	_info_label = RichTextLabel.new()
	_info_label.bbcode_enabled = true
	_info_label.fit_content = false
	_info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_label.add_theme_color_override("default_color", COL_TEXT)
	content.add_child(_info_label)

	# Bottom hint bar.
	_hint_label = _make_label("", 13)
	_hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint_label.offset_left = 16
	_hint_label.offset_top = -30
	_hint_label.offset_right = -16
	_hint_label.offset_bottom = -8
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_color_override("font_color", COL_TEXT_DIM)
	_panel.add_child(_hint_label)


# --- UI factory helpers -----------------------------------------------------

func _make_panel(bg: Color, border: Color) -> Panel:
	var p := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = border
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


func _make_list_stylebox() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.03, 0.06, 0.8)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = COL_PANEL_BORDER
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 6.0
	style.content_margin_top = 6.0
	style.content_margin_right = 6.0
	style.content_margin_bottom = 6.0
	return style


func _make_selected_stylebox() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.20, 0.16, 0.08, 0.95)
	style.border_width_left = 3
	style.border_color = COL_ACCENT
	style.content_margin_left = 6.0
	style.content_margin_top = 2.0
	style.content_margin_right = 6.0
	style.content_margin_bottom = 2.0
	return style


func _make_label(text: String, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", COL_TEXT)
	return l
