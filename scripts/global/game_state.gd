## GameState: Global game state singleton (Autoload)
## Manages player progress, party, inventory, equipment, skills, quests,
## tank state, and scene transitions.
extends Node

# --- Signals ---
signal gold_changed(amount: int)
signal hp_changed(current: int, maximum: int)
signal tank_hp_changed(current: int, maximum: int)
signal tank_sp_changed(current: int, maximum: int)
signal fuel_changed(current: int, maximum: int)
signal exp_changed(current: int, next: int)
signal level_up(new_level: int)
signal equipment_changed()
signal skill_used(skill_id: String)
signal scene_change_started(target: String)
signal battle_started(enemy_id: String)
signal battle_ended(result: int)
signal quest_updated(quest_id: String, status: String)

# --- Enums ---
enum BattleResult { VICTORY, DEFEAT, FLED }
enum QuestStatus { INACTIVE, ACTIVE, COMPLETED, FAILED, CLAIMED }

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

# --- Infantry Equipment (player on foot) ---
var weapon_slot: String = "pistol"   # equipment id
var armor_slot: String = ""          # equipment id (empty = none)

# --- Tank State ---
var tank_owned: bool = false
var tank_hp: int = 200
var tank_max_hp: int = 200
var tank_sp: int = 100       # Armor / shield points
var tank_max_sp: int = 100
var tank_fuel: int = 100
var tank_max_fuel: int = 100
var tank_parts: Dictionary = {
	"chassis": null,
	"main_cannon": null,
	"sub_cannon": null,
	"se_unit": null,
	"c_unit": null,
	"engine": null,
}

# --- Skills ---
var learned_skills: Array[String] = ["rapid_fire"]
var skill_cooldowns: Dictionary = {}  # skill_id -> turns remaining

# --- Quests ---
var active_quests: Array[String] = []
var completed_quests: Array[String] = []
var quest_progress: Dictionary = {}  # quest_id -> { "kills": {...}, "collected": {...} }

# --- World State ---
var current_map: String = "wasteland"
var player_position: Vector3 = Vector3(0, 0, 0)
var defeated_bounties: Array[String] = []
var flags: Dictionary = {}  # event flags

# --- Battle State ---
var in_battle: bool = false
var current_enemy_id: String = ""
var battle_mode: String = "infantry"  # "infantry" or "tank"

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
				# Track bounty defeats
				if enemy_data.get("is_bounty", false):
					defeated_bounties.append(current_enemy_id)
					_update_quest_progress("kill", current_enemy_id)
		BattleResult.DEFEAT:
			# Revive at last town with half HP
			player_hp = player_max_hp / 2
			gold = max(0, gold / 2)
			current_map = "wasteland"
	change_scene("res://scenes/world.tscn")

# --- Effective Stats (with equipment) ---

## Returns the player's attack stat including weapon bonus.
func get_effective_attack() -> int:
	var total := player_attack
	if not weapon_slot.is_empty():
		var eq := DataLoader.get_equipment(weapon_slot)
		total += int(eq.get("attack", 0))
	return total

## Returns the player's defense stat including armor bonus.
func get_effective_defense() -> int:
	var total := player_defense
	if not armor_slot.is_empty():
		var eq := DataLoader.get_equipment(armor_slot)
		total += int(eq.get("defense", 0))
	return total

## Returns the player's speed (equipment can modify this in the future).
func get_effective_speed() -> int:
	return player_speed

## Returns the tank's total attack from all equipped parts.
func get_tank_attack() -> int:
	var total := 0
	for slot in tank_parts:
		var part_id = tank_parts[slot]
		if part_id != null and not String(part_id).is_empty():
			var eq := DataLoader.get_equipment(String(part_id))
			total += int(eq.get("attack", 0))
	return total

## Returns the tank's total defense from all equipped parts.
func get_tank_defense() -> int:
	var total := 0
	for slot in tank_parts:
		var part_id = tank_parts[slot]
		if part_id != null and not String(part_id).is_empty():
			var eq := DataLoader.get_equipment(String(part_id))
			total += int(eq.get("defense", 0))
	return total

## Returns true if the tank can move (weight <= engine power).
func tank_can_move() -> bool:
	var weight := 0
	var power := 0
	for slot in tank_parts:
		var part_id = tank_parts[slot]
		if part_id != null and not String(part_id).is_empty():
			var eq := DataLoader.get_equipment(String(part_id))
			weight += int(eq.get("weight", 0))
			if String(slot) == "engine":
				power = int(eq.get("power", 0))
	return weight <= power

# --- Stat Modifiers ---
func gain_gold(amount: int) -> void:
	gold += amount
	if amount > 0:
		AudioManager.play_sfx("coin")
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

func take_tank_damage(amount: int) -> int:
	# SP absorbs damage first, then HP
	var sp_absorb := min(tank_sp, amount)
	tank_sp -= sp_absorb
	var remaining := amount - sp_absorb
	tank_hp = max(0, tank_hp - remaining)
	tank_hp_changed.emit(tank_hp, tank_max_hp)
	tank_sp_changed.emit(tank_sp, tank_max_sp)
	return remaining

func repair_tank(amount: int) -> void:
	tank_sp = min(tank_max_sp, tank_sp + amount)
	tank_sp_changed.emit(tank_sp, tank_max_sp)

func heal_tank(amount: int) -> void:
	tank_hp = min(tank_max_hp, tank_hp + amount)
	tank_hp_changed.emit(tank_hp, tank_max_hp)

func consume_fuel(amount: int) -> void:
	tank_fuel = max(0, tank_fuel - amount)
	fuel_changed.emit(tank_fuel, tank_max_fuel)

func refuel(amount: int) -> void:
	tank_fuel = min(tank_max_fuel, tank_fuel + amount)
	fuel_changed.emit(tank_fuel, tank_max_fuel)

func gain_exp(amount: int) -> void:
	player_exp += amount
	exp_changed.emit(player_exp, player_exp_next)
	while player_exp >= player_exp_next:
		player_exp -= player_exp_next
		level_up()

func level_up() -> void:
	AudioManager.play_sfx("level_up")
	player_level += 1
	player_max_hp += 15
	player_hp = player_max_hp  # Full heal on level up
	player_attack += 3
	player_defense += 2
	player_speed += 1
	player_exp_next = int(player_exp_next * 1.5)
	hp_changed.emit(player_hp, player_max_hp)
	level_up.emit(player_level)
	# Unlock new skills at certain levels
	_check_skill_unlocks()
	print("[GameState] Level Up! Now level %d" % player_level)

func _check_skill_unlocks() -> void:
	# Skills unlocked at specific levels
	var unlock_table := {
		3: "power_slash",
		4: "field_medic",
		5: "guard_break",
		6: "toxic_strike",
		7: "incendiary_round",
		8: "barrage",
		9: "battle_focus",
		10: "iron_wall",
		12: "overdrive",
	}
	if unlock_table.has(player_level):
		var skill_id: String = unlock_table[player_level]
		if not learned_skills.has(skill_id):
			learned_skills.append(skill_id)
			print("[GameState] Learned new skill: %s" % skill_id)

# --- Skill Cooldowns ---
func can_use_skill(skill_id: String) -> bool:
	if not learned_skills.has(skill_id):
		return false
	if skill_cooldowns.has(skill_id) and int(skill_cooldowns[skill_id]) > 0:
		return false
	return true

func use_skill(skill_id: String) -> void:
	var skill := DataLoader.get_skill(skill_id)
	if skill.is_empty():
		return
	skill_cooldowns[skill_id] = int(skill.get("cooldown", 1))
	skill_used.emit(skill_id)

func tick_cooldowns() -> void:
	for skill_id in skill_cooldowns.keys():
		skill_cooldowns[skill_id] = int(skill_cooldowns[skill_id]) - 1
		if int(skill_cooldowns[skill_id]) <= 0:
			skill_cooldowns.erase(skill_id)

func reset_cooldowns() -> void:
	skill_cooldowns.clear()

# --- Quest System ---
func start_quest(quest_id: String) -> bool:
	if active_quests.has(quest_id) or completed_quests.has(quest_id):
		return false
	active_quests.append(quest_id)
	quest_progress[quest_id] = {"kills": {}, "collected": {}}
	quest_updated.emit(quest_id, "active")
	print("[GameState] Quest started: %s" % quest_id)
	return true

func _update_quest_progress(type: String, target_id: String) -> void:
	for quest_id in active_quests:
		var quest := DataLoader.get_quest(quest_id)
		if quest.is_empty():
			continue
		var objectives: Array = quest.get("objectives", [])
		for obj in objectives:
			if String(obj.get("type", "")) == type and String(obj.get("target", "")) == target_id:
				var progress: Dictionary = quest_progress.get(quest_id, {"kills": {}, "collected": {}})
				var key: String = type + "s"  # "kills" or "collected"
				if not progress.has(key):
					progress[key] = {}
				var current: int = int(progress[key].get(target_id, 0))
				progress[key][target_id] = current + 1
				quest_progress[quest_id] = progress
				_check_quest_completion(quest_id)

func _check_quest_completion(quest_id: String) -> void:
	var quest := DataLoader.get_quest(quest_id)
	if quest.is_empty():
		return
	var objectives: Array = quest.get("objectives", [])
	var progress: Dictionary = quest_progress.get(quest_id, {})
	var all_done := true
	for obj in objectives:
		var obj_type: String = String(obj.get("type", ""))
		var target: String = String(obj.get("target", ""))
		var required: int = int(obj.get("count", 1))
		var key: String = obj_type + "s"
		var current: int = 0
		if progress.has(key) and progress[key].has(target):
			current = int(progress[key][target])
		if current < required:
			all_done = false
			break
	if all_done:
		complete_quest(quest_id)

func complete_quest(quest_id: String) -> void:
	if not active_quests.has(quest_id):
		return
	active_quests.erase(quest_id)
	completed_quests.append(quest_id)
	quest_updated.emit(quest_id, "completed")
	# Auto-claim rewards
	var quest := DataLoader.get_quest(quest_id)
	if not quest.is_empty():
		gain_gold(int(quest.get("reward_gold", 0)))
		var reward_exp := int(quest.get("reward_exp", 0))
		if reward_exp > 0:
			gain_exp(reward_exp)
		var reward_item: String = String(quest.get("reward_item", ""))
		if not reward_item.is_empty():
			inventory[reward_item] = int(inventory.get(reward_item, 0)) + 1
	print("[GameState] Quest completed: %s" % quest_id)

func get_quest_status(quest_id: String) -> int:
	if completed_quests.has(quest_id):
		return QuestStatus.COMPLETED
	if active_quests.has(quest_id):
		return QuestStatus.ACTIVE
	return QuestStatus.INACTIVE

func get_quest_progress_text(quest_id: String) -> String:
	var quest := DataLoader.get_quest(quest_id)
	if quest.is_empty():
		return ""
	var progress: Dictionary = quest_progress.get(quest_id, {"kills": {}, "collected": {}})
	var lines: Array[String] = []
	for obj in quest.get("objectives", []):
		var obj_type: String = String(obj.get("type", ""))
		var target: String = String(obj.get("target", ""))
		var required: int = int(obj.get("count", 1))
		var key: String = obj_type + "s"
		var current: int = 0
		if progress.has(key) and progress[key].has(target):
			current = int(progress[key][target])
		var target_data: Dictionary = {}
		if obj_type == "kill":
			target_data = DataLoader.get_enemy(target)
		lines.append("  %s: %d / %d" % [String(target_data.get("name", target)), current, required])
	return "\n".join(lines)

# --- Equipment Management ---
func equip_infantry(slot: String, equip_id: String) -> void:
	match slot:
		"weapon":
			if not weapon_slot.is_empty():
				# Return old weapon to inventory
				inventory[weapon_slot] = int(inventory.get(weapon_slot, 0)) + 1
			weapon_slot = equip_id
		"armor":
			if not armor_slot.is_empty():
				inventory[armor_slot] = int(inventory.get(armor_slot, 0)) + 1
			armor_slot = equip_id
	equipment_changed.emit()

func unequip_infantry(slot: String) -> void:
	match slot:
		"weapon":
			if not weapon_slot.is_empty():
				inventory[weapon_slot] = int(inventory.get(weapon_slot, 0)) + 1
				weapon_slot = ""
		"armor":
			if not armor_slot.is_empty():
				inventory[armor_slot] = int(inventory.get(armor_slot, 0)) + 1
				armor_slot = ""
	equipment_changed.emit()

# --- Save / Load (multi-slot) ---
const SAVE_DIR := "user://saves/"
const SAVE_PREFIX := "save_"
const SAVE_EXT := ".json"

func _ensure_save_dir() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)

func save_game(slot: int = 0) -> void:
	_ensure_save_dir()
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
		"weapon_slot": weapon_slot,
		"armor_slot": armor_slot,
		"tank_owned": tank_owned,
		"tank_hp": tank_hp,
		"tank_max_hp": tank_max_hp,
		"tank_sp": tank_sp,
		"tank_max_sp": tank_max_sp,
		"tank_fuel": tank_fuel,
		"tank_max_fuel": tank_max_fuel,
		"tank_parts": tank_parts,
		"learned_skills": learned_skills,
		"active_quests": active_quests,
		"completed_quests": completed_quests,
		"quest_progress": quest_progress,
		"current_map": current_map,
		"defeated_bounties": defeated_bounties,
		"flags": flags,
	}
	var path := SAVE_DIR + SAVE_PREFIX + str(slot) + SAVE_EXT
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(save_data, "\t"))
		file.close()
		print("[GameState] Game saved to slot %d." % slot)

func load_game(slot: int = 0) -> bool:
	var path := SAVE_DIR + SAVE_PREFIX + str(slot) + SAVE_EXT
	if not FileAccess.file_exists(path):
		return false
	var file = FileAccess.open(path, FileAccess.READ)
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
	tank_hp_changed.emit(tank_hp, tank_max_hp)
	tank_sp_changed.emit(tank_sp, tank_max_sp)
	fuel_changed.emit(tank_fuel, tank_max_fuel)
	equipment_changed.emit()
	print("[GameState] Game loaded from slot %d." % slot)
	return true

func has_save(slot: int = 0) -> bool:
	var path := SAVE_DIR + SAVE_PREFIX + str(slot) + SAVE_EXT
	return FileAccess.file_exists(path)

func get_save_info(slot: int = 0) -> Dictionary:
	var path := SAVE_DIR + SAVE_PREFIX + str(slot) + SAVE_EXT
	if not FileAccess.file_exists(path):
		return {}
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return {}
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		return {}
	file.close()
	var data = json.data
	return {
		"name": String(data.get("player_name", "???")),
		"level": int(data.get("player_level", 1)),
		"map": String(data.get("current_map", "???")),
		"gold": int(data.get("gold", 0)),
	}

func delete_save(slot: int = 0) -> void:
	var path := SAVE_DIR + SAVE_PREFIX + str(slot) + SAVE_EXT
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

## Backward-compatible single-slot API (used by existing HUD/menu code).
func save_game_legacy() -> void:
	save_game(0)

func load_game_legacy() -> bool:
	return load_game(0)

func has_save_legacy() -> bool:
	return has_save(0)
