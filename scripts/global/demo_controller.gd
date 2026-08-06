## DemoController: Automated demo recorder.
## Drives the game through key scenes via direct API calls and captures screenshots.
## Activated by the project arg "--demo".
extends Node

const STEP_DELAY := 3.0  # seconds between actions (lets scenes fully render)

var _step := 0
var _timer := 0.0
var _active := false

func _ready() -> void:
        var args := OS.get_cmdline_args()
        for a in args:
                if a == "--demo":
                        _active = true
                        break
        if _active:
                print("DemoController: starting automated demo recording")
        process_mode = Node.PROCESS_MODE_ALWAYS

func _process(delta: float) -> void:
        if not _active:
                return
        _timer += delta
        if _timer < STEP_DELAY:
                return
        _timer = 0.0
        _advance_step()

func _advance_step() -> void:
        var tree := get_tree()
        var current := tree.current_scene
        var scene_name: String = current.name if current else "<none>"
        print("DemoController step %d | scene=%s" % [_step, scene_name])
        match _step:
                0:
                        # Title screen — already loaded as main scene
                        ScreenshotHelper.capture("01_title_screen")
                1:
                        # Enter the world (wasteland exploration)
                        GameState.change_scene("res://scenes/world.tscn")
                2:
                        ScreenshotHelper.capture("02_world_exploration")
                3:
                        # Enable tank ownership and switch to tank mode
                        GameState.tank_owned = true
                        GameState.tank_hp = GameState.tank_max_hp
                        GameState.tank_sp = GameState.tank_max_sp
                        var p := _get_player()
                        if p:
                                p.call("toggle_mode")
                4:
                        ScreenshotHelper.capture("03_tank_mode")
                5:
                        # Switch back to infantry mode for variety
                        var p2 := _get_player()
                        if p2:
                                p2.call("toggle_mode")
                6:
                        ScreenshotHelper.capture("04_world_infantry")
                7:
                        # Start a battle vs slime
                        GameState.start_battle("slime")
                8:
                        ScreenshotHelper.capture("05_battle_slime")
                9:
                        # Return to world, then battle a bandit
                        GameState.change_scene("res://scenes/world.tscn")
                10:
                        GameState.start_battle("bandit")
                11:
                        ScreenshotHelper.capture("06_battle_bandit")
                12:
                        # Return to world, then battle the boss (titan)
                        GameState.change_scene("res://scenes/world.tscn")
                13:
                        GameState.start_battle("titan")
                14:
                        ScreenshotHelper.capture("07_battle_boss")
                15:
                        # Return to world, open the world map
                        GameState.change_scene("res://scenes/world.tscn")
                16:
                        ScreenshotHelper.capture("08_world_aftermath")
                17:
                        # Load the shop scene
                        GameState.change_scene("res://scenes/shop.tscn")
                18:
                        ScreenshotHelper.capture("09_shop")
                19:
                        # Load the tank garage
                        GameState.change_scene("res://scenes/tank_garage.tscn")
                20:
                        ScreenshotHelper.capture("10_tank_garage")
                21:
                        # Load the bounty board
                        GameState.change_scene("res://scenes/bounty_board.tscn")
                22:
                        ScreenshotHelper.capture("11_bounty_board")
                23:
                        print("DemoController: demo sequence complete — %d screenshots captured" % (_step / 2 + 1))
                        _active = false
        _step += 1

func _get_player() -> Node:
        var tree := get_tree()
        var root := tree.current_scene
        if root:
                var p := root.get_node_or_null("Player")
                if p:
                        return p
        var players := tree.get_nodes_in_group("player")
        if players.size() > 0:
                return players[0]
        return null
