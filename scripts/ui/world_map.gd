## WorldMap
## An overworld map overlay showing all discovered locations and routes.
## Players can select a destination to fast-travel (if connected to current map).
## This mimics the Metal Max travel system where you pick destinations
## from a map rather than walking to edges.
extends Control

signal destination_selected(map_id: String)
signal map_closed()

# --- Map positions (normalized 0-1 coordinates for a 800x500 map area) ---
const MAP_POSITIONS := {
    "wasteland": Vector2(0.45, 0.45),
    "town": Vector2(0.45, 0.75),
    "ruins": Vector2(0.30, 0.20),
    "desert": Vector2(0.65, 0.40),
    "mountain_pass": Vector2(0.75, 0.20),
    "toxic_swamp": Vector2(0.90, 0.30),
    "underground_lab": Vector2(0.25, 0.10),
    "secret_base": Vector2(0.80, 0.05),
}

var _dim: ColorRect
var _main_panel: Panel
var _map_container: Control
var _detail_label: RichTextLabel
var _travel_button: Button
var _close_button: Button
var _status_label: Label
var _node_buttons: Dictionary = {}  # map_id -> Button
var _selected_map: String = ""
var _hint_label: Label

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()
    visible = false

func _unhandled_input(event: InputEvent) -> void:
    if not visible:
        return
    if event.is_action_pressed("cancel") or event.is_action_pressed("menu"):
        close()
        get_viewport().set_input_as_handled()
    elif event.is_action_pressed("confirm"):
        if not _selected_map.is_empty():
            _travel_to_selected()
            get_viewport().set_input_as_handled()

func open() -> void:
    visible = true
    get_tree().paused = true
    _refresh_map()
    AudioManager.play_sfx("select")

func close() -> void:
    visible = false
    get_tree().paused = false
    map_closed.emit()
    AudioManager.play_sfx("cancel")

func _build_ui() -> void:
    set_anchors_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_STOP

    _dim = ColorRect.new()
    _dim.set_anchors_preset(Control.PRESET_FULL_RECT)
    _dim.color = Color(0, 0, 0, 0.8)
    _dim.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(_dim)

    _main_panel = Panel.new()
    _main_panel.set_anchors_preset(Control.PRESET_CENTER)
    _main_panel.offset_left = -500
    _main_panel.offset_top = -340
    _main_panel.offset_right = 500
    _main_panel.offset_bottom = 340
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.05, 0.05, 0.08, 0.97)
    style.border_width_left = 2
    style.border_width_top = 2
    style.border_width_right = 2
    style.border_width_bottom = 2
    style.border_color = Color(0.5, 0.45, 0.3, 1.0)
    style.corner_radius_top_left = 8
    style.corner_radius_top_right = 8
    style.corner_radius_bottom_left = 8
    style.corner_radius_bottom_right = 8
    _main_panel.add_theme_stylebox_override("panel", style)
    add_child(_main_panel)

    # Title
    var title := Label.new()
    title.text = "世界地图"
    title.set_anchors_preset(Control.PRESET_TOP_WIDE)
    title.offset_top = 10
    title.offset_bottom = 38
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 24)
    title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.23))
    title.add_theme_color_override("font_outline_color", Color.BLACK)
    title.add_theme_constant_override("outline_size", 4)
    _main_panel.add_child(title)

    # Map area (left side)
    _map_container = Control.new()
    _map_container.set_anchors_preset(Control.PRESET_FULL_RECT)
    _map_container.offset_left = 16
    _map_container.offset_top = 48
    _map_container.offset_right = -280
    _map_container.offset_bottom = -56
    _map_container.mouse_filter = Control.MOUSE_FILTER_STOP
    _main_panel.add_child(_map_container)

    # Draw map background
    var bg := ColorRect.new()
    bg.set_anchors_preset(Control.PRESET_FULL_RECT)
    bg.color = Color(0.08, 0.07, 0.05, 0.9)
    bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _map_container.add_child(bg)

    # Detail panel (right side)
    _detail_label = RichTextLabel.new()
    _detail_label.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
    _detail_label.offset_left = -264
    _detail_label.offset_top = 48
    _detail_label.offset_right = -16
    _detail_label.offset_bottom = -100
    _detail_label.bbcode_enabled = true
    _detail_label.text = "[center][i]Select a location[/i][/center]"
    _main_panel.add_child(_detail_label)

    # Buttons (bottom right)
    var btn_row := HBoxContainer.new()
    btn_row.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
    btn_row.offset_left = 16
    btn_row.offset_top = -48
    btn_row.offset_right = -16
    btn_row.offset_bottom = -12
    btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
    btn_row.add_theme_constant_override("separation", 8)
    _main_panel.add_child(btn_row)

    _travel_button = Button.new()
    _travel_button.text = "前往"
    _travel_button.custom_minimum_size = Vector2(140, 36)
    _travel_button.focus_mode = Control.FOCUS_NONE
    _travel_button.disabled = true
    _travel_button.pressed.connect(_travel_to_selected)
    btn_row.add_child(_travel_button)

    _close_button = Button.new()
    _close_button.text = "关闭"
    _close_button.custom_minimum_size = Vector2(140, 36)
    _close_button.focus_mode = Control.FOCUS_NONE
    _close_button.pressed.connect(close)
    btn_row.add_child(_close_button)

    _status_label = Label.new()
    _status_label.text = ""
    _status_label.custom_minimum_size = Vector2(200, 36)
    _status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _status_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
    btn_row.add_child(_status_label)

    # Hint
    _hint_label = Label.new()
    _hint_label.text = "点击地点选择  Z:前往  Esc:关闭"
    _hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
    _hint_label.offset_top = -22
    _hint_label.offset_bottom = -4
    _hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _hint_label.add_theme_font_size_override("font_size", 12)
    _hint_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
    _main_panel.add_child(_hint_label)

func _refresh_map() -> void:
    # Clear old nodes
    for key in _node_buttons.keys():
        if is_instance_valid(_node_buttons[key]):
            _node_buttons[key].queue_free()
    _node_buttons.clear()

    var map_size := _map_container.size
    var current_map := GameState.current_map
    var current_data := DataLoader.get_map_data(current_map)
    var connections: Dictionary = current_data.get("connections", {})

    # Spawn map nodes
    for map_id in MAP_POSITIONS.keys():
        var pos: Vector2 = MAP_POSITIONS[map_id]
        var world_pos := Vector2(pos.x * map_size.x, pos.y * map_size.y)
        var map_data := DataLoader.get_map_data(map_id)

        var btn := Button.new()
        btn.position = world_pos - Vector2(60, 16)
        btn.size = Vector2(120, 32)
        btn.text = String(map_data.get("name", map_id))
        btn.add_theme_font_size_override("font_size", 11)
        btn.focus_mode = Control.FOCUS_NONE

        # Color code: current=green, connected=yellow, other=gray
        if map_id == current_map:
            btn.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
            btn.text = "[HERE] " + btn.text
            btn.disabled = true
        elif connections.values().has(map_id) or _is_connected(map_id, current_map):
            btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
        else:
            btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
            btn.disabled = true  # Can only travel to connected maps

        btn.pressed.connect(_on_map_node_clicked.bind(map_id))
        _map_container.add_child(btn)
        _node_buttons[map_id] = btn

    _selected_map = ""
    _detail_label.text = "[center][i]Select a connected location to travel.[/i][/center]\n\n"
    _detail_label.text += "[color=green]Green[/color] = Current location\n"
    _detail_label.text += "[color=yellow]Yellow[/color] = Can travel\n"
    _detail_label.text += "[color=gray]Gray[/color] = Not connected\n"
    _travel_button.disabled = true
    _status_label.text = ""

func _is_connected(map_a: String, map_b: String) -> bool:
    var data := DataLoader.get_map_data(map_a)
    var connections: Dictionary = data.get("connections", {})
    for dest in connections.values():
        if String(dest) == map_b:
            return true
    return false

func _on_map_node_clicked(map_id: String) -> void:
    _selected_map = map_id
    _show_detail(map_id)
    AudioManager.play_sfx("cursor")
    # Enable travel button if connected
    var current_data := DataLoader.get_map_data(GameState.current_map)
    var connections: Dictionary = current_data.get("connections", {})
    var can_travel: bool = _is_connected(GameState.current_map, map_id)
    _travel_button.disabled = not can_travel

func _show_detail(map_id: String) -> void:
    var data := DataLoader.get_map_data(map_id)
    var name := String(data.get("name", map_id))
    var is_town := bool(data.get("is_town", false))
    var no_enc := bool(data.get("no_encounters", false))
    var is_dungeon := bool(data.get("is_dungeon", false))

    var text := "[b][font_size=18]%s[/font_size][/b]\n\n" % name
    text += "[b]Type:[/b] "
    if is_town:
        text += "Town (Safe Zone)\n"
    elif is_dungeon:
        text += "Dungeon (Dangerous)\n"
    else:
        text += "Wilderness\n"

    text += "[b]遭遇区:[/b] %s\n" % ("无" if no_enc else "有")
    text += "[b]商店:[/b] %s\n" % ("有" if not String(data.get("shop_id", "")).is_empty() else "无")

    # Show connections
    var connections: Dictionary = data.get("connections", {})
    if not connections.is_empty():
        text += "\n[b]Routes:[/b]\n"
        for direction in connections:
            var dest_id := String(connections[direction])
            var dest := DataLoader.get_map_data(dest_id)
            text += "  %s -> %s\n" % [String(direction).capitalize(), String(dest.get("name", dest_id))]

    # Travel availability
    var current_data := DataLoader.get_map_data(GameState.current_map)
    var can_travel := _is_connected(GameState.current_map, map_id)
    if map_id == GameState.current_map:
        text += "\n[color=green]You are here.[/color]"
    elif can_travel:
        text += "\n[color=yellow]Ready to travel![/color]"
    else:
        text += "\n[color=gray]Not directly connected.[/color]"

    _detail_label.text = text

func _travel_to_selected() -> void:
    if _selected_map.is_empty():
        return
    var can_travel := _is_connected(GameState.current_map, _selected_map)
    if not can_travel:
        _status_label.text = "无法前往该地点！"
        _status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
        AudioManager.play_sfx("cancel")
        return

    AudioManager.play_sfx("door")
    _status_label.text = "正在前往%s..." % _selected_map
    _status_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
    destination_selected.emit(_selected_map)
    GameState.current_map = _selected_map
    close()
    # Change scene after a brief delay
    get_tree().paused = false
    GameState.change_scene("res://scenes/world.tscn")
