## DataLoader: Global data loading singleton (Autoload)
## Loads all JSON data tables at startup and provides lookup APIs.
extends Node

# --- Data Caches ---
var enemies: Dictionary = {}
var equipment: Dictionary = {}
var encounters: Dictionary = {}
var dialogues: Dictionary = {}
var items: Dictionary = {}
var maps: Dictionary = {}
var skills: Dictionary = {}
var quests: Dictionary = {}
var shops: Dictionary = {}
var crafting: Dictionary = {}

func _ready() -> void:
	_load_all()

func _load_all() -> void:
	enemies = _load_json("res://data/enemies.json")
	equipment = _load_json("res://data/equipment.json")
	encounters = _load_json("res://data/encounters.json")
	dialogues = _load_json("res://data/dialogues.json")
	items = _load_json("res://data/items.json")
	maps = _load_json("res://data/maps.json")
	skills = _load_json("res://data/skills.json")
	quests = _load_json("res://data/quests.json")
	shops = _load_json("res://data/shops.json")
	crafting = _load_json("res://data/crafting.json")
	print("[DataLoader] Loaded %d enemies, %d equipment, %d encounters, %d items, %d skills, %d quests, %d shops, %d recipes"
		% [enemies.size(), equipment.size(), encounters.size(), items.size(),
		   skills.size(), quests.size(), shops.size(), crafting.size()])

func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[DataLoader] File not found: %s" % path)
		return {}
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return {}
	var text = file.get_as_text()
	file.close()
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		push_error("[DataLoader] Parse error in %s: %s" % [path, json.get_error_message()])
		return {}
	return json.data if json.data is Dictionary else {}

# --- Enemy API ---
func get_enemy(id: String) -> Dictionary:
	return enemies.get(id, {})

func get_enemy_list() -> Array:
	return enemies.keys()

func get_bounty_list() -> Array:
	var bounties = []
	for id in enemies:
		var e = enemies[id]
		if e.get("is_bounty", false):
			bounties.append(id)
	return bounties

# --- Equipment API ---
func get_equipment(id: String) -> Dictionary:
	return equipment.get(id, {})

func get_equipment_by_slot(slot: String) -> Array:
	var result = []
	for id in equipment:
		var eq = equipment[id]
		if eq.get("slot", "") == slot:
			result.append(id)
	return result

# --- Encounter API ---
func get_encounter_table(map_id: String) -> Array:
	var table = encounters.get(map_id, {})
	return table.get("table", [])

func roll_encounter(map_id: String) -> String:
	var table = get_encounter_table(map_id)
	if table.is_empty():
		return ""
	var total_weight = 0
	for entry in table:
		total_weight += entry.get("weight", 1)
	var roll = randi() % total_weight
	for entry in table:
		roll -= entry.get("weight", 1)
		if roll < 0:
			return entry.get("enemy_id", "")
	return table[0].get("enemy_id", "")

# --- Item API ---
func get_item(id: String) -> Dictionary:
	return items.get(id, {})

# --- Dialogue API ---
func get_dialogue(id: String) -> Dictionary:
	return dialogues.get(id, {})

# --- Map API ---
func get_map_data(map_id: String) -> Dictionary:
	return maps.get(map_id, {})

func get_map_list() -> Array:
	return maps.keys()

# --- Skill API ---
func get_skill(id: String) -> Dictionary:
	return skills.get(id, {})

func get_skill_list() -> Array:
	return skills.keys()

func get_skills_by_type(type: String) -> Array:
	var result := []
	for id in skills:
		if String(skills[id].get("type", "")) == type:
			result.append(id)
	return result

# --- Quest API ---
func get_quest(id: String) -> Dictionary:
	return quests.get(id, {})

func get_quest_list() -> Array:
	return quests.keys()

func get_bounty_quests() -> Array:
	var result := []
	for id in quests:
		var q: Dictionary = quests[id]
		if String(q.get("type", "")) == "bounty":
			result.append(id)
	return result

# --- Shop API ---
func get_shop(id: String) -> Dictionary:
	return shops.get(id, {})

func get_shop_items(shop_id: String) -> Array:
	var shop: Dictionary = shops.get(shop_id, {})
	return shop.get("items", [])

func get_shop_equipment(shop_id: String) -> Array:
	var shop: Dictionary = shops.get(shop_id, {})
	return shop.get("equipment", [])

# --- Crafting API ---
func get_crafting_recipe(id: String) -> Dictionary:
	return crafting.get(id, {})

func get_crafting_list() -> Array:
	return crafting.keys()

## Checks whether the player currently meets all requirements for a recipe.
## Returns a Dictionary: { "can_craft": bool, "missing": Dictionary, "gold_ok": bool }
func check_craft_requirements(recipe_id: String) -> Dictionary:
	var recipe := get_crafting_recipe(recipe_id)
	if recipe.is_empty():
		return {"can_craft": false, "missing": {}, "gold_ok": false}
	var materials: Dictionary = recipe.get("materials", {})
	var gold_cost: int = int(recipe.get("gold_cost", 0))
	var missing: Dictionary = {}
	for mat_id in materials:
		var needed: int = int(materials[mat_id])
		var have: int = int(GameState.inventory.get(mat_id, 0))
		if have < needed:
			missing[mat_id] = needed - have
	var gold_ok: bool = GameState.gold >= gold_cost
	return {
		"can_craft": missing.is_empty() and gold_ok,
		"missing": missing,
		"gold_ok": gold_ok,
	}
