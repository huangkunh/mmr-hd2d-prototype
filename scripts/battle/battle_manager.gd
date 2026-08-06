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
const ACTION_SKILL := "skill"
const ACTION_ITEM := "item"
const ACTION_FLEE := "flee"
const ACTION_TANK_ATTACK := "tank_attack"
const ACTION_TANK_SE := "tank_se"

## Enemy AI skill use chance (per turn when a skill is available).
const ENEMY_SKILL_CHANCE := 0.30
## When enemy HP drops below this ratio, it gets more aggressive with skills.
const ENEMY_LOW_HP_RATIO := 0.30
## Skill use chance when the enemy is low on HP.
const ENEMY_LOW_HP_SKILL_CHANCE := 0.50

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
var party_actors: Array[BattleActor] = []

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
	# Check if player should fight in tank mode
	var use_tank: bool = GameState.tank_owned and GameState.battle_mode == "tank"
	if use_tank:
		player_actor = BattleActor.create_from_tank()
	else:
		player_actor = BattleActor.create_from_player()
	enemy_actor = BattleActor.create_from_enemy(enemy_data)
	# Create party member actors (recruited companions)
	party_actors.clear()
	for member in GameState.get_active_party():
		var party_actor = BattleActor.create_from_party_member(member)
		party_actors.append(party_actor)
	actors_ready.emit(player_actor, enemy_actor)

	# Pick the battle BGM: boss encounters get their own theme.
	if bool(enemy_data.get("is_bounty", false)):
		AudioManager.play_bgm("boss_theme")
	else:
		AudioManager.play_bgm("battle_theme")

	_log("A wild %s appeared!" % enemy_actor.name)

	_set_state(State.INTRO)
	await get_tree().create_timer(intro_delay).timeout

	# Decide who acts first this round by comparing speed.
	_begin_round()

# --- Round / turn orchestration ----------------------------------------------

## Begins a fresh round: the faster combatant acts first.
## Ticks status effects and skill cooldowns at the start of each round.
func _begin_round() -> void:
	# Tick status effects (poison damage, duration decrements).
	if player_actor.is_alive():
		var p_result := player_actor.tick_status_effects()
		if p_result.damage > 0:
			_log("%s takes %d poison/burn damage." % [player_actor.name, p_result.damage])
			GameState.take_damage(p_result.damage)
			AudioManager.play_sfx("hit")
			await get_tree().create_timer(0.3).timeout
		if not player_actor.is_alive():
			_enter_defeat()
			return
	if enemy_actor.is_alive():
		var e_result := enemy_actor.tick_status_effects()
		if e_result.damage > 0:
			_log("%s takes %d poison/burn damage." % [enemy_actor.name, e_result.damage])
			AudioManager.play_sfx("hit")
			await get_tree().create_timer(0.3).timeout
		if not enemy_actor.is_alive():
			_enter_victory()
			return
	# Tick player skill cooldowns.
	GameState.tick_cooldowns()

	if player_actor.get_effective_speed() >= enemy_actor.get_effective_speed():
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
## `skill_id` is only used for the "skill" action.
func select_action(action: String, item_id: String = "", skill_id: String = "") -> void:
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
		ACTION_SKILL:
			await _execute_skill(skill_id)
		ACTION_ITEM:
			await _execute_item(item_id)
		ACTION_FLEE:
			await _execute_flee()
		ACTION_TANK_ATTACK:
			await _execute_tank_cannon_attack()
		ACTION_TANK_SE:
			await _execute_tank_se_attack()
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
		AudioManager.play_sfx("miss")
		_log("...but missed!")
		await get_tree().create_timer(action_delay).timeout
		return

	enemy_actor.take_damage(result.amount)
	if result.crit:
		AudioManager.play_sfx("critical")
	else:
		AudioManager.play_sfx("hit")
	_emit_hit(enemy_actor, result)
	_log_damage(enemy_actor, result.crit, result.amount)
	await get_tree().create_timer(action_delay).timeout

	if not enemy_actor.is_alive():
		_enter_victory()

## Tank main cannon attack: high damage, single hit
func _execute_tank_cannon_attack() -> void:
	_log("%s fires the main cannon!" % player_actor.name)
	AudioManager.play_sfx("explosion")
	await get_tree().create_timer(turn_delay).timeout

	var result := _compute_tank_damage(player_actor, enemy_actor, player_actor.cannon_attack)
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

## Tank sub-weapon attack: multiple hits, lower damage each
func _execute_tank_sub_attack() -> void:
	_log("%s fires the sub-weapon!" % player_actor.name)
	AudioManager.play_sfx("hit")
	await get_tree().create_timer(turn_delay).timeout

	var hit_count: int = 3
	for i in range(hit_count):
		if not enemy_actor.is_alive():
			break
		var result := _compute_tank_damage(player_actor, enemy_actor, player_actor.sub_attack)
		if not result.hit:
			attack_missed.emit(enemy_actor)
			_log("Hit %d: missed!" % (i + 1))
		else:
			enemy_actor.take_damage(result.amount)
			_emit_hit(enemy_actor, result)
			_log("Hit %d: %d damage." % [(i + 1), result.amount])
		await get_tree().create_timer(0.3).timeout

	if not enemy_actor.is_alive():
		_enter_victory()

## Tank SE weapon attack: special effect depending on SE type
## Types: missile (multi-hit), flamethrower (burn DoT), laser (defense-ignoring),
##        smoke (evasion buff), repair (SP heal), earthquake (defense break + damage)
func _execute_tank_se_attack() -> void:
	var se_type: String = player_actor.se_type
	if se_type.is_empty():
		se_type = "missile"  # Default fallback
	
	_log("%s launches the SE weapon!" % player_actor.name)
	AudioManager.play_sfx("explosion")
	await get_tree().create_timer(turn_delay).timeout
	
	match se_type:
		"missile":
			await _se_missile_attack()
		"flamethrower":
			await _se_flamethrower_attack()
		"laser":
			await _se_laser_attack()
		"smoke":
			await _se_smoke_attack()
		"repair":
			await _se_repair_attack()
		"earthquake":
			await _se_earthquake_attack()
		_:
			await _se_missile_attack()
	
	if not enemy_actor.is_alive():
		_enter_victory()

## SE Missile: multi-hit (default 4 hits), high damage each
func _se_missile_attack() -> void:
	var hit_count: int = int(player_actor.se_data.get("se_hits", 4))
	for i in range(hit_count):
		if not enemy_actor.is_alive():
			break
		var result := _compute_tank_damage(player_actor, enemy_actor, player_actor.se_attack)
		if not result.hit:
			attack_missed.emit(enemy_actor)
			_log("Hit %d: missed!" % (i + 1))
		else:
			enemy_actor.take_damage(result.amount)
			_emit_hit(enemy_actor, result)
			_log("Hit %d: %d damage." % [(i + 1), result.amount])
		await get_tree().create_timer(0.25).timeout

## SE Flamethrower: single powerful hit + chance to burn
func _se_flamethrower_attack() -> void:
	var burn_chance: float = float(player_actor.se_data.get("se_burn_chance", 0.5))
	var burn_duration: int = int(player_actor.se_data.get("se_burn_duration", 3))
	var result := _compute_tank_damage(player_actor, enemy_actor, player_actor.se_attack)
	if not result.hit:
		attack_missed.emit(enemy_actor)
		_log("...but missed!")
	else:
		enemy_actor.take_damage(result.amount)
		_emit_hit(enemy_actor, result)
		_log_damage(enemy_actor, result.crit, result.amount)
		# Chance to apply burn
		if randf() < burn_chance:
			enemy_actor.apply_status(BattleActor.STATUS_BURN, burn_duration)
			_log("%s is engulfed in flames!" % enemy_actor.name)
	await get_tree().create_timer(action_delay).timeout

## SE Laser: single hit that ignores defense
func _se_laser_attack() -> void:
	var miss_chance: float = clampf(
		BASE_MISS_CHANCE - float(player_actor.accuracy_bonus) * 0.005,
		0.01, MISS_CHANCE_MAX
	)
	miss_chance += enemy_actor.get_evasion_bonus()
	if randf() < miss_chance:
		attack_missed.emit(enemy_actor)
		_log("...but missed!")
		await get_tree().create_timer(action_delay).timeout
		return
	# Laser ignores defense entirely
	var base: int = maxi(1, player_actor.se_attack + randi_range(-DMG_VARIANCE, DMG_VARIANCE))
	var crit: bool = randf() < CRIT_CHANCE * 1.5  # Higher crit chance for laser
	if crit:
		base = int(base * CRIT_MULTIPLIER)
	enemy_actor.take_damage(base)
	_emit_hit(enemy_actor, {"crit": crit, "amount": base})
	_log("Laser pierces through! %d damage!" % base)
	if crit:
		_log("Critical hit!")
	await get_tree().create_timer(action_delay).timeout

## SE Smoke: deploys smoke screen, boosts evasion
func _se_smoke_attack() -> void:
	var evasion_amount: float = float(player_actor.se_data.get("se_evasion_amount", 0.7))
	var evasion_duration: int = int(player_actor.se_data.get("se_evasion_duration", 3))
	player_actor.apply_status(BattleActor.STATUS_EVASION_UP, evasion_duration, evasion_amount)
	_log("Smoke screen deployed! Evasion +%.0f%% for %d turns!" % [evasion_amount * 100, evasion_duration])
	AudioManager.play_sfx("hit")
	await get_tree().create_timer(action_delay).timeout

## SE Repair: restores tank SP
func _se_repair_attack() -> void:
	var repair_amount: int = int(player_actor.se_data.get("se_repair_amount", 50))
	var actual: int = player_actor.repair_sp(repair_amount)
	_log("Repair drone active! Restored %d SP!" % actual)
	AudioManager.play_sfx("heal")
	healed.emit(player_actor, actual)
	await get_tree().create_timer(action_delay).timeout

## SE Earthquake: high damage + defense break debuff
func _se_earthquake_attack() -> void:
	var def_break: float = float(player_actor.se_data.get("se_defense_break", 0.4))
	var def_break_duration: int = int(player_actor.se_data.get("se_defense_break_duration", 2))
	var result := _compute_tank_damage(player_actor, enemy_actor, player_actor.se_attack)
	if not result.hit:
		attack_missed.emit(enemy_actor)
		_log("...but missed!")
	else:
		# Earthquake does 1.5x damage
		var amplified: int = int(result.amount * 1.5)
		enemy_actor.take_damage(amplified)
		_emit_hit(enemy_actor, {"crit": result.crit, "amount": amplified})
		_log("Earthquake strikes! %d damage!" % amplified)
		# Apply defense break
		enemy_actor.apply_status(BattleActor.STATUS_DEFENSE_DOWN, def_break_duration, def_break)
		_log("%s's defense is shattered!" % enemy_actor.name)
	await get_tree().create_timer(action_delay).timeout

## Computes tank damage with accuracy bonus from C-Unit
func _compute_tank_damage(attacker: BattleActor, defender: BattleActor, weapon_attack: int) -> Dictionary:
	# Tank accuracy is higher due to C-Unit
	var miss_chance: float = clampf(
		BASE_MISS_CHANCE + (defender.get_effective_speed() - attacker.get_effective_speed()) * MISS_SPEED_FACTOR,
		MISS_CHANCE_MIN, MISS_CHANCE_MAX
	)
	# C-Unit reduces miss chance
	miss_chance -= float(attacker.accuracy_bonus) * 0.005
	miss_chance = maxf(miss_chance, 0.01)
	miss_chance += defender.get_evasion_bonus()

	if randf() < miss_chance:
		return {"hit": false, "crit": false, "amount": 0}

	# Tank damage formula: weapon_attack - defender_defense + variance
	var base: int = maxi(1, weapon_attack - defender.get_effective_defense() + randi_range(-DMG_VARIANCE, DMG_VARIANCE))

	var crit: bool = randf() < CRIT_CHANCE
	if crit:
		base = int(base * CRIT_MULTIPLIER)

	return {"hit": true, "crit": crit, "amount": base}

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

	var item_name: String = item.get("name", "道具")
	var type: String = item.get("type", "")

	if type == "heal":
		var restore: int = int(item.get("hp_restore", 0))
		var healed_amount: int = player_actor.heal(restore)
		GameState.heal(healed_amount)
		AudioManager.play_sfx("heal")
		healed.emit(player_actor, healed_amount)
		_log("Used %s! Restored %d HP." % [item_name, healed_amount])
		_consume_item(item_id)
		await get_tree().create_timer(action_delay).timeout
	elif type == "escape":
		_log("Used %s!" % item_name)
		_consume_item(item_id)
		await get_tree().create_timer(turn_delay).timeout
		_enter_fled(true)
	elif type == "cure":
		# Cure status effects
		var cures: Array = item.get("cures", [])
		var cured_any: bool = false
		for status_id in cures:
			if player_actor.has_status(String(status_id)):
				player_actor.remove_status(String(status_id))
				cured_any = true
		if cured_any:
			_log("Used %s! Status effects cured!" % item_name)
		else:
			_log("Used %s, but nothing to cure." % item_name)
		_consume_item(item_id)
		await get_tree().create_timer(action_delay).timeout
	elif type == "buff":
		# Apply temporary buff
		var buff_type: String = String(item.get("buff", ""))
		var buff_amount: float = float(item.get("buff_amount", 0)) / 100.0
		var buff_duration: int = int(item.get("buff_duration", 3))
		match buff_type:
			"attack":
				player_actor.apply_status(BattleActor.STATUS_ATTACK_UP, buff_duration, buff_amount)
				_log("Used %s! Attack boosted by %d%%!" % [item_name, int(item.get("buff_amount", 0))])
			"defense":
				player_actor.apply_status(BattleActor.STATUS_DEFENSE_UP, buff_duration, buff_amount)
				_log("Used %s! Defense boosted by %d%%!" % [item_name, int(item.get("buff_amount", 0))])
			_:
				_log("Used %s, but nothing happened." % item_name)
		_consume_item(item_id)
		await get_tree().create_timer(action_delay).timeout
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

# --- Skill execution ---------------------------------------------------------

func _execute_skill(skill_id: String) -> void:
	if skill_id.is_empty() or not player_actor.skills.has(skill_id):
		_log("No usable skills!")
		await get_tree().create_timer(action_delay).timeout
		return
	if not GameState.can_use_skill(skill_id):
		_log("Skill is on cooldown!")
		await get_tree().create_timer(action_delay).timeout
		return

	var skill: Dictionary = DataLoader.get_skill(skill_id)
	if skill.is_empty():
		_log("Unknown skill!")
		await get_tree().create_timer(action_delay).timeout
		return

	var skill_name: String = String(skill.get("name", skill_id))
	var power_mult: float = float(skill.get("power_multiplier", 1.0))
	var hit_count: int = int(skill.get("hit_count", 1))
	var effect: String = String(skill.get("effect", ""))
	var cooldown: int = int(skill.get("cooldown", 1))

	AudioManager.play_sfx("skill")
	_log("%s uses %s!" % [player_actor.name, skill_name])
	GameState.use_skill(skill_id)
	await get_tree().create_timer(turn_delay).timeout

	match effect:
		"multi_hit":
			await _execute_multi_hit(player_actor, enemy_actor, power_mult, hit_count)
		"burst":
			await _execute_burst(player_actor, enemy_actor, power_mult)
		"debuff_defense":
			var debuff_amount: float = float(skill.get("debuff_amount", 0.5))
			var debuff_duration: int = int(skill.get("debuff_duration", 3))
			enemy_actor.apply_status(BattleActor.STATUS_DEFENSE_DOWN, debuff_duration, debuff_amount)
			_log("%s's defense reduced!" % enemy_actor.name)
			await get_tree().create_timer(action_delay).timeout
			# Also deal normal damage.
			await _execute_burst(player_actor, enemy_actor, 1.0)
		"buff_evasion":
			var buff_amount: float = float(skill.get("buff_amount", 0.5))
			var buff_duration: int = int(skill.get("buff_duration", 3))
			player_actor.apply_status(BattleActor.STATUS_EVASION_UP, buff_duration, buff_amount)
			_log("%s's evasion increased!" % player_actor.name)
			await get_tree().create_timer(action_delay).timeout
		"heal_self":
			var heal_percent: float = float(skill.get("heal_percent", 0.0))
			var heal_amount: int = int(player_actor.max_hp * heal_percent)
			var healed_amount: int = player_actor.heal(heal_amount)
			GameState.heal(healed_amount)
			healed.emit(player_actor, healed_amount)
			_log("%s recovered %d HP!" % [player_actor.name, healed_amount])
			await get_tree().create_timer(action_delay).timeout
		"poison_target":
			var poison_duration: int = int(skill.get("poison_duration", 3))
			enemy_actor.apply_status(BattleActor.STATUS_POISON, poison_duration)
			_log("%s is poisoned!" % enemy_actor.name)
			await get_tree().create_timer(action_delay).timeout
			# Also deal normal burst damage at power_mult.
			await _execute_burst(player_actor, enemy_actor, power_mult)
		"burn_target":
			var burn_duration: int = int(skill.get("burn_duration", 3))
			enemy_actor.apply_status(BattleActor.STATUS_BURN, burn_duration)
			_log("%s is burning!" % enemy_actor.name)
			await get_tree().create_timer(action_delay).timeout
			# Also deal normal burst damage at power_mult.
			await _execute_burst(player_actor, enemy_actor, power_mult)
		"buff_attack":
			var atk_buff_amount: float = float(skill.get("buff_amount", 0.5))
			var atk_buff_duration: int = int(skill.get("buff_duration", 3))
			player_actor.apply_status(BattleActor.STATUS_ATTACK_UP, atk_buff_duration, atk_buff_amount)
			_log("%s's attack increased!" % player_actor.name)
			await get_tree().create_timer(action_delay).timeout
		"buff_defense":
			var def_buff_amount: float = float(skill.get("buff_amount", 0.5))
			var def_buff_duration: int = int(skill.get("buff_duration", 3))
			player_actor.apply_status(BattleActor.STATUS_DEFENSE_UP, def_buff_duration, def_buff_amount)
			_log("%s's defense increased!" % player_actor.name)
			await get_tree().create_timer(action_delay).timeout
		"repair_sp":
			var repair_amount: int = int(skill.get("repair_amount", 30))
			var actual_repair: int = player_actor.repair_sp(repair_amount)
			_log("%s repaired %d SP!" % [player_actor.name, actual_repair])
			AudioManager.play_sfx("heal")
			healed.emit(player_actor, actual_repair)
			await get_tree().create_timer(action_delay).timeout
		_:
			await _execute_burst(player_actor, enemy_actor, power_mult)

	if not enemy_actor.is_alive():
		_enter_victory()

func _execute_multi_hit(attacker: BattleActor, defender: BattleActor, power_mult: float, hit_count: int) -> void:
	for i in range(hit_count):
		if not defender.is_alive():
			break
		var result := _compute_skill_damage(attacker, defender, power_mult)
		if not result.hit:
			attack_missed.emit(defender)
			_log("Hit %d: missed!" % (i + 1))
		else:
			defender.take_damage(result.amount)
			_emit_hit(defender, result)
			_log("Hit %d: %d damage." % [(i + 1), result.amount])
		await get_tree().create_timer(0.3).timeout
		if not defender.is_alive():
			break

func _execute_burst(attacker: BattleActor, defender: BattleActor, power_mult: float) -> void:
	var result := _compute_skill_damage(attacker, defender, power_mult)
	if not result.hit:
		attack_missed.emit(defender)
		_log("...but missed!")
	else:
		defender.take_damage(result.amount)
		_emit_hit(defender, result)
		_log_damage(defender, result.crit, result.amount)
	await get_tree().create_timer(action_delay).timeout

## Computes skill damage with a power multiplier applied to the base damage.
func _compute_skill_damage(attacker: BattleActor, defender: BattleActor, power_mult: float) -> Dictionary:
	var result := _compute_damage(attacker, defender)
	if result.hit:
		result.amount = int(result.amount * power_mult)
	return result

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

	# Enemy AI: randomly decide whether to use a skill (if available).
	# When wounded (HP below ENEMY_LOW_HP_RATIO), the enemy uses skills more
	# often and prioritises healing skills to stay alive.
	var use_skill: bool = false
	var skill_id: String = ""
	var low_hp: bool = enemy_actor.hp_ratio() < ENEMY_LOW_HP_RATIO
	var skill_chance: float = ENEMY_LOW_HP_SKILL_CHANCE if low_hp else ENEMY_SKILL_CHANCE
	if not enemy_actor.skills.is_empty() and randf() < skill_chance:
		if low_hp:
			# Prefer healing skills when HP is low.
			var healing_skills: Array[String] = []
			for sid in enemy_actor.skills:
				var sdata: Dictionary = DataLoader.get_skill(sid)
				if String(sdata.get("effect", "")) == "heal_self":
					healing_skills.append(sid)
			if not healing_skills.is_empty():
				skill_id = healing_skills[randi() % healing_skills.size()]
			else:
				skill_id = enemy_actor.skills[randi() % enemy_actor.skills.size()]
		else:
			skill_id = enemy_actor.skills[randi() % enemy_actor.skills.size()]
		use_skill = not skill_id.is_empty()

	if use_skill:
		var skill: Dictionary = DataLoader.get_skill(skill_id)
		if not skill.is_empty():
			var skill_name: String = String(skill.get("name", skill_id))
			var power_mult: float = float(skill.get("power_multiplier", 1.0))
			var hit_count: int = int(skill.get("hit_count", 1))
			var effect: String = String(skill.get("effect", ""))
			_log("%s uses %s!" % [enemy_actor.name, skill_name])
			await get_tree().create_timer(turn_delay).timeout

			if effect == "multi_hit":
				for i in range(hit_count):
					if not player_actor.is_alive():
						break
					var result := _compute_skill_damage(enemy_actor, player_actor, power_mult)
					if not result.hit:
						attack_missed.emit(player_actor)
						_log("Hit %d: missed!" % (i + 1))
					else:
						var amount: int = result.amount
						if player_actor.defending:
							amount = int(amount / 2.0)
						var actual: int = player_actor.take_damage(amount)
						GameState.take_damage(actual)
						_emit_hit(player_actor, {"crit": result.crit, "amount": actual})
						_log("Hit %d: %d damage." % [(i + 1), actual])
					await get_tree().create_timer(0.3).timeout
			elif effect == "debuff_defense":
				var debuff_amount: float = float(skill.get("debuff_amount", 0.5))
				var debuff_duration: int = int(skill.get("debuff_duration", 3))
				player_actor.apply_status(BattleActor.STATUS_DEFENSE_DOWN, debuff_duration, debuff_amount)
				_log("%s's defense reduced!" % player_actor.name)
				await get_tree().create_timer(action_delay).timeout
			elif effect == "heal_self":
				var heal_percent: float = float(skill.get("heal_percent", 0.0))
				var heal_amount: int = int(enemy_actor.max_hp * heal_percent)
				var healed_amount: int = enemy_actor.heal(heal_amount)
				healed.emit(enemy_actor, healed_amount)
				_log("%s recovered %d HP!" % [enemy_actor.name, healed_amount])
				await get_tree().create_timer(action_delay).timeout
			elif effect == "poison_target":
				var poison_duration: int = int(skill.get("poison_duration", 3))
				player_actor.apply_status(BattleActor.STATUS_POISON, poison_duration)
				_log("%s is poisoned!" % player_actor.name)
				await get_tree().create_timer(action_delay).timeout
				# Also deal normal burst damage at power_mult.
				var presult := _compute_skill_damage(enemy_actor, player_actor, power_mult)
				if not presult.hit:
					attack_missed.emit(player_actor)
					_log("...but missed!")
				else:
					var pamount: int = presult.amount
					if player_actor.defending:
						pamount = int(pamount / 2.0)
					var pactual: int = player_actor.take_damage(pamount)
					GameState.take_damage(pactual)
					_emit_hit(player_actor, {"crit": presult.crit, "amount": pactual})
					_log_damage(player_actor, presult.crit, pactual)
			elif effect == "burn_target":
				var burn_duration: int = int(skill.get("burn_duration", 3))
				player_actor.apply_status(BattleActor.STATUS_BURN, burn_duration)
				_log("%s is burning!" % player_actor.name)
				await get_tree().create_timer(action_delay).timeout
				# Also deal normal burst damage at power_mult.
				var bresult := _compute_skill_damage(enemy_actor, player_actor, power_mult)
				if not bresult.hit:
					attack_missed.emit(player_actor)
					_log("...but missed!")
				else:
					var bamount: int = bresult.amount
					if player_actor.defending:
						bamount = int(bamount / 2.0)
					var bactual: int = player_actor.take_damage(bamount)
					GameState.take_damage(bactual)
					_emit_hit(player_actor, {"crit": bresult.crit, "amount": bactual})
					_log_damage(player_actor, bresult.crit, bactual)
			elif effect == "buff_attack":
				var atk_buff_amount: float = float(skill.get("buff_amount", 0.5))
				var atk_buff_duration: int = int(skill.get("buff_duration", 3))
				enemy_actor.apply_status(BattleActor.STATUS_ATTACK_UP, atk_buff_duration, atk_buff_amount)
				_log("%s's attack increased!" % enemy_actor.name)
				await get_tree().create_timer(action_delay).timeout
			elif effect == "buff_defense":
				var def_buff_amount: float = float(skill.get("buff_amount", 0.5))
				var def_buff_duration: int = int(skill.get("buff_duration", 3))
				enemy_actor.apply_status(BattleActor.STATUS_DEFENSE_UP, def_buff_duration, def_buff_amount)
				_log("%s's defense increased!" % enemy_actor.name)
				await get_tree().create_timer(action_delay).timeout
			else:
				var result := _compute_skill_damage(enemy_actor, player_actor, power_mult)
				if not result.hit:
					attack_missed.emit(player_actor)
					_log("...but missed!")
				else:
					var amount: int = result.amount
					if player_actor.defending:
						amount = int(amount / 2.0)
					var actual: int = player_actor.take_damage(amount)
					GameState.take_damage(actual)
					_emit_hit(player_actor, {"crit": result.crit, "amount": actual})
					_log_damage(player_actor, result.crit, actual)
			await get_tree().create_timer(action_delay).timeout
			player_actor.defending = false
			if not player_actor.is_alive():
				_enter_defeat()
				return
			_begin_player_turn()
			return

	# Normal attack.
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
		AudioManager.play_sfx("hit")
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
	# Also add evasion bonus from status effects (e.g. smokescreen).
	var miss_chance: float = clampf(
		BASE_MISS_CHANCE + (defender.get_effective_speed() - attacker.get_effective_speed()) * MISS_SPEED_FACTOR,
		MISS_CHANCE_MIN, MISS_CHANCE_MAX
	)
	miss_chance += defender.get_evasion_bonus()
	if randf() < miss_chance:
		return {"hit": false, "crit": false, "amount": 0}

	# Core formula: atk - def +/- a small random variance, never below 1.
	# Uses effective stats (with status modifiers like defense_down).
	var base: int = maxi(1, attacker.get_effective_attack() - defender.get_effective_defense() + randi_range(-DMG_VARIANCE, DMG_VARIANCE))

	var crit: bool = randf() < CRIT_CHANCE
	if crit:
		base = int(base * CRIT_MULTIPLIER)

	return {"hit": true, "crit": crit, "amount": base}

## Flee success chance: 60% base, +/- 2% per point of speed difference.
func _flee_chance() -> float:
	return clampf(
		FLEE_BASE_CHANCE + (player_actor.get_effective_speed() - enemy_actor.get_effective_speed()) * FLEE_SPEED_FACTOR,
		FLEE_CHANCE_MIN, FLEE_CHANCE_MAX
	)

# --- End-of-battle transitions ----------------------------------------------

## Returns true if the player or any party member can still fight.
func _party_can_fight() -> bool:
	if player_actor.is_alive():
		return true
	for actor in party_actors:
		if actor.is_alive():
			return true
	return false

func _enter_victory() -> void:
	_set_state(State.VICTORY)
	AudioManager.play_bgm("victory_theme")
	AudioManager.play_sfx("victory")
	var exp_gained: int = int(enemy_data.get("exp", 0))
	var gold_gained: int = int(enemy_data.get("gold", 0))
	var is_bounty: bool = bool(enemy_data.get("is_bounty", false))
	var bounty_reward: int = int(enemy_data.get("bounty_reward", 0))
	if is_bounty:
		gold_gained += bounty_reward
		_log("BOUNTY target downed!")
	_log("Victory! Gained %d EXP and %d gold." % [exp_gained, gold_gained])
	# Sync party member HP back to GameState
	var active_party = GameState.get_active_party()
	for i in range(mini(party_actors.size(), active_party.size())):
		active_party[i]["hp"] = party_actors[i].hp
	# Sync tank state back to GameState
	if player_actor.is_tank_mode:
		GameState.tank_hp = player_actor.hp
		GameState.tank_sp = player_actor.sp
	victory.emit(exp_gained, gold_gained, is_bounty, bounty_reward)

func _enter_defeat() -> void:
	# If tank was destroyed, switch to infantry instead of full game over
	if player_actor.is_tank_mode and GameState.tank_owned:
		_log("Tank destroyed! Switching to infantry mode!")
		AudioManager.play_sfx("explosion")
		GameState.tank_hp = 1  # Tank barely survives
		GameState.battle_mode = "infantry"
		GameState.movement_mode = "infantry"
		# Recreate player as infantry
		player_actor = BattleActor.create_from_player()
		actors_ready.emit(player_actor, enemy_actor)
		_log("%s continues on foot!" % player_actor.name)
		await get_tree().create_timer(action_delay).timeout
		_begin_player_turn()
		return
	# Check if any party member is still standing
	if not player_actor.is_alive():
		for actor in party_actors:
			if actor.is_alive():
				# Swap to the party member as the active fighter
				_log("%s takes over!" % actor.name)
				player_actor = actor
				actors_ready.emit(player_actor, enemy_actor)
				await get_tree().create_timer(action_delay).timeout
				_begin_player_turn()
				return
	_set_state(State.DEFEAT)
	AudioManager.play_bgm("game_over_theme")
	AudioManager.play_sfx("defeat")
	_log("You have been defeated...")
	defeat.emit()

func _enter_fled(used_item: bool) -> void:
	_set_state(State.OUTRO)
	# Sync tank HP/SP back to GameState when fleeing in tank mode.
	if player_actor and player_actor.is_tank_mode:
		GameState.tank_hp = player_actor.hp
		GameState.tank_sp = player_actor.sp
	AudioManager.play_sfx("flee")
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
