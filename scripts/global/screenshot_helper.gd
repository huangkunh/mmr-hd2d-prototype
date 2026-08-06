## ScreenshotHelper: 截取视口画面保存为 PNG，用于文档/演示。
## 触发方式：F12 手动截图、capture(name) 脚本调用、或命令行参数 --shot <名称> 自动截图。
extends Node

const ABS_SCREENSHOT_DIR := "/home/z/my-project/screenshots/"

var _capture_queue: Array[String] = []
var _frame_delay := 0
var _auto_shot_name := ""
var _auto_shot_timer := 0.0
var _auto_shot_delay := 2.5  # 场景加载后等待秒数再截图
var _opened := false

func _ready() -> void:
        DirAccess.make_dir_recursive_absolute(ABS_SCREENSHOT_DIR)
        process_mode = Node.PROCESS_MODE_ALWAYS
        var args := OS.get_cmdline_args()
        for i in range(args.size()):
                if args[i] == "--shot" and i + 1 < args.size():
                        _auto_shot_name = args[i + 1]
                        print("ScreenshotHelper: 自动截图模式，%2.1f秒后截取 '%s'" % [_auto_shot_delay, _auto_shot_name])

func _unhandled_input(event: InputEvent) -> void:
        if event is InputEventKey and event.pressed and not event.echo:
                if event.keycode == KEY_F12:
                        capture("manual_%d" % Time.get_ticks_msec())

func capture(name: String) -> void:
        _capture_queue.append(name)

func _process(delta: float) -> void:
        if _auto_shot_name != "":
                _auto_shot_timer += delta
                # 在截图前0.8秒，尝试调用场景的 open() 方法（UI场景默认隐藏）
                if not _opened and _auto_shot_timer >= _auto_shot_delay - 0.8:
                        _try_open_scene()
                        _opened = true
                if _auto_shot_timer >= _auto_shot_delay:
                        capture(_auto_shot_name)
                        _auto_shot_name = ""
        if _capture_queue.size() > 0:
                _frame_delay += 1
                if _frame_delay >= 3:
                        _frame_delay = 0
                        var name: String = _capture_queue.pop_front()
                        _do_capture(name)

func _try_open_scene() -> void:
        var scene := get_tree().current_scene
        if not scene:
                return
        if scene.has_method("open"):
                scene.open()
                print("ScreenshotHelper: 已调用 open() 显示场景UI")
        elif scene.has_method("start"):
                scene.start("intro_npc")
                print("ScreenshotHelper: 已调用 start() 显示对话UI")

func _do_capture(name: String) -> void:
        var img := get_viewport().get_texture().get_image()
        if img == null:
                push_warning("ScreenshotHelper: 视口图像为空")
                return
        var path := ABS_SCREENSHOT_DIR + name + ".png"
        var err := img.save_png(path)
        if err == OK:
                print("ScreenshotHelper: 已保存 ", path)
        else:
                push_warning("ScreenshotHelper: 保存失败 %s (err=%d)" % [path, err])
