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
signal mode_changed(mode: String)
signal party_changed()

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

# --- Vehicle Garage (multi-tank system, MMR-style) ---
## Stores all owned vehicles. The active vehicle's stats are mirrored in
## tank_hp/tank_sp/tank_fuel/tank_parts above. When switching, the current
## state is saved back to the garage entry and the new one is loaded.
var vehicle_garage: Array[Dictionary] = []
var active_vehicle_index: int = 0
const MAX_VEHICLES: int = 4
const DEFAULT_VEHICLE_NAME := "Tank"

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
var movement_mode: String = "infantry"  # "infantry" or "tank" for world exploration

# --- Party System ---
## Party member data. Each member is a Dictionary with:
## { id, name, class_type, level, hp, max_hp, attack, defense, speed,
##   skill_id, recruited, recruited_map, dialogue_id }
var party_members: Array[Dictionary] = []
const MAX_PARTY_SIZE: int = 3  # Player + 2 companions

# --- Battle State ---
var in_battle: bool = false
var current_enemy_id: String = ""
var battle_mode: String = "infantry"  # "infantry" or "tank"

# --- Lifecycle ---

func _ready() -> void:
	_init_party_roster()
	_init_garage()

# --- Scene Management ---
func change_scene(target: String) -> void:
	scene_change_started.emit(target)
	get_tree().change_scene_to_file(target)

func set_movement_mode(mode: String) -> void:
	movement_mode = mode
	mode_changed.emit(mode)

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

# --- Party Management ---

## Returns the number of active party members (including the player).
func get_party_size() -> int:
	return 1 + _get_recruited_count()

func _get_recruited_count() -> int:
	var count := 0
	for member in party_members:
		if bool(member.get("recruited", false)):
			count += 1
	return count

## Attempts to recruit a party member by id. Returns true on success.
func recruit_member(member_id: String) -> bool:
	for member in party_members:
		if String(member.get("id", "")) == member_id:
			if bool(member.get("recruited", false)):
				return false  # Already recruited
			if get_party_size() >= MAX_PARTY_SIZE:
				return false  # Party full
			member["recruited"] = true
			party_changed.emit()
			print("[GameState] Recruited party member: %s" % member.get("name", member_id))
			return true
	return false

## Removes a party member from the active party.
func dismiss_member(member_id: String) -> void:
	for member in party_members:
		if String(member.get("id", "")) == member_id:
			member["recruited"] = false
			party_changed.emit()
			return

## Returns all recruited party members (not including the player).
func get_active_party() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for member in party_members:
		if bool(member.get("recruited", false)):
			result.append(member)
	return result

## Heals all party members to full (e.g. at an inn).
func heal_party() -> void:
	for member in party_members:
		if bool(member.get("recruited", false)):
			member["hp"] = member.get("max_hp", 100)
	party_changed.emit()

## Initialize default party member roster (called on first game start).
func _init_party_roster() -> void:
	if not party_members.is_empty():
		return
	party_members = [
		{
			"id": "mechanic",
			"name": "Sparky",
			"class_type": "Mechanic",
			"level": 1,
			"hp": 80,
			"max_hp": 80,
			"attack": 15,
			"defense": 12,
			"speed": 10,
			"skill_id": "repair_field",
			"recruited": false,
			"recruited_map": "town",
			"dialogue_id": "mechanic_npc",
			"description": "A skilled mechanic who can repair tanks mid-battle."
		},
		{
			"id": "soldier",
			"name": "Ironhand",
			"class_type": "Soldier",
			"level": 1,
			"hp": 120,
			"max_hp": 120,
			"attack": 25,
			"defense": 15,
			"speed": 12,
			"skill_id": "barrage",
			"recruited": false,
			"recruited_map": "secret_base",
			"dialogue_id": "soldier_npc",
			"description": "A veteran soldier with heavy weapons expertise."
		}
	]

# --- Vehicle Garage Management ---

## Initializes the garage. Called on first game start.
## If the player already owns a tank, it becomes the first garage entry.
func _init_garage() -> void:
	if not vehicle_garage.is_empty():
		return
	if tank_owned:
		# The existing tank becomes the first garage entry.
		vehicle_garage.append(_pack_vehicle_state(DEFAULT_VEHICLE_NAME))
		active_vehicle_index = 0

## Packs the current tank_hp/sp/fuel/parts into a Dictionary for garage storage.
func _pack_vehicle_state(vname: String) -> Dictionary:
	return {
		"name": vname,
		"hp": tank_hp,
		"max_hp": tank_max_hp,
		"sp": tank_sp,
		"max_sp": tank_max_sp,
		"fuel": tank_fuel,
		"max_fuel": tank_max_fuel,
		"parts": tank_parts.duplicate(true),
	}

## Loads a vehicle from the garage into the active tank state variables.
func _load_vehicle_from_garage(index: int) -> void:
	if index < 0 or index >= vehicle_garage.size():
		return
	var v: Dictionary = vehicle_garage[index]
	tank_hp = int(v.get("hp", 200))
	tank_max_hp = int(v.get("max_hp", 200))
	tank_sp = int(v.get("sp", 100))
	tank_max_sp = int(v.get("max_sp", 100))
	tank_fuel = int(v.get("fuel", 100))
	tank_max_fuel = int(v.get("max_fuel", 100))
	tank_parts = v.get("parts", {}).duplicate(true)
	tank_hp_changed.emit(tank_hp, tank_max_hp)
	tank_sp_changed.emit(tank_sp, tank_max_sp)
	fuel_changed.emit(tank_fuel, tank_max_fuel)

## Saves the current active vehicle state back to the garage entry.
func _save_active_to_garage() -> void:
	if active_vehicle_index < 0 or active_vehicle_index >= vehicle_garage.size():
		return
	var v: Dictionary = vehicle_garage[active_vehicle_index]
	v["hp"] = tank_hp
	v["max_hp"] = tank_max_hp
	v["sp"] = tank_sp
	v["max_sp"] = tank_max_sp
	v["fuel"] = tank_fuel
	v["max_fuel"] = tank_max_fuel
	v["parts"] = tank_parts.duplicate(true)

## Adds a new vehicle to the garage. Returns true on success.
## The new vehicle starts with default stats and no parts.
func add_vehicle(vname: String = "") -> bool:
	if vehicle_garage.size() >= MAX_VEHICLES:
		return false
	if vname.is_empty():
		vname = "%s %d" % [DEFAULT_VEHICLE_NAME, vehicle_garage.size() + 1]
	vehicle_garage.append({
		"name": vname,
		"hp": 200,
		"max_hp": 200,
		"sp": 100,
		"max_sp": 100,
		"fuel": 100,
		"max_fuel": 100,
		"parts": {
			"chassis": null,
			"main_cannon": null,
			"sub_cannon": null,
			"se_unit": null,
			"c_unit": null,
			"engine": null,
		},
	})
	if not tank_owned:
		tank_owned = true
		active_vehicle_index = vehicle_garage.size() - 1
		_load_vehicle_from_garage(active_vehicle_index)
	print("[GameState] Added vehicle: %s (garage size: %d)" % [vname, vehicle_garage.size()])
	return true

## Switches to a different vehicle in the garage.
## Saves the current vehicle state and loads the new one.
func switch_vehicle(index: int) -> bool:
	if index < 0 or index >= vehicle_garage.size() or index == active_vehicle_index:
		return false
	_save_active_to_garage()
	active_vehicle_index = index
	_load_vehicle_from_garage(index)
	print("[GameState] Switched to vehicle: %s" % vehicle_garage[index].get("name", "Tank"))
	return true

## Returns the number of vehicles in the garage.
func get_vehicle_count() -> int:
	return vehicle_garage.size()

## Returns the active vehicle's name.
func get_active_vehicle_name() -> String:
	if active_vehicle_index < 0 or active_vehicle_index >= vehicle_garage.size():
		return DEFAULT_VEHICLE_NAME
	return String(vehicle_garage[active_vehicle_index].get("name", DEFAULT_VEHICLE_NAME))

## Returns a summary array of all vehicles for garage display.
## Each entry: { name, hp, max_hp, sp, max_sp, fuel, max_fuel, parts_count, active }
func get_garage_summary() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in range(vehicle_garage.size()):
		var v: Dictionary = vehicle_garage[i]
		var parts_count: int = 0
		var parts: Dictionary = v.get("parts", {})
		for slot in parts:
			if parts[slot] != null and not String(parts[slot]).is_empty():
				parts_count += 1
		result.append({
			"name": String(v.get("name", "Tank")),
			"hp": int(v.get("hp", 0)),
			"max_hp": int(v.get("max_hp", 0)),
			"sp": int(v.get("sp", 0)),
			"max_sp": int(v.get("max_sp", 0)),
			"fuel": int(v.get("fuel", 0)),
			"max_fuel": int(v.get("max_fuel", 0)),
			"parts_count": parts_count,
			"active": i == active_vehicle_index,
			"index": i,
		})
	return result

## Renames a vehicle in the garage.
func rename_vehicle(index: int, new_name: String) -> void:
	if index < 0 or index >= vehicle_garage.size():
		return
	vehicle_garage[index]["name"] = new_name

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
	# In tank battles the BattleActor handles SP/HP absorption directly.
	# GameState.tank_hp / tank_sp are synced by BattleManager at battle end,
	# so we must not reduce the player's *infantry* HP here.
	if in_battle and battle_mode == "tank":
		return
	player_hp = max(0, player_hp - amount)
	hp_changed.emit(player_hp, player_max_hp)

func heal(amount: int) -> void:
	# Same guard as take_damage: don't modify infantry HP during a tank battle.
	if in_battle and battle_mode == "tank":
		return
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
	# Tank skills (prefixed "tank_") are available while the player owns a tank.
	# Infantry skills must be in the learned_skills list.
	if skill_id.begins_with("tank_"):
		if not tank_owned:
			return false
	elif not learned_skills.has(skill_id):
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

## Returns all tracked bounty IDs (active quests that start with "bounty_")
func get_tracked_bounties() -> Array[String]:
	var result: Array[String] = []
	for quest_id in active_quests:
		if quest_id.begins_with("bounty_"):
			result.append(quest_id.substr(7))  # Remove "bounty_" prefix
	return result

## Returns all available bounty IDs that haven't been defeated
func get_available_bounties() -> Array[String]:
	var result: Array[String] = []
	var all_bounties = DataLoader.get_bounty_list()
	for bounty_id in all_bounties:
		if not defeated_bounties.has(String(bounty_id)):
			result.append(String(bounty_id))
	return result

## Returns bounty enemy IDs that are tracked AND located on the given map.
## Each bounty enemy has a "location" field in enemies.json that matches a
## map's "name" field. This lets us spawn bounty NPCs on the correct map.
func get_bounties_for_map(map_id: String) -> Array[String]:
	var result: Array[String] = []
	var tracked := get_tracked_bounties()
	if tracked.is_empty():
		return result
	var map_data := DataLoader.get_map_data(map_id)
	if map_data.is_empty():
		return result
	var map_name: String = String(map_data.get("name", ""))
	for bounty_id in tracked:
		if defeated_bounties.has(bounty_id):
			continue
		var enemy_data := DataLoader.get_enemy(bounty_id)
		if enemy_data.is_empty():
			continue
		var bounty_location: String = String(enemy_data.get("location", ""))
		# Match by location name or by a direct map_id mapping.
		if bounty_location == map_name or _bounty_map_match(bounty_id, map_id):
			result.append(bounty_id)
	return result

## Hardcoded mapping of bounty IDs to map IDs for reliable spawning.
func _bounty_map_match(bounty_id: String, map_id: String) -> bool:
	var mapping := {
		"desert_worm": "desert",
		"iron_titan": "ruins",
		"prototype_mech": "underground_lab",
		"mad_maxer": "mountain_pass",
	}
	return String(mapping.get(bounty_id, "")) == map_id

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

# --- Crafting System ---

## Attempts to craft an item from a recipe. Returns true on success.
## Consumes materials from inventory and gold. Result is added to inventory
## (for items) or can be equipped in the garage (for equipment).
func craft_item(recipe_id: String) -> bool:
	var recipe := DataLoader.get_crafting_recipe(recipe_id)
	if recipe.is_empty():
		return false
	# Verify requirements one more time.
	var check := DataLoader.check_craft_requirements(recipe_id)
	if not bool(check.get("can_craft", false)):
		return false
	# Consume materials.
	var materials: Dictionary = recipe.get("materials", {})
	for mat_id in materials:
		var needed: int = int(materials[mat_id])
		var remaining: int = int(inventory.get(mat_id, 0)) - needed
		if remaining <= 0:
			inventory.erase(mat_id)
		else:
			inventory[mat_id] = remaining
	# Consume gold.
	var gold_cost: int = int(recipe.get("gold_cost", 0))
	if gold_cost > 0:
		spend_gold(gold_cost)
	# Add result item to inventory.
	var result_item: String = String(recipe.get("result_item", ""))
	var result_count: int = int(recipe.get("result_count", 1))
	if not result_item.is_empty():
		inventory[result_item] = int(inventory.get(result_item, 0)) + result_count
	AudioManager.play_sfx("confirm")
	print("[GameState] Crafted: %s (recipe: %s)" % [result_item, recipe_id])
	return true

## Returns the count of an item in the inventory.
func get_item_count(item_id: String) -> int:
	return int(inventory.get(item_id, 0))

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
		"vehicle_garage": vehicle_garage,
		"active_vehicle_index": active_vehicle_index,
		"party_members": party_members,
		"movement_mode": movement_mode,
		"battle_mode": battle_mode,
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
