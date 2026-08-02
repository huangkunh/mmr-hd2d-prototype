## BattleManager
## Node-based controller that drives the entire turn-based battle loop.
##
## State machine flow:
##   INTRO -> PLAYER_TURN -> ENEMY_TURN -> VICTORY / DEFEAT -> OUTRO
##
## The manager owns all combat logic (damage formula, crits, misses, flee
## chances, turn order) and exposes a small set of signals that the BattleUI
## listens to for presentation. The UI calls back into `select_action()` and
## `confirm_proceed()` to feed the player's choices back in.
##
## On conclusion it hands control to `GameState.end_battle(result)`, which
## rewards gold/EXP and transitions back to the world scene.
class_name BattleManager
extends Node

# --- Required signals --------------------------------------------------------

## Emitted when the player confirms a command (attack/defend/item/flee).
signal action_selected(action: String)

## Emitted whenever a non-critical hit lands damage on `target`.
signal damage_dealt(target: BattleActor, amount: int)

## Emitted whenever the battle state machine transitions to a new state.
signal battle_state_changed(state: int)

# --- Additional UI-facing signals -------------------------------------------

## A line of flavour text to append to the battle log.
signal battle_log(message: String)

## Emitted once both actors have been created and are ready to be displayed.
signal actors_ready(player_actor: BattleActor, enemy_actor: BattleActor)

## Emitted when the manager is waiting for the player to pick a command.
signal request_player_action()

## An attack missed `target` (no damage). Lets the UI show a "MISS" popup.
signal attack_missed(target: BattleActor)

## A critical hit landed on `target` for `amount`. Replaces damage_dealt.
signal critical_hit(target: BattleActor, amount: int)

## `target` was healed for `amount`.
signal healed(target: BattleActor, amount: int)

## Victory reached. Carries the rewards to display on the victory screen.
signal victory(exp_gained: int, gold_gained: int, is_bounty: bool, bounty_reward: int)

## Defeat reached.
signal defeat()

## The player escaped from battle.
signal fled()

## The OUTRO sequence has finished and the scene is about to change.
signal outro_finished()

# --- State machine -----------------------------------------------------------

enum State { INTRO, PLAYER_TURN, ENEMY_TURN, VICTORY, DEFEAT, OUTRO }

# Player command identifiers (also used as the `action` in action_selected).
const ACTION_ATTACK := "attack"
const ACTION_DEFEND := "defend"
const ACTION_ITEM := "item"
const ACTION_FLEE := "flee"

# --- Combat tuning constants -------------------------------------------------

const CRIT_CHANCE := 0.10          # 10% base critical hit chance.
const CRIT_MULTIPLIER := 1.5       # Crits deal 150% damage.
const BASE_MISS_CHANCE := 0.05     # 5% base miss chance.
const MISS_SPEED_FACTOR := 0.01    # Each point of speed gap adjusts miss %.
const MISS_CHANCE_MIN := 0.02
const MISS_CHANCE_MAX := 0.50

const FLEE_BASE_CHANCE := 0.60     # 60% base flee success.
const FLEE_SPEED_FACTOR := 0.02    # Each point of speed gap adjusts flee %.
const FLEE_CHANCE_MIN := 0.10
const FLEE_CHANCE_MAX := 0.95

const DMG_VARIANCE := 3            # +/- variance applied to base damage.

# --- Exports -----------------------------------------------------------------

## Path to the BattleUI Control node. Resolved in _ready().
@export var battle_ui_path: NodePath = ^"../BattleUI"

## Pause lengths (seconds) used to pace the turn loop so the player can read
## the battle log and watch animations.
@export var intro_delay: float = 1.2
@export var action_delay: float = 0.8
@export var turn_delay: float = 0.6

# --- Runtime state -----------------------------------------------------------

var current_state: int = State.INTRO
var player_actor: BattleActor
var enemy_actor: BattleActor
var enemy_data: Dictionary = {}

var _battle_ui: Control
var _busy: bool = false  # True while a player command is being resolved.

# --- Lifecycle ---------------------------------------------------------------

func _ready() -> void:
	# Resolve the UI lazily; it lives as a sibling in the scene tree.
	_battle_ui = get_node_or_null(battle_ui_path)
	# Defer the battle start so the UI (and its signal connections) is ready.
	call_deferred("_start_battle")

# --- Bootstrapping -----------------------------------------------------------

func _start_battle() -> void:
	var enemy_id := GameState.current_enemy_id
	if enemy_id.is_empty():
		push_error("[BattleManager] GameState.current_enemy_id is empty. Falling back to 'slime'.")
		enemy_id = "slime"

	enemy_data = DataLoader.get_enemy(enemy_id)
	if enemy_data.is_empty():
		push_error("[BattleManager] Enemy '%s' not found in DataLoader. Falling back to 'slime'." % enemy_id)
		enemy_data = DataLoader.get_enemy("slime")

	# Create the two combatants from data.
	player_actor = BattleActor.create_from_player()
	enemy_actor = BattleActor.create_from_enemy(enemy_data)
	actors_ready.emit(player_actor, enemy_actor)

	_log("A wild %s appeared!" % enemy_actor.name)

	_set_state(State.INTRO)
	await get_tree().create_timer(intro_delay).timeout

	# Decide who acts first this round by comparing speed.
	_begin_round()

# --- Round / turn orchestration ----------------------------------------------

## Begins a fresh round: the faster combatant acts first.
func _begin_round() -> void:
	if player_actor.speed >= enemy_actor.speed:
		_begin_player_turn()
	else:
		await _do_enemy_turn()

## Hands control to the player and asks the UI to show the command menu.
func _begin_player_turn() -> void:
	player_actor.defending = false
	_set_state(State.PLAYER_TURN)
	_busy = false
	request_player_action.emit()

## Called by the BattleUI when the player confirms a command.
## `item_id` is only used for the "item" action.
func select_action(action: String, item_id: String = "") -> void:
	if current_state != State.PLAYER_TURN or _busy:
		return
	action_selected.emit(action)
	_busy = true

	match action:
		ACTION_ATTACK:
			await _execute_player_attack()
		ACTION_DEFEND:
			_execute_defend()
			await get_tree().create_timer(action_delay).timeout
		ACTION_ITEM:
			await _execute_item(item_id)
		ACTION_FLEE:
			await _execute_flee()
		_:
			push_warning("[BattleManager] Unknown action: %s" % action)
			_busy = false
			return

	_busy = false

	# If the action already ended the battle (victory / fled), stop here.
	if current_state != State.PLAYER_TURN:
		return

	# Otherwise hand the turn to the enemy.
	await _end_player_turn()

func _end_player_turn() -> void:
	if not enemy_actor.is_alive():
		_enter_victory()
		return
	await _do_enemy_turn()

# --- Player command implementations -----------------------------------------

func _execute_player_attack() -> void:
	_log("%s attacks!" % player_actor.name)
	await get_tree().create_timer(turn_delay).timeout

	var result := _compute_damage(player_actor, enemy_actor)
	if not result.hit:
		attack_missed.emit(enemy_actor)
		_log("...but missed!")
		await get_tree().create_timer(action_delay).timeout
		return

	enemy_actor.take_damage(result.amount)
	_emit_hit(enemy_actor, result)
	_log_damage(enemy_actor, result.crit, result.amount)
	await get_tree().create_timer(action_delay).timeout

	if not enemy_actor.is_alive():
		_enter_victory()

func _execute_defend() -> void:
	player_actor.defending = true
	_log("%s takes a defensive stance." % player_actor.name)

func _execute_item(item_id: String) -> void:
	if item_id.is_empty() or not GameState.inventory.has(item_id) or GameState.inventory[item_id] <= 0:
		_log("No usable items!")
		await get_tree().create_timer(action_delay).timeout
		return

	var item: Dictionary = DataLoader.get_item(item_id)
	if item.is_empty():
		_log("No usable items!")
		return

	var item_name: String = item.get("name", "Item")
	var type: String = item.get("type", "")

	if type == "heal":
		var restore: int = int(item.get("hp_restore", 0))
		var healed_amount: int = player_actor.heal(restore)
		GameState.heal(healed_amount)
		healed.emit(player_actor, healed_amount)
		_log("Used %s! Restored %d HP." % [item_name, healed_amount])
		_consume_item(item_id)
		await get_tree().create_timer(action_delay).timeout
	elif type == "escape":
		_log("Used %s!" % item_name)
		_consume_item(item_id)
		await get_tree().create_timer(turn_delay).timeout
		_enter_fled(true)
	else:
		_log("Can't use %s here." % item_name)
		await get_tree().create_timer(action_delay).timeout

func _execute_flee() -> void:
	_log("Trying to flee...")
	await get_tree().create_timer(turn_delay).timeout

	if randf() <= _flee_chance():
		_log("Got away safely!")
		await get_tree().create_timer(action_delay).timeout
		_enter_fled(false)
	else:
		_log("Couldn't escape!")
		await get_tree().create_timer(action_delay).timeout

func _consume_item(item_id: String) -> void:
	if not GameState.inventory.has(item_id):
		return
	GameState.inventory[item_id] -= 1
	if GameState.inventory[item_id] <= 0:
		GameState.inventory.erase(item_id)

# --- Enemy turn --------------------------------------------------------------

func _do_enemy_turn() -> void:
	_set_state(State.ENEMY_TURN)
	await get_tree().create_timer(turn_delay).timeout

	# The enemy may have died mid-round (e.g. to a counter); bail out safely.
	if not enemy_actor.is_alive():
		_begin_player_turn()
		return

	_log("%s attacks!" % enemy_actor.name)
	await get_tree().create_timer(turn_delay).timeout

	var result := _compute_damage(enemy_actor, player_actor)
	if not result.hit:
		attack_missed.emit(player_actor)
		_log("...but missed!")
	else:
		var amount: int = result.amount
		# Defending halves the next incoming hit, then the stance is consumed.
		if player_actor.defending:
			amount = int(amount / 2.0)
		var actual: int = player_actor.take_damage(amount)
		GameState.take_damage(actual)  # keep global state in sync
		# Re-emit with the (possibly halved) actual amount for the UI popup.
		if result.crit:
			critical_hit.emit(player_actor, actual)
		else:
			damage_dealt.emit(player_actor, actual)
		_log_damage(player_actor, result.crit, actual)

	player_actor.defending = false
	await get_tree().create_timer(action_delay).timeout

	if not player_actor.is_alive():
		_enter_defeat()
		return

	_begin_player_turn()

# --- Damage / flee math ------------------------------------------------------

## Computes the outcome of one attack. Returns a Dictionary with:
##   { hit: bool, crit: bool, amount: int }
func _compute_damage(attacker: BattleActor, defender: BattleActor) -> Dictionary:
	# Miss chance: base 5% nudged by the speed gap (faster defenders dodge more).
	var miss_chance: float = clampf(
		BASE_MISS_CHANCE + (defender.speed - attacker.speed) * MISS_SPEED_FACTOR,
		MISS_CHANCE_MIN, MISS_CHANCE_MAX
	)
	if randf() < miss_chance:
		return {"hit": false, "crit": false, "amount": 0}

	# Core formula: atk - def +/- a small random variance, never below 1.
	var base: int = maxi(1, attacker.attack - defender.defense + randi_range(-DMG_VARIANCE, DMG_VARIANCE))

	var crit: bool = randf() < CRIT_CHANCE
	if crit:
		base = int(base * CRIT_MULTIPLIER)

	return {"hit": true, "crit": crit, "amount": base}

## Flee success chance: 60% base, +/- 2% per point of speed difference.
func _flee_chance() -> float:
	return clampf(
		FLEE_BASE_CHANCE + (player_actor.speed - enemy_actor.speed) * FLEE_SPEED_FACTOR,
		FLEE_CHANCE_MIN, FLEE_CHANCE_MAX
	)

# --- End-of-battle transitions ----------------------------------------------

func _enter_victory() -> void:
	_set_state(State.VICTORY)
	var exp_gained: int = int(enemy_data.get("exp", 0))
	var gold_gained: int = int(enemy_data.get("gold", 0))
	var is_bounty: bool = bool(enemy_data.get("is_bounty", false))
	var bounty_reward: int = int(enemy_data.get("bounty_reward", 0))
	if is_bounty:
		gold_gained += bounty_reward
		_log("BOUNTY target downed!")
	_log("Victory! Gained %d EXP and %d gold." % [exp_gained, gold_gained])
	victory.emit(exp_gained, gold_gained, is_bounty, bounty_reward)

func _enter_defeat() -> void:
	_set_state(State.DEFEAT)
	_log("You have been defeated...")
	defeat.emit()

func _enter_fled(used_item: bool) -> void:
	_set_state(State.OUTRO)
	fled.emit()
	await get_tree().create_timer(action_delay).timeout
	GameState.end_battle(GameState.BattleResult.FLED)

## Called by the BattleUI once the player dismisses the victory/defeat screen.
func confirm_proceed() -> void:
	match current_state:
		State.VICTORY:
			_set_state(State.OUTRO)
			# Bounty bonus gold is layered on top of the base reward that
			# GameState.end_battle(VICTORY) already grants from enemy_data.
			if bool(enemy_data.get("is_bounty", false)):
				GameState.gain_gold(int(enemy_data.get("bounty_reward", 0)))
			outro_finished.emit()
			GameState.end_battle(GameState.BattleResult.VICTORY)
		State.DEFEAT:
			_set_state(State.OUTRO)
			outro_finished.emit()
			GameState.end_battle(GameState.BattleResult.DEFEAT)

# --- Helpers -----------------------------------------------------------------

func _set_state(state: int) -> void:
	current_state = state
	battle_state_changed.emit(state)

func _log(message: String) -> void:
	battle_log.emit(message)

func _emit_hit(target: BattleActor, result: Dictionary) -> void:
	if result.crit:
		critical_hit.emit(target, int(result.amount))
	else:
		damage_dealt.emit(target, int(result.amount))

func _log_damage(target: BattleActor, crit: bool, amount: int) -> void:
	var tag: String = "Critical! " if crit else ""
	_log("%sDealt %d damage to %s." % [tag, amount, target.name])
