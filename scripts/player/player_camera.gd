## PlayerCamera: Orthographic HD-2D camera with DOF and smooth follow
extends Camera3D

# --- Config ---
@export_group("Follow")
@export var target_path: NodePath = ^"../Player"
@export var follow_speed: float = 5.0
@export var offset: Vector3 = Vector3(0, 8, 8)

@export_group("HD-2D Rendering")
@export var ortho_size: float = 8.0
@export var tilt_angle: float = 35.0  # degrees, camera pitch

@export_group("Depth of Field")
@export var dof_enabled: bool = true
@export var dof_blur_near: float = 2.0
@export var dof_blur_far: float = 15.0
@export var dof_amount: float = 0.3

# --- Internal ---
var _target: Node3D


func _ready() -> void:
	# Configure orthographic projection for HD-2D look
	projection = Camera3D.PROJECTION_ORTHOGONAL
	size = ortho_size
	near = 0.1
	far = 100.0

	# Apply tilt angle (pitch down for top-down-ish perspective)
	rotation_degrees.x = -tilt_angle

	# Setup DOF via CameraAttributes
	_setup_dof()

	# Resolve target
	if not target_path.is_empty():
		_target = get_node_or_null(target_path)


func _setup_dof() -> void:
	var attrs := CameraAttributesPractical.new()
	attrs.auto_exposure_enabled = false

	if dof_enabled:
		attrs.dof_blur_far_enabled = true
		attrs.dof_blur_far_distance = dof_blur_far
		attrs.dof_blur_far_transition = 3.0
		attrs.dof_blur_far_amount = dof_amount

		attrs.dof_blur_near_enabled = false  # Near blur rarely needed for HD-2D

	camera_attributes = attrs


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_target):
		# Try to re-resolve
		_target = get_node_or_null(target_path)
		if not _target:
			return

	# Smooth follow with lerp
	var target_pos := _target.global_position + offset
	global_position = global_position.lerp(target_pos, follow_speed * delta)

	# Always look at the player
	look_at(_target.global_position, Vector3.UP)
