## TankSystem
## Resource representing a tank's full equipment loadout across the 6
## customisation slots (chassis, main_cannon, sub_cannon, se_unit, c_unit,
## engine). Stores equipment IDs (empty string == unequipped) and computes
## aggregate stats (attack, defense, weight, power) by querying the
## DataLoader autoload.
##
## The resource is a plain data/logic container: it does NOT touch GameState
## on its own except through the explicit sync helpers load_from_game_state()
## and apply_to_game_state(), so it can be reused in tests, previews or
## battle without side effects.
class_name TankSystem
extends Resource

# --- Slot constants ----------------------------------------------------------
## Slot key matching GameState.tank_parts keys and the "slot" field in equipment.json.
const SLOT_CHASSIS: String = "chassis"
const SLOT_MAIN_CANNON: String = "main_cannon"
const SLOT_SUB_CANNON: String = "sub_cannon"
const SLOT_SE_UNIT: String = "se_unit"
const SLOT_C_UNIT: String = "c_unit"
const SLOT_ENGINE: String = "engine"

## Ordered list of all tank slots (used for iteration and indexing in the garage).
const SLOTS: Array[String] = [
	SLOT_CHASSIS,
	SLOT_MAIN_CANNON,
	SLOT_SUB_CANNON,
	SLOT_SE_UNIT,
	SLOT_C_UNIT,
	SLOT_ENGINE,
]

## Human-readable labels for each slot, keyed by slot string.
const SLOT_LABELS: Dictionary = {
	SLOT_CHASSIS: "Chassis",
	SLOT_MAIN_CANNON: "Main Cannon",
	SLOT_SUB_CANNON: "Sub Cannon",
	SLOT_SE_UNIT: "SE Unit",
	SLOT_C_UNIT: "C-Unit",
	SLOT_ENGINE: "Engine",
}

# --- Equipment IDs per slot --------------------------------------------------
## Empty string ("") means the slot is unequipped. We use "" instead of null
## because @export String serialises cleanly and is editor-friendly; the
## sync helpers convert to/from the null values stored in GameState.tank_parts.
@export var chassis: String = ""
@export var main_cannon: String = ""
@export var sub_cannon: String = ""
@export var se_unit: String = ""
@export var c_unit: String = ""
@export var engine: String = ""


# --- Slot accessors ----------------------------------------------------------

## Returns the equipment ID currently assigned to [param slot], or "" if empty.
func get_slot_id(slot: String) -> String:
	match slot:
		SLOT_CHASSIS: return chassis
		SLOT_MAIN_CANNON: return main_cannon
		SLOT_SUB_CANNON: return sub_cannon
		SLOT_SE_UNIT: return se_unit
		SLOT_C_UNIT: return c_unit
		SLOT_ENGINE: return engine
	return ""


## Sets the equipment ID for [param slot]. Pass "" to clear it.
func set_slot_id(slot: String, id: String) -> void:
	match slot:
		SLOT_CHASSIS: chassis = id
		SLOT_MAIN_CANNON: main_cannon = id
		SLOT_SUB_CANNON: sub_cannon = id
		SLOT_SE_UNIT: se_unit = id
		SLOT_C_UNIT: c_unit = id
		SLOT_ENGINE: engine = id


## True when the slot has any equipment assigned.
func is_slot_equipped(slot: String) -> bool:
	return not get_slot_id(slot).is_empty()


## Returns the slot key that [param part_id] belongs to, based on its data.
## Returns "" if the part is unknown or its slot is not a tank slot.
func get_slot_for_part(part_id: String) -> String:
	if part_id.is_empty():
		return ""
	var eq: Dictionary = DataLoader.get_equipment(part_id)
	if eq.is_empty():
		return ""
	var slot: String = String(eq.get("slot", ""))
	if SLOTS.has(slot):
		return slot
	return ""


# --- Calculated stats --------------------------------------------------------

## Sum of the "attack" stat of every equipped part.
func get_total_attack() -> int:
	var total: int = 0
	for slot in SLOTS:
		var id: String = get_slot_id(slot)
		if id.is_empty():
			continue
		total += int(DataLoader.get_equipment(id).get("attack", 0))
	return total


## Sum of the "defense" stat of every equipped part.
func get_total_defense() -> int:
	var total: int = 0
	for slot in SLOTS:
		var id: String = get_slot_id(slot)
		if id.is_empty():
			continue
		total += int(DataLoader.get_equipment(id).get("defense", 0))
	return total


## Sum of the "weight" stat of every equipped part. Parts without an explicit
## "weight" field (e.g. chassis / c-unit in the default data) contribute 0.
func get_weight() -> int:
	var total: int = 0
	for slot in SLOTS:
		var id: String = get_slot_id(slot)
		if id.is_empty():
			continue
		total += int(DataLoader.get_equipment(id).get("weight", 0))
	return total


## Power provided by the equipped engine (0 when no engine is fitted).
func get_power() -> int:
	if engine.is_empty():
		return 0
	return int(DataLoader.get_equipment(engine).get("power", 0))


## True when total weight exceeds engine power — the tank cannot move.
func is_overweight() -> bool:
	return get_weight() > get_power()


## Inverse of is_overweight(); the tank can only act in battle when this is true.
func can_move() -> bool:
	return get_weight() <= get_power()


## Convenience snapshot of all four aggregate stats at once.
func get_stats() -> Dictionary:
	return {
		"attack": get_total_attack(),
		"defense": get_total_defense(),
		"weight": get_weight(),
		"power": get_power(),
	}


## Returns what the aggregate stats WOULD be if [param part_id] were equipped
## in its own slot (temporarily swapping out whatever is there now).
## Returns an empty Dictionary if the part is unknown.
func stats_with_part(part_id: String) -> Dictionary:
	if part_id.is_empty():
		return {}
	var slot: String = get_slot_for_part(part_id)
	if slot.is_empty():
		return {}
	return stats_if_slot_set(slot, part_id)


## Returns what the aggregate stats WOULD be if [param slot] held [param part_id]
## (pass "" to preview the slot being emptied). Used by the garage for the
## current-vs-new comparison panel.
func stats_if_slot_set(slot: String, part_id: String) -> Dictionary:
	var original: String = get_slot_id(slot)
	set_slot_id(slot, part_id)
	var snapshot: Dictionary = {
		"attack": get_total_attack(),
		"defense": get_total_defense(),
		"weight": get_weight(),
		"power": get_power(),
	}
	set_slot_id(slot, original)
	return snapshot


# --- Equip / Unequip ---------------------------------------------------------

## Equips [param part_id] into the slot defined by its data.
## Returns false if the part is unknown or belongs to a non-tank slot.
func equip(part_id: String) -> bool:
	if part_id.is_empty():
		return false
	var eq: Dictionary = DataLoader.get_equipment(part_id)
	if eq.is_empty():
		push_warning("[TankSystem] Unknown equipment id: %s" % part_id)
		return false
	var slot: String = String(eq.get("slot", ""))
	if not SLOTS.has(slot):
		push_warning("[TankSystem] Equipment %s has non-tank slot '%s'" % [part_id, slot])
		return false
	set_slot_id(slot, part_id)
	return true


## Removes whatever is equipped in [param slot] (no-op for invalid slots).
func unequip(slot: String) -> void:
	if SLOTS.has(slot):
		set_slot_id(slot, "")


## Removes every part from every slot.
func clear_all() -> void:
	for slot in SLOTS:
		set_slot_id(slot, "")


# --- GameState sync ----------------------------------------------------------
## These helpers bridge the "" (none) convention used by this resource and
## the null (none) convention used by GameState.tank_parts, so the garage can
## load/apply the live configuration without leaking either representation.

## Copies the currently equipped IDs from GameState.tank_parts into this resource.
func load_from_game_state() -> void:
	chassis = _to_str(GameState.tank_parts.get(SLOT_CHASSIS))
	main_cannon = _to_str(GameState.tank_parts.get(SLOT_MAIN_CANNON))
	sub_cannon = _to_str(GameState.tank_parts.get(SLOT_SUB_CANNON))
	se_unit = _to_str(GameState.tank_parts.get(SLOT_SE_UNIT))
	c_unit = _to_str(GameState.tank_parts.get(SLOT_C_UNIT))
	engine = _to_str(GameState.tank_parts.get(SLOT_ENGINE))


## Writes this resource's loadout back into GameState.tank_parts (null for empty).
func apply_to_game_state() -> void:
	GameState.tank_parts[SLOT_CHASSIS] = _to_null(chassis)
	GameState.tank_parts[SLOT_MAIN_CANNON] = _to_null(main_cannon)
	GameState.tank_parts[SLOT_SUB_CANNON] = _to_null(sub_cannon)
	GameState.tank_parts[SLOT_SE_UNIT] = _to_null(se_unit)
	GameState.tank_parts[SLOT_C_UNIT] = _to_null(c_unit)
	GameState.tank_parts[SLOT_ENGINE] = _to_null(engine)


## Builds a fresh TankSystem pre-populated from GameState. Handy one-liner.
static func from_game_state() -> TankSystem:
	var t := TankSystem.new()
	t.load_from_game_state()
	return t


# --- Internal helpers --------------------------------------------------------

static func _to_str(value: Variant) -> String:
	if value == null:
		return ""
	return String(value)


static func _to_null(value: String) -> Variant:
	if value.is_empty():
		return null
	return value
