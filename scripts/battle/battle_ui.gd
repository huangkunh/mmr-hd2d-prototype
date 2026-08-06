## BattleUI
## Full-screen Control overlay that presents the battle. It builds all of its
## widgets in code (so the scene file stays light and the look is consistent
## without external UI assets) and reacts to BattleManager signals.
##
## Responsibilities:
##   * Command menu (Attack / Defend / Item / Flee) — keyboard navigable.
##   * Item submenu listing usable battle items from GameState.inventory.
##   * HP bars for the player and the enemy (custom ColorRect bars).
##   * Floating damage / heal / miss popups with tween animation.
##   * Battle log text area.
##   * Enemy & player sprite display with HDR bloom modulate + idle bob.
##   * Animated victory and defeat (Game Over) screens.
##
## Input: move_up/down to navigate, confirm (Z/Enter) to select,
##        cancel (X/Esc) to back out of the item submenu.
class_name BattleUI
extends Control

# --- UI interaction mode -----------------------------------------------------
enum UIMode { NONE, COMMAND, ITEM, SKILL, VICTORY, DEFEAT }

# --- Palette (HD-2D dark / amber) -------------------------------------------
const COL_PANEL_BG := Color(0.06, 0.05, 0.09, 0.86)
const COL_PANEL_BORDER := Color(0.34, 0.30, 0.46, 1.0)
const COL_ACCENT := Color(0.92, 0.76, 0.34, 1.0)        # amber/gold
const COL_TEXT := Color(0.93, 0.93, 0.96, 1.0)
const COL_TEXT_DIM := Color(0.66, 0.64, 0.72, 1.0)

const COL_HP_GREEN := Color(0.22, 0.80, 0.34, 1.0)
const COL_HP_YELLOW := Color(0.95, 0.80, 0.22, 1.0)
const COL_HP_RED := Color(0.90, 0.26, 0.26, 1.0)
const COL_HP_BG := Color(0.09, 0.08, 0.12, 1.0)

const COL_DAMAGE := Color(1.0, 0.34, 0.30, 1.0)
const COL_CRIT := Color(1.0, 0.85, 0.25, 1.0)
const COL_HEAL := Color(0.45, 1.0, 0.55, 1.0)
const COL_MISS := Color(0.82, 0.82, 0.86, 1.0)

## Sprite modulate > 1.0 enables HDR bloom on the sprites when the project has
## "HDR for 2D" enabled (Forward+). Without it the value simply clamps to white.
const SPRITE_BLOOM_MODULATE := Color(1.45, 1.45, 1.45, 1.0)

# --- Manager / actor references ----------------------------------------------
var _manager: BattleManager
var _player_actor: BattleActor
var _enemy_actor: BattleActor

# Sprite nodes live in the scene tree (siblings of this Control).
var _enemy_display: Node2D
var _player_display: Node2D
var _enemy_sprite: Sprite2D
var _player_sprite: Sprite2D
var _enemy_pos: Vector2 = Vector2.ZERO
var _player_pos: Vector2 = Vector2.ZERO

# --- UI state ----------------------------------------------------------------
var _ui_mode: int = UIMode.NONE
var _vp_size: Vector2 = Vector2(1280, 720)

# Command menu
var _commands: Array = []          # [{id, label}, ...]
var _cmd_index: int = 0
var _command_menu: Panel
var _command_labels: Array = []    # [Label, ...]
var _command_menu_pos: Vector2

# Item submenu
var _item_menu: Panel
var _item_labels: Array = []
var _item_ids: Array = []          # [item_id, ...]
var _item_index: int = 0

# Skill submenu
var _skill_menu: Panel
var _skill_labels: Array = []
var _skill_ids: Array = []          # [skill_id, ...]
var _skill_index: int = 0

# HP bars
var _player_hp_bar: Dictionary
var _enemy_hp_bar: Dictionary
var _player_sp_bar: Dictionary
var _player_name_label: Label
var _enemy_name_label: Label
var _player_status_label: Label

# Status effect displays
var _player_status_container: HBoxContainer
var _enemy_status_container: HBoxContainer

# Log
var _log_label: Label
var _log_lines: Array[String] = []
const LOG_MAX_LINES := 6

# Popups
var _popup_layer: Control

# End screens
var _victory_screen: Panel
var _victory_bounty_label: Label
var _defeat_screen: Panel

# --- Lifecycle ---------------------------------------------------------------

func _ready() -> void:
	# Make sure this Control covers the viewport regardless of how it was
	# parented in the scene tree.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vp_size = get_viewport_rect().size

	_manager = get_node_or_null("../BattleManager")
	_enemy_display = get_node_or_null("../EnemyDisplay")
	_player_display = get_node_or_null("../PlayerDisplay")
	_enemy_sprite = get_node_or_null("../EnemyDisplay/EnemySprite")
	_player_sprite = get_node_or_null("../PlayerDisplay/PlayerSprite")

	if _enemy_display:
		_enemy_pos = _enemy_display.position
	if _player_display:
		_player_pos = _player_display.position

	_refresh_commands()

	_build_ui()
	_connect_manager_signals()

func _connect_manager_signals() -> void:
	if not _manager:
		push_warning("[BattleUI] BattleManager not found; UI will be inert.")
		return
	_manager.actors_ready.connect(_on_actors_ready)
	_manager.battle_state_changed.connect(_on_state_changed)
	_manager.battle_log.connect(_on_battle_log)
	_manager.request_player_action.connect(_open_command_menu)
	_manager.damage_dealt.connect(_on_damage_dealt)
	_manager.critical_hit.connect(_on_critical_hit)
	_manager.attack_missed.connect(_on_attack_missed)
	_manager.healed.connect(_on_healed)
	_manager.victory.connect(_on_victory)
	_manager.defeat.connect(_on_defeat)
	_manager.fled.connect(_on_fled)

## Rebuilds the command list depending on whether the player is fighting in
## tank mode (Cannon / Skill / SE Weapon / Item / Flee) or on foot
## (Attack / Skill / Defend / Item / Flee). Called on ready and whenever a
## new actor pair is presented (e.g. after a tank is destroyed).
func _refresh_commands() -> void:
	if _player_actor and _player_actor.is_tank_mode:
		# Show the SE weapon type in the label for clarity.
		var se_label: String = "SE Weapon"
		if not _player_actor.se_type.is_empty():
			se_label = "SE: %s" % _player_actor.se_type.capitalize()
		_commands = [
			{id = BattleManager.ACTION_TANK_ATTACK, label = "Cannon"},
			{id = BattleManager.ACTION_SKILL, label = "技能"},
			{id = BattleManager.ACTION_TANK_SE, label = se_label},
			{id = BattleManager.ACTION_ITEM, label = "道具"},
			{id = BattleManager.ACTION_FLEE, label = "逃跑"},
		]
	else:
		_commands = [
			{id = BattleManager.ACTION_ATTACK, label = "攻击"},
			{id = BattleManager.ACTION_SKILL, label = "技能"},
			{id = BattleManager.ACTION_DEFEND, label = "防御"},
			{id = BattleManager.ACTION_ITEM, label = "道具"},
			{id = BattleManager.ACTION_FLEE, label = "逃跑"},
		]

# --- UI construction ---------------------------------------------------------

func _build_ui() -> void:
	_add_vignette()
	_popup_layer = Control.new()
	_popup_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_popup_layer)

	_build_enemy_info()
	_build_battle_log()
	_build_player_info()
	_build_command_menu()
	_build_item_menu()
	_build_skill_menu()
	_build_victory_screen()
	_build_defeat_screen()

## Atmospheric dark vignette drawn via a canvas_item shader.
func _add_vignette() -> void:
	var v := ColorRect.new()
	v.position = Vector2.ZERO
	v.size = _vp_size
	v.color = Color.WHITE
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = "\nshader_type canvas_item;\nvoid fragment() {\n    float d = distance(SCREEN_UV, vec2(0.5, 0.5));\n    float a = smoothstep(0.30, 0.90, d) * 0.72;\n    COLOR = vec4(0.0, 0.0, 0.0, a);\n}\n"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	v.material = mat
	add_child(v)

func _make_style(bg: Color, border: Color, border_w: int, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(border_w + 8)
	return s

func _add_panel(x: float, y: float, w: float, h: float, style: StyleBoxFlat) -> Panel:
	var p := Panel.new()
	p.position = Vector2(x, y)
	p.size = Vector2(w, h)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", style)
	add_child(p)
	return p

func _make_label(text: String, color: Color, size: int, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _make_hp_bar(width: float, height: float) -> Dictionary:
	var root := Control.new()
	root.size = Vector2(width, height)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bg := ColorRect.new()
	bg.color = COL_HP_BG
	bg.size = Vector2(width, height)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)

	var fill := ColorRect.new()
	fill.color = COL_HP_GREEN
	fill.size = Vector2(width, height)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fill)

	var lbl := Label.new()
	lbl.size = Vector2(width, height)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(lbl)

	return {"root": root, "fill": fill, "label": lbl, "width": width, "height": height}

func _build_enemy_info() -> void:
	var w: float = 420.0
	var h: float = 84.0
	var x: float = _vp_size.x * 0.5 - w * 0.5
	var y: float = 24.0
	var panel := _add_panel(x, y, w, h, _make_style(COL_PANEL_BG, COL_PANEL_BORDER, 2, 8))

	_enemy_name_label = _make_label("敌人", COL_TEXT, 22, HORIZONTAL_ALIGNMENT_LEFT)
	_enemy_name_label.position = Vector2(16, 8)
	_enemy_name_label.size = Vector2(w - 32, 30)
	panel.add_child(_enemy_name_label)

	_enemy_hp_bar = _make_hp_bar(w - 32, 26)
	_enemy_hp_bar.root.position = Vector2(16, 44)
	panel.add_child(_enemy_hp_bar.root)

	# Enemy status effects
	_enemy_status_container = HBoxContainer.new()
	_enemy_status_container.position = Vector2(16, 72)
	_enemy_status_container.size = Vector2(w - 32, 12)
	_enemy_status_container.add_theme_constant_override("separation", 4)
	_enemy_status_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_enemy_status_container)

func _build_player_info() -> void:
	var w: float = 400.0
	var h: float = 158.0
	var x: float = 24.0
	var y: float = _vp_size.y - h - 24.0
	var panel := _add_panel(x, y, w, h, _make_style(COL_PANEL_BG, COL_PANEL_BORDER, 2, 8))

	_player_name_label = _make_label(GameState.player_name, COL_TEXT, 22, HORIZONTAL_ALIGNMENT_LEFT)
	_player_name_label.position = Vector2(16, 8)
	_player_name_label.size = Vector2(w - 32, 30)
	panel.add_child(_player_name_label)

	_player_status_label = _make_label("等级 %d" % GameState.player_level, COL_ACCENT, 16, HORIZONTAL_ALIGNMENT_LEFT)
	_player_status_label.position = Vector2(16, 38)
	_player_status_label.size = Vector2(w - 32, 22)
	panel.add_child(_player_status_label)

	_player_hp_bar = _make_hp_bar(w - 32, 26)
	_player_hp_bar.root.position = Vector2(16, 66)
	panel.add_child(_player_hp_bar.root)

	# SP bar (for tank mode)
	_player_sp_bar = _make_hp_bar(w - 32, 18)
	_player_sp_bar.root.position = Vector2(16, 94)
	_player_sp_bar.fill.color = Color(0.3, 0.5, 0.9)  # Blue for SP
	_player_sp_bar.root.visible = false
	panel.add_child(_player_sp_bar.root)

	# Show a compact stat line under the bar (effective stats with equipment).
	var stats := _make_label("ATK %d   DEF %d   SPD %d" % [GameState.get_effective_attack(), GameState.get_effective_defense(), GameState.get_effective_speed()], COL_TEXT_DIM, 14, HORIZONTAL_ALIGNMENT_LEFT)
	stats.position = Vector2(16, 116)
	stats.size = Vector2(w - 32, 22)
	panel.add_child(stats)

	# Status effect display
	_player_status_container = HBoxContainer.new()
	_player_status_container.position = Vector2(16, 140)
	_player_status_container.size = Vector2(w - 32, 16)
	_player_status_container.add_theme_constant_override("separation", 4)
	_player_status_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_player_status_container)

func _build_battle_log() -> void:
	var w: float = 400.0
	var h: float = 168.0
	var x: float = 24.0
	var y: float = 24.0
	var panel := _add_panel(x, y, w, h, _make_style(Color(0.05, 0.04, 0.08, 0.8), COL_PANEL_BORDER, 1, 8))

	_log_label = Label.new()
	_log_label.text = ""
	_log_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_log_label.offset_left = 12
	_log_label.offset_top = 10
	_log_label.offset_right = -12
	_log_label.offset_bottom = -10
	_log_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_log_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log_label.add_theme_font_size_override("font_size", 15)
	_log_label.add_theme_color_override("font_color", COL_TEXT)
	_log_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_log_label.add_theme_constant_override("outline_size", 3)
	_log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_log_label)

func _build_command_menu() -> void:
	var w: float = 300.0
	var h: float = 240.0
	_command_menu_pos = Vector2(_vp_size.x - w - 24.0, _vp_size.y - h - 24.0)
	_command_menu = _add_panel(_command_menu_pos.x, _command_menu_pos.y, w, h, _make_style(COL_PANEL_BG, COL_ACCENT, 2, 8))
	_command_menu.visible = false

	var title := _make_label("COMMAND", COL_ACCENT, 16, HORIZONTAL_ALIGNMENT_CENTER)
	title.position = Vector2(0, 8)
	title.size = Vector2(w, 22)
	_command_menu.add_child(title)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_top = 36
	vbox.offset_right = -16
	vbox.offset_bottom = -12
	vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_command_menu.add_child(vbox)

	_command_labels.clear()
	for cmd in _commands:
		var l := _make_label(cmd.label, COL_TEXT, 22, HORIZONTAL_ALIGNMENT_LEFT)
		l.custom_minimum_size = Vector2(0, 38)
		vbox.add_child(l)
		_command_labels.append(l)

## Rebuilds the command labels inside the existing command menu so the list
## matches the current `_commands` (which changes between tank/infantry mode).
## Preserves the "COMMAND" title and reuses the VBoxContainer from _build_command_menu.
func _rebuild_command_menu() -> void:
	if _command_menu == null:
		return
	# Locate the VBoxContainer created by _build_command_menu().
	var vbox: VBoxContainer = null
	for child in _command_menu.get_children():
		if child is VBoxContainer:
			vbox = child
			break
	if vbox == null:
		return
	# Clear existing command labels (preserves the "COMMAND" title).
	for label in vbox.get_children():
		label.queue_free()
	_command_labels.clear()
	# Rebuild with current commands.
	for cmd in _commands:
		var l := _make_label(cmd.label, COL_TEXT, 22, HORIZONTAL_ALIGNMENT_LEFT)
		l.custom_minimum_size = Vector2(0, 38)
		vbox.add_child(l)
		_command_labels.append(l)
	_cmd_index = 0

func _build_item_menu() -> void:
	var w: float = 360.0
	var h: float = 240.0
	_item_menu = _add_panel(_vp_size.x - w - 24.0, _vp_size.y - h - 24.0, w, h, _make_style(COL_PANEL_BG, COL_ACCENT, 2, 8))
	_item_menu.visible = false

func _build_skill_menu() -> void:
	var w: float = 400.0
	var h: float = 280.0
	_skill_menu = _add_panel(_vp_size.x - w - 24.0, _vp_size.y - h - 24.0, w, h, _make_style(COL_PANEL_BG, COL_ACCENT, 2, 8))
	_skill_menu.visible = false

func _rebuild_skill_menu() -> void:
	for child in _skill_menu.get_children():
		child.queue_free()
	_skill_labels.clear()
	_skill_ids.clear()

	var title := _make_label("SKILLS", COL_ACCENT, 16, HORIZONTAL_ALIGNMENT_CENTER)
	title.position = Vector2(0, 8)
	title.size = Vector2(_skill_menu.size.x, 22)
	_skill_menu.add_child(title)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_top = 36
	vbox.offset_right = -16
	vbox.offset_bottom = -12
	vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skill_menu.add_child(vbox)

	# Gather usable skills from the player actor.
	if _player_actor and not _player_actor.skills.is_empty():
		for skill_id in _player_actor.skills:
			var skill: Dictionary = DataLoader.get_skill(String(skill_id))
			if skill.is_empty():
				continue
			var skill_name: String = String(skill.get("name", skill_id))
			var cooldown: int = 0
			if GameState.skill_cooldowns.has(String(skill_id)):
				cooldown = int(GameState.skill_cooldowns[String(skill_id)])
			var detail: String = ""
			if cooldown > 0:
				detail = "  (CD: %d)" % cooldown
			else:
				var power_mult: float = float(skill.get("power_multiplier", 1.0))
				var hits: int = int(skill.get("hit_count", 1))
				detail = "  x%.1f, %d hits" % [power_mult, hits]
			var l := _make_label("%s%s" % [skill_name, detail], COL_TEXT, 18, HORIZONTAL_ALIGNMENT_LEFT)
			l.custom_minimum_size = Vector2(0, 32)
			vbox.add_child(l)
			_skill_labels.append(l)
			_skill_ids.append(String(skill_id))
	else:
		var l := _make_label("(No skills available)", COL_TEXT_DIM, 16, HORIZONTAL_ALIGNMENT_LEFT)
		l.custom_minimum_size = Vector2(0, 32)
		vbox.add_child(l)

	_skill_index = 0

func _rebuild_item_menu() -> void:
	for child in _item_menu.get_children():
		child.queue_free()
	_item_labels.clear()
	_item_ids.clear()

	var title := _make_label("ITEMS", COL_ACCENT, 16, HORIZONTAL_ALIGNMENT_CENTER)
	title.position = Vector2(0, 8)
	title.size = Vector2(_item_menu.size.x, 22)
	_item_menu.add_child(title)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_top = 36
	vbox.offset_right = -16
	vbox.offset_bottom = -12
	vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_item_menu.add_child(vbox)

	# Gather usable battle items (heal / escape) from the player inventory.
	for item_id in GameState.inventory.keys():
		var count: int = int(GameState.inventory[item_id])
		if count <= 0:
			continue
		var item: Dictionary = DataLoader.get_item(item_id)
		if item.is_empty():
			continue
		var type: String = item.get("type", "")
		if type != "heal" and type != "escape" and type != "cure" and type != "buff":
			continue
		var name: String = item.get("name", item_id)
		var detail: String = ""
		if type == "heal":
			detail = "  +%d HP" % int(item.get("hp_restore", 0))
		else:
			detail = "  escape"
		var l := _make_label("%s (x%d)%s" % [name, count, detail], COL_TEXT, 18, HORIZONTAL_ALIGNMENT_LEFT)
		l.custom_minimum_size = Vector2(0, 32)
		vbox.add_child(l)
		_item_labels.append(l)
		_item_ids.append(item_id)

	_item_index = 0

func _build_victory_screen() -> void:
	_victory_screen = _add_panel(0, 0, _vp_size.x, _vp_size.y, _make_style(Color(0.04, 0.05, 0.03, 0.92), COL_ACCENT, 0, 0))
	_victory_screen.visible = false
	_victory_screen.modulate.a = 0.0

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 0
	vbox.offset_top = 0
	vbox.offset_right = 0
	vbox.offset_bottom = 0
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_victory_screen.add_child(vbox)

	var title := _make_label("胜利！", COL_ACCENT, 64, HORIZONTAL_ALIGNMENT_CENTER)
	title.add_theme_color_override("font_outline_color", Color(0.2, 0.12, 0.0))
	title.add_theme_constant_override("outline_size", 8)
	vbox.add_child(title)

	var exp_label := _make_label("EXP gained: 0", COL_TEXT, 26, HORIZONTAL_ALIGNMENT_CENTER)
	vbox.add_child(exp_label)
	exp_label.name = "ExpLabel"

	var gold_label := _make_label("Gold gained: 0", COL_ACCENT, 26, HORIZONTAL_ALIGNMENT_CENTER)
	vbox.add_child(gold_label)
	gold_label.name = "GoldLabel"

	_victory_bounty_label = _make_label("BOUNTY REWARD!", COL_HP_YELLOW, 24, HORIZONTAL_ALIGNMENT_CENTER)
	_victory_bounty_label.visible = false
	vbox.add_child(_victory_bounty_label)

	var prompt := _make_label("Press Z to continue", COL_TEXT_DIM, 18, HORIZONTAL_ALIGNMENT_CENTER)
	vbox.add_child(prompt)
	# Store references for updating text later.
	_victory_screen.set_meta("exp_label", exp_label)
	_victory_screen.set_meta("gold_label", gold_label)

func _build_defeat_screen() -> void:
	_defeat_screen = _add_panel(0, 0, _vp_size.x, _vp_size.y, _make_style(Color(0.10, 0.02, 0.02, 0.94), COL_HP_RED, 0, 0))
	_defeat_screen.visible = false
	_defeat_screen.modulate.a = 0.0

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_defeat_screen.add_child(vbox)

	var title := _make_label("游戏结束", COL_HP_RED, 72, HORIZONTAL_ALIGNMENT_CENTER)
	title.add_theme_color_override("font_outline_color", Color(0.2, 0.0, 0.0))
	title.add_theme_constant_override("outline_size", 8)
	vbox.add_child(title)

	var sub := _make_label("You have fallen in the wasteland...", COL_TEXT_DIM, 22, HORIZONTAL_ALIGNMENT_CENTER)
	vbox.add_child(sub)

	var prompt := _make_label("Press Z to continue", COL_TEXT_DIM, 18, HORIZONTAL_ALIGNMENT_CENTER)
	vbox.add_child(prompt)

# --- Input -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	# Ignore key-repeat echoes so a held key only registers once.
	if event.is_echo():
		return
	if event.is_action_pressed("move_up"):
		_navigate(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_down"):
		_navigate(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("confirm"):
		_on_confirm()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("cancel"):
		_on_cancel()
		get_viewport().set_input_as_handled()

func _navigate(dir: int) -> void:
	match _ui_mode:
		UIMode.COMMAND:
			_cmd_index = posmod(_cmd_index + dir, _commands.size())
			_refresh_command_highlight()
		UIMode.ITEM:
			if _item_ids.is_empty():
				return
			_item_index = posmod(_item_index + dir, _item_ids.size())
			_refresh_item_highlight()
		UIMode.SKILL:
			if _skill_ids.is_empty():
				return
			_skill_index = posmod(_skill_index + dir, _skill_ids.size())
			_refresh_skill_highlight()

func _on_confirm() -> void:
	match _ui_mode:
		UIMode.COMMAND:
			var action: String = _commands[_cmd_index].id
			if action == BattleManager.ACTION_ITEM:
				_open_item_menu()
			elif action == BattleManager.ACTION_SKILL:
				_open_skill_menu()
			else:
				_close_command_menu()
				_ui_mode = UIMode.NONE
				_manager.select_action(action)
		UIMode.ITEM:
			if _item_ids.is_empty():
				_close_item_menu()
				_open_command_menu()
			else:
				var item_id: String = _item_ids[_item_index]
				_close_item_menu()
				_ui_mode = UIMode.NONE
				_manager.select_action(BattleManager.ACTION_ITEM, item_id)
		UIMode.SKILL:
			if _skill_ids.is_empty():
				_close_skill_menu()
				_open_command_menu()
			else:
				var skill_id: String = _skill_ids[_skill_index]
				# Check if skill is on cooldown.
				if not GameState.can_use_skill(skill_id):
					_append_log("Skill is on cooldown!")
					return
				_close_skill_menu()
				_ui_mode = UIMode.NONE
				_manager.select_action(BattleManager.ACTION_SKILL, "", skill_id)
		UIMode.VICTORY, UIMode.DEFEAT:
			_ui_mode = UIMode.NONE
			_manager.confirm_proceed()

func _on_cancel() -> void:
	match _ui_mode:
		UIMode.ITEM:
			_close_item_menu()
			_open_command_menu()
		UIMode.SKILL:
			_close_skill_menu()
			_open_command_menu()

# --- Command / item menu control --------------------------------------------

func _open_command_menu() -> void:
	if not _manager or _ui_mode == UIMode.VICTORY or _ui_mode == UIMode.DEFEAT:
		return
	_cmd_index = 0
	_refresh_command_highlight()
	_command_menu.visible = true
	_command_menu.modulate.a = 0.0
	_command_menu.position = _command_menu_pos + Vector2(28, 0)
	var tw := create_tween()
	tw.tween_property(_command_menu, "position", _command_menu_pos, 0.18).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(_command_menu, "modulate:a", 1.0, 0.18)
	_ui_mode = UIMode.COMMAND

func _close_command_menu() -> void:
	if not is_instance_valid(_command_menu):
		return
	var tw := create_tween()
	tw.tween_property(_command_menu, "modulate:a", 0.0, 0.12)
	await tw.finished
	if is_instance_valid(_command_menu):
		_command_menu.visible = false

func _open_item_menu() -> void:
	_rebuild_item_menu()
	_item_menu.visible = true
	_item_menu.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_item_menu, "modulate:a", 1.0, 0.15)
	if _item_ids.is_empty():
		_append_log("You have no usable items.")
	_refresh_item_highlight()
	_command_menu.visible = false
	_ui_mode = UIMode.ITEM

func _close_item_menu() -> void:
	if not is_instance_valid(_item_menu):
		return
	var tw := create_tween()
	tw.tween_property(_item_menu, "modulate:a", 0.0, 0.10)
	await tw.finished
	if is_instance_valid(_item_menu):
		_item_menu.visible = false

func _open_skill_menu() -> void:
	_rebuild_skill_menu()
	_skill_menu.visible = true
	_skill_menu.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_skill_menu, "modulate:a", 1.0, 0.15)
	if _skill_ids.is_empty():
		_append_log("You have no usable skills.")
	_refresh_skill_highlight()
	_command_menu.visible = false
	_ui_mode = UIMode.SKILL

func _close_skill_menu() -> void:
	if not is_instance_valid(_skill_menu):
		return
	var tw := create_tween()
	tw.tween_property(_skill_menu, "modulate:a", 0.0, 0.10)
	await tw.finished
	if is_instance_valid(_skill_menu):
		_skill_menu.visible = false

func _refresh_skill_highlight() -> void:
	for i in range(_skill_labels.size()):
		var l: Label = _skill_labels[i]
		if not l.has_meta("raw"):
			l.set_meta("raw", l.text)
		var selected: bool = (i == _skill_index)
		l.text = ("> " if selected else "  ") + String(l.get_meta("raw"))
		# Grey out skills on cooldown.
		var on_cd: bool = false
		if i < _skill_ids.size():
			on_cd = not GameState.can_use_skill(_skill_ids[i])
		if on_cd:
			l.add_theme_color_override("font_color", COL_TEXT_DIM)
		else:
			l.add_theme_color_override("font_color", COL_ACCENT if selected else COL_TEXT)

func _refresh_command_highlight() -> void:
	for i in range(_command_labels.size()):
		var l: Label = _command_labels[i]
		var selected: bool = (i == _cmd_index)
		l.text = ("> " if selected else "  ") + _commands[i].label
		l.add_theme_color_override("font_color", COL_ACCENT if selected else COL_TEXT)

func _refresh_item_highlight() -> void:
	for i in range(_item_labels.size()):
		var l: Label = _item_labels[i]
		# Cache the descriptive text the first time so the cursor prefix
		# doesn't accumulate across refreshes.
		if not l.has_meta("raw"):
			l.set_meta("raw", l.text)
		var selected: bool = (i == _item_index)
		l.text = ("> " if selected else "  ") + String(l.get_meta("raw"))
		l.add_theme_color_override("font_color", COL_ACCENT if selected else COL_TEXT)

# --- Manager signal handlers ------------------------------------------------

func _on_actors_ready(p_actor: BattleActor, e_actor: BattleActor) -> void:
	_player_actor = p_actor
	_enemy_actor = e_actor

	# Keep HP bars in sync with actor hp_changed signals.
	p_actor.hp_changed.connect(_on_player_hp_changed)
	e_actor.hp_changed.connect(_on_enemy_hp_changed)

	# Keep status effect displays in sync with actor status_changed signals.
	if _player_actor:
		_player_actor.status_changed.connect(_on_player_status_changed)
	if _enemy_actor:
		_enemy_actor.status_changed.connect(_on_enemy_status_changed)

	_enemy_name_label.text = e_actor.name
	_player_name_label.text = p_actor.name
	_update_hp_bar(_player_hp_bar, p_actor.hp_ratio(), p_actor.hp, p_actor.max_hp, false)
	_update_hp_bar(_enemy_hp_bar, e_actor.hp_ratio(), e_actor.hp, e_actor.max_hp, false)

	_load_sprite(_enemy_sprite, e_actor.sprite_path, Color(0.82, 0.24, 0.24), 80, 96)
	_load_sprite(_player_sprite, p_actor.sprite_path, Color(0.26, 0.52, 0.92), 72, 96)

	_start_idle_bob(_enemy_sprite, 5.0, 2.4)
	_start_idle_bob(_player_sprite, 4.0, 2.0)

	# Refresh status effect displays for the initial state.
	_on_player_status_changed()
	_on_enemy_status_changed()

	# Update player name to show tank mode
	if _player_name_label and _player_actor:
		if _player_actor.is_tank_mode:
			_player_name_label.text = _player_actor.name
		else:
			_player_name_label.text = GameState.player_name

	# Refresh the command menu for the current battle mode (tank vs infantry).
	_refresh_commands()
	_rebuild_command_menu()

	# Show the SP bar only in tank mode and sync its value.
	if not _player_sp_bar.is_empty():
		_player_sp_bar.root.visible = _player_actor.is_tank_mode
	if _player_actor.is_tank_mode:
		_update_sp_bar()

func _on_state_changed(state: int) -> void:
	# Close menus whenever we leave the player's turn.
	if state != BattleManager.State.PLAYER_TURN:
		if _ui_mode == UIMode.COMMAND or _ui_mode == UIMode.ITEM or _ui_mode == UIMode.SKILL:
			_ui_mode = UIMode.NONE
		# Hide menus (without animation) during processing / enemy turn.
		if is_instance_valid(_command_menu):
			_command_menu.visible = false
		if is_instance_valid(_item_menu):
			_item_menu.visible = false
		if is_instance_valid(_skill_menu):
			_skill_menu.visible = false

func _on_battle_log(message: String) -> void:
	_append_log(message)

func _on_player_hp_changed(current: int, maximum: int) -> void:
	if _player_actor:
		_update_hp_bar(_player_hp_bar, float(current) / float(maxi(1, maximum)), current, maximum, true)
		# In tank mode, SP absorbs damage before HP, so refresh the SP bar too.
		if _player_actor.is_tank_mode:
			_update_sp_bar()

func _on_enemy_hp_changed(current: int, maximum: int) -> void:
	if _enemy_actor:
		_update_hp_bar(_enemy_hp_bar, float(current) / float(maxi(1, maximum)), current, maximum, true)

func _on_player_status_changed() -> void:
	if _player_actor and _player_status_container:
		_update_status_display(_player_actor, _player_status_container)

func _on_enemy_status_changed() -> void:
	if _enemy_actor and _enemy_status_container:
		_update_status_display(_enemy_actor, _enemy_status_container)

func _on_damage_dealt(target: BattleActor, amount: int) -> void:
	_spawn_popup(str(amount), _pos_for(target), COL_DAMAGE, false)
	_flash_sprite(_sprite_for(target), Color(1.7, 0.35, 0.35))

func _on_critical_hit(target: BattleActor, amount: int) -> void:
	_spawn_popup(str(amount), _pos_for(target), COL_CRIT, true)
	_flash_sprite(_sprite_for(target), Color(1.9, 0.6, 0.2))

func _on_attack_missed(target: BattleActor) -> void:
	_spawn_popup("MISS", _pos_for(target), COL_MISS, false)

func _on_healed(target: BattleActor, amount: int) -> void:
	_spawn_popup("+%d" % amount, _pos_for(target), COL_HEAL, false)
	_flash_sprite(_sprite_for(target), Color(0.5, 1.6, 0.6))

func _on_victory(exp_gained: int, gold_gained: int, is_bounty: bool, bounty_reward: int) -> void:
	_ui_mode = UIMode.VICTORY
	var exp_label := _victory_screen.get_meta("exp_label") as Label
	var gold_label := _victory_screen.get_meta("gold_label") as Label
	if exp_label:
		exp_label.text = "获得经验: %d" % exp_gained
	if gold_label:
		gold_label.text = "获得金币: %d" % gold_gained
	_victory_bounty_label.visible = is_bounty
	if is_bounty:
		_victory_bounty_label.text = "赏金奖励: %d金币！" % bounty_reward
	_animate_end_screen(_victory_screen)

func _on_defeat() -> void:
	_ui_mode = UIMode.DEFEAT
	_animate_end_screen(_defeat_screen)

func _on_fled() -> void:
	_ui_mode = UIMode.NONE
	if is_instance_valid(_command_menu):
		_command_menu.visible = false
	if is_instance_valid(_item_menu):
		_item_menu.visible = false
	if is_instance_valid(_skill_menu):
		_skill_menu.visible = false

# --- Helpers: sprites, popups, bars, log ------------------------------------

func _load_sprite(sprite: Sprite2D, path: String, placeholder_color: Color, w: int, h: int) -> void:
	if sprite == null:
		return
	if path != "" and ResourceLoader.exists(path):
		var tex := load(path)
		if tex is Texture2D:
			sprite.texture = tex
			sprite.modulate = SPRITE_BLOOM_MODULATE
			sprite.set_meta("base_modulate", SPRITE_BLOOM_MODULATE)
			return
	# Fallback: a procedurally generated placeholder so something is visible.
	sprite.texture = _make_placeholder_texture(placeholder_color, w, h)
	sprite.modulate = Color.WHITE
	sprite.set_meta("base_modulate", Color.WHITE)

func _make_placeholder_texture(color: Color, w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(color)
	var border := color.darkened(0.45)
	for x in range(w):
		img.set_pixel(x, 0, border)
		img.set_pixel(x, h - 1, border)
	for y in range(h):
		img.set_pixel(0, y, border)
		img.set_pixel(w - 1, y, border)
	# A lighter inner band to suggest a "sprite silhouette".
	var inner := color.lightened(0.18)
	for y in range(h / 3, (h * 2) / 3):
		for x in range(w / 4, (w * 3) / 4):
			img.set_pixel(x, y, inner)
	return ImageTexture.create_from_image(img)

func _start_idle_bob(sprite: Sprite2D, amplitude: float, period: float) -> void:
	if sprite == null:
		return
	var base_y: float = sprite.position.y
	var tw := create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(sprite, "position:y", base_y - amplitude, period * 0.5)
	tw.tween_property(sprite, "position:y", base_y, period * 0.5)

func _pos_for(target: BattleActor) -> Vector2:
	if target == _enemy_actor:
		return _enemy_pos + Vector2(0, -60)
	return _player_pos + Vector2(0, -70)

func _sprite_for(target: BattleActor) -> Sprite2D:
	if target == _enemy_actor:
		return _enemy_sprite
	return _player_sprite

func _spawn_popup(text: String, pos: Vector2, color: Color, big: bool) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 34 if big else 24)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 5 if big else 4)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size = Vector2(160, 40)
	lbl.position = pos - Vector2(80, 20)
	lbl.z_index = 20
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_popup_layer.add_child(lbl)

	var tw := create_tween()
	tw.tween_property(lbl, "position:y", lbl.position.y - 52, 0.85).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(lbl, "modulate:a", 0.0, 0.85).set_delay(0.1)
	if big:
		tw.parallel().tween_property(lbl, "scale", Vector2(1.15, 1.15), 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(lbl.queue_free)

func _flash_sprite(sprite: Sprite2D, flash_color: Color) -> void:
	if sprite == null:
		return
	var base: Color = sprite.get_meta("base_modulate", Color.WHITE)
	var tw := create_tween()
	tw.tween_property(sprite, "modulate", flash_color, 0.08)
	tw.tween_property(sprite, "modulate", base, 0.20)

func _update_hp_bar(bar: Dictionary, ratio: float, current: int, maximum: int, animate: bool) -> void:
	if bar.is_empty():
		return
	var fill: ColorRect = bar.fill
	var width: float = bar.width
	var height: float = bar.height
	bar.label.text = "%d / %d" % [current, maximum]
	var r := clampf(ratio, 0.0, 1.0)
	var target_w: float = width * r
	var color: Color = COL_HP_GREEN if r > 0.5 else (COL_HP_YELLOW if r > 0.25 else COL_HP_RED)
	if animate:
		var tw := create_tween()
		tw.tween_property(fill, "size", Vector2(target_w, height), 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(fill, "color", color, 0.25)
	else:
		fill.size = Vector2(target_w, height)
		fill.color = color

## Updates the tank SP bar fill width and label from the player actor's SP.
func _update_sp_bar() -> void:
	if _player_actor == null or _player_sp_bar.is_empty():
		return
	var fill: ColorRect = _player_sp_bar.fill
	var width: float = _player_sp_bar.width
	var height: float = _player_sp_bar.height
	_player_sp_bar.label.text = "护盾 %s" % _player_actor.sp_text()
	var r := clampf(_player_actor.sp_ratio(), 0.0, 1.0)
	fill.size = Vector2(width * r, height)

func _update_status_display(target: BattleActor, container: HBoxContainer) -> void:
	if container == null:
		return
	# Clear old labels
	for child in container.get_children():
		child.queue_free()
	if target == null or target.status_effects.is_empty():
		return
	# Create compact labels for each status
	for effect_id in target.status_effects:
		var duration: int = int(target.status_effects[effect_id].get("duration", 0))
		var label_text: String = ""
		var label_color: Color = Color.WHITE
		match effect_id:
			BattleActor.STATUS_POISON:
				label_text = "毒"
				label_color = Color(0.5, 1.0, 0.3)
			BattleActor.STATUS_BURN:
				label_text = "燃"
				label_color = Color(1.0, 0.5, 0.2)
			BattleActor.STATUS_DEFENSE_DOWN:
				label_text = "防降"
				label_color = Color(1.0, 0.5, 0.5)
			BattleActor.STATUS_DEFENSE_UP:
				label_text = "防升"
				label_color = Color(0.5, 0.8, 1.0)
			BattleActor.STATUS_ATTACK_UP:
				label_text = "攻升"
				label_color = Color(1.0, 0.8, 0.3)
			BattleActor.STATUS_EVASION_UP:
				label_text = "闪升"
				label_color = Color(0.7, 0.7, 1.0)
			_:
				label_text = effect_id.substr(0, 3).to_upper()
				label_color = Color(0.8, 0.8, 0.8)
		var l := Label.new()
		l.text = "%s(%d)" % [label_text, duration]
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", label_color)
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 2)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		container.add_child(l)

func _append_log(message: String) -> void:
	_log_lines.append(message)
	while _log_lines.size() > LOG_MAX_LINES:
		_log_lines.pop_front()
	if not is_instance_valid(_log_label):
		return
	# Build the text manually for cross-version safety (String.join expects a
	# PackedStringArray, not a typed Array[String]).
	var joined := ""
	for i in range(_log_lines.size()):
		joined += ("" if i == 0 else "\n") + _log_lines[i]
	_log_label.text = joined

func _animate_end_screen(panel: Panel) -> void:
	panel.visible = true
	panel.modulate.a = 0.0
	panel.scale = Vector2(0.96, 0.96)
	# Scale around the centre of the full-screen panel.
	panel.pivot_offset = _vp_size * 0.5
	var tw := create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, 0.35).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(panel, "scale", Vector2.ONE, 0.35).set_ease(Tween.EASE_OUT)
