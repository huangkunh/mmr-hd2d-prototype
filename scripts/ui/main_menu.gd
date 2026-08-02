## MainMenu: Title screen controller
extends Control

@onready var press_start: Label = $TitleContainer/PressStart
@onready var blink_timer: Timer = $TitleContainer/PressStart/BlinkTimer
@onready var title: Label = $TitleContainer/Title


func _ready() -> void:
	blink_timer.timeout.connect(_on_blink)


func _on_blink() -> void:
	press_start.visible = not press_start.visible


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("confirm"):
		_start_game()
	elif event.is_action_pressed("cancel"):
		get_tree().quit()


func _start_game() -> void:
	# Check if save exists
	if GameState.has_save():
		# Could show load/new choice, for prototype just start new
		pass
	GameState.change_scene("res://scenes/world.tscn")
