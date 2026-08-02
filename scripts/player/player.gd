## Player: 4-directional movement controller for HD-2D world
extends CharacterBody3D

# --- Signals ---
signal steps_taken(count: int)
signal interaction_triggered(target: Node)
signal mode_changed(mode: String)
signal fuel_consumed(amount: int)

# --- Config ---
@export_group("Movement")
@export var move_speed: float = 5.0
@export var acceleration: float = 10.0
@export var friction: float = 12.0

@export_group("Tank Mode")
@export var tank_move_speed: float = 7.0
@export var fuel_per_step: int = 1
@export var fuel_consumption_interval: int = 5  # consume fuel every N steps

@export_group("Encounters")
@export var steps_until_encounter: int = 12
@export var encounter_variance: int = 8

@export_group("Sprite")
@export var sprite_size: float = 1.0

# --- Internal ---
var _direction: Vector2 = Vector2.ZERO  # Current input direction (x=right, y=down)
var _facing: int = 0  # 0=down, 1=left, 2=right, 3=up
var _step_counter: int = 0
var _encounter_threshold: int = 12
var _can_encounter: bool = true
var _sprite: AnimatedSprite3D
var _interaction_ray: RayCast3D
var _current_mode: String = "infantry"  # "infantry" or "tank"
var _fuel_step_counter: int = 0

# Sprite frame names per direction
const DIR_FRAMES = {
	0: "walk_down",
	1: "walk_left",
	2: "walk_right",
	3: "walk_up",
}
const IDLE_FRAMES = {
	0: "idle_down",
	1: "idle_left",
	2: "idle_right",
	3: "idle_up",
}


func _ready() -> void:
	_setup_sprite()
	_setup_interaction()
	_encounter_threshold = steps_until_encounter + randi() % encounter_variance
	# Sync mode with GameState
	_current_mode = GameState.battle_mode  # Use battle_mode as the source of truth
	if _current_mode == "tank" and GameState.tank_owned:
		move_speed = tank_move_speed


func _setup_sprite() -> void:
	# Find or create AnimatedSprite3D
	_sprite = get_node_or_null("AnimatedSprite3D")
	if not _sprite:
		_sprite = AnimatedSprite3D.new()
		_sprite.name = "AnimatedSprite3D"
		add_child(_sprite)
	_sprite.pixel_size = 0.015625  # 1px = 0.015625 world units (16px tile = 0.25 units)
	_sprite.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_sprite.no_depth_test = false
	_sprite.cast_shadow = false
	# Create placeholder animation frames if no sprite frames resource
	_create_placeholder_frames()


func _create_placeholder_frames() -> void:
	# If a SpriteFrames resource already exists, don't override
	if _sprite.sprite_frames != null:
		return
	var sf := SpriteFrames.new()
	for dir_idx in range(4):
		var dir_name = ["down", "left", "right", "up"][dir_idx]
		# Idle animation (1 frame)
		sf.add_animation("idle_%s" % dir_name)
		sf.add_frame("idle_%s" % dir_name, _make_placeholder_texture(Color(0.4, 0.5, 0.3)))
		# Walk animation (4 frames)
		sf.add_animation("walk_%s" % dir_name)
		for i in range(4):
			var shade := 0.3 + i * 0.15
			sf.add_frame("walk_%s" % dir_name, _make_placeholder_texture(Color(shade * 0.4, shade * 0.5, shade * 0.3)))
	_sprite.sprite_frames = sf
	_sprite.animation = "idle_down"
	_sprite.play("idle_down")


func _make_placeholder_texture(color: Color) -> ImageTexture:
	var img := Image.create(16, 24, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))  # Transparent
	# Draw a simple humanoid silhouette
	for y in range(24):
		for x in range(16):
			# Head (rows 0-6)
			if y < 7 and x > 5 and x < 11:
				img.set_pixel(x, y, Color(0.8, 0.6, 0.4, 1.0))
			# Body (rows 7-17)
			elif y >= 7 and y < 18 and x > 3 and x < 13:
				img.set_pixel(x, y, color)
			# Legs (rows 18-23)
			elif y >= 18 and ((x > 4 and x < 8) or (x > 8 and x < 12)):
				img.set_pixel(x, y, Color(0.2, 0.2, 0.3, 1.0))
	return ImageTexture.create_from_image(img)


func _setup_interaction() -> void:
	_interaction_ray = get_node_or_null("InteractionRay")
	if not _interaction_ray:
		_interaction_ray = RayCast3D.new()
		_interaction_ray.name = "InteractionRay"
		_interaction_ray.target_position = Vector3(0, 0, -1.5)
		_interaction_ray.collision_mask = 2  # Layer 2 = interactables
		add_child(_interaction_ray)


func _physics_process(delta: float) -> void:
	_read_input()

	if _direction != Vector2.ZERO:
		_apply_movement(delta)
		_update_facing()
		_play_walk_animation()
		_count_step()
	else:
		_apply_friction(delta)
		_play_idle_animation()

	move_and_slide()


func _read_input() -> void:
	var input_vec := Vector2.ZERO
	if Input.is_action_pressed("move_up"):
		input_vec.y -= 1
	if Input.is_action_pressed("move_down"):
		input_vec.y += 1
	if Input.is_action_pressed("move_left"):
		input_vec.x -= 1
	if Input.is_action_pressed("move_right"):
		input_vec.x += 1

	# Normalize diagonal movement
	if input_vec.length() > 1.0:
		input_vec = input_vec.normalized()

	_direction = input_vec


func _apply_movement(delta: float) -> void:
	# Convert 2D input to 3D velocity (x=right, z=down in world space)
	var target_vel := Vector3(_direction.x, 0, _direction.y) * move_speed
	velocity = velocity.lerp(target_vel, acceleration * delta)


func _apply_friction(delta: float) -> void:
	velocity = velocity.lerp(Vector3.ZERO, friction * delta)


func _update_facing() -> void:
	# Priority: horizontal > vertical (prevents flickering on diagonals)
	if absf(_direction.x) > absf(_direction.y):
		_facing = 1 if _direction.x < 0 else 2
	elif _direction.y != 0:
		_facing = 0 if _direction.y > 0 else 3


func _play_walk_animation() -> void:
	var anim := DIR_FRAMES.get(_facing, "walk_down")
	if _sprite.animation != anim:
		_sprite.play(anim)


func _play_idle_animation() -> void:
	if velocity.length() < 0.5:
		var anim := IDLE_FRAMES.get(_facing, "idle_down")
		if _sprite.animation != anim:
			_sprite.play(anim)


func _count_step() -> void:
	# Count steps based on distance traveled (not every physics frame)
	if not _can_encounter:
		return
	if velocity.length() < 1.0:
		return
	_step_counter += 1
	steps_taken.emit(_step_counter)

	if _step_counter >= _encounter_threshold:
		_trigger_encounter()

	# Fuel consumption in tank mode
	if _current_mode == "tank" and GameState.tank_owned:
		_fuel_step_counter += 1
		if _fuel_step_counter >= fuel_consumption_interval:
			_fuel_step_counter = 0
			GameState.consume_fuel(fuel_per_step)
			fuel_consumed.emit(fuel_per_step)
			# Auto-switch to infantry if out of fuel
			if GameState.tank_fuel <= 0:
				print("[Player] Tank out of fuel! Switching to infantry mode.")
				toggle_mode()


func _trigger_encounter() -> void:
	_step_counter = 0
	_encounter_threshold = steps_until_encounter + randi() % encounter_variance
	# Emit signal — World controller will handle the actual encounter roll
	interaction_triggered.emit(self)  # reuse for world to pick up
	# Direct call to world if parent has the method
	var world := get_parent()
	while world:
		if world.has_method("_on_player_steps_threshold"):
			world._on_player_steps_threshold()
			break
		world = world.get_parent()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		_try_interact()
	elif event.is_action_pressed("toggle_mode"):
		toggle_mode()


func _try_interact() -> void:
	_interaction_ray.force_raycast_update()
	if _interaction_ray.is_colliding():
		var collider := _interaction_ray.get_collider()
		if collider and collider.has_method("interact"):
			collider.interact()
			interaction_triggered.emit(collider)


func reset_step_counter() -> void:
	_step_counter = 0
	_encounter_threshold = steps_until_encounter + randi() % encounter_variance


func toggle_mode() -> void:
	if not GameState.tank_owned:
		print("[Player] You don't own a tank!")
		return
	if _current_mode == "infantry":
		_current_mode = "tank"
		move_speed = tank_move_speed
		# Change sprite color to indicate tank mode
		if _sprite:
			_sprite.modulate = Color(0.7, 0.7, 0.8, 1.0)
		print("[Player] Switched to TANK mode")
	else:
		_current_mode = "infantry"
		move_speed = 5.0
		if _sprite:
			_sprite.modulate = Color.WHITE
		print("[Player] Switched to INFANTRY mode")
	# Sync mode to GameState so battles use the correct combat mode.
	GameState.battle_mode = _current_mode
	GameState.set_movement_mode(_current_mode)
	mode_changed.emit(_current_mode)
	AudioManager.play_sfx("confirm")


func get_current_mode() -> String:
	return _current_mode
