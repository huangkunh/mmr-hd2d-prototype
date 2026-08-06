## BattleActor
## A lightweight RefCounted container representing a single participant in a
## turn-based battle (the player or one enemy). It holds the *mutable* combat
## stats for the duration of the fight and emits `hp_changed` whenever HP is
## modified so that the UI can react without polling.
##
## The actor is intentionally "dumb": it knows nothing about turn order,
## damage formulas, or the global GameState. The BattleManager computes final
## damage (applying crits, misses and defend modifiers) and feeds the result
## into `take_damage()`.
##
## Status Effects:
##   The actor tracks temporary status effects (poison, defense_down,
##   evasion_up, attack_up, defense_up) that modify combat behaviour.
##   The manager calls tick_status_effects() at the start of each round.
class_name BattleActor
extends RefCounted

# --- Signals -----------------------------------------------------------------

## Emitted every time HP changes. Carries the new current and maximum values.
signal hp_changed(current: int, maximum: int)

## Emitted once when HP reaches 0.
signal died()

## Emitted when a status effect is applied or removed.
signal status_changed()

# --- Status effect identifiers -----------------------------------------------
const STATUS_POISON := "poison"
const STATUS_DEFENSE_DOWN := "defense_down"
const STATUS_EVASION_UP := "evasion_up"
const STATUS_ATTACK_UP := "attack_up"
const STATUS_DEFENSE_UP := "defense_up"
const STATUS_BURN := "burn"

# --- Properties --------------------------------------------------------------

var name: String = "Actor"

var hp: int = 1
var max_hp: int = 1
var attack: int = 1
var defense: int = 0
var speed: int = 1
var is_player: bool = false
var sprite_path: String = ""

## Transient combat flag set by the BattleManager when the actor chose to
## defend. The manager reads it back to halve the next incoming hit.
var defending: bool = false

## Status effects: { effect_id: { "duration": int, "amount": float } }
var status_effects: Dictionary = {}

## Skill IDs this actor can use (populated from data or learned skills).
var skills: Array[String] = []

## Tank-specific properties (used when is_tank_mode is true)
var sp: int = 0           # Shield Points - absorbs damage before HP
var max_sp: int = 0
var is_tank_mode: bool = false
var cannon_attack: int = 0    # Main cannon attack power
var sub_attack: int = 0       # Sub-weapon attack power
var se_attack: int = 0        # SE unit attack power
var accuracy_bonus: int = 0   # From C-Unit

## SE weapon type and parameters (read from equipment data).
## Supported types: "missile", "flamethrower", "laser", "smoke", "repair", "earthquake"
var se_type: String = ""
var se_data: Dictionary = {}  # Full SE equipment data for effect parameters

# --- Constructor -------------------------------------------------------------

func _init(
                p_name: String = "Actor",
                p_max_hp: int = 1,
                p_attack: int = 1,
                p_defense: int = 0,
                p_speed: int = 1
        ) -> void:
        name = p_name
        max_hp = max(1, p_max_hp)
        hp = max_hp
        attack = p_attack
        defense = p_defense
        speed = p_speed

# --- Combat API --------------------------------------------------------------

## Apply `amount` damage. In tank mode, SP absorbs damage first, then HP.
func take_damage(amount: int) -> int:
        var remaining: int = clampi(amount, 0, hp + sp)
        if is_tank_mode and sp > 0:
                var sp_absorb: int = mini(sp, remaining)
                sp -= sp_absorb
                remaining -= sp_absorb
                hp_changed.emit(hp, max_hp)
        var actual: int = clampi(remaining, 0, hp)
        hp -= actual
        hp_changed.emit(hp, max_hp)
        if hp <= 0:
                died.emit()
        return clampi(amount, 0, hp + sp)

## Restore up to `amount` HP. Returns the amount actually healed.
func heal(amount: int) -> int:
        var before: int = hp
        hp = mini(max_hp, hp + maxi(0, amount))
        hp_changed.emit(hp, max_hp)
        return hp - before

## True while the actor still has HP remaining.
func is_alive() -> bool:
        return hp > 0

## Human-readable HP string, e.g. "45 / 100".
func hp_text() -> String:
        return "%d / %d" % [hp, max_hp]

## Current HP ratio in the 0.0–1.0 range, handy for driving HP bars.
func hp_ratio() -> float:
        if max_hp <= 0:
                return 0.0
        return float(hp) / float(max_hp)

## Current SP ratio in the 0.0–1.0 range, handy for driving SP bars.
func sp_ratio() -> float:
        if max_sp <= 0:
                return 0.0
        return float(sp) / float(max_sp)

## Human-readable SP string, e.g. "45 / 100".
func sp_text() -> String:
        return "%d / %d" % [sp, max_sp]

## Restore up to `amount` SP. Returns the amount actually repaired.
func repair_sp(amount: int) -> int:
        var before: int = sp
        sp = mini(max_sp, sp + maxi(0, amount))
        # Emit hp_changed so the UI refreshes the SP bar (which is tied to hp_changed
        # in tank mode).
        hp_changed.emit(hp, max_hp)
        return sp - before

# --- Effective stats (with status modifiers) ---------------------------------

## Returns the effective attack, applying attack_up buff if active.
func get_effective_attack() -> int:
        var total := attack
        if status_effects.has(STATUS_ATTACK_UP):
                var amount: float = float(status_effects[STATUS_ATTACK_UP].get("amount", 0.0))
                total = int(total * (1.0 + amount))
        return total

## Returns the effective defense, applying defense_up/defense_down modifiers.
func get_effective_defense() -> int:
        var total := defense
        if status_effects.has(STATUS_DEFENSE_UP):
                var amount: float = float(status_effects[STATUS_DEFENSE_UP].get("amount", 0.0))
                total = int(total * (1.0 + amount))
        if status_effects.has(STATUS_DEFENSE_DOWN):
                var amount: float = float(status_effects[STATUS_DEFENSE_DOWN].get("amount", 0.0))
                total = int(total * (1.0 - amount))
        return maxi(0, total)

## Returns the effective speed (currently no speed modifiers).
func get_effective_speed() -> int:
        return speed

## Returns the evasion bonus from evasion_up status (0.0 to 1.0).
func get_evasion_bonus() -> float:
        if status_effects.has(STATUS_EVASION_UP):
                return float(status_effects[STATUS_EVASION_UP].get("amount", 0.0))
        return 0.0

# --- Status effects ----------------------------------------------------------

## Applies a status effect with the given duration and amount.
## amount is a multiplier (e.g. 0.5 for 50% defense down).
func apply_status(effect_id: String, duration: int, amount: float = 0.0) -> void:
        status_effects[effect_id] = {"duration": duration, "amount": amount}
        status_changed.emit()

## Returns true if the actor has the given status effect.
func has_status(effect_id: String) -> bool:
        return status_effects.has(effect_id)

## Removes a status effect immediately.
func remove_status(effect_id: String) -> void:
        if status_effects.has(effect_id):
                status_effects.erase(effect_id)
                status_changed.emit()

## Ticks all status effects at the start of a round. Returns a dictionary of
## effects that expired this tick: { effect_id: true }
## Also applies poison/burn damage and returns it in the dict.
func tick_status_effects() -> Dictionary:
        var expired: Dictionary = {}
        var damage_taken: int = 0

        # Apply damage from poison/burn first.
        if status_effects.has(STATUS_POISON):
                var poison_dmg: int = maxi(1, int(max_hp * 0.05))  # 5% max HP per turn
                damage_taken += poison_dmg
        if status_effects.has(STATUS_BURN):
                var burn_dmg: int = maxi(1, int(max_hp * 0.08))  # 8% max HP per turn
                damage_taken += burn_dmg

        if damage_taken > 0:
                take_damage(damage_taken)

        # Decrement durations.
        for effect_id in status_effects.keys():
                status_effects[effect_id]["duration"] = int(status_effects[effect_id]["duration"]) - 1
                if int(status_effects[effect_id]["duration"]) <= 0:
                        expired[effect_id] = true

        # Remove expired effects.
        for effect_id in expired:
                status_effects.erase(effect_id)

        if not expired.is_empty():
                status_changed.emit()

        return {"expired": expired, "damage": damage_taken}

## Returns a human-readable summary of active status effects.
func get_status_summary() -> String:
        if status_effects.is_empty():
                return ""
        var parts: Array[String] = []
        for effect_id in status_effects:
                var duration: int = int(status_effects[effect_id].get("duration", 0))
                var label: String = effect_id.replace("_", " ").capitalize()
                parts.append("%s(%d)" % [label, duration])
        return ", ".join(parts)

# --- Factory helpers ---------------------------------------------------------

## Build a BattleActor initialised from the global GameState player stats.
## Uses effective stats (including equipment bonuses).
static func create_from_player() -> BattleActor:
        var actor := BattleActor.new()
        actor.name = GameState.player_name
        actor.is_player = true
        actor.max_hp = GameState.player_max_hp
        actor.hp = GameState.player_hp
        # Use effective stats that include weapon/armor bonuses.
        actor.attack = GameState.get_effective_attack()
        actor.defense = GameState.get_effective_defense()
        actor.speed = GameState.get_effective_speed()
        actor.sprite_path = "res://assets/sprites/player_idle_down.jpg"
        # Populate learned skills.
        actor.skills = GameState.learned_skills.duplicate()
        return actor

## Build a BattleActor initialised from the player's tank state.
## Uses tank parts for attack/defense and SP for shield absorption.
static func create_from_tank() -> BattleActor:
        var actor := BattleActor.new()
        actor.name = GameState.player_name + "'s Tank"
        actor.is_player = true
        actor.is_tank_mode = true
        actor.max_hp = GameState.tank_max_hp
        actor.hp = GameState.tank_hp
        actor.max_sp = GameState.tank_max_sp
        actor.sp = GameState.tank_sp
        # Tank attack comes from equipped parts
        actor.cannon_attack = 0
        actor.sub_attack = 0
        actor.se_attack = 0
        actor.attack = GameState.get_tank_attack()
        actor.defense = GameState.get_tank_defense()
        actor.speed = 10  # Tanks are slower
        actor.accuracy_bonus = 0
        # Read accuracy from C-Unit
        var c_unit_id = GameState.tank_parts.get("c_unit")
        if c_unit_id != null and not String(c_unit_id).is_empty():
                var c_unit = DataLoader.get_equipment(String(c_unit_id))
                actor.accuracy_bonus = int(c_unit.get("accuracy_bonus", 0))
        # Read individual weapon attacks
        var main_cannon_id = GameState.tank_parts.get("main_cannon")
        if main_cannon_id != null and not String(main_cannon_id).is_empty():
                var cannon = DataLoader.get_equipment(String(main_cannon_id))
                actor.cannon_attack = int(cannon.get("attack", 0))
        var sub_cannon_id = GameState.tank_parts.get("sub_cannon")
        if sub_cannon_id != null and not String(sub_cannon_id).is_empty():
                var sub = DataLoader.get_equipment(String(sub_cannon_id))
                actor.sub_attack = int(sub.get("attack", 0))
        var se_unit_id = GameState.tank_parts.get("se_unit")
        if se_unit_id != null and not String(se_unit_id).is_empty():
                var se = DataLoader.get_equipment(String(se_unit_id))
                actor.se_attack = int(se.get("attack", 0))
                actor.se_type = String(se.get("se_type", "missile"))
                actor.se_data = se
        actor.sprite_path = "res://assets/sprites/player_idle_down.jpg"
        # Tank skills
        actor.skills = ["tank_cannon_barrage", "tank_smokescreen", "tank_missile_swarm"]
        return actor

## Build a BattleActor initialised from an enemy data dictionary returned by
## `DataLoader.get_enemy(id)`.
static func create_from_enemy(enemy_data: Dictionary) -> BattleActor:
        var actor := BattleActor.new()
        actor.name = enemy_data.get("name", "Unknown Enemy")
        actor.is_player = false
        actor.max_hp = int(enemy_data.get("hp", 1))
        actor.hp = actor.max_hp
        actor.attack = int(enemy_data.get("attack", 1))
        actor.defense = int(enemy_data.get("defense", 0))
        actor.speed = int(enemy_data.get("speed", 1))
        actor.sprite_path = String(enemy_data.get("sprite", ""))
        # Populate enemy skills from data.
        var enemy_skills: Array = enemy_data.get("skills", [])
        for skill_id in enemy_skills:
                actor.skills.append(String(skill_id))
        return actor

## Build a BattleActor from a party member dictionary.
static func create_from_party_member(member: Dictionary) -> BattleActor:
        var actor := BattleActor.new()
        actor.name = String(member.get("name", "Companion"))
        actor.is_player = true
        actor.max_hp = int(member.get("max_hp", 100))
        actor.hp = int(member.get("hp", actor.max_hp))
        actor.attack = int(member.get("attack", 10))
        actor.defense = int(member.get("defense", 5))
        actor.speed = int(member.get("speed", 10))
        actor.sprite_path = "res://assets/sprites/player_idle_down.jpg"
        var skill_id = String(member.get("skill_id", ""))
        if not skill_id.is_empty():
                actor.skills.append(skill_id)
        return actor
