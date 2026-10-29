class_name HorizonMenu
extends Control
## A row of choices laid along a hand-inked waterline, each one a tiny low-poly
## island. The title and pause screens use it in place of a button column.
##
## Hovering or focusing an item lifts its island on a spring, inks it ember and
## raises a waving pennant; the label below turns ember too. Hover takes keyboard
## focus, so mouse and arrow keys always agree on what is selected. reveal()
## draws the waterline out from the centre and lets the islands surface one by
## one; conceal() sinks them again.

signal chosen(id: StringName)

## Height of the waterline inside each item; labels start a little below it.
const WATER_Y := 40.0
const LABEL_TOP := 52
const ITEM_SPACING := 44

## Fraction of this control's width the waterline spans.
@export_range(0.2, 1.0) var line_span := 0.78

var _row: HBoxContainer
var _items: Array[HorizonItem] = []
var _line := 0.0   # 0..1, how much of the waterline is drawn
var _line_tween: Tween


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size.y = WATER_Y + 46.0
	_row = HBoxContainer.new()
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override("separation", ITEM_SPACING)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_row)
	_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## kind picks the island's silhouette: &"isle", &"stack" (a lone sea stack),
## &"light" (an islet with a lighthouse), &"twin" (two hills), &"palm" (a low atoll)
## or &"cairn" (a flat skerry with an explorer's cairn of stacked stones).
func add_item(id: StringName, text: String, primary := false, kind := &"isle") -> HorizonItem:
	var item := HorizonItem.new()
	item.id = id
	item.text = text
	item.primary = primary
	item.kind = kind
	item.pressed.connect(func() -> void: chosen.emit(id))
	_row.add_child(item)
	_items.append(item)
	_link_focus()
	return item


func get_item(id: StringName) -> HorizonItem:
	for item in _items:
		if item.id == id:
			return item
	return null


func focus_first() -> void:
	if not _items.is_empty():
		_items[0].grab_focus()


func set_interactive(on: bool) -> void:
	for item in _items:
		item.disabled = not on
		item.focus_mode = Control.FOCUS_ALL if on else Control.FOCUS_NONE
		item.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE


## Draws the waterline out from the centre, then surfaces each island in turn.
func reveal(delay := 0.0) -> void:
	_animate_line(1.0, 1.1, delay)
	for i in _items.size():
		var item := _items[i]
		item.sink = 1.0
		item.modulate.a = 0.0
		var tw := _item_tween(item)
		var d := delay + 0.35 + i * 0.09
		tw.tween_property(item, "modulate:a", 1.0, 0.3).set_delay(d).set_trans(Tween.TRANS_SINE)
		tw.tween_property(item, "sink", 0.0, 1.1).set_delay(d).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)


## Sinks every island and pulls the waterline back in. Returns the last tween.
func conceal(duration := 0.5) -> Tween:
	set_interactive(false)
	var last: Tween
	for i in _items.size():
		var item := _items[i]
		var tw := _item_tween(item)
		var d := (_items.size() - 1 - i) * 0.05
		tw.tween_property(item, "sink", 1.0, duration).set_delay(d).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		tw.tween_property(item, "modulate:a", 0.0, duration * 0.8).set_delay(d + duration * 0.2)
		last = tw
	_animate_line(0.0, duration + 0.2, 0.15)
	return last


## One running reveal or conceal per island, so a quick back-and-forth never fights.
func _item_tween(item: HorizonItem) -> Tween:
	if item.has_meta(&"_horizon_tween"):
		var running: Tween = item.get_meta(&"_horizon_tween")
		if running and running.is_valid():
			running.kill()
	var tw := item.create_tween().set_parallel()
	item.set_meta(&"_horizon_tween", tw)
	return tw


func _animate_line(to: float, duration: float, delay: float) -> void:
	if _line_tween and _line_tween.is_valid():
		_line_tween.kill()
	_line_tween = create_tween()
	_line_tween.tween_method(func(v: float) -> void:
		_line = v
		queue_redraw(), _line, to, duration).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _link_focus() -> void:
	for i in _items.size():
		var item := _items[i]
		var prev := _items[(i - 1 + _items.size()) % _items.size()]
		var next := _items[(i + 1) % _items.size()]
		item.focus_neighbor_left = item.get_path_to(prev) if item.is_inside_tree() else NodePath()
		item.focus_neighbor_right = item.get_path_to(next) if item.is_inside_tree() else NodePath()
		item.focus_previous = item.focus_neighbor_left
		item.focus_next = item.focus_neighbor_right


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE or what == NOTIFICATION_READY:
		_link_focus.call_deferred()


func _draw() -> void:
	if _line <= 0.001:
		return
	# A hairline of ink that thins out toward both ends, drawn from the centre.
	var half := size.x * line_span * 0.5 * _line
	var cx := size.x * 0.5
	var y := WATER_Y
	var points := PackedVector2Array()
	var colours := PackedColorArray()
	var steps := 24
	for s in steps + 1:
		var t := float(s) / steps
		var x := lerpf(cx - half, cx + half, t)
		points.append(Vector2(x, y))
		var edge := 1.0 - pow(absf(t * 2.0 - 1.0), 2.2)
		colours.append(Color(CozyHUD.INK_TEXT, 0.38 * edge))
	draw_polyline_colors(points, colours, 1.2, true)


## One choice: an island glyph sitting on the waterline, its label underneath.
class HorizonItem extends Button:
	var id: StringName
	var primary := false
	var kind := &"isle"
	## 0 = resting, 1 = selected (lifted, ember, pennant up).
	var lift := 0.0:
		set(v):
			lift = v
			queue_redraw()
	## 0 = sitting on the water, 1 = sunk below it.
	var sink := 0.0:
		set(v):
			sink = v
			queue_redraw()
	## Small caption that fades in under the label while selected.
	var detail := "":
		set(v):
			detail = v
			queue_redraw()

	const CAIRN_HEIGHT := 10.0
	var _shape := PackedVector2Array()
	var _time := 0.0
	var _phase := 0.0
	var _lift_tween: Tween

	func _ready() -> void:
		theme_type_variation = &"HorizonPrimary" if primary else &"HorizonItem"
		focus_mode = Control.FOCUS_ALL
		action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		custom_minimum_size.x = 124.0 if primary else 104.0
		_build_shape()
		mouse_entered.connect(func() -> void:
			if not disabled:
				grab_focus())
		focus_entered.connect(func() -> void: _set_lift(1.0))
		focus_exited.connect(func() -> void: _set_lift(0.0))
		button_down.connect(func() -> void: _squash())
		resized.connect(func() -> void: pivot_offset = Vector2(size.x * 0.5, HorizonMenu.WATER_Y))

	func _set_lift(to: float) -> void:
		if _lift_tween and _lift_tween.is_valid():
			_lift_tween.kill()
		_lift_tween = create_tween().set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
		_lift_tween.tween_property(self, "lift", to, 0.75 if to > 0.5 else 0.45)

	func _squash() -> void:
		var tw := create_tween()
		tw.tween_property(self, "scale", Vector2(1.06, 0.9), 0.08).set_trans(Tween.TRANS_SINE)
		tw.tween_property(self, "scale", Vector2.ONE, 0.6).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)

	## A small faceted island silhouette: drawn per kind, or hashed from the id for &"isle".
	func _build_shape() -> void:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(String(id)) & 0x7fffffff
		_phase = rng.randf() * TAU
		match kind:
			&"stack":
				_shape = PackedVector2Array([Vector2(-9, 0), Vector2(-6, -8), Vector2(-5, -16), Vector2(-1, -21),
					Vector2(4, -17), Vector2(6, -7), Vector2(10, 0)])
				return
			&"light":
				_shape = PackedVector2Array([Vector2(-18, 0), Vector2(-11, -4), Vector2(-3, -6), Vector2(4, -6),
					Vector2(11, -3), Vector2(18, 0)])
				return
			&"twin":
				_shape = PackedVector2Array([Vector2(-21, 0), Vector2(-15, -7), Vector2(-9, -10), Vector2(-4, -5),
					Vector2(0, -4), Vector2(5, -9), Vector2(11, -12), Vector2(16, -6), Vector2(21, 0)])
				return
			&"palm":
				_shape = PackedVector2Array([Vector2(-22, 0), Vector2(-15, -3), Vector2(-5, -5), Vector2(6, -4),
					Vector2(15, -2), Vector2(22, 0)])
				return
			&"cairn":
				_shape = PackedVector2Array([Vector2(-19, 0), Vector2(-13, -3), Vector2(-6, -4), Vector2(2, -5),
					Vector2(9, -4), Vector2(14, -2), Vector2(19, 0)])
				return
		var w := 27.0 if primary else 19.0
		var peak_at := rng.randf_range(-0.25, 0.3)
		_shape.clear()
		_shape.append(Vector2(-w, 0.0))
		var n := 6
		for i in range(1, n):
			var t := float(i) / n
			var x := lerpf(-w, w, t)
			var u := (t * 2.0 - 1.0) - peak_at
			var h := (1.0 - u * u * 1.6) * (13.0 if primary else 10.0)
			h = maxf(h, 2.0) * rng.randf_range(0.82, 1.12)
			_shape.append(Vector2(x, -h))
		_shape.append(Vector2(w, 0.0))

	func _process(delta: float) -> void:
		_time += delta
		queue_redraw()   # the islands bob gently on the swell even at rest

	func _draw() -> void:
		var base := Vector2(size.x * 0.5, HorizonMenu.WATER_Y)
		var grow := (1.0 + 0.1 * lift)
		var rise := -4.0 * lift + sink * 18.0 + sin(_time * 1.3 + _phase) * 0.7
		var ink := Color(CozyHUD.INK_TEXT, 0.5 + 0.35 * lift).lerp(CozyHUD.EMBER, lift)

		# Island, clipped at the waterline so it sinks rather than slides.
		var poly := PackedVector2Array()
		var peak := Vector2.ZERO
		for p in _shape:
			var q := base + Vector2(p.x * grow, p.y * grow + rise)
			q.y = minf(q.y, base.y)
			poly.append(q)
			if p.y < peak.y:
				peak = p
		# (Skip it once fully under: an all-flat polygon cannot be triangulated.)
		if peak.y * grow + rise < -0.6:
			draw_colored_polygon(poly, ink)
			# Lit facets on the sun side (left of the peak), one step lighter.
			var lit := PackedVector2Array()
			var lit_top := base.y
			for q in poly:
				if q.x <= base.x + peak.x * grow:
					lit.append(q)
					lit_top = minf(lit_top, q.y)
			lit.append(base + Vector2(peak.x * grow, 0.0))
			if lit.size() >= 3 and lit_top < base.y - 0.6:
				draw_colored_polygon(lit, ink.lightened(0.16))

		_draw_landmark(base, grow, rise, ink)

		# Pennant: a mast rises from the peak and a little flag waves (the lighthouse lights up instead).
		if lift > 0.02 and sink < 0.5 and kind != &"light":
			var top := base + Vector2(peak.x * grow, peak.y * grow + rise)
			if kind == &"cairn":
				top.y -= CAIRN_HEIGHT * grow   # the pennant flies from the top stone
			var mast_top := top + Vector2(0.0, -15.0 * lift)
			draw_line(top, mast_top, ink, 1.4, true)
			var wave := sin(_time * 5.5) * 1.6
			var flag_col := Color(CozyHUD.CORAL.darkened(0.15), lift)
			draw_colored_polygon(PackedVector2Array([
				mast_top, mast_top + Vector2(11.0, 3.0 + wave), mast_top + Vector2(0.0, 6.5)]), flag_col)

		# Ripples on the water under the island, widening as it lifts.
		var ripple := Color(CozyHUD.INK_TEXT, (0.18 + 0.2 * lift) * (1.0 - sink))
		for k in 2:
			var half := (16.0 - k * 6.0) * (1.0 + 0.35 * lift) * (0.6 if not primary else 0.8)
			var y := base.y + 5.0 + k * 4.0
			draw_line(Vector2(base.x - half, y), Vector2(base.x + half, y), ripple, 1.0, true)

		# Detail caption under the label, only while selected.
		if not detail.is_empty() and lift > 0.05:
			var font := get_theme_default_font()
			var fs := 12
			var w := font.get_string_size(detail, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var y2 := size.y + 14.0
			draw_string(font, Vector2((size.x - w) * 0.5, y2), detail, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				Color(CozyHUD.INK_FAINT, lift * 0.9))

	## The lighthouse, palm and cairn that stand on their islets.
	func _draw_landmark(base: Vector2, grow: float, rise: float, ink: Color) -> void:
		if sink > 0.35:
			return
		match kind:
			&"light":
				var foot := base + Vector2(1.0 * grow, -6.0 * grow + rise)
				var top := foot + Vector2(0.0, -13.0 * grow)
				draw_colored_polygon(PackedVector2Array([foot + Vector2(-3.2, 0), top + Vector2(-2.0, 0),
					top + Vector2(2.0, 0), foot + Vector2(3.2, 0)]), ink)
				draw_colored_polygon(PackedVector2Array([top + Vector2(-3.0, 0), top + Vector2(0, -4.0),
					top + Vector2(3.0, 0)]), ink)
				var lamp := top + Vector2(0.0, 1.8)
				if lift > 0.02:
					draw_circle(lamp, 6.0 * lift, Color(CozyHUD.AMBER, 0.28 * lift), true, -1.0, true)
				draw_circle(lamp, 1.6, CozyHUD.AMBER.lerp(Color(CozyHUD.HAZE, 1.0), 1.0 - lift), true, -1.0, true)
			&"palm":
				var foot := base + Vector2(-5.0 * grow, -5.0 * grow + rise)
				var sway := sin(_time * 2.0 + _phase) * 0.8 * (0.4 + lift)
				var top := foot + Vector2(3.0 + sway, -13.0 * grow)
				draw_polyline(PackedVector2Array([foot, foot.lerp(top, 0.5) + Vector2(-1.0, 0), top]), ink, 1.6, true)
				for f in [Vector2(-7, 2), Vector2(-4, 4.5), Vector2(6, 2.5), Vector2(4, 5)]:
					draw_line(top, top + Vector2(f.x + sway * 0.5, f.y), ink, 1.6, true)
			&"cairn":
				# Three stones, smaller toward the top, standing on the skerry's crown.
				var foot := base + Vector2(2.0 * grow, -5.0 * grow + rise)
				var y := 0.0
				for stone: Vector2 in [Vector2(4.2, 1.9), Vector2(3.1, 1.6), Vector2(2.0, 1.4)]:
					var c := foot + Vector2(0.0, (y - stone.y) * grow)
					var pts := PackedVector2Array()
					for k in 7:
						var a := TAU * k / 7.0
						pts.append(c + Vector2(cos(a) * stone.x, sin(a) * stone.y) * grow)
					draw_colored_polygon(pts, ink)
					y -= stone.y * 2.0 - 0.4
