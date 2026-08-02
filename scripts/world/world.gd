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

	# Setup environment
	_setup_environment()

	# Spawn ground
	_setup_ground()

	# Spawn environment props
	_spawn_props()

	# Spawn NPCs
	_spawn_npcs()

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

	# Background — dark warm sky for post-apocalyptic mood
	env.background_mode = Environment.BG_GRADIENT
	var sky := Gradient.new()
	sky.add_point(0.0, Color(0.12, 0.08, 0.06))  # Top: dark brown
	sky.add_point(1.0, Color(0.25, 0.18, 0.12))  # Bottom: warm brown

	var gradient_tex := GradientTexture2D.new()
	gradient_tex.gradient = sky
	gradient_tex.fill = GradientTexture2D.FILL_LINEAR_VERTICAL
	# env.background_gradient = gradient_tex  # Not available in all versions, fallback:
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.10, 0.08)

	# Bloom — critical for HD-2D glow effect
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_strength = 1.0
	env.glow_bloom = 0.2
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE

	# Fog — atmospheric depth
	env.fog_enabled = true
	env.fog_light_color = Color(0.4, 0.3, 0.2)
	env.fog_light_energy = 0.3
	env.fog_density = 0.005

	# Ambient light
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.25, 0.2)
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
	mat.albedo_color = Color(0.35, 0.28, 0.20)  # Dry earth
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
	mat.albedo_color = Color(0.5, 0.4, 0.3)
	body.material_override = mat
	npc.add_child(body)

	# Add collision shape
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.6, 1.2, 0.4)
	col.shape = shape
	col.position = Vector3(0, 0.6, 0)
	npc.add_child(col)

	# Position NPCs around the map
	var angle := randf() * TAU
	npc.position = Vector3(cos(angle) * 5.0, 0, sin(angle) * 5.0)

	# Store dialogue ID for interaction
	npc.set_meta("dialogue_id", npc_id)
	npc.set_meta("npc_id", npc_id)

	# Add interact method via script attachment
	var npc_script := GDScript.new()
	npc_script.source_code = @"
extends CharacterBody3D

func interact() -> void:
	var dialogue_id = get_meta(\"dialogue_id\", \"\")
	if dialogue_id != \"\":
		get_parent().get_parent()._on_npc_interact(dialogue_id)
"
	npc.set_script(npc_script)

	return npc


func _on_npc_interact(dialogue_id: String) -> void:
	npc_interacted.emit(dialogue_id)
	# Show dialogue box — instantiate the dialogue scene
	var dialogue_scene := load("res://scenes/dialogue.tscn")
	if dialogue_scene:
		var dialogue_box := dialogue_scene.instantiate() as Control
		get_tree().current_scene.add_child(dialogue_box)
		if dialogue_box.has_method("start"):
			dialogue_box.start(dialogue_id)
		if dialogue_box.has_signal("dialogue_finished"):
			dialogue_box.dialogue_finished.connect(dialogue_box.queue_free)


func _on_player_steps(count: int) -> void:
	# Lightweight step tracking — actual encounter trigger is in player
	pass


func _on_player_steps_threshold() -> void:
	# Called by player when step threshold reached
	var zone: String = _map_data.get("encounter_zone", "")
	if zone.is_empty():
		return

	# Roll encounter
	var enemy_id := DataLoader.roll_encounter(zone)
	if not enemy_id.is_empty():
		encounter_triggered.emit(enemy_id)
		# Transition to battle
		GameState.start_battle(enemy_id)


func get_map_connections() -> Dictionary:
	return _map_data.get("connections", {})


func transition_to_map(direction: String) -> void:
	var connections := get_map_connections()
	var target_map: String = connections.get(direction, "")
	if not target_map.is_empty():
		GameState.current_map = target_map
		GameState.change_scene("res://scenes/world.tscn")
