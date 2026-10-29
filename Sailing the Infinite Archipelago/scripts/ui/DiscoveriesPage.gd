class_name DiscoveriesPage
extends MenuPage
## The voyage so far: a chart of every island found, inked where it lies, with
## the track sailed between them, home and the boat; beside it, a list naming
## each island, newest first. Hovering or choosing a name lights its island and
## brings it into view; clicking an island picks its name. Drag the chart to pan,
## wheel to zoom.
##
## Shared by the title screen and the pause menu. Everything comes from
## VoyageLog, so the chart is the same before setting sail as it was at anchor.

const LIST_WIDTH := 300.0
const GAP := 36.0

var _summary: Label
var _chart: Chart
var _list_scroll: ScrollContainer
var _list: VBoxContainer
var _list_rows: Array[Control] = []


func _init() -> void:
	heading = "DISCOVERIES"


func _build_body() -> void:
	_summary = CozyHUD.make_label("", &"MenuLine")
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_row(_summary)
	body.add_child(CozyHUD.make_gap(16))

	var spread := CozyHUD.make_hbox(int(GAP))
	_chart = Chart.new()
	_chart.island_clicked.connect(func(index: int) -> void:
		for row in _list_rows:
			if row.get_meta(&"island") == index:
				row.grab_focus())
	spread.add_child(_chart)
	_list_scroll = ScrollContainer.new()
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_scroll.follow_focus = true
	_list_scroll.custom_minimum_size.x = LIST_WIDTH
	_list = CozyHUD.make_vbox(0)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.add_child(_list)
	spread.add_child(_list_scroll)
	add_row(spread)


func open() -> void:
	if is_open():
		return
	_refresh()
	super.open()


func _first_focus() -> Control:
	return _list_rows[0] if not _list_rows.is_empty() else get_back_item()


func _focus_chain() -> Array[Control]:
	return _list_rows.duplicate()


func _refresh() -> void:
	VoyageLog.ensure_loaded()
	var ship := get_tree().get_first_node_in_group("player_ship") as ShipController
	var found := VoyageLog.discoveries.size()
	var sailed := ship.distance_sailed if ship else VoyageLog.distance_sailed
	var at_sea := ship.time_at_sea if ship else VoyageLog.time_at_sea
	var parts: PackedStringArray = ["%d %s charted" % [found, "island" if found == 1 else "islands"],
		"%s sailed" % GameSettings.format_distance(sailed)]
	if at_sea >= 60.0:
		parts.append("%s at sea" % GameSettings.format_duration(at_sea))
	_summary.text = "  ·  ".join(parts)

	# The chart takes whatever room the page has beside the list.
	var room := size if size.x > 0.0 else get_viewport_rect().size
	var side := 2.0 * (BORDER + BORDER_GAP + 40.0)
	var w := clampf(room.x - side - LIST_WIDTH - GAP - 16.0, 340.0, 720.0)
	var h := clampf(room.y - 350.0, 200.0, 420.0)
	_chart.custom_minimum_size = Vector2(w, h)
	_list_scroll.custom_minimum_size.y = h

	var boat := ship.global_position if ship else VoyageLog.ship_position
	var yaw := ship.global_rotation.y if ship else VoyageLog.ship_yaw
	_chart.set_voyage(VoyageLog.discoveries, VoyageLog.track, Vector2(boat.x, boat.z), yaw)
	_build_list()
	_link_focus()


func _build_list() -> void:
	for child in _list.get_children():
		child.queue_free()
	_list_rows.clear()
	var entries := VoyageLog.discoveries
	if entries.is_empty():
		var empty := CozyHUD.make_label("No islands yet. Sail toward any shape on the horizon; "
			+ "reaching its shore puts it on this chart.", &"PageNote")
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.custom_minimum_size.x = LIST_WIDTH - 32.0
		var pad := MarginContainer.new()
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pad.add_theme_constant_override("margin_left", 16)
		pad.add_theme_constant_override("margin_top", 6)
		pad.add_child(empty)
		_list.add_child(pad)
		return
	for i in range(entries.size() - 1, -1, -1):
		var entry := entries[i]
		var row := MenuPage.Row.new()
		row.ruled = i > 0
		row.focus_mode = Control.FOCUS_ALL
		row.set_meta(&"island", i)
		var words := CozyHUD.make_vbox(2)
		row.add_child(words)
		var top := CozyHUD.make_hbox(10)
		var name_label := CozyHUD.make_label(entry["name"], &"PageRow")
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		top.add_child(name_label)
		var home := Vector2(float(entry["x"]), float(entry["z"])).length()
		top.add_child(CozyHUD.make_label(GameSettings.format_distance(home), &"PageNote"))
		words.add_child(top)
		var said: String = entry["description"]
		if entry.get("massive", false):
			said += " · %d of %d landmarks found" % [(entry.get("found", []) as Array).size(),
				(entry.get("landmarks", []) as Array).size()]
		var about := CozyHUD.make_label(said, &"PageNote")
		about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		words.add_child(about)
		row.activate = func() -> void:
			row.grab_focus()
			_chart.show_island(i)
		row.focus_entered.connect(func() -> void: _chart.show_island(i))
		row.focus_exited.connect(func() -> void: _chart.unlight(i))
		row.mouse_entered.connect(func() -> void: _chart.hot = i)
		row.mouse_exited.connect(func() -> void: _chart.hot = -1)
		_list.add_child(row)
		_list_rows.append(row)


## The drawn chart. World x runs right and world z down, so north is up.
class Chart extends Control:
	signal island_clicked(index: int)

	const NICE_STEPS: Array[float] = [50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0, 20000.0, 50000.0]
	const MAX_ZOOM := 2.0        # px per metre
	const MIN_SPAN := 700.0      # the chart never frames less sea than this, in metres
	const RIVER_INK := Color("4f7f95")

	## The island under the pointer (on the chart or its name in the list); -1 for none.
	var hot := -1:
		set(v):
			if v != hot:
				hot = v
				queue_redraw()
	## The island whose name holds focus in the list. Both it and `hot` are lit ember.
	var chosen := -1:
		set(v):
			if v != chosen:
				chosen = v
				queue_redraw()
	var _entries: Array[Dictionary] = []
	var _coasts: Array[PackedVector2Array] = []
	var _reach: PackedFloat32Array = []
	var _track := PackedVector2Array()
	var _boat := Vector2.ZERO
	var _boat_yaw := 0.0
	var _centre := Vector2.ZERO:
		set(v):
			_centre = v
			queue_redraw()
	var _zoom := 0.2
	var _fit_zoom := 0.2
	var _dragging := false
	var _drag_moved := 0.0
	var _pan: Tween

	func _init() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_exited.connect(func() -> void:
			if not _dragging:
				hot = -1)

	func set_voyage(entries: Array[Dictionary], track: PackedVector2Array, boat: Vector2, yaw: float) -> void:
		_entries = entries
		_coasts.clear()
		_reach.clear()
		for entry in entries:
			_coasts.append(VoyageLog.coast_points(entry))
			var r := 0.0
			for v: Variant in entry["coast"]:
				r = maxf(r, float(v))
			_reach.append(r)
		_track = track.duplicate()
		if _track.is_empty() or _track[_track.size() - 1].distance_to(boat) > 1.0:
			_track.append(boat)
		_boat = boat
		_boat_yaw = yaw
		hot = -1
		chosen = -1
		_fit()

	## Frames home, the boat, the whole track and every island.
	func _fit() -> void:
		var bounds := Rect2(Vector2.ZERO, Vector2.ZERO).expand(_boat)
		for p in _track:
			bounds = bounds.expand(p)
		for coast in _coasts:
			for p in coast:
				bounds = bounds.expand(p)
		var pad := maxf(bounds.size.x, bounds.size.y) * 0.1 + 80.0
		bounds = bounds.grow(pad)
		var centre := bounds.get_center()
		bounds.size = bounds.size.max(Vector2.ONE * MIN_SPAN)
		var frame := custom_minimum_size
		_fit_zoom = minf(frame.x / bounds.size.x, frame.y / bounds.size.y)
		_zoom = _fit_zoom
		_centre = centre

	## Lights an island and eases the chart over to it if it is off the edge.
	func show_island(index: int) -> void:
		chosen = index
		var entry := _entries[index]
		var at := Vector2(float(entry["x"]), float(entry["z"]))
		var margin := _reach[index] * _zoom + 40.0
		if Rect2(Vector2.ZERO, size).grow(-margin).has_point(to_screen(at)):
			return
		if _pan and _pan.is_valid():
			_pan.kill()
		_pan = create_tween().set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
		_pan.tween_property(self, "_centre", at, 0.9)

	func unlight(index: int) -> void:
		if chosen == index:
			chosen = -1

	func to_screen(p: Vector2) -> Vector2:
		return size * 0.5 + (p - _centre) * _zoom

	func to_world(s: Vector2) -> Vector2:
		return _centre + (s - size * 0.5) / _zoom

	func _gui_input(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb:
			if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				# Zoom about the pointer, so what is under it stays under it.
				var before := to_world(mb.position)
				var factor := 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
				_zoom = clampf(_zoom * factor, _fit_zoom * 0.5, maxf(MAX_ZOOM, _fit_zoom))
				_centre = before - (mb.position - size * 0.5) / _zoom
				accept_event()
			elif mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_dragging = true
					_drag_moved = 0.0
					mouse_default_cursor_shape = Control.CURSOR_DRAG
				else:
					_dragging = false
					mouse_default_cursor_shape = Control.CURSOR_ARROW
					if _drag_moved < 4.0 and hot >= 0:
						island_clicked.emit(hot)
				accept_event()
			return
		var mm := event as InputEventMouseMotion
		if mm:
			if _dragging:
				if _pan and _pan.is_valid():
					_pan.kill()
				_centre -= mm.relative / _zoom
				_drag_moved += mm.relative.length()
			else:
				hot = _pick(mm.position)
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hot >= 0 else Control.CURSOR_ARROW

	func _pick(at: Vector2) -> int:
		var best := -1
		var best_d := INF
		for i in _entries.size():
			var entry := _entries[i]
			var d := to_screen(Vector2(float(entry["x"]), float(entry["z"]))).distance_to(at)
			if d < _reach[i] * _zoom + 10.0 and d < best_d:
				best_d = d
				best = i
		return best

	func _draw() -> void:
		var ink := CozyHUD.INK_TEXT
		var paper := Rect2(Vector2.ZERO, size)
		draw_rect(paper, Color(1.0, 0.96, 0.9, 0.4))
		var font := get_theme_font(&"font", &"PageNote")
		var step := _grid_step()

		# Graticule.
		var tl := to_world(Vector2.ZERO)
		var br := to_world(size)
		var x := ceilf(tl.x / step) * step
		while x <= br.x:
			var sx := to_screen(Vector2(x, 0.0)).x
			draw_line(Vector2(sx, 0.0), Vector2(sx, size.y), Color(ink, 0.07), 1.0)
			x += step
		var z := ceilf(tl.y / step) * step
		while z <= br.y:
			var sy := to_screen(Vector2(0.0, z)).y
			draw_line(Vector2(0.0, sy), Vector2(size.x, sy), Color(ink, 0.07), 1.0)
			z += step

		# Islands: two faint water-lines around each coast, then the land.
		for i in _coasts.size():
			var lit := i == hot or i == chosen
			var centre := Vector2(float(_entries[i]["x"]), float(_entries[i]["z"]))
			var c := to_screen(centre)
			var reach := _reach[i] * _zoom
			var line_col := CozyHUD.EMBER if lit else Color(ink, 0.7)
			if reach < 3.0:
				draw_circle(c, 3.0, line_col, true, -1.0, true)
			else:
				var land := PackedVector2Array()
				for p in _coasts[i]:
					land.append(to_screen(p))
				for k: int in [2, 1]:
					var ring := PackedVector2Array()
					for p in land:
						ring.append(p + (p - c).normalized() * 5.0 * k)
					ring.append(ring[0])
					draw_polyline(ring, Color(ink, 0.07 * (3 - k)), 1.0, true)
				draw_colored_polygon(land, Color(CozyHUD.EMBER, 0.2) if lit else Color(ink, 0.13))
				land.append(land[0])
				draw_polyline(land, line_col, 1.6 if lit else 1.2, true)
			# Names live in the list beside the chart; the chart keeps to shapes.
			_draw_features(_entries[i], ink, lit)

		# The track, dashed, from home to the boat.
		for i in range(1, _track.size()):
			draw_dashed_line(to_screen(_track[i - 1]), to_screen(_track[i]), Color(ink, 0.4), 1.3, 5.0, true, true)

		# Home: a ringed cross where the voyage began.
		var home := to_screen(Vector2.ZERO)
		draw_arc(home, 5.0, 0.0, TAU, 20, Color(ink, 0.7), 1.2, true)
		draw_line(home + Vector2(-8.0, 0.0), home + Vector2(8.0, 0.0), Color(ink, 0.7), 1.0, true)
		draw_line(home + Vector2(0.0, -8.0), home + Vector2(0.0, 8.0), Color(ink, 0.7), 1.0, true)
		var home_w := font.get_string_size("Home", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(font, home + Vector2(-12.0 - home_w, 4.0), "Home", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(ink, 0.6))

		# The boat, pointing the way it lies.
		var b := to_screen(_boat)
		var fwd := Vector2(-sin(_boat_yaw), -cos(_boat_yaw))
		var side := Vector2(-fwd.y, fwd.x)
		var boat_col := CozyHUD.CORAL.darkened(0.2)
		draw_circle(b, 11.0, Color(boat_col, 0.16), true, -1.0, true)
		draw_colored_polygon(PackedVector2Array([b + fwd * 8.0, b - fwd * 5.0 + side * 4.5, b - fwd * 3.0,
			b - fwd * 5.0 - side * 4.5]), boat_col)

		_draw_compass(font, ink)
		_draw_scale_bar(font, ink, step)
		draw_rect(paper, Color(ink, 0.45), false, 1.0)

	## A great island's rivers and lake in river ink, its village as a cluster of
	## roofs and its lighthouse as a small star. A massive island draws the same,
	## plus the parts of it found so far: each river sailed opens up as wide water
	## through the land, the sound (and its harbour town), falls and old stones.
	func _draw_features(entry: Dictionary, ink: Color, lit: bool) -> void:
		var massive: bool = entry.get("massive", false)
		if not entry.get("great", false) and not massive:
			return
		var found: Array = entry.get("found", [])
		var water := Color(RIVER_INK, 0.95 if lit else 0.8)
		if massive:
			var channels: Array = entry.get("channels", [])
			for i in channels.size():
				if not found.has("river%d" % i):
					continue
				var flat: Array = channels[i]["line"]
				var line := PackedVector2Array()
				var width := 0.0
				for k in range(0, flat.size() - 2, 3):
					line.append(to_screen(Vector2(float(flat[k]), float(flat[k + 1]))))
					width += float(flat[k + 2])
				if line.size() >= 2:
					width /= line.size()
					draw_polyline(line, Color(RIVER_INK, 0.4 if lit else 0.32), maxf(width * _zoom, 2.0), true)
					draw_polyline(line, water, clampf(_zoom * 3.0, 1.0, 1.6), true)
			if found.has("sound"):
				var sound: Array = entry["sound"]
				var at := to_screen(Vector2(float(sound[0]), float(sound[1])))
				var reach := maxf(float(sound[2]) * _zoom, 3.0)
				draw_circle(at, reach, Color(RIVER_INK, 0.4 if lit else 0.32), true, -1.0, true)
				draw_circle(at, reach, water, false, 1.0, true)
		for flat: Array in entry.get("rivers", []):
			var line := PackedVector2Array()
			for k in range(0, flat.size() - 1, 2):
				line.append(to_screen(Vector2(float(flat[k]), float(flat[k + 1]))))
			if line.size() >= 2:
				draw_polyline(line, water, clampf(_zoom * 4.0, 1.0, 2.6), true)
		if entry.has("lake"):
			var lake: Array = entry["lake"]
			draw_circle(to_screen(Vector2(float(lake[0]), float(lake[1]))), maxf(float(lake[2]) * _zoom, 2.0),
				Color(RIVER_INK, 0.55), true, -1.0, true)
		if entry.has("village") and (not massive or found.has("sound")):
			var v := to_screen(Vector2(float(entry["village"][0]), float(entry["village"][1])))
			for o: Vector2 in [Vector2(-3.0, 0.0), Vector2(2.5, -2.5), Vector2(2.0, 2.5)]:
				draw_rect(Rect2(v + o - Vector2(1.6, 1.6), Vector2(3.2, 3.2)), Color(ink, 0.8))
		var lights: Array = entry.get("lighthouses", [])
		if entry.has("lighthouse"):
			lights = [entry["lighthouse"]]
		for spot: Array in lights:
			var l := to_screen(Vector2(float(spot[0]), float(spot[1])))
			var star := PackedVector2Array()
			for k in 10:
				star.append(l + Vector2.from_angle(TAU * k / 10.0 - PI * 0.5) * (5.0 if k % 2 == 0 else 2.0))
			draw_colored_polygon(star, CozyHUD.EMBER if lit else Color(ink, 0.85))
		for mark: Dictionary in entry.get("landmarks", []):
			if not found.has(mark["id"]):
				continue
			var m := to_screen(Vector2(float(mark["x"]), float(mark["z"])))
			match String(mark["kind"]):
				"falls":
					# Three short strokes of falling water.
					for o: float in [-2.5, 0.0, 2.5]:
						draw_line(m + Vector2(o, -4.0), m + Vector2(o, 3.0), water, 1.2, true)
				"stones":
					for o: float in [-3.0, 0.0, 3.0]:
						draw_rect(Rect2(m + Vector2(o - 0.9, -3.0 + absf(o) * 0.4), Vector2(1.8, 5.0 - absf(o) * 0.4)),
							Color(ink, 0.8))

	func _draw_compass(font: Font, ink: Color) -> void:
		var at := Vector2(size.x - 26.0, 44.0)
		draw_colored_polygon(PackedVector2Array([at + Vector2(0.0, -16.0), at + Vector2(4.5, 0.0),
			at + Vector2(-4.5, 0.0)]), Color(ink, 0.75))
		draw_polyline(PackedVector2Array([at + Vector2(-4.5, 0.0), at + Vector2(0.0, 14.0), at + Vector2(4.5, 0.0)]),
			Color(ink, 0.5), 1.0, true)
		var w := font.get_string_size("N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(font, at + Vector2(-w * 0.5, -21.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(ink, 0.75))

	## A chart scale bar: one grid step, split into alternately inked halves.
	func _draw_scale_bar(font: Font, ink: Color, step: float) -> void:
		var length := step * _zoom
		var at := Vector2(16.0, size.y - 18.0)
		var half := length * 0.5
		draw_rect(Rect2(at, Vector2(half, 4.0)), Color(ink, 0.6))
		draw_rect(Rect2(at, Vector2(length, 4.0)), Color(ink, 0.6), false, 1.0)
		draw_string(font, at + Vector2(length + 8.0, 5.0), GameSettings.format_distance(step),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(ink, 0.7))

	func _grid_step() -> float:
		for s in NICE_STEPS:
			if s * _zoom >= 80.0:
				return s
		return NICE_STEPS[NICE_STEPS.size() - 1]
