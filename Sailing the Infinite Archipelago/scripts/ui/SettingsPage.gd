class_name SettingsPage
extends MenuPage
## Settings, shared by the title screen and the pause menu.
##
## Every change applies at once and is saved when the page closes. Interface
## size applies when a slider drag ends, so the page does not rescale under the
## pointer mid-drag. Clicking anywhere on a line works its control.

const SLOT_WIDTH := 230.0

var _scale_slider: HSlider
var _look_slider: HSlider
var _invert_switch: Switch
var _fullscreen_switch: Switch
var _dragging_scale := false


func _init() -> void:
	heading = "SETTINGS"


func _build_body() -> void:
	GameSettings.ensure_loaded()
	body.custom_minimum_size.x = 640.0

	var scale_row := _slider_row("Interface size", "Scales every panel, menu and page",
		80.0, 130.0, 5.0, GameSettings.interface_scale * 100.0)
	_scale_slider = scale_row[0]
	var scale_value: Label = scale_row[1]
	_scale_slider.drag_started.connect(func() -> void: _dragging_scale = true)
	_scale_slider.drag_ended.connect(func(_changed: bool) -> void:
		_dragging_scale = false
		_apply_scale())
	_scale_slider.value_changed.connect(func(v: float) -> void:
		scale_value.text = "%d%%" % roundi(v)
		if not _dragging_scale:
			_apply_scale())

	var look_row := _slider_row("Look speed", "How fast dragging turns the camera",
		40.0, 200.0, 10.0, GameSettings.look_speed * 100.0)
	_look_slider = look_row[0]
	var look_value: Label = look_row[1]
	_look_slider.value_changed.connect(func(v: float) -> void:
		look_value.text = "%d%%" % roundi(v)
		GameSettings.look_speed = v / 100.0)

	_invert_switch = _switch_row("Invert vertical look", "Drag up to look down", GameSettings.invert_look_y)
	_invert_switch.toggled.connect(func(on: bool) -> void:
		GameSettings.invert_look_y = on)

	_fullscreen_switch = _switch_row("Fullscreen", "Fill the whole display", GameSettings.fullscreen, false)
	_fullscreen_switch.toggled.connect(func(on: bool) -> void:
		GameSettings.fullscreen = on
		GameSettings.apply(get_tree()))


func _first_focus() -> Control:
	return _scale_slider


func _focus_chain() -> Array[Control]:
	return [_scale_slider, _look_slider, _invert_switch, _fullscreen_switch]


func _on_close() -> void:
	GameSettings.save()


func _apply_scale() -> void:
	GameSettings.interface_scale = _scale_slider.value / 100.0
	GameSettings.apply(get_tree())


## The name and a one-line note on the left, the control in a fixed slot, and
## its value at the right edge. Returns [row, value label, slot].
func _line(title: String, note: String, ruled: bool) -> Array:
	var row := MenuPage.Row.new()
	row.ruled = ruled
	var line := CozyHUD.make_hbox(18)
	row.add_child(line)
	var words := CozyHUD.make_vbox(1)
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	words.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	words.add_child(CozyHUD.make_label(title, &"PageRow"))
	words.add_child(CozyHUD.make_label(note, &"PageNote"))
	line.add_child(words)
	var slot := CozyHUD.make_hbox(0)
	slot.alignment = BoxContainer.ALIGNMENT_END
	slot.custom_minimum_size.x = SLOT_WIDTH
	slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(slot)
	var value := CozyHUD.make_label("", &"PageValue")
	value.custom_minimum_size.x = 48.0
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(value)
	add_row(row)
	return [row, value, slot]


## [slider, value label]
func _slider_row(title: String, note: String, lo: float, hi: float, step: float, value: float) -> Array:
	var parts := _line(title, note, true)
	var row: MenuPage.Row = parts[0]
	var value_label: Label = parts[1]
	var slider := HSlider.new()
	slider.theme_type_variation = &"PageSlider"
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size.y = 24.0
	slider.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	(parts[2] as HBoxContainer).add_child(slider)
	value_label.text = "%d%%" % roundi(value)
	row.activate = slider.grab_focus
	return [slider, value_label]


func _switch_row(title: String, note: String, on: bool, ruled := true) -> Switch:
	var parts := _line(title, note, ruled)
	var row: MenuPage.Row = parts[0]
	var value_label: Label = parts[1]
	var sw := Switch.new()
	sw.set_pressed_no_signal(on)
	(parts[2] as HBoxContainer).add_child(sw)
	var show_state := func(state: bool) -> void:
		value_label.text = "On" if state else "Off"
		value_label.theme_type_variation = &"PageValue" if state else &"PageValueOff"
	show_state.call(on)
	sw.toggled.connect(show_state)
	row.activate = func() -> void:
		sw.grab_focus()
		sw.button_pressed = not sw.button_pressed
	return sw


## An on/off switch inked on the haze: a pill groove that fills ember, and a
## cream thumb that springs across.
class Switch extends Button:
	const W := 48.0
	const H := 26.0
	var _knob := 0.0:
		set(v):
			_knob = v
			queue_redraw()
	var _track := StyleBoxFlat.new()
	var _ring := StyleBoxFlat.new()

	func _init() -> void:
		toggle_mode = true
		focus_mode = Control.FOCUS_ALL
		custom_minimum_size = Vector2(W, H)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var empty := StyleBoxEmpty.new()
		for state: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled", &"focus"]:
			add_theme_stylebox_override(state, empty)
		_track.set_corner_radius_all(int(H * 0.5))
		_track.anti_aliasing = true
		_track.corner_detail = 10
		_track.set_border_width_all(1)
		_ring.draw_center = false
		_ring.set_corner_radius_all(int(H * 0.5) + 4)
		_ring.set_border_width_all(2)
		_ring.border_color = CozyHUD.EMBER
		_ring.anti_aliasing = true
		toggled.connect(func(on: bool) -> void: UiMotion.spring(self, ^"_knob", 1.0 if on else 0.0, 0.6))
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)
		mouse_entered.connect(queue_redraw)
		mouse_exited.connect(queue_redraw)

	func _ready() -> void:
		_knob = 1.0 if button_pressed else 0.0

	func _draw() -> void:
		var rect := Rect2(Vector2(size.x - W, (size.y - H) * 0.5), Vector2(W, H))
		var off := Color(CozyHUD.INK_TEXT, 0.16 if is_hovered() else 0.1)
		_track.bg_color = off.lerp(CozyHUD.EMBER, _knob)
		_track.border_color = Color(CozyHUD.INK_TEXT, 0.3).lerp(CozyHUD.EMBER, _knob)
		draw_style_box(_track, rect)
		var r := H * 0.5 - 3.5
		var x := lerpf(rect.position.x + 3.5 + r, rect.end.x - 3.5 - r, _knob)
		draw_circle(Vector2(x, rect.get_center().y + 1.0), r, Color(0, 0, 0, 0.18), true, -1.0, true)
		draw_circle(Vector2(x, rect.get_center().y), r, CozyHUD.CREAM, true, -1.0, true)
		if has_focus():
			draw_style_box(_ring, rect.grow(4.0))
