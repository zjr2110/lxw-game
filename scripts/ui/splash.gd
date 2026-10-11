extends Control
## 开屏动画（只在冷启动播放）：底色上图标淡入并轻轻放大，停留片刻后整体淡出进入首页。
## 点屏幕任意处可跳过。设置里可以关掉开屏动画。

signal finished

const Ui = preload("res://scripts/ui_style.gd")
const ICON := preload("res://assets/icon.png")

var main = null

var _bg: ColorRect
var _icon: TextureRect
var _menu_shown := false
var _done := false
var _skipping := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_bg = ColorRect.new()
	_bg.color = Ui.BG
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	_icon = TextureRect.new()
	_icon.texture = ICON
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.modulate.a = 0.0
	add_child(_icon)
	await get_tree().process_frame
	var s := minf(size.x * 0.56, 420.0)
	_icon.size = Vector2(s, s)
	_icon.position = Vector2((size.x - s) * 0.5, size.y * 0.44 - s * 0.5)
	_icon.pivot_offset = _icon.size * 0.5
	_play()


func _gui_input(e: InputEvent) -> void:
	if (e is InputEventMouseButton or e is InputEventScreenTouch) and e.pressed:
		skip()
		accept_event()


func _play() -> void:
	_icon.scale = Vector2(0.92, 0.92)
	var tw := create_tween().set_parallel()
	tw.tween_property(_icon, "modulate:a", 1.0, 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(_icon, "scale", Vector2.ONE, 1.0).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await get_tree().create_timer(1.5).timeout
	if _skipping or _done:
		return
	_show_menu()
	var tw2 := create_tween()
	tw2.tween_property(self, "modulate:a", 0.0, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw2.finished
	_finish()


func _show_menu() -> void:
	if _menu_shown:
		return
	_menu_shown = true
	if main:
		main.goto("menu", "none")
		main.move_child(self, main.get_child_count() - 1)


func skip() -> void:
	if _skipping or _done:
		return
	_skipping = true
	_show_menu()
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.25)
	await tw.finished
	_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	finished.emit()
	# 稍后再释放：让还在等待计时器的动画协程先自然结束
	get_tree().create_timer(1.0).timeout.connect(queue_free)
