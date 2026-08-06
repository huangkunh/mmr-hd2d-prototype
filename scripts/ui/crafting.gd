## CraftingUI
## Full-screen overlay for the item crafting / modification workshop.
##
## Opened via the "craft" NPC interaction type or the menu Craft tab.
## The UI is built programmatically — no companion .tscn is strictly required,
## but a minimal crafting.tscn wraps this script as a Control node.
##
## Layout:
##   - Title bar with "合成工坊" and current gold.
##   - Left panel: scrollable ItemList of all recipes from crafting.json.
##     Each row shows the recipe name and a [READY] / [LOCKED] tag.
##   - Right panel: RichTextLabel showing the selected recipe's description,
##     materials (with have/need counts), gold cost, and result item.
##   - Bottom: "Z: Craft   X: Back" hint.
extends Control

# --- Signals ----------------------------------------------------------------
signal crafting_closed()

# --- Constants --------------------------------------------------------------
const COLOR_TITLE: Color = Color(1.0, 0.92, 0.23)
const COLOR_GOOD: Color = Color(0.45, 1.0, 0.45)
const COLOR_BAD: Color = Color(1.0, 0.35, 0.35)
const COLOR_WARN: Color = Color(1.0, 0.55, 0.0)
const COLOR_TEXT: Color = Color(0.85, 0.85, 0.85)
const COLOR_TEXT_DIM: Color = Color(0.55, 0.55, 0.55)

# --- State ------------------------------------------------------------------
var _recipe_ids: Array[String] = []
var _selected_index: int = 0

# --- UI handles -------------------------------------------------------------
var _dim: ColorRect
var _panel: Panel
var _title_label: Label
var _gold_label: Label
var _recipe_list: ItemList
var _detail_label: RichTextLabel
var _hint_label: Label
var _status_label: Label


# --- Lifecycle --------------------------------------------------------------

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_populate_recipes()
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_up"):
		_move_selection(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_down"):
		_move_selection(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("confirm"):
		_craft_selected()
		get_viewport().set_input_as_handled()


# --- Public API -------------------------------------------------------------

func open() -> void:
	visible = true
	_populate_recipes()
	_refresh_gold()
	if not _recipe_ids.is_empty():
		_selected_index = clampi(_selected_index, 0, _recipe_ids.size() - 1)
		_recipe_list.select(_selected_index)
		_show_detail(_selected_index)
	AudioManager.play_sfx("select")


func close() -> void:
	visible = false
	AudioManager.play_sfx("cancel")
	crafting_closed.emit()


# --- UI Construction --------------------------------------------------------

func _build_ui() -> void:
	# Dim background
	_dim = ColorRect.new()
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0, 0, 0, 0.7)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	# Main panel
	_panel = _make_panel(Color(0.06, 0.06, 0.10, 0.97))
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -480.0
	_panel.offset_top = -320.0
	_panel.offset_right = 480.0
	_panel.offset_bottom = 320.0
	add_child(_panel)

	# Title
	_title_label = _make_label("合成工坊", 26)
	_title_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_title_label.offset_top = 14
	_title_label.offset_bottom = 46
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", COLOR_TITLE)
	_panel.add_child(_title_label)

	# Gold counter (top-right)
	_gold_label = _make_label("", 18)
	_gold_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_gold_label.offset_left = -200
	_gold_label.offset_top = 18
	_gold_label.offset_right = -16
	_gold_label.offset_bottom = 44
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_gold_label.add_theme_color_override("font_color", COLOR_TITLE)
	_panel.add_child(_gold_label)

	# Content area (HBox: recipe list | detail)
	var content := HBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 16
	content.offset_top = 56
	content.offset_right = -16
	content.offset_bottom = -56
	content.add_theme_constant_override("separation", 12)
	_panel.add_child(content)

	# Left: recipe list
	_recipe_list = ItemList.new()
	_recipe_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipe_list.custom_minimum_size = Vector2(340, 0)
	_recipe_list.focus_mode = Control.FOCUS_NONE
	_recipe_list.item_selected.connect(_on_recipe_selected)
	_recipe_list.item_activated.connect(_on_recipe_activated)
	content.add_child(_recipe_list)

	# Right: detail panel
	_detail_label = RichTextLabel.new()
	_detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_label.bbcode_enabled = true
	_detail_label.text = ""
	content.add_child(_detail_label)

	# Status label (shows craft result / errors)
	_status_label = _make_label("", 15)
	_status_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status_label.offset_top = -72
	_status_label.offset_bottom = -48
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(_status_label)

	# Hint label
	_hint_label = _make_label("↑↓:选择  Z:合成  X:返回", 14)
	_hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint_label.offset_top = -30
	_hint_label.offset_bottom = -10
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_color_override("font_color", COLOR_TEXT_DIM)
	_panel.add_child(_hint_label)


# --- Recipe list population -------------------------------------------------

func _populate_recipes() -> void:
	_recipe_ids.clear()
	_recipe_list.clear()
	var all_recipes: Array = DataLoader.get_crafting_list()
	# Sort alphabetically for a stable display.
	all_recipes.sort()
	for id in all_recipes:
		var rid := String(id)
		_recipe_ids.append(rid)
		var recipe := DataLoader.get_crafting_recipe(rid)
		var name: String = String(recipe.get("name", rid))
		var check := DataLoader.check_craft_requirements(rid)
		var tag: String = "[READY]" if bool(check.get("can_craft", false)) else "[---]"
		_recipe_list.add_item("%s  %s" % [tag, name])
	if not _recipe_ids.is_empty():
		_recipe_list.select(0)
		_selected_index = 0
		_show_detail(0)
	else:
		_detail_label.text = "[i]No crafting recipes available.[/i]"


func _move_selection(direction: int) -> void:
	if _recipe_ids.is_empty():
		return
	AudioManager.play_sfx("cursor")
	_selected_index = posmod(_selected_index + direction, _recipe_ids.size())
	_recipe_list.select(_selected_index)
	_recipe_list.ensure_current_is_visible()
	_show_detail(_selected_index)


func _on_recipe_selected(idx: int) -> void:
	_selected_index = idx
	_show_detail(idx)


func _on_recipe_activated(_idx: int) -> void:
	_craft_selected()


# --- Detail display ---------------------------------------------------------

func _show_detail(idx: int) -> void:
	if idx < 0 or idx >= _recipe_ids.size():
		_detail_label.text = ""
		return
	var recipe_id: String = _recipe_ids[idx]
	var recipe := DataLoader.get_crafting_recipe(recipe_id)
	if recipe.is_empty():
		_detail_label.text = "[color=red]Error: Recipe not found.[/color]"
		return

	var check := DataLoader.check_craft_requirements(recipe_id)
	var name: String = String(recipe.get("name", recipe_id))
	var desc: String = String(recipe.get("description", ""))
	var gold_cost: int = int(recipe.get("gold_cost", 0))
	var result_item: String = String(recipe.get("result_item", ""))
	var result_count: int = int(recipe.get("result_count", 1))
	var materials: Dictionary = recipe.get("materials", {})

	var text := "[b][color=yellow]%s[/color][/b]\n\n" % name
	text += "%s\n\n" % desc

	# Materials section
	text += "[b]Materials Required:[/b]\n"
	if materials.is_empty():
		text += "  (none)\n"
	else:
		for mat_id in materials:
			var needed: int = int(materials[mat_id])
			var have: int = GameState.get_item_count(mat_id)
			var mat_data := DataLoader.get_item(mat_id)
			if mat_data.is_empty():
				mat_data = DataLoader.get_equipment(mat_id)
			var mat_name: String = String(mat_data.get("name", mat_id))
			var color: String = "green" if have >= needed else "red"
			text += "  [color=%s]%s  %d/%d[/color]\n" % [color, mat_name, have, needed]

	# Gold cost
	text += "\n[b]Gold Cost:[/b] "
	var gold_color: String = "green" if bool(check.get("gold_ok", false)) else "red"
	text += "[color=%s]%d G[/color]\n" % [gold_color, gold_cost]

	# Result
	text += "\n[b]Result:[/b] "
	var result_data := DataLoader.get_item(result_item)
	if result_data.is_empty():
		result_data = DataLoader.get_equipment(result_item)
	var result_name: String = String(result_data.get("name", result_item))
	text += "%s x%d" % [result_name, result_count]

	# Overall status
	text += "\n\n"
	if bool(check.get("can_craft", false)):
		text += "[color=green]>> Ready to craft! Press Z. <<[/color]"
	else:
		text += "[color=red]>> Requirements not met. <<[/color]"

	_detail_label.text = text
	_status_label.text = ""


# --- Crafting action --------------------------------------------------------

func _craft_selected() -> void:
	if _selected_index < 0 or _selected_index >= _recipe_ids.size():
		return
	var recipe_id: String = _recipe_ids[_selected_index]
	var recipe := DataLoader.get_crafting_recipe(recipe_id)
	var name: String = String(recipe.get("name", recipe_id))

	var check := DataLoader.check_craft_requirements(recipe_id)
	if not bool(check.get("can_craft", false)):
		# Provide specific feedback.
		var missing: Dictionary = check.get("missing", {})
		if not missing.is_empty():
			var first_mat: String = String(missing.keys()[0])
			var mat_data := DataLoader.get_item(first_mat)
			if mat_data.is_empty():
				mat_data = DataLoader.get_equipment(first_mat)
			var mat_name: String = String(mat_data.get("name", first_mat))
			_status_label.text = "%s不足！(还需%d)" % [mat_name, int(missing[first_mat])]
		elif not bool(check.get("gold_ok", false)):
			_status_label.text = "金币不足！(需%dG)" % int(recipe.get("gold_cost", 0))
		else:
			_status_label.text = "无法合成此物品。"
		_status_label.add_theme_color_override("font_color", COLOR_BAD)
		AudioManager.play_sfx("cancel")
		return

	# Perform the craft.
	if GameState.craft_item(recipe_id):
		_status_label.text = "合成%s成功！" % name
		_status_label.add_theme_color_override("font_color", COLOR_GOOD)
		# Refresh the list (tags may have changed) and detail.
		_refresh_gold()
		var prev_index := _selected_index
		_populate_recipes()
		_selected_index = clampi(prev_index, 0, _recipe_ids.size() - 1)
		_recipe_list.select(_selected_index)
		_show_detail(_selected_index)
	else:
		_status_label.text = "合成失败！"
		_status_label.add_theme_color_override("font_color", COLOR_BAD)


# --- Helpers ----------------------------------------------------------------

func _refresh_gold() -> void:
	_gold_label.text = "金币: %dG" % GameState.gold


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
