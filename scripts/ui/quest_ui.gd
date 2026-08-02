## QuestUI
## Control node that renders the quest log for the HD-2D RPG.
##
## The interface is built entirely from code in _ready(), so the companion
## .tscn only needs to attach this script to a Control node (a CanvasLayer
## child is included for convenience). Place the scene under a world
## CanvasLayer or load it directly as an overlay.
##
## Layout:
##   Left  : a scrollable, grouped list of quests.
##             - ACTIVE    : quests currently in progress (GameState.active_quests).
##             - BOUNTY    : available bounty quests not yet accepted.
##             - COMPLETED : finished quests, drawn in green.
##   Right : a RichTextLabel (BBCode) showing the selected quest's details —
##           name, type badge, description, prerequisite, objective progress
##           and rewards.
##
## Controls (project input actions):
##   - Up / Down     : move the selection one entry.
##   - Left / Right  : page through the list (+/- PAGE_STEP entries).
##   - Z / Enter     : accept the selected bounty quest (if eligible).
##   - X / Esc       : close the quest log.
##
## The node runs with PROCESS_MODE_ALWAYS and (optionally) pauses the
## SceneTree while open. It refreshes automatically whenever
## GameState.quest_updated fires. Emits [signal quest_ui_closed] when the
## player closes the log.
class_name QuestUI
extends Control

# --- Signals ----------------------------------------------------------------
## Emitted when the quest log is closed by the player (X / Esc).
signal quest_ui_closed

# --- Colours ----------------------------------------------------------------
const COL_PANEL_BG := Color(0.06, 0.05, 0.09, 0.86)
const COL_PANEL_BORDER := Color(0.34, 0.30, 0.46, 1.0)
const COL_ACCENT := Color(0.92, 0.76, 0.34, 1.0)
const COL_TEXT := Color(0.93, 0.93, 0.96, 1.0)
const COL_TEXT_DIM := Color(0.66, 0.64, 0.72, 1.0)
const COL_COMPLETED := Color(0.45, 1.0, 0.55, 1.0)
const COL_BOUNTY := Color(0.95, 0.80, 0.22, 1.0)

# --- Constants --------------------------------------------------------------
## Number of entries skipped when paging with Left/Right.
const PAGE_STEP: int = 5
## Group identifiers used internally to tag list rows.
const GROUP_ACTIVE: String = "active"
const GROUP_BOUNTY: String = "bounty"
const GROUP_COMPLETED: String = "completed"

# --- Exports ----------------------------------------------------------------
## When true, opening the quest log pauses the SceneTree so the world freezes
## behind the overlay.
@export var pause_tree_on_open: bool = true

# --- State ------------------------------------------------------------------
var is_open: bool = false
## Flat list of every list row (headers, placeholders and quest entries).
## Each entry is a Dictionary with the keys:
##   "header"   : bool   - true for group header rows.
##   "quest_id" : String - the quest id (empty for headers / placeholders).
##   "group"    : String - one of the GROUP_* constants (empty for headers).
##   "label"    : Label  - the row's Label node.
##   "name"     : String - display text used when (re)building the row.
var _entries: Array[Dictionary] = []
## Indices into [_entries] that point at selectable quest rows.
var _selectable: Array[int] = []
## Current selection, expressed as an index into [_selectable] (-1 = none).
var _sel_pos: int = -1

# --- UI Handles (built in _ready) -------------------------------------------
var _dim: ColorRect
var _main_panel: Panel
var _list_scroll: ScrollContainer
var _list_container: VBoxContainer
var _detail_label: RichTextLabel
var _hint_label: Label


# --- Lifecycle --------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false
	# Live-refresh the log whenever a quest changes status while it is open.
	if not GameState.quest_updated.is_connected(_on_quest_updated):
		GameState.quest_updated.connect(_on_quest_updated)


## GameState.quest_updated handler — refreshes the log live while it is open.
func _on_quest_updated(_quest_id: String, _status: String) -> void:
	if is_open:
		_refresh_list()
		_show_details()
		_update_hint()


func _exit_tree() -> void:
	if GameState and GameState.quest_updated.is_connected(_on_quest_updated):
		GameState.quest_updated.disconnect(_on_quest_updated)
	if pause_tree_on_open and get_tree():
		get_tree().paused = false


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		return

	if event.is_action_pressed("cancel") or event.is_action_pressed("menu"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_up"):
		_move_selection(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_down"):
		_move_selection(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_left"):
		_move_selection(-PAGE_STEP)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_right"):
		_move_selection(PAGE_STEP)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("confirm"):
		_confirm_selection()
		get_viewport().set_input_as_handled()


# --- Open / close -----------------------------------------------------------

## Shows the quest log, refreshes its contents and (optionally) pauses the game.
func open() -> void:
	is_open = true
	visible = true
	if pause_tree_on_open:
		get_tree().paused = true
	_refresh_list()
	_show_details()
	_update_hint()


## Hides the quest log, un-pauses the game and emits [signal quest_ui_closed].
func close() -> void:
	is_open = false
	visible = false
	if pause_tree_on_open:
		get_tree().paused = false
	quest_ui_closed.emit()


## Convenience toggle for callers that want a single entry point.
func toggle() -> void:
	if is_open:
		close()
	else:
		open()


# --- List building ----------------------------------------------------------

## Rebuilds the grouped quest list from the current GameState / DataLoader.
## The selection is preserved across rebuilds by quest id when possible.
func _refresh_list() -> void:
	# Remember the currently selected quest so we can reselect it afterwards.
	var prev_id: String = ""
	if _sel_pos >= 0 and _selectable.size() > 0:
		prev_id = String(_entries[_selectable[_sel_pos]].get("quest_id", ""))

	# Tear down existing rows (immediate free — these are plain Labels).
	for child in _list_container.get_children():
		child.free()
	_entries.clear()
	_selectable.clear()

	# --- Active quests -------------------------------------------------------
	_add_header("ACTIVE")
	if GameState.active_quests.is_empty():
		_add_placeholder("(no active quests)")
	else:
		for qid in GameState.active_quests:
			_add_quest_row(String(qid), GROUP_ACTIVE)

	# --- Available bounty quests --------------------------------------------
	_add_header("BOUNTY")
	var bounty_found: bool = false
	for qid in DataLoader.get_bounty_quests():
		var sid: String = String(qid)
		# Skip bounties already accepted or finished — they appear elsewhere.
		if GameState.active_quests.has(sid) or GameState.completed_quests.has(sid):
			continue
		_add_quest_row(sid, GROUP_BOUNTY)
		bounty_found = true
	if not bounty_found:
		_add_placeholder("(no bounties available)")

	# --- Completed quests ----------------------------------------------------
	_add_header("COMPLETED")
	if GameState.completed_quests.is_empty():
		_add_placeholder("(none yet)")
	else:
		for qid in GameState.completed_quests:
			_add_quest_row(String(qid), GROUP_COMPLETED)

	# Restore / clamp selection.
	if _selectable.is_empty():
		_sel_pos = -1
	elif prev_id.is_empty():
		_sel_pos = 0
	else:
		var found: bool = false
		for i in _selectable.size():
			if String(_entries[_selectable[i]].get("quest_id", "")) == prev_id:
				_sel_pos = i
				found = true
				break
		if not found:
			_sel_pos = clampi(_sel_pos, 0, _selectable.size() - 1)
	_apply_highlight()


## Adds a non-selectable, accent-coloured group header row.
func _add_header(text: String) -> void:
	var label: Label = _make_label(text, 16)
	label.add_theme_color_override("font_color", COL_ACCENT)
	_list_container.add_child(label)
	_entries.append({
		"header": true,
		"quest_id": "",
		"group": "",
		"label": label,
		"name": text,
	})


## Adds a dim, non-selectable placeholder row (e.g. "(no active quests)").
func _add_placeholder(text: String) -> void:
	var label: Label = _make_label("   " + text, 13)
	label.add_theme_color_override("font_color", COL_TEXT_DIM)
	_list_container.add_child(label)
	_entries.append({
		"header": false,
		"quest_id": "",
		"group": "",
		"label": label,
		"name": text,
	})


## Adds a selectable quest row and registers it in [_selectable].
func _add_quest_row(quest_id: String, group: String) -> void:
	var quest: Dictionary = DataLoader.get_quest(quest_id)
	var display_name: String = String(quest.get("name", quest_id))
	var label: Label = _make_label(display_name, 14)
	_list_container.add_child(label)
	var idx: int = _entries.size()
	_entries.append({
		"header": false,
		"quest_id": quest_id,
		"group": group,
		"label": label,
		"name": display_name,
	})
	_selectable.append(idx)


# --- Selection --------------------------------------------------------------

## Moves the selection by [param delta] entries (wraps around; pages with
## Left/Right). Updates the highlight, details panel, hint and scroll position.
func _move_selection(delta: int) -> void:
	if _selectable.is_empty():
		return
	if _sel_pos < 0:
		_sel_pos = 0
	_sel_pos = posmod(_sel_pos + delta, _selectable.size())
	_apply_highlight()
	_show_details()
	_update_hint()
	var sel_label: Label = _entries[_selectable[_sel_pos]]["label"]
	_list_scroll.ensure_control_visible(sel_label)


## Recolours every quest row and updates its cursor prefix. The selected row
## uses the accent colour with a ">" cursor; completed rows are green, bounty
## rows are gold and active rows are white.
func _apply_highlight() -> void:
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		if bool(entry.get("header", false)):
			continue
		var qid: String = String(entry.get("quest_id", ""))
		if qid.is_empty():
			continue  # placeholder row — leave its dim colour alone
		var label: Label = entry["label"]
		var group: String = String(entry.get("group", ""))
		var is_sel: bool = (_sel_pos >= 0 and _selectable.size() > 0
				and _selectable[_sel_pos] == i)
		var base: Color = COL_TEXT
		match group:
			GROUP_COMPLETED:
				base = COL_COMPLETED
			GROUP_BOUNTY:
				base = COL_BOUNTY
			_:
				base = COL_TEXT
		label.add_theme_color_override("font_color", COL_ACCENT if is_sel else base)
		label.text = (">  " if is_sel else "   ") + String(entry.get("name", ""))


## Accepts the selected bounty quest when it is eligible (prerequisite met).
## Non-bounty selections do nothing on confirm.
func _confirm_selection() -> void:
	if _sel_pos < 0 or _selectable.is_empty():
		return
	var entry: Dictionary = _entries[_selectable[_sel_pos]]
	if String(entry.get("group", "")) != GROUP_BOUNTY:
		return
	var quest_id: String = String(entry.get("quest_id", ""))
	if not _can_accept(quest_id):
		return
	GameState.start_quest(quest_id)
	# start_quest() emits quest_updated, which triggers _on_quest_updated() and
	# rebuilds the list (the quest moves from BOUNTY into ACTIVE). We refresh
	# explicitly as well to keep the selection tidy immediately.
	_refresh_list()
	_show_details()
	_update_hint()


## Returns true if [param quest_id] (a bounty) can be accepted right now —
## i.e. its prerequisite is empty or already completed.
func _can_accept(quest_id: String) -> bool:
	var quest: Dictionary = DataLoader.get_quest(quest_id)
	var prereq: String = String(quest.get("prerequisite", ""))
	if prereq.is_empty():
		return true
	return GameState.completed_quests.has(prereq)


# --- Details panel ----------------------------------------------------------

## Renders the selected quest's details into the right-hand RichTextLabel.
func _show_details() -> void:
	if _sel_pos < 0 or _selectable.is_empty():
		_detail_label.text = "[i][color=%s]No quests to display.[/color][/i]" % _col(COL_TEXT_DIM)
		return

	var entry: Dictionary = _entries[_selectable[_sel_pos]]
	var quest_id: String = String(entry.get("quest_id", ""))
	var quest: Dictionary = DataLoader.get_quest(quest_id)
	if quest.is_empty():
		_detail_label.text = ""
		return

	var qname: String = String(quest.get("name", quest_id))
	var qtype: String = String(quest.get("type", ""))
	var desc: String = String(quest.get("description", ""))
	var status: int = GameState.get_quest_status(quest_id)

	var text: String = ""
	# Title.
	text += "[b][color=%s]%s[/color][/b]\n" % [_col(COL_ACCENT), qname]
	# Type + status badges.
	text += _type_badge(qtype)
	if status == GameState.QuestStatus.COMPLETED:
		text += "  [color=%s][COMPLETED][/color]" % _col(COL_COMPLETED)
	text += "\n\n"
	# Description.
	text += desc + "\n\n"
	# Prerequisite (if any).
	var prereq: String = String(quest.get("prerequisite", ""))
	if not prereq.is_empty():
		var prereq_quest: Dictionary = DataLoader.get_quest(prereq)
		var prereq_name: String = String(prereq_quest.get("name", prereq))
		var done: bool = GameState.completed_quests.has(prereq)
		var pcol: Color = COL_COMPLETED if done else COL_TEXT_DIM
		text += "Requires: [color=%s]%s[/color]%s\n\n" % [
			_col(pcol), prereq_name, " (done)" if done else ""
		]
	# Objectives / progress (e.g. "Slime: 3 / 5").
	text += "[b][color=%s]OBJECTIVES[/color][/b]\n" % _col(COL_ACCENT)
	var progress_text: String = GameState.get_quest_progress_text(quest_id)
	if progress_text.is_empty():
		text += "  (no objectives)\n"
	else:
		text += progress_text + "\n"
	text += "\n"
	# Rewards.
	text += "[b][color=%s]REWARDS[/color][/b]\n" % _col(COL_ACCENT)
	var gold: int = int(quest.get("reward_gold", 0))
	var exp: int = int(quest.get("reward_exp", 0))
	var reward_item: String = String(quest.get("reward_item", ""))
	text += "  Gold: [color=%s]%d G[/color]\n" % [_col(COL_BOUNTY), gold]
	text += "  EXP : %d\n" % exp
	if not reward_item.is_empty():
		var item: Dictionary = DataLoader.get_item(reward_item)
		var item_name: String = String(item.get("name", reward_item))
		text += "  Item: %s\n" % item_name
	# Accept hint for bounties.
	if String(entry.get("group", "")) == GROUP_BOUNTY:
		text += "\n"
		if _can_accept(quest_id):
			text += "[color=%s]Press Z to accept this bounty.[/color]" % _col(COL_COMPLETED)
		else:
			text += "[color=%s]Complete the prerequisite to unlock.[/color]" % _col(COL_TEXT_DIM)
	_detail_label.text = text


## Builds a coloured "[Bounty]"/"[Story]"/"[Side]" badge string.
func _type_badge(qtype: String) -> String:
	var color: Color = COL_TEXT_DIM
	match qtype:
		"bounty":
			color = COL_BOUNTY
		"story":
			color = COL_ACCENT
		"side":
			color = COL_TEXT_DIM
	return "[color=%s][%s][/color]" % [_col(color), qtype.capitalize()]


# --- Hint -------------------------------------------------------------------

## Updates the bottom hint bar to reflect what the current selection can do.
func _update_hint() -> void:
	var hint: String = "Up/Down: Select    Left/Right: Page    Esc/X: Close"
	if _sel_pos >= 0 and _selectable.size() > 0:
		var entry: Dictionary = _entries[_selectable[_sel_pos]]
		if String(entry.get("group", "")) == GROUP_BOUNTY:
			var qid: String = String(entry.get("quest_id", ""))
			if _can_accept(qid):
				hint = "Z: Accept    Up/Down: Select    Esc/X: Close"
			else:
				hint = "Locked: complete prerequisite    Esc/X: Close"
	_hint_label.text = hint


# --- UI construction --------------------------------------------------------

## Builds the entire overlay from code: dim background, main panel, the grouped
## quest list (left) and the detail RichTextLabel (right), plus a bottom hint.
func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Dim background.
	_dim = ColorRect.new()
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.0, 0.0, 0.0, 0.66)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	# Main panel (centred, 1120 x 640).
	_main_panel = _make_panel(COL_PANEL_BG, COL_PANEL_BORDER)
	_main_panel.set_anchors_preset(Control.PRESET_CENTER)
	_main_panel.offset_left = -560.0
	_main_panel.offset_top = -320.0
	_main_panel.offset_right = 560.0
	_main_panel.offset_bottom = 320.0
	add_child(_main_panel)

	# Title.
	var title: Label = _make_label("QUEST LOG", 24)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 14.0
	title.offset_bottom = 46.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", COL_ACCENT)
	_main_panel.add_child(title)

	# Content row: list (left) | details (right).
	var content: HBoxContainer = HBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 20.0
	content.offset_top = 58.0
	content.offset_right = -20.0
	content.offset_bottom = -50.0
	content.add_theme_constant_override("separation", 18.0)
	_main_panel.add_child(content)

	# Left: scrollable quest list.
	_list_scroll = ScrollContainer.new()
	_list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_scroll.custom_minimum_size = Vector2(430.0, 0.0)
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	content.add_child(_list_scroll)

	_list_container = VBoxContainer.new()
	_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_container.add_theme_constant_override("separation", 3.0)
	_list_scroll.add_child(_list_container)

	# Right: quest details (BBCode).
	_detail_label = _make_rich_label()
	_detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_label.add_theme_color_override("default_color", COL_TEXT)
	content.add_child(_detail_label)

	# Bottom hint bar.
	_hint_label = _make_label("", 13)
	_hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint_label.offset_top = -34.0
	_hint_label.offset_bottom = -12.0
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.add_theme_color_override("font_color", COL_TEXT_DIM)
	_main_panel.add_child(_hint_label)


# --- UI factory helpers -----------------------------------------------------

## Creates a styled Panel with the given background and border colours.
func _make_panel(bg: Color, border: Color = Color(1, 1, 1, 0.15)) -> Panel:
	var p: Panel = Panel.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
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


## Creates a Label with the given text and font size.
func _make_label(text: String, font_size: int) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	return l


## Creates a BBCode-enabled RichTextLabel suitable for read-only detail text.
func _make_rich_label() -> RichTextLabel:
	var r: RichTextLabel = RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = false
	r.text = ""
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## Converts a Color to a BBCode colour tag value ("#RRGGBB").
func _col(c: Color) -> String:
	return "#" + c.to_html(false)
