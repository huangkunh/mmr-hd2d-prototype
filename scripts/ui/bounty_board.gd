## BountyBoard
## A full-screen wanted poster display showing all available bounties.
## Shows bounty alias, difficulty stars, threat level, reward, and status.
## Players can track bounties to set them as active targets.
extends Control

signal bounty_board_closed()
signal bounty_tracked(bounty_id: String)

const STAR_FILLED := "[color=yellow]*[/color]"
const STAR_EMPTY := "[color=gray]*[/color]"

var _dim: ColorRect
var _main_panel: Panel
var _bounty_list: ItemList
var _detail_label: RichTextLabel
var _track_button: Button
var _close_button: Button
var _status_label: Label
var _bounty_ids: Array[String] = []
var _selected_index: int = 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()
    _refresh_bounty_list()
    visible = false

func _unhandled_input(event: InputEvent) -> void:
    if not visible:
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
    elif event.is_action_pressed("confirm"):
        _track_selected()
        get_viewport().set_input_as_handled()

func open() -> void:
    visible = true
    get_tree().paused = true
    _refresh_bounty_list()
    AudioManager.play_sfx("select")

func close() -> void:
    visible = false
    get_tree().paused = false
    bounty_board_closed.emit()
    AudioManager.play_sfx("cancel")

func _build_ui() -> void:
    set_anchors_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_STOP
    
    _dim = ColorRect.new()
    _dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    _dim.color = Color(0, 0, 0, 0.75)
    _dim.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(_dim)
    
    _main_panel = Panel.new()
    _main_panel.set_anchors_preset(Control.PRESET_CENTER)
    _main_panel.offset_left = -480
    _main_panel.offset_top = -320
    _main_panel.offset_right = 480
    _main_panel.offset_bottom = 320
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.06, 0.05, 0.09, 0.97)
    style.border_width_left = 2
    style.border_width_top = 2
    style.border_width_right = 2
    style.border_width_bottom = 2
    style.border_color = Color(0.8, 0.65, 0.2, 1.0)
    style.corner_radius_top_left = 8
    style.corner_radius_top_right = 8
    style.corner_radius_bottom_left = 8
    style.corner_radius_bottom_right = 8
    _main_panel.add_theme_stylebox_override("panel", style)
    add_child(_main_panel)
    
    # Title
    var title := Label.new()
    title.text = "通缉令"
    title.set_anchors_preset(Control.PRESET_TOP_WIDE)
    title.offset_top = 12
    title.offset_bottom = 44
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 28)
    title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
    title.add_theme_color_override("font_outline_color", Color.BLACK)
    title.add_theme_constant_override("outline_size", 4)
    _main_panel.add_child(title)
    
    var subtitle := Label.new()
    subtitle.text = "赏金榜"
    subtitle.set_anchors_preset(Control.PRESET_TOP_WIDE)
    subtitle.offset_top = 44
    subtitle.offset_bottom = 64
    subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    subtitle.add_theme_font_size_override("font_size", 14)
    subtitle.add_theme_color_override("font_color", Color(0.7, 0.65, 0.5))
    _main_panel.add_child(subtitle)
    
    # Content area: list on left, detail on right
    var hbox := HBoxContainer.new()
    hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
    hbox.offset_left = 16
    hbox.offset_top = 72
    hbox.offset_right = -16
    hbox.offset_bottom = -60
    hbox.add_theme_constant_override("separation", 12)
    _main_panel.add_child(hbox)
    
    # Bounty list
    _bounty_list = ItemList.new()
    _bounty_list.custom_minimum_size = Vector2(320, 0)
    _bounty_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _bounty_list.focus_mode = Control.FOCUS_NONE
    _bounty_list.item_selected.connect(_on_bounty_selected)
    hbox.add_child(_bounty_list)
    
    # Detail panel
    _detail_label = RichTextLabel.new()
    _detail_label.bbcode_enabled = true
    _detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _detail_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
    hbox.add_child(_detail_label)
    
    # Buttons
    var btn_row := HBoxContainer.new()
    btn_row.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
    btn_row.offset_top = -48
    btn_row.offset_bottom = -12
    btn_row.offset_left = 16
    btn_row.offset_right = -16
    btn_row.add_theme_constant_override("separation", 8)
    _main_panel.add_child(btn_row)
    
    _track_button = Button.new()
    _track_button.text = "追踪赏金"
    _track_button.custom_minimum_size = Vector2(0, 36)
    _track_button.focus_mode = Control.FOCUS_NONE
    _track_button.pressed.connect(_track_selected)
    btn_row.add_child(_track_button)
    
    _close_button = Button.new()
    _close_button.text = "关闭"
    _close_button.custom_minimum_size = Vector2(0, 36)
    _close_button.focus_mode = Control.FOCUS_NONE
    _close_button.pressed.connect(close)
    btn_row.add_child(_close_button)
    
    _status_label = Label.new()
    _status_label.text = ""
    _status_label.custom_minimum_size = Vector2(200, 36)
    _status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _status_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
    btn_row.add_child(_status_label)
    
    # Hint
    var hint := Label.new()
    hint.text = "↑↓:选择  Z:追踪  Esc:关闭"
    hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
    hint.offset_top = -24
    hint.offset_bottom = -6
    hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hint.add_theme_font_size_override("font_size", 12)
    hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
    _main_panel.add_child(hint)

func _refresh_bounty_list() -> void:
    _bounty_ids.clear()
    _bounty_list.clear()
    var bounty_ids = DataLoader.get_bounty_list()
    for bounty_id in bounty_ids:
        var enemy = DataLoader.get_enemy(String(bounty_id))
        if enemy.is_empty():
            continue
        _bounty_ids.append(String(bounty_id))
        var name_text = String(enemy.get("alias", enemy.get("name", bounty_id)))
        var status = _get_bounty_status_text(String(bounty_id))
        _bounty_list.add_item("%s %s" % [name_text, status])
    if not _bounty_ids.is_empty():
        _selected_index = 0
        _bounty_list.select(0)
        _show_bounty_detail(0)

func _get_bounty_status_text(bounty_id: String) -> String:
    if GameState.defeated_bounties.has(bounty_id):
        return "[DEFEATED]"
    if GameState.active_quests.has("bounty_" + bounty_id):
        return "[TRACKING]"
    return ""

func _on_bounty_selected(idx: int) -> void:
    _selected_index = idx
    _show_bounty_detail(idx)

func _move_selection(direction: int) -> void:
    if _bounty_ids.is_empty():
        return
    _selected_index = posmod(_selected_index + direction, _bounty_ids.size())
    _bounty_list.select(_selected_index)
    _show_bounty_detail(_selected_index)
    AudioManager.play_sfx("cursor")

func _show_bounty_detail(idx: int) -> void:
    if idx < 0 or idx >= _bounty_ids.size():
        _detail_label.text = ""
        return
    var bounty_id = _bounty_ids[idx]
    var enemy = DataLoader.get_enemy(bounty_id)
    if enemy.is_empty():
        _detail_label.text = "暂无数据。"
        return
    
    var name = String(enemy.get("name", bounty_id))
    var alias = String(enemy.get("alias", ""))
    var difficulty = int(enemy.get("difficulty", 1))
    var threat = String(enemy.get("threat_level", "Unknown"))
    var location = String(enemy.get("location", "Unknown"))
    var reward = int(enemy.get("bounty_reward", 0))
    var desc = String(enemy.get("description", ""))
    var hp = int(enemy.get("hp", 0))
    var atk = int(enemy.get("attack", 0))
    var def = int(enemy.get("defense", 0))
    
    var stars = ""
    for i in range(5):
        stars += STAR_FILLED if i < difficulty else STAR_EMPTY
    
    var defeated = GameState.defeated_bounties.has(bounty_id)
    var tracking = GameState.active_quests.has("bounty_" + bounty_id)
    
    var text = ""
    text += "[center][b][font_size=24]%s[/font_size][/b][/center]\n" % (alias if not alias.is_empty() else name)
    text += "[center][i]%s[/i][/center]\n\n" % name
    text += "[center]%s[/center]\n" % stars
    text += "[center]Threat: [color=red]%s[/color][/center]\n\n" % threat
    text += "%s\n\n" % desc
    text += "[b]Target Data:[/b]\n"
    text += "  HP: %d\n" % hp
    text += "  Attack: %d\n" % atk
    text += "  Defense: %d\n" % def
    text += "  Weakness: %s\n\n" % String(enemy.get("weakness", "Unknown"))
    text += "[b]Last Seen:[/b] %s\n" % location
    text += "[b]Reward:[/b] [color=yellow]%d G[/color]\n\n" % reward
    
    if defeated:
        text += "[center][color=green]*** BOUNTY CLAIMED ***[/color][/center]\n"
        _track_button.disabled = true
        _track_button.text = "已击败"
    elif tracking:
        text += "[center][color=yellow]*** CURRENTLY TRACKING ***[/color][/center]\n"
        _track_button.disabled = false
        _track_button.text = "取消追踪"
    else:
        _track_button.disabled = false
        _track_button.text = "追踪赏金"
    
    _detail_label.text = text

func _track_selected() -> void:
    if _selected_index < 0 or _selected_index >= _bounty_ids.size():
        return
    var bounty_id = _bounty_ids[_selected_index]
    if GameState.defeated_bounties.has(bounty_id):
        _status_label.text = "该赏金已领取。"
        return
    
    var quest_id = "bounty_" + bounty_id
    if GameState.active_quests.has(quest_id):
        # Untrack
        GameState.active_quests.erase(quest_id)
        GameState.quest_progress.erase(quest_id)
        _status_label.text = "已取消追踪。"
        AudioManager.play_sfx("cancel")
    else:
        # Track
        GameState.start_quest(quest_id)
        _status_label.text = "正在追踪: %s" % bounty_id
        AudioManager.play_sfx("confirm")
        bounty_tracked.emit(bounty_id)
    
    _refresh_bounty_list()
    _show_bounty_detail(_selected_index)
