## GameState: Global game state singleton (Autoload)
## Manages player progress, party, inventory, and scene transitions.
extends Node

# --- Signals ---
signal gold_changed(amount: int)
signal hp_changed(current: int, maximum: int)
signal scene_change_started(target: String)
signal battle_started(enemy_id: String)
signal battle_ended(result: int)

# --- Enums ---
enum BattleResult { VICTORY, DEFEAT, FLED }

# --- Player State ---
var player_name: String = "Hunter"
var player_level: int = 1
var player_hp: int = 100
var player_max_hp: int = 100
var player_attack: int = 20
var player_defense: int = 10
var player_speed: int = 15
var player_exp: int = 0
var player_exp_next: int = 50

# --- Currency ---
var gold: int = 500

# --- Inventory ---
var inventory: Dictionary = {}  # item_id -> count

# --- Tank State ---
var tank_owned: bool = false
var tank_parts: Dictionary = {
	"chassis": null,
	"main_cannon": null,
	"sub_cannon": null,
	"se_unit": null,
	"c_unit": null,
	"engine": null,
}

# --- World State ---
var current_map: String = "wasteland"
var player_position: Vector3 = Vector3(0, 0, 0)
var defeated_bounties: Array[String] = []
var flags: Dictionary = {}  # event flags

# --- Battle State ---
var in_battle: bool = false
var current_enemy_id: String = ""

# --- Scene Management ---
func change_scene(target: String) -> void:
	scene_change_started.emit(target)
	get_tree().change_scene_to_file(target)

func start_battle(enemy_id: String) -> void:
	current_enemy_id = enemy_id
	in_battle = true
	battle_started.emit(enemy_id)
	change_scene("res://scenes/battle.tscn")

func end_battle(result: BattleResult) -> void:
	in_battle = false
	battle_ended.emit(result)
	match result:
		BattleResult.VICTORY:
			var enemy_data = DataLoader.get_enemy(current_enemy_id)
			if enemy_data:
				gain_gold(enemy_data.get("gold", 0))
				gain_exp(enemy_data.get("exp", 0))
		BattleResult.DEFEAT:
			# Revive at last town with half HP
			player_hp = player_max_hp / 2
			gold = max(0, gold / 2)
	change_scene("res://scenes/world.tscn")

# --- Stat Modifiers ---
func gain_gold(amount: int) -> void:
	gold += amount
	gold_changed.emit(gold)

func spend_gold(amount: int) -> bool:
	if gold >= amount:
		gold -= amount
		gold_changed.emit(gold)
		return true
	return false

func take_damage(amount: int) -> void:
	player_hp = max(0, player_hp - amount)
	hp_changed.emit(player_hp, player_max_hp)

func heal(amount: int) -> void:
	player_hp = min(player_max_hp, player_hp + amount)
	hp_changed.emit(player_hp, player_max_hp)

func gain_exp(amount: int) -> void:
	player_exp += amount
	while player_exp >= player_exp_next:
		player_exp -= player_exp_next
		level_up()

func level_up() -> void:
	player_level += 1
	player_max_hp += 15
	player_hp = player_max_hp  # Full heal on level up
	player_attack += 3
	player_defense += 2
	player_speed += 1
	player_exp_next = int(player_exp_next * 1.5)
	hp_changed.emit(player_hp, player_max_hp)
	print("[GameState] Level Up! Now level %d" % player_level)

# --- Save / Load ---
func save_game() -> void:
	var save_data = {
		"player_name": player_name,
		"player_level": player_level,
		"player_hp": player_hp,
		"player_max_hp": player_max_hp,
		"player_attack": player_attack,
		"player_defense": player_defense,
		"player_speed": player_speed,
		"player_exp": player_exp,
		"player_exp_next": player_exp_next,
		"gold": gold,
		"inventory": inventory,
		"tank_owned": tank_owned,
		"tank_parts": tank_parts,
		"current_map": current_map,
		"defeated_bounties": defeated_bounties,
		"flags": flags,
	}
	var file = FileAccess.open("user://savegame.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(save_data, "\t"))
		file.close()
		print("[GameState] Game saved.")

func load_game() -> bool:
	if not FileAccess.file_exists("user://savegame.json"):
		return false
	var file = FileAccess.open("user://savegame.json", FileAccess.READ)
	if not file:
		return false
	var json_text = file.get_as_text()
	file.close()
	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		return false
	var data = json.data
	for key in data:
		set(key, data[key])
	hp_changed.emit(player_hp, player_max_hp)
	print("[GameState] Game loaded.")
	return true

func has_save() -> bool:
	return FileAccess.file_exists("user://savegame.json")
