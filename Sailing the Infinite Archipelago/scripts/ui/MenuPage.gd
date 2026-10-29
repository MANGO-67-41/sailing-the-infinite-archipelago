class_name MenuPage
extends Control
## A full-screen page opened from the title or pause menu (Settings, Controls).
##
## The menu behind it sinks away and a sheet of sea haze settles over the frame,
## held inside an inked chart border: a double neat-line with the alternating
## latitude scale of an engraved sea chart between the two lines. The page's
## name is lettered at the top, the content sits in the middle, and BACK rides
## on a short waterline at the foot. Esc goes back too.
##
## Subclasses set `heading` in _init(), fill `body` in _build_body() (adding each
## line with add_row() so it fades in with the rest), and name the control that
## takes focus in _first_focus().

signal closed

const BORDER := 26.0        # inset of the outer neat-line
const BORDER_GAP := 6.0     # between the two lines, where the scale is drawn
const SCALE_STEP := 46.0

var heading := ""
## The centred column a subclass fills.
var body: VBoxContainer

var _sheet: Sheet
var _root: MarginContainer
var _back: HorizonMenu
var _rows: Array[Control] = []
var _open := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	_sheet = Sheet.new()
	add_child(_sheet)
	_sheet.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_root = MarginContainer.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var side := int(BORDER + BORDER_GAP + 40.0)
	_root.add_theme_constant_override("margin_left", side)
	_root.add_theme_constant_override("margin_right", side)
	_root.add_theme_constant_override("margin_top", int(BORDER + 30.0))
	_root.add_theme_constant_override("margin_bottom", int(BORDER + 22.0))
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var col := CozyHUD.make_vbox(0)
	_root.add_child(col)
	var title := CozyHUD.make_label(heading, &"PageTitle")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	col.add_child(CozyHUD.make_gap(8))
	var rule := Flourish.new()
	rule.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(rule)

	var middle := CenterContainer.new()
	middle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(middle)
	body = CozyHUD.make_vbox(0)
	middle.add_child(body)
	_build_body()

	_back = HorizonMenu.new()
	_back.line_span = 0.3
	col.add_child(_back)
	_back.add_item(&"back", "BACK").detail = "Esc also goes back"
	_back.chosen.connect(func(_id: StringName) -> void: close())
	_back.set_interactive(false)
	# Room under the waterline for the BACK caption.
	col.add_child(CozyHUD.make_gap(18))
	_link_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()


func is_open() -> bool:
	return _open


func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	_sheet.modulate.a = 0.0
	UiMotion.fade(_sheet, true, 0.35)
	_root.modulate.a = 0.0
	_root.position.y = 18.0
	UiMotion.fade(_root, true, 0.3, 0.08)
	UiMotion.spring(_root, ^"position:y", 0.0, 0.9)
	for i in _rows.size():
		var row := _rows[i]
		row.modulate.a = 0.0
		row.create_tween().tween_property(row, "modulate:a", 1.0, 0.35) \
			.set_delay(0.14 + i * 0.045).set_trans(Tween.TRANS_SINE)
	_back.set_interactive(true)
	_back.reveal(0.15)
	get_tree().create_timer(0.3).timeout.connect(func() -> void:
		var target := _first_focus()
		if _open and target:
			target.grab_focus())


func close() -> void:
	if not _open:
		return
	_open = false
	_on_close()
	_back.conceal(0.3)
	UiMotion.fade(_root, false, 0.2)
	UiMotion.fade(_sheet, false, 0.35, 0.1).tween_callback(func() -> void:
		if not _open:
			visible = false)
	closed.emit()


## Hides at once, without the walk back (the pause menu closing underneath).
func dismiss() -> void:
	if _open:
		_on_close()
	_open = false
	visible = false


## Adds a line to the body; lines fade in one after another when the page opens.
func add_row(row: Control) -> Control:
	body.add_child(row)
	_rows.append(row)
	return row


func get_back_item() -> Control:
	return _back.get_item(&"back")


# Overridden by each page.
func _build_body() -> void:
	pass


func _first_focus() -> Control:
	return get_back_item()


func _focus_chain() -> Array[Control]:
	return []


func _on_close() -> void:
	pass


## Up and down walk the page's controls in order and wrap through BACK.
func _link_focus() -> void:
	var chain := _focus_chain()
	chain.append(get_back_item())
	if chain.size() < 2:
		return
	for i in chain.size():
		var c := chain[i]
		c.focus_neighbor_bottom = c.get_path_to(chain[(i + 1) % chain.size()])
		c.focus_neighbor_top = c.get_path_to(chain[(i - 1 + chain.size()) % chain.size()])


## One line of a page: padded, ruled underneath, and (when interactive) washed
## with a little ink and marked with an ember tick while hovered or holding focus.
## Clicking anywhere on it runs `activate`.
class Row extends PanelContainer:
	var interactive := true
	var ruled := true
	var activate := Callable()
	var _hovered := false
	var _glow := 0.0:
		set(v):
			_glow = v
			queue_redraw()
	var _wash := StyleBoxFlat.new()

	func _init(is_interactive := true) -> void:
		interactive = is_interactive
		var pad := StyleBoxEmpty.new()
		pad.content_margin_left = 16
		pad.content_margin_right = 16
		pad.content_margin_top = 11
		pad.content_margin_bottom = 11
		add_theme_stylebox_override(&"panel", pad)
		mouse_filter = Control.MOUSE_FILTER_PASS if interactive else Control.MOUSE_FILTER_IGNORE
		if interactive:
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_wash.set_corner_radius_all(10)
		_wash.corner_detail = 8
		_wash.anti_aliasing = true

	func _ready() -> void:
		if not interactive:
			return
		mouse_entered.connect(func() -> void:
			_hovered = true
			_refresh())
		mouse_exited.connect(func() -> void:
			_hovered = false
			_refresh())
		get_viewport().gui_focus_changed.connect(func(_c: Control) -> void: _refresh())

	func _refresh() -> void:
		var focus := get_viewport().gui_get_focus_owner()
		var lit := _hovered or (focus != null and (focus == self or is_ancestor_of(focus)))
		UiMotion.spring(self, ^"_glow", 1.0 if lit else 0.0, 0.45)

	func _gui_input(event: InputEvent) -> void:
		if not interactive or not activate.is_valid():
			return
		var mb := event as InputEventMouseButton
		var clicked := mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed
		# A row that takes focus itself (a list entry) answers Enter too.
		if clicked or (focus_mode != Control.FOCUS_NONE and event.is_action_pressed("ui_accept")):
			activate.call()
			accept_event()

	func _draw() -> void:
		if _glow > 0.01:
			_wash.bg_color = Color(CozyHUD.INK_TEXT, 0.055 * _glow)
			draw_style_box(_wash, Rect2(Vector2.ZERO, size))
			var h := size.y * 0.42
			draw_rect(Rect2(Vector2(3.0, (size.y - h) * 0.5), Vector2(2.5, h)), Color(CozyHUD.EMBER, _glow))
		if ruled:
			draw_line(Vector2(16.0, size.y - 0.5), Vector2(size.x - 16.0, size.y - 0.5), Color(CozyHUD.INK_TEXT, 0.14), 1.0)


## The sheet: thin haze over the sea at the margins, dense haze inside the border.
class Sheet extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _draw() -> void:
		var outer := Rect2(Vector2.ONE * BORDER, size - Vector2.ONE * BORDER * 2.0)
		var inner := outer.grow(-BORDER_GAP)
		draw_rect(Rect2(Vector2.ZERO, size), Color(CozyHUD.HAZE, 0.4))
		draw_rect(outer, Color(CozyHUD.HAZE, 0.86))
		var ink := CozyHUD.INK_TEXT
		# Latitude scale: alternate segments between the lines are inked in, measured
		# out from the top-left corner along every side.
		var bar := Color(ink, 0.2)
		var x := inner.position.x
		var i := 0
		while x < inner.end.x:
			var w := minf(SCALE_STEP, inner.end.x - x)
			if i % 2 == 0:
				draw_rect(Rect2(Vector2(x, outer.position.y), Vector2(w, BORDER_GAP)), bar)
				draw_rect(Rect2(Vector2(x, inner.end.y), Vector2(w, BORDER_GAP)), bar)
			x += SCALE_STEP
			i += 1
		var y := inner.position.y
		i = 0
		while y < inner.end.y:
			var h := minf(SCALE_STEP, inner.end.y - y)
			if i % 2 == 0:
				draw_rect(Rect2(Vector2(outer.position.x, y), Vector2(BORDER_GAP, h)), bar)
				draw_rect(Rect2(Vector2(inner.end.x, y), Vector2(BORDER_GAP, h)), bar)
			y += SCALE_STEP
			i += 1
		for corner: Vector2 in [outer.position, Vector2(inner.end.x, outer.position.y),
				Vector2(outer.position.x, inner.end.y), inner.end]:
			draw_rect(Rect2(corner, Vector2.ONE * BORDER_GAP), Color(ink, 0.42))
		draw_rect(outer, Color(ink, 0.5), false, 1.5)
		draw_rect(inner, Color(ink, 0.34), false, 1.0)


## A hairline under the page name with a small inked diamond at its centre.
class Flourish extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(280.0, 14.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var ink := CozyHUD.INK_TEXT
		for d: float in [-1.0, 1.0]:
			var points := PackedVector2Array([c + Vector2(9.0 * d, 0.0), c + Vector2(size.x * 0.5 * d, 0.0)])
			var colours := PackedColorArray([Color(ink, 0.45), Color(ink, 0.0)])
			draw_polyline_colors(points, colours, 1.0, true)
		draw_colored_polygon(PackedVector2Array([c + Vector2(0.0, -4.0), c + Vector2(4.0, 0.0),
			c + Vector2(0.0, 4.0), c + Vector2(-4.0, 0.0)]), Color(ink, 0.55))
