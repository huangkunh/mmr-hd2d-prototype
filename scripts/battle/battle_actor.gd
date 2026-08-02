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
class_name BattleActor
extends RefCounted

# --- Signals -----------------------------------------------------------------

## Emitted every time HP changes. Carries the new current and maximum values.
signal hp_changed(current: int, maximum: int)

## Emitted once when HP reaches 0.
signal died()

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

## Apply `amount` damage (already finalised by the manager). Returns the actual
## damage dealt, clamped to the remaining HP so it can never drop below zero.
func take_damage(amount: int) -> int:
	var actual: int = clampi(amount, 0, hp)
	hp -= actual
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		died.emit()
	return actual

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

# --- Factory helpers ---------------------------------------------------------

## Build a BattleActor initialised from the global GameState player stats.
static func create_from_player() -> BattleActor:
	var actor := BattleActor.new()
	actor.name = GameState.player_name
	actor.is_player = true
	actor.max_hp = GameState.player_max_hp
	actor.hp = GameState.player_hp
	actor.attack = GameState.player_attack
	actor.defense = GameState.player_defense
	actor.speed = GameState.player_speed
	# Placeholder battle sprite path; the user can drop the real asset in later.
	actor.sprite_path = "res://assets/sprites/player_battle.png"
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
	return actor
