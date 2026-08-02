## World: HD-2D world scene controller
## Manages map loading, environment, NPCs, and random encounters.
extends Node3D

# --- Signals ---
signal encounter_triggered(enemy_id: String)
signal npc_interacted(npc_id: String)

# --- Config ---
@export var map_id: String = "wasteland"
@export var encounter_check_interval: float = 0.5

# --- Internal ---
var _player: CharacterBody3D
var _player_camera: Camera3D
var _env: WorldEnvironment
var _sun: DirectionalLight3D
var _ground: MeshInstance3D
var _props: Node3D
var _npcs: Node3D
var _map_data: Dictionary
var _step_accumulator: float = 0.0


func _ready() -> void:
	# Cache node references
	_player = $Player
	_player_camera = $PlayerCamera
	_env = $WorldEnvironment
	_sun = $DirectionalLight3D
	_props = $Props
	_npcs = $NPCs

	# Load map data
	_map_data = DataLoader.get_map_data(map_id)
	if _map_data.is_empty():
		push_warning("[World] No map data for: %s, using defaults" % map_id)
		_map_data = {"name": "Wasteland", "encounter_zone": "wasteland"}

	# Play BGM track for this map.
	AudioManager.play_bgm(String(_map_data.get("bgm", "wasteland_theme")))

	# Setup environment
	_setup_environment()

	# Spawn ground
	_setup_ground()

	# Spawn environment props
	_spawn_props()

	# Spawn NPCs
	_spawn_npcs()

	# Spawn hidden treasure chests
	_spawn_treasures()

	# Spawn map transition zones at edges
	_spawn_transition_zones()

	# Connect player signals
	if _player:
		_player.steps_taken.connect(_on_player_steps)

	print("[World] Loaded map: %s (zone: %s)" % [_map_data.get("name", "Unknown"), _map_data.get("encounter_zone", "none")])


func _setup_environment() -> void:
	# Create or configure WorldEnvironment for HD-2D look
	if not _env:
		_env = WorldEnvironment.new()
		_env.name = "WorldEnvironment"
		add_child(_env)

	var env := Environment.new()

	# Use map-specific ambient color if available, otherwise default.
	var ambient_arr: Array = _map_data.get("ambient_color", [0.3, 0.25, 0.2])
	var ambient_col := Color(
		float(ambient_arr[0]) if ambient_arr.size() > 0 else 0.3,
		float(ambient_arr[1]) if ambient_arr.size() > 1 else 0.25,
		float(ambient_arr[2]) if ambient_arr.size() > 2 else 0.2
	)

	# Background — use ambient color for a cohesive mood per map.
	env.background_mode = Environment.BG_COLOR
	env.background_color = ambient_col.darkened(0.5)

	# Bloom — critical for HD-2D glow effect
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_strength = 1.0
	env.glow_bloom = 0.2
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE

	# Fog — atmospheric depth, tinted by map ambient color
	env.fog_enabled = true
	env.fog_light_color = ambient_col
	env.fog_light_energy = 0.3
	env.fog_density = 0.005

	# Ambient light
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient_col
	env.ambient_light_energy = 0.4

	# SSAO for subtle contact shadows
	env.ssao_enabled = true
	env.ssao_intensity = 1.5

	# Tone mapping
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0

	_env.environment = env

	# Configure sun light
	if _sun:
		_sun.light_color = Color(1.0, 0.85, 0.6)  # Warm sunlight
		_sun.light_energy = 1.5
		_sun.shadow_enabled = true
		_sun.rotation_degrees = Vector3(-45, 30, 0)


func _setup_ground() -> void:
	# Create ground plane with placeholder texture
	if not _ground:
		_ground = MeshInstance3D.new()
		_ground.name = "Ground"
		add_child(_ground)
		_ground.move_to_front()  # Behind everything

	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	plane.material = _create_ground_material()
	_ground.mesh = plane
	_ground.position = Vector3(0, 0, 0)


func _create_ground_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	# Use map-specific ground color if available.
	var ground_arr: Array = _map_data.get("ground_color", [0.35, 0.28, 0.20])
	var ground_col := Color(
		float(ground_arr[0]) if ground_arr.size() > 0 else 0.35,
		float(ground_arr[1]) if ground_arr.size() > 1 else 0.28,
		float(ground_arr[2]) if ground_arr.size() > 2 else 0.20
	)
	mat.albedo_color = ground_col
	mat.roughness = 0.9
	mat.metallic = 0.0
	# Generate procedural texture for ground detail
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in range(64):
		for x in range(64):
			var noise_val := randf() * 0.15
			var c := Color(0.35 + noise_val, 0.28 + noise_val * 0.8, 0.20 + noise_val * 0.6)
			img.set_pixel(x, y, c)
	var tex := ImageTexture.create_from_image(img)
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return mat


func _spawn_props() -> void:
	if not _props:
		_props = Node3D.new()
		_props.name = "Props"
		add_child(_props)

	# Spawn random rocks, dead trees, ruins as simple meshes
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(map_id)  # Deterministic per map

	var prop_count := 15
	for i in range(prop_count):
		var x := rng.randf_range(-25, 25)
		var z := rng.randf_range(-25, 25)
		# Avoid spawning too close to center (player spawn)
		if Vector2(x, z).length() < 3.0:
			continue

		var prop_type := rng.randi() % 3
		match prop_type:
			0:  # Rock
				_spawn_rock(Vector3(x, 0, z), rng)
			1:  # Dead tree
				_spawn_dead_tree(Vector3(x, 0, z), rng)
			2:  # Ruin block
				_spawn_ruin_block(Vector3(x, 0, z), rng)


func _spawn_rock(pos: Vector3, rng: RandomNumberGenerator) -> void:
	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	var s := rng.randf_range(0.3, 0.8)
	box.size = Vector3(s, s * 0.6, s)
	mesh_inst.mesh = box
	mesh_inst.position = pos + Vector3(0, s * 0.3, 0)
	mesh_inst.rotation_degrees.y = rng.randf_range(0, 360)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.38, 0.35)
	mat.roughness = 0.95
	mesh_inst.material_override = mat
	_props.add_child(mesh_inst)


func _spawn_dead_tree(pos: Vector3, rng: RandomNumberGenerator) -> void:
	var mesh_inst := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	var h := rng.randf_range(1.5, 3.0)
	cyl.height = h
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.15
	mesh_inst.mesh = cyl
	mesh_inst.position = pos + Vector3(0, h / 2.0, 0)
	mesh_inst.rotation_degrees = Vector3(rng.randf_range(-5, 5), rng.randf_range(0, 360), rng.randf_range(-5, 5))

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.18, 0.12)
	mat.roughness = 1.0
	mesh_inst.material_override = mat
	_props.add_child(mesh_inst)


func _spawn_ruin_block(pos: Vector3, rng: RandomNumberGenerator) -> void:
	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	var w := rng.randf_range(0.5, 1.5)
	var h := rng.randf_range(0.3, 1.2)
	var d := rng.randf_range(0.5, 1.5)
	box.size = Vector3(w, h, d)
	mesh_inst.mesh = box
	mesh_inst.position = pos + Vector3(0, h / 2.0, 0)
	mesh_inst.rotation_degrees.y = rng.randf_range(0, 360)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.42, 0.38)
	mat.roughness = 0.85
	mesh_inst.material_override = mat
	_props.add_child(mesh_inst)


func _spawn_npcs() -> void:
	if not _npcs:
		_npcs = Node3D.new()
		_npcs.name = "NPCs"
		add_child(_npcs)

	var npc_ids: Array = _map_data.get("npcs", [])
	for npc_id in npc_ids:
		var npc := _create_npc(npc_id)
		if npc:
			_npcs.add_child(npc)


## Spawns hidden treasure chest NPCs for every entry in the map's "treasures"
## array. Chests reuse the standard NPC factory so they get the gold color and
## "[TREASURE]" label automatically via _get_npc_type/_get_npc_color/_get_npc_label.
func _spawn_treasures() -> void:
	if not _npcs:
		_npcs = Node3D.new()
		_npcs.name = "NPCs"
		add_child(_npcs)

	# Read the map's treasure list and spawn a chest NPC for each.
	var treasure_ids: Array = _map_data.get("treasures", [])
	for treasure_id in treasure_ids:
		var t_id := String(treasure_id)
		var treasure_npc := _create_npc(t_id)
		if treasure_npc:
			_npcs.add_child(treasure_npc)


func _create_npc(npc_id: String) -> Node3D:
	var npc := CharacterBody3D.new()
	npc.name = "NPC_%s" % npc_id
	npc.collision_layer = 2  # Interactable layer

	# Add a simple body mesh
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 1.2, 0.4)
	body.mesh = box
	body.position = Vector3(0, 0.6, 0)
	var mat := StandardMaterial3D.new()
	# Color-code NPCs by type for visual feedback.
	mat.albedo_color = _get_npc_color(npc_id)
	body.material_override = mat
	npc.add_child(body)

	# Add a floating label above the NPC.
	var label := Label3D.new()
	label.text = _get_npc_label(npc_id)
	label.position = Vector3(0, 1.8, 0)
	label.font_size = 24
	label.outline_size = 8
	label.outline_modulate = Color.BLACK
	label.modulate = Color(1.0, 0.92, 0.23)
	npc.add_child(label)

	# Add collision shape
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.6, 1.2, 0.4)
	col.shape = shape
	col.position = Vector3(0, 0.6, 0)
	npc.add_child(col)

	# Position NPCs around the map (deterministic per npc_id).
	var angle := float(hash(npc_id)) * TAU / 4294967296.0
	var radius := 5.0 + float(hash(npc_id + "_r") % 100) / 100.0 * 3.0
	npc.position = Vector3(cos(angle) * radius, 0, sin(angle) * radius)

	# Store metadata for interaction.
	npc.set_meta("npc_id", npc_id)
	npc.set_meta("interaction_type", _get_npc_type(npc_id))

	# Add interact method via script attachment.
	var npc_script := GDScript.new()
	npc_script.source_code = @"
extends CharacterBody3D

func interact() -> void:
	var npc_id = get_meta(\"npc_id\", \"\")
	var interaction_type = get_meta(\"interaction_type\", \"dialogue\")
	var world = get_parent().get_parent()
	if world.has_method(\"_on_npc_interact\"):
		world._on_npc_interact(npc_id, interaction_type)
"
	npc.set_script(npc_script)

	return npc


func _get_npc_type(npc_id: String) -> String:
	# Hidden treasure chests use IDs prefixed with "treasure_".
	if npc_id.begins_with("treasure_"):
		return "treasure"
	# Determine interaction type based on npc_id.
	if npc_id.find("shop") >= 0 or npc_id.find("merchant") >= 0 or npc_id.find("ruins_npc") >= 0 or npc_id.find("desert_npc") >= 0:
		return "shop"
	elif npc_id == "bounty_board":
		return "quest"
	elif npc_id == "save_point":
		return "save"
	elif npc_id == "inn":
		return "inn"
	elif npc_id == "healer_npc":
		return "heal"
	elif npc_id == "tank_depot":
		return "tank_depot"
	else:
		return "dialogue"


func _get_npc_color(npc_id: String) -> Color:
	var npc_type := _get_npc_type(npc_id)
	match npc_type:
		"shop": return Color(0.3, 0.6, 0.3)  # Green for shops
		"quest": return Color(0.9, 0.8, 0.2)  # Gold for quests
		"save": return Color(0.3, 0.5, 0.9)  # Blue for save
		"inn": return Color(0.8, 0.5, 0.3)  # Orange for inn
		"heal": return Color(0.9, 0.3, 0.3)  # Red for healer
		"tank_depot": return Color(0.5, 0.5, 0.6)  # Gray for tank
		"treasure": return Color(1.0, 0.84, 0.0)  # Gold for treasure chests
		_: return Color(0.5, 0.4, 0.3)


func _get_npc_label(npc_id: String) -> String:
	var npc_type := _get_npc_type(npc_id)
	match npc_type:
		"shop": return "[SHOP]"
		"quest": return "[BOUNTY]"
		"save": return "[SAVE]"
		"inn": return "[INN]"
		"heal": return "[HEAL]"
		"tank_depot": return "[TANK DEPOT]"
		"treasure": return "[TREASURE]"
		_: return "[TALK]"


func _on_npc_interact(npc_id: String, interaction_type: String = "dialogue") -> void:
	npc_interacted.emit(npc_id)
	match interaction_type:
		"shop":
			_open_shop(npc_id)
		"quest":
			_open_quest_board()
		"save":
			AudioManager.play_sfx("save")
			_save_game()
		"inn":
			_rest_at_inn()
		"heal":
			_heal_player()
		"tank_depot":
			_recover_tank()
		"treasure":
			_open_treasure(npc_id)
		_:
			_show_dialogue(npc_id)


func _open_shop(npc_id: String) -> void:
	# Determine which shop to open based on the current map.
	var shop_id: String = String(_map_data.get("shop_id", ""))
	if shop_id.is_empty():
		# Fallback: try to match by npc_id.
		shop_id = npc_id.replace("_npc", "_shop")
	var shop_data: Dictionary = DataLoader.get_shop(shop_id)
	if shop_data.is_empty():
		print("[World] No shop found for: %s" % shop_id)
		return
	# Store the shop_id in flags so the shop scene knows which to load.
	GameState.flags["shop_id"] = shop_id
	GameState.flags["shop_back_scene"] = "res://scenes/world.tscn"
	GameState.change_scene("res://scenes/shop.tscn")


func _open_quest_board() -> void:
	# Instantiate the quest UI overlay.
	var quest_scene := load("res://scenes/quest_ui.tscn")
	if quest_scene:
		var quest_ui := quest_scene.instantiate() as Control
		add_child(quest_ui)
		if quest_ui.has_method("open"):
			quest_ui.open()
		if quest_ui.has_signal("quest_ui_closed"):
			quest_ui.quest_ui_closed.connect(quest_ui.queue_free)


func _save_game() -> void:
	GameState.save_game(0)
	print("[World] Game saved!")


func _rest_at_inn() -> void:
	var cost: int = 50
	if GameState.gold < cost:
		print("[World] Not enough gold to rest! (need %d G)" % cost)
		return
	GameState.spend_gold(cost)
	GameState.heal(GameState.player_max_hp)
	AudioManager.play_sfx("heal")
	if GameState.tank_owned:
		GameState.heal_tank(GameState.tank_max_hp)
		GameState.repair_tank(GameState.tank_max_sp)
		GameState.refuel(GameState.tank_max_fuel)
	print("[World] Rested at the inn. Full HP restored!")


func _heal_player() -> void:
	GameState.heal(GameState.player_max_hp)
	AudioManager.play_sfx("heal")
	print("[World] HP fully restored by the healer!")


func _recover_tank() -> void:
	if not GameState.tank_owned:
		print("[World] You don't own a tank yet!")
		return
	GameState.heal_tank(GameState.tank_max_hp)
	GameState.repair_tank(GameState.tank_max_sp)
	GameState.refuel(GameState.tank_max_fuel)
	print("[World] Tank fully repaired and refueled!")
	# Also give a free chassis if the player doesn't have one.
	var has_chassis: bool = GameState.tank_parts.get("chassis") != null and not String(GameState.tank_parts.get("chassis")).is_empty()
	if not has_chassis:
		GameState.tank_parts["chassis"] = "tank_chassis_basic"
		GameState.tank_owned = true
		print("[World] Recovered a tank chassis from the depot!")


func _show_dialogue(dialogue_id: String) -> void:
	# Show dialogue box — instantiate the dialogue scene.
	var dialogue_scene := load("res://scenes/dialogue.tscn")
	if dialogue_scene:
		var dialogue_box := dialogue_scene.instantiate() as Control
		get_tree().current_scene.add_child(dialogue_box)
		if dialogue_box.has_method("start"):
			dialogue_box.start(dialogue_id)
		if dialogue_box.has_signal("dialogue_finished"):
			dialogue_box.dialogue_finished.connect(dialogue_box.queue_free)


## Opens a hidden treasure chest. Each chest can only be looted once: the
## collected state is persisted in GameState.flags under "treasure_collected_<id>".
## Reward: 100-500 gold, with a 30% chance to also grant a random item.
func _open_treasure(treasure_id: String) -> void:
	var flag_key := "treasure_collected_" + treasure_id
	# Already collected -> the chest is empty.
	if bool(GameState.flags.get(flag_key, false)):
		print("This chest is empty.")
		return

	# Random gold reward (100-500).
	var gold_reward := randi_range(100, 500)
	GameState.gold += gold_reward
	GameState.gold_changed.emit(GameState.gold)

	# 30% chance to also grant a random item from a pool.
	var item_pool := [
		"potion_small", "potion_medium", "potion_large",
		"antidote", "smoke_bomb", "fuel_can",
		"repair_kit", "energy_cell", "armor_plate"
	]
	if randf() < 0.30:
		var item_id: String = String(item_pool[randi() % item_pool.size()])
		GameState.inventory[item_id] = int(GameState.inventory.get(item_id, 0)) + 1
		print("[Treasure] %s opened! Found %d G and a %s!" % [treasure_id, gold_reward, item_id])
	else:
		print("[Treasure] %s opened! Found %d G!" % [treasure_id, gold_reward])

	# Mark the treasure as collected so it can't be looted again.
	GameState.flags[flag_key] = true

	# Play the coin sound effect.
	AudioManager.play_sfx("coin")

	# Remove the treasure chest NPC from the scene.
	var treasure_npc := _find_npc_by_id(treasure_id)
	if treasure_npc:
		treasure_npc.queue_free()


## Finds an NPC node currently in the scene by its stored npc_id meta.
func _find_npc_by_id(npc_id: String) -> Node3D:
	if not _npcs:
		return null
	for child in _npcs.get_children():
		if child is CharacterBody3D and String(child.get_meta("npc_id", "")) == npc_id:
			return child
	return null


func _on_player_steps(count: int) -> void:
	# Lightweight step tracking — actual encounter trigger is in player
	pass


func _on_player_steps_threshold() -> void:
	# Skip encounters in towns or maps marked no_encounters.
	if bool(_map_data.get("no_encounters", false)):
		return
	var zone: String = _map_data.get("encounter_zone", "")
	if zone.is_empty():
		return

	# Roll encounter
	var enemy_id := DataLoader.roll_encounter(zone)
	if not enemy_id.is_empty():
		encounter_triggered.emit(enemy_id)
		# Transition to battle
		GameState.start_battle(enemy_id)


func _spawn_transition_zones() -> void:
	# Create Area3D triggers at map edges for each connection direction.
	var connections: Dictionary = _map_data.get("connections", {})
	if connections.is_empty():
		return
	for direction in connections:
		var zone := Area3D.new()
		zone.name = "Transition_%s" % String(direction)
		zone.collision_layer = 4  # Layer 3 = triggers
		zone.collision_mask = 1  # Detect player (layer 1)
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(2, 3, 2)
		col.shape = shape
		zone.add_child(col)
		# Position at map edge based on direction.
		var edge_pos := _get_edge_position(String(direction))
		zone.position = edge_pos
		# Store the target direction as metadata.
		zone.set_meta("direction", String(direction))
		# Connect body_entered signal.
		zone.body_entered.connect(_on_transition_zone_entered.bind(zone))
		add_child(zone)


func _get_edge_position(direction: String) -> Vector3:
	var edge: float = 27.0  # Near the edge of the 60x60 ground plane.
	match direction:
		"north": return Vector3(0, 0, -edge)
		"south": return Vector3(0, 0, edge)
		"east": return Vector3(edge, 0, 0)
		"west": return Vector3(-edge, 0, 0)
		"up", "down": return Vector3(0, 0, 0)  # Portal at center for vertical transitions
		_: return Vector3(edge, 0, 0)


func _on_transition_zone_entered(body: Node, zone: Area3D) -> void:
	if body is CharacterBody3D and body.name == "Player":
		var direction: String = String(zone.get_meta("direction", ""))
		if not direction.is_empty():
			print("[World] Transitioning to map: %s" % direction)
			transition_to_map(direction)


func get_map_connections() -> Dictionary:
	return _map_data.get("connections", {})


func transition_to_map(direction: String) -> void:
	var connections := get_map_connections()
	var target_map: String = connections.get(direction, "")
	if not target_map.is_empty():
		AudioManager.play_sfx("door")
		GameState.current_map = target_map
		GameState.change_scene("res://scenes/world.tscn")
