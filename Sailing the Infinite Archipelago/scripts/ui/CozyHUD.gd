class_name CozyHUD
extends Control
## Cozy sailing HUD, built entirely in code on top of a generated Theme.
##
## The sea is the screen, so the HUD stays small and low:
##   Bottom left:   one instrument: a wind compass, speed in km/h, point of sail,
##                  a trim hint, and a status row of tiny drawn gauges (sail hoist,
##                  engine telegraph, trim). Hovering it slides up a drawer with the
##                  full clickable sail / trim / engine controls.
##   Top centre:    toast stack (discoveries, wind shifts); slides in with TRANS_BACK
##   Bottom right:  control hints that tuck away into a chip (H toggles)
## While the player drags the camera to look around, the instrument and hints fade
## back so nothing sits in front of the view.
##
## Discrete feedback (hover, press, focus, spawn, state changes) uses Tweens with
## TRANS_SPRING / EASE_OUT (see UiMotion). Values that change every frame (compass
## angles, speed) run on small spring or exponential smoothers instead, since
## restarting a tween each frame would stutter.
##
## The title screen calls hold_intro() and later play_intro() when the voyage
## starts. Other systems announce discoveries with:
##   get_tree().call_group("cozy_hud", "announce_discovery", "Lanternfall Isle", "A quiet cove")

# -- Palette: warm ink panels, cream type, amber and sea-glass accents --------
const INK := Color(0.137, 0.094, 0.078, 0.82)
const INK_SOLID := Color("2a1d18")
const WELL := Color(1.0, 0.92, 0.8, 0.07)
const WELL_HOVER := Color(1.0, 0.92, 0.8, 0.14)
const LINE := Color(1.0, 0.9, 0.76, 0.16)
const CREAM := Color("fbefdc")
const CREAM_DIM := Color(0.984, 0.937, 0.863, 0.72)
const MUTED := Color("cbb398")
const AMBER := Color("f3a65a")
const AMBER_SOFT := Color("f7bf86")
const CORAL := Color("ee7b5e")
const SEA := Color("85ccb9")
const SHADOW := Color(0.08, 0.04, 0.02, 0.32)
# -- Menus are lettered in ink on the sea haze (the fog colour) ---------------
const HAZE := Color(0.98, 0.82, 0.67)
const INK_TEXT := Color(0.165, 0.114, 0.094, 0.92)
const INK_FAINT := Color(0.165, 0.114, 0.094, 0.62)
const EMBER := Color("9c4022")

const FONT_NAMES: PackedStringArray = ["Avenir Next", "Nunito", "Segoe UI", "Helvetica Neue", "Arial"]
## Marcellus (SIL OFL 1.1, licence beside the file): a flared titling face in the
## spirit of engraved chart lettering, bundled so the title reads the same everywhere.
const DISPLAY_FONT_PATH := "res://Sailing the Infinite Archipelago/assets/fonts/Marcellus-Regular.ttf"
const SAIL_SHORT: PackedStringArray = ["Furl", "Reef", "Half", "Full"]
const ENGINE_SHORT: PackedStringArray = ["Astern", "Stop", "Slow", "Half", "Full"]
const CARD_RADIUS := 18
const SCREEN_MARGIN := 24.0
const TOAST_WIDTH := 360.0
const TOAST_GAP := 10.0
const TOAST_HOLD := 3.6
const MAX_TOASTS := 3
const HINT_AUTO_HIDE := 14.0
## How far the HUD fades while the player looks around.
const LOOK_ALPHA := 0.22
## Seconds the drawer stays open after the pointer leaves the instrument.
const DRAWER_LINGER := 0.45

const HINT_ROWS := [
	[["W", "S"], "Sail up / down, back up"],
	[["A", "D"], "Helm"],
	[["Q", "E"], "Trim by hand"],
	[["T"], "Auto-trim"],
	[["R", "F"], "Engine ahead / astern"],
	[["Space"], "Moor / cast off"],
	[["Drag"], "Look around"],
	[["H"], "Hide controls"],
	[["Esc"], "Pause"],
]

var _ship: ShipController
var _dock: VBoxContainer
var _drawer: PanelContainer
var _instrument: PanelContainer
var _dial: WindDial
var _rig: RigStatus
var _wind_label: Label
var _speed_label: Label
var _unit_label: Label
var _pos_label: Label
var _trim_hint: Label
var _sail_buttons: Array[Button] = []
var _engine_buttons: Array[Button] = []
var _engine_label: Label
var _trim_bar: TrimBar
var _trim_button: Button
var _toast_stack: VBoxContainer
var _toast_queue: Array[Dictionary] = []
var _hint_holder: Control
var _hints: PanelContainer
var _hint_chip: PanelContainer
var _hints_open := true
var _hints_touched := false
var _drawer_open := false
var _drawer_linger := 0.0
var _view_alpha := 1.0
var _shown_kmh := 0.0
var _last_point_of_sail := ""
var _intro_held := false
var _intro_played := false


func _ready() -> void:
	add_to_group("cozy_hud")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = build_theme()

	_build_dock()
	_build_toast_stack()
	_build_hints()
	_dock.visible = false
	_hint_holder.visible = false

	WindManager.wind_shift_started.connect(_on_wind_shift_started)
	WindManager.gust_started.connect(_on_gust_started)
	_connect_ship.call_deferred()
	_auto_intro.call_deferred()


func _process(delta: float) -> void:
	if _ship == null:
		return
	_dial.heading_target = _ship.heading
	_dial.wind_target = WindManager.angle
	_dial.strength = WindManager.strength
	_dial.boom = _ship.boom_angle
	_set_text(_wind_label, "%s from %s" % [WindManager.get_strength_name().to_lower(), WindManager.get_from_cardinal()])

	_shown_kmh = lerpf(_shown_kmh, _ship.get_speed_kmh(), 1.0 - exp(-6.0 * delta))
	_set_text(_speed_label, "%d" % roundi(absf(_shown_kmh)))
	_set_text(_unit_label, "km/h astern" if _shown_kmh < -0.3 else "km/h")

	var pos := _ship.point_of_sail
	if pos != _last_point_of_sail:
		_last_point_of_sail = pos
		_pos_label.text = pos
		_pos_label.add_theme_color_override("font_color", _point_of_sail_colour(pos))
		UiMotion.pulse(_pos_label, 1.12)

	var hint := _trim_hint_for_ship()
	_set_text(_trim_hint, hint[0])
	_trim_hint.add_theme_color_override("font_color", hint[1])
	_trim_bar.target = _ship.trim_efficiency
	_trim_bar.dim = _ship.hoist < 0.05
	_rig.trim = _ship.trim_efficiency
	_rig.dim_trim = _ship.hoist < 0.05

	# Step back while the player looks around, so the view is clear.
	var looking := _ship.is_orbiting()
	_view_alpha = lerpf(_view_alpha, LOOK_ALPHA if looking else 1.0, 1.0 - exp(-(9.0 if looking else 4.0) * delta))
	_dock.modulate.a = _view_alpha
	_hint_holder.modulate.a = _view_alpha
	_toast_stack.modulate.a = lerpf(0.35, 1.0, (_view_alpha - LOOK_ALPHA) / (1.0 - LOOK_ALPHA))

	_update_drawer(delta, looking)


func _unhandled_input(event: InputEvent) -> void:
	if not _intro_played:
		return
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.physical_keycode == KEY_H:
		_hints_touched = true
		_set_hints_open(not _hints_open)
		get_viewport().set_input_as_handled()


# =============================================================================
# Public API
# =============================================================================

## kind: what was found, shown before the detail ("New island", "Great island",
## "Massive island", or "Landmark" for a place on a massive island).
func announce_discovery(place_name: String, detail := "", kind := "New island") -> void:
	show_toast(place_name, kind + " · " + detail if not detail.is_empty() else kind, "discovery")


## kind: "discovery" (amber compass star) or "wind" (sea-glass gusts); the drawn
## icon and its accent tell them apart, so there is no label above the title.
func show_toast(title: String, subtitle := "", kind := "discovery") -> void:
	var data := {"title": title, "subtitle": subtitle, "kind": kind}
	if _toast_stack.get_child_count() >= MAX_TOASTS:
		_toast_queue.append(data)
	else:
		_spawn_toast(data)


## Keeps the HUD hidden until play_intro() (the title screen owns the opening).
func hold_intro() -> void:
	_intro_held = true


func play_intro() -> void:
	if _intro_played:
		return
	_intro_played = true
	_play_intro()


# =============================================================================
# Ship and wind events
# =============================================================================

func _connect_ship() -> void:
	_ship = get_tree().get_first_node_in_group("player_ship") as ShipController
	if _ship == null:
		push_warning("CozyHUD: no node in group 'player_ship'; the HUD will stay idle.")
		return
	_ship.sail_level_changed.connect(_on_sail_level_changed)
	_ship.trim_mode_changed.connect(_on_trim_mode_changed)
	_ship.throttle_changed.connect(_on_throttle_changed)
	_on_sail_level_changed(_ship.sail_level, false)
	_on_trim_mode_changed(_ship.auto_trim, false)
	_on_throttle_changed(_ship.throttle_level, false)
	_dial.snap(_ship.heading, WindManager.angle)
	_shown_kmh = _ship.get_speed_kmh()


func _auto_intro() -> void:
	if not _intro_held:
		play_intro()


func _on_sail_level_changed(level: int, animate := true) -> void:
	for i in _sail_buttons.size():
		_sail_buttons[i].set_pressed_no_signal(i == level)
	_rig.set_sail(level, animate)
	if animate and level < _sail_buttons.size() and _drawer_open:
		UiMotion.pulse(_sail_buttons[level], 1.14)


func _on_throttle_changed(level: int, animate := true) -> void:
	for i in _engine_buttons.size():
		_engine_buttons[i].set_pressed_no_signal(i == level)
	_engine_label.text = ShipController.THROTTLE_NAMES[level]
	var colour := MUTED
	if level == ShipController.Throttle.ASTERN:
		colour = CORAL
	elif level != ShipController.Throttle.STOP:
		colour = AMBER_SOFT
	_engine_label.add_theme_color_override("font_color", colour)
	_rig.set_throttle(level, animate)
	if animate and _drawer_open:
		UiMotion.pulse(_engine_buttons[level], 1.14)
		UiMotion.pulse(_engine_label, 1.12)


func _on_trim_mode_changed(is_auto: bool, animate := true) -> void:
	_trim_button.text = "AUTO" if is_auto else "HAND"
	_trim_button.set_pressed_no_signal(is_auto)
	_rig.auto_trim = is_auto
	_rig.queue_redraw()
	if animate and _drawer_open:
		UiMotion.pulse(_trim_button, 1.16)


func _on_wind_shift_started(target_angle: float, target_strength: float) -> void:
	if absf(angle_difference(WindManager.base_angle, target_angle)) < deg_to_rad(30.0):
		return
	var from := WindManager.bearing_to_cardinal(target_angle + PI)
	show_toast("Wind from the %s" % from,
		"%s · your sails will want a fresh trim" % WindManager.strength_name(target_strength), "wind")


func _on_gust_started(_peak: float) -> void:
	_dial.punch()
	UiMotion.pulse(_wind_label, 1.1)


func _point_of_sail_colour(pos: String) -> Color:
	match pos:
		"In irons":
			return CORAL
		"Close-hauled", "Close reach":
			return AMBER_SOFT
		"Beam reach", "Broad reach":
			return SEA
	return CREAM_DIM


## [text, colour] for the line under the speed readout.
func _trim_hint_for_ship() -> Array:
	var motoring := _ship.engine_rpm > 0.05
	if _ship.moored:
		return ["Moored · Space or W to cast off", SEA]
	if not _ship.berth_near.is_empty():
		if _ship.can_moor():
			return ["Space · moor at %s" % _ship.berth_near["name"], AMBER_SOFT]
		return ["Slow down to moor at %s" % _ship.berth_near["name"], MUTED]
	if _ship.speed < -0.3:
		return ["Going astern · W stops, A / D swing the stern", CORAL]
	if _ship.sail_level == ShipController.SailLevel.FURLED:
		return ["Motoring · W to hoist sail", MUTED] if motoring else ["Sails furled · W to hoist, S to back up", MUTED]
	if _ship.point_of_sail == "In irons":
		if motoring:
			return ["Motoring into the wind", MUTED]
		return ["Head to wind · bear away, or R for engine", CORAL]
	if _ship.auto_trim:
		return ["Sails auto-trimmed", MUTED]
	var over := _ship.sheet_angle - _ship.ideal_sheet_angle
	if over > deg_to_rad(8.0):
		return ["Sails luffing · haul in with Q", AMBER_SOFT]
	if over < deg_to_rad(-10.0):
		return ["Over-trimmed · ease out with E", AMBER_SOFT]
	return ["Drawing beautifully", SEA]


# =============================================================================
# Layout
# =============================================================================

func _build_dock() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "Dock"
	_dock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dock.add_theme_constant_override("separation", 8)
	add_child(_dock)

	_drawer = _build_drawer()
	_drawer.visible = false
	_dock.add_child(_drawer)
	_instrument = _build_instrument()
	_instrument.modulate.a = 0.0   # revealed by the intro
	_dock.add_child(_instrument)

	_dock.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, int(SCREEN_MARGIN))
	_dock.grow_horizontal = Control.GROW_DIRECTION_END
	_dock.grow_vertical = Control.GROW_DIRECTION_BEGIN


## The always-visible gauge: compass on the left, readouts on the right.
func _build_instrument() -> PanelContainer:
	var card := _card(Vector4(12, 12, 18, 12))
	var row := make_hbox(14)
	card.add_child(row)

	_dial = WindDial.new()
	_dial.custom_minimum_size = Vector2(112.0, 112.0)
	_dial.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_dial)

	var col := make_vbox(2)
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(col)

	var readout := make_hbox(6)
	_speed_label = make_label("0", &"Numeral")
	readout.add_child(_speed_label)
	_unit_label = make_label("km/h", &"Unit")
	_unit_label.size_flags_vertical = Control.SIZE_SHRINK_END
	_unit_label.custom_minimum_size.y = 34.0
	_unit_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	readout.add_child(_unit_label)
	readout.add_child(make_spacer())
	_pos_label = make_label("Beam reach", &"Caption")
	_pos_label.size_flags_vertical = Control.SIZE_SHRINK_END
	_pos_label.custom_minimum_size.y = 34.0
	_pos_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	readout.add_child(_pos_label)
	col.add_child(readout)

	_wind_label = make_label("fresh breeze from W", &"Caption")
	col.add_child(_wind_label)
	_trim_hint = make_label("Auto-trimmed", &"Caption")
	col.add_child(_trim_hint)
	col.add_child(make_gap(4))
	_rig = RigStatus.new()
	col.add_child(_rig)
	return card


## Full controls; slides up above the instrument while the pointer is over it.
func _build_drawer() -> PanelContainer:
	var card := _card(Vector4(16, 14, 16, 14))
	var col := make_vbox(6)
	card.add_child(col)

	col.add_child(make_label("SAILS", &"Eyebrow"))
	var sails := make_hbox(6)
	var group := ButtonGroup.new()
	for i in SAIL_SHORT.size():
		var b := Button.new()
		b.text = SAIL_SHORT[i]
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = "%s  (W / S)" % ShipController.SAIL_LEVEL_NAMES[i]
		b.pressed.connect(_on_sail_button_pressed.bind(i))
		UiMotion.make_tactile(b)
		sails.add_child(b)
		_sail_buttons.append(b)
	col.add_child(sails)

	col.add_child(make_gap(2))
	var trim := make_hbox(10)
	trim.add_child(make_label("TRIM", &"Eyebrow"))
	_trim_bar = TrimBar.new()
	_trim_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trim_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	trim.add_child(_trim_bar)
	_trim_button = Button.new()
	_trim_button.text = "AUTO"
	_trim_button.theme_type_variation = &"Pill"
	_trim_button.toggle_mode = true
	_trim_button.focus_mode = Control.FOCUS_NONE
	_trim_button.custom_minimum_size.x = 58.0
	_trim_button.tooltip_text = "Auto-trim the sheet  (T)"
	_trim_button.pressed.connect(func() -> void:
		if _ship:
			_ship.set_auto_trim(not _ship.auto_trim))
	UiMotion.make_tactile(_trim_button, 1.08, 0.9)
	trim.add_child(_trim_button)
	col.add_child(trim)

	col.add_child(make_gap(2))
	var engine_head := make_hbox(8)
	engine_head.add_child(make_label("ENGINE", &"Eyebrow"))
	engine_head.add_child(make_spacer())
	_engine_label = make_label("Stop", &"Caption")
	engine_head.add_child(_engine_label)
	col.add_child(engine_head)
	var engine := make_hbox(5)
	var engine_group := ButtonGroup.new()
	for i in ENGINE_SHORT.size():
		var b := Button.new()
		b.text = ENGINE_SHORT[i]
		b.theme_type_variation = &"Segment"
		b.toggle_mode = true
		b.button_group = engine_group
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = "%s  (R / F)" % ShipController.THROTTLE_NAMES[i]
		if i == ShipController.Throttle.ASTERN:
			# Astern lights coral rather than amber: it's the "careful" setting.
			for state: StringName in [&"pressed", &"hover_pressed"]:
				var sb := (theme.get_stylebox(state, &"Segment") as StyleBoxFlat).duplicate() as StyleBoxFlat
				sb.bg_color = CORAL if state == &"pressed" else CORAL.lightened(0.12)
				sb.border_color = CORAL.lightened(0.2)
				b.add_theme_stylebox_override(state, sb)
		b.pressed.connect(_on_engine_button_pressed.bind(i))
		UiMotion.make_tactile(b)
		engine.add_child(b)
		_engine_buttons.append(b)
	col.add_child(engine)
	return card


func _on_engine_button_pressed(level: int) -> void:
	if _ship:
		_ship.set_throttle(level)


func _on_sail_button_pressed(level: int) -> void:
	if _ship:
		_ship.set_sail_level(level)


func _update_drawer(delta: float, looking: bool) -> void:
	if not _intro_played:
		return
	var mouse := get_global_mouse_position()
	var over := _instrument.get_global_rect().has_point(mouse) \
		or (_drawer.visible and _drawer.get_global_rect().grow(10.0).has_point(mouse))
	if over and not looking:
		_drawer_linger = DRAWER_LINGER
	else:
		_drawer_linger -= delta
	var want := _drawer_linger > 0.0
	if want != _drawer_open:
		_set_drawer_open(want)


func _set_drawer_open(open: bool) -> void:
	_drawer_open = open
	_drawer.pivot_offset = Vector2(0.0, _drawer.size.y)
	if open:
		_drawer.scale = Vector2(0.94, 0.94)
		UiMotion.fade(_drawer, true, 0.2)
		UiMotion.spring(_drawer, ^"scale", Vector2.ONE, 0.7)
	else:
		UiMotion.fade(_drawer, false, 0.16)
		UiMotion.spring(_drawer, ^"scale", Vector2(0.96, 0.96), 0.4)


func _build_toast_stack() -> void:
	_toast_stack = VBoxContainer.new()
	_toast_stack.name = "Toasts"
	_toast_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_stack.add_theme_constant_override("separation", 0)
	add_child(_toast_stack)
	_toast_stack.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, int(SCREEN_MARGIN))
	_toast_stack.grow_horizontal = Control.GROW_DIRECTION_BOTH


func _build_hints() -> void:
	_hint_holder = Control.new()
	_hint_holder.name = "Hints"
	_hint_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint_holder)
	_hint_holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_hints = PanelContainer.new()
	_hints.theme_type_variation = &"HintPanel"
	_hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hints.add_child(build_controls_list(6))

	_hint_chip = PanelContainer.new()
	_hint_chip.theme_type_variation = &"HintPanel"
	_hint_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var chip_row := make_hbox(6)
	for pair: Array in [["H", "Controls"], ["Esc", "Pause"]]:
		chip_row.add_child(make_keycap(pair[0]))
		var chip_text := make_label(pair[1], &"Caption")
		chip_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		chip_row.add_child(chip_text)
		chip_row.add_child(make_gap(4))
	_hint_chip.add_child(chip_row)
	_hint_chip.visible = false

	for panel: PanelContainer in [_hints, _hint_chip]:
		_hint_holder.add_child(panel)
		panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, int(SCREEN_MARGIN))
		panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
		panel.resized.connect(func() -> void: panel.pivot_offset = panel.size)


## Key caps and labels for every control; shared with the pause menu.
static func build_controls_list(separation := 7) -> VBoxContainer:
	var col := make_vbox(separation)
	for entry: Array in HINT_ROWS:
		var row := make_hbox(5)
		for key: String in entry[0]:
			row.add_child(make_keycap(key))
		var text := make_label(entry[1], &"Caption")
		text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(make_gap(4))
		row.add_child(text)
		col.add_child(row)
	return col


func _set_hints_open(open: bool) -> void:
	_hints_open = open
	var show_panel := _hints if open else _hint_chip
	var hide_panel := _hint_chip if open else _hints
	var out := hide_panel.create_tween().set_parallel()
	out.tween_property(hide_panel, "modulate:a", 0.0, 0.18).set_trans(Tween.TRANS_SINE)
	out.tween_property(hide_panel, "scale", Vector2(0.9, 0.9), 0.18).set_trans(Tween.TRANS_SINE)
	out.chain().tween_callback(func() -> void: hide_panel.visible = false)

	show_panel.visible = true
	show_panel.modulate.a = 0.0
	show_panel.scale = Vector2(0.86, 0.86)
	var tw := show_panel.create_tween().set_parallel()
	tw.tween_property(show_panel, "modulate:a", 1.0, 0.25).set_delay(0.12).set_trans(Tween.TRANS_SINE)
	tw.tween_property(show_panel, "scale", Vector2.ONE, 0.75).set_delay(0.12) \
		.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)


func _play_intro() -> void:
	_dock.visible = true
	_hint_holder.visible = true
	await get_tree().process_frame
	var rest_y := _dock.position.y
	_dock.position.y = rest_y + 40.0
	var slide := _dock.create_tween()
	slide.tween_property(_dock, "position:y", rest_y, 0.8).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_instrument.pivot_offset = _instrument.size * 0.5
	_instrument.scale = Vector2(0.86, 0.86)
	var tw := _instrument.create_tween().set_parallel()
	tw.tween_property(_instrument, "modulate:a", 1.0, 0.35).set_delay(0.1).set_trans(Tween.TRANS_SINE)
	tw.tween_property(_instrument, "scale", Vector2.ONE, 0.9).set_delay(0.1) \
		.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	_hints.modulate.a = 0.0
	_hints.create_tween().tween_property(_hints, "modulate:a", 1.0, 0.6).set_delay(0.5)
	get_tree().create_timer(HINT_AUTO_HIDE).timeout.connect(func() -> void:
		if _hints_open and not _hints_touched:
			_set_hints_open(false))

	await get_tree().create_timer(0.9).timeout
	if VoyageLog.time_at_sea > 1.0:
		var found := VoyageLog.discoveries.size()
		show_toast("Back at sea", "%s sailed · %d %s on your chart" % [GameSettings.format_distance(VoyageLog.distance_sailed),
			found, "island" if found == 1 else "islands"])
	else:
		show_toast("A new voyage", "Follow the wind. Every horizon hides an island.")


# =============================================================================
# Toasts
# =============================================================================

func _spawn_toast(data: Dictionary) -> void:
	var kind: String = data["kind"]
	var accent := SEA if kind == "wind" else AMBER

	var toast := PanelContainer.new()
	toast.theme_type_variation = &"ToastPanel"
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var outer := make_vbox(0)
	toast.add_child(outer)
	var row := make_hbox(14)
	var icon := ToastIcon.new()
	icon.kind = kind
	icon.accent = accent
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)
	var text := make_vbox(2)
	text.add_child(make_label(data["title"], &"ToastTitle"))
	if not String(data["subtitle"]).is_empty():
		text.add_child(make_label(data["subtitle"], &"Caption"))
	row.add_child(text)
	outer.add_child(row)
	outer.add_child(make_gap(12))
	var timer_line := ColorRect.new()
	timer_line.color = Color(accent, 0.55)
	timer_line.custom_minimum_size.y = 2.0
	timer_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(timer_line)

	# The slot lives in the VBox and animates its height; the toast inside it is free
	# to slide, so neighbours glide out of the way instead of jumping.
	var slot := Control.new()
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(toast)
	_toast_stack.add_child(slot)
	var min_size := toast.get_combined_minimum_size()
	var toast_size := Vector2(maxf(TOAST_WIDTH, min_size.x), min_size.y)
	slot.custom_minimum_size = Vector2(toast_size.x, 0.0)
	toast.size = toast_size
	toast.pivot_offset = toast_size * 0.5
	toast.position = Vector2(0.0, -32.0)
	toast.modulate.a = 0.0
	toast.scale = Vector2(0.92, 0.92)

	var tw := toast.create_tween()
	tw.tween_property(slot, "custom_minimum_size:y", toast_size.y + TOAST_GAP, 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(toast, "position:y", 0.0, 0.65) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(toast, "modulate:a", 1.0, 0.25).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(toast, "scale", Vector2.ONE, 0.85) \
		.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	# The thin line drains while the toast holds, so the player can see it is about to go.
	tw.parallel().tween_property(timer_line, "scale:x", 0.0, TOAST_HOLD + 0.65).from(1.0)
	tw.tween_property(toast, "modulate:a", 0.0, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(toast, "position:y", -14.0, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_property(slot, "custom_minimum_size:y", 0.0, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(slot.queue_free)
	tw.tween_callback(_drain_toast_queue)


func _drain_toast_queue() -> void:
	if not _toast_queue.is_empty():
		_spawn_toast(_toast_queue.pop_front())


# =============================================================================
# Small builders (static: the title and pause screens use them too)
# =============================================================================

## A warm ink card whose border warms and which lifts a touch on hover.
func _card(margins: Vector4) -> PanelContainer:
	var card := PanelContainer.new()
	var style := (theme.get_stylebox(&"panel", &"PanelContainer") as StyleBoxFlat).duplicate() as StyleBoxFlat
	style.content_margin_left = margins.x
	style.content_margin_top = margins.y
	style.content_margin_right = margins.z
	style.content_margin_bottom = margins.w
	card.add_theme_stylebox_override(&"panel", style)
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	card.mouse_entered.connect(func() -> void: UiMotion.spring(style, ^"border_color", Color(AMBER, 0.42), 0.5, card))
	card.mouse_exited.connect(func() -> void: UiMotion.spring(style, ^"border_color", LINE, 0.5, card))
	return card


static func make_keycap(key: String) -> PanelContainer:
	var cap := PanelContainer.new()
	cap.theme_type_variation = &"KeyCap"
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var text := make_label(key, &"KeyCapLabel")
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.custom_minimum_size.x = 24.0
	cap.add_child(text)
	return cap


static func make_label(text: String, variation := &"") -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


static func make_vbox(separation: int) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return box


static func make_hbox(separation: int) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", separation)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return box


static func make_spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func make_gap(px: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(px, px)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func _set_text(label: Label, text: String) -> void:
	if label.text != text:
		label.text = text


# =============================================================================
# Theme
# =============================================================================

static func build_theme() -> Theme:
	var t := Theme.new()
	var regular := _system_font(500)
	var strong := _system_font(600)
	var heavy := _system_font(700)
	var tracked := FontVariation.new()
	tracked.base_font = strong
	tracked.spacing_glyph = 2
	var numerals := FontVariation.new()
	numerals.base_font = heavy
	numerals.opentype_features = {TextServerManager.get_primary_interface().name_to_tag("tnum"): 1}

	t.default_font = regular
	t.default_font_size = 15

	t.set_color(&"font_color", &"Label", CREAM)
	_variation(t, &"Eyebrow", &"Label", tracked, 11, MUTED)
	_variation(t, &"Caption", &"Label", regular, 13, MUTED)
	_variation(t, &"Body", &"Label", regular, 14, CREAM)
	_variation(t, &"Numeral", &"Label", numerals, 40, CREAM)
	_variation(t, &"Unit", &"Label", strong, 14, MUTED)
	_variation(t, &"ToastTitle", &"Label", heavy, 20, CREAM)
	_variation(t, &"KeyCapLabel", &"Label", strong, 11, CREAM)

	t.set_stylebox(&"panel", &"PanelContainer", _flat(INK, CARD_RADIUS, Vector4(18, 16, 18, 16), LINE, 14))

	t.set_type_variation(&"ToastPanel", &"PanelContainer")
	t.set_stylebox(&"panel", &"ToastPanel", _flat(Color(INK, 0.9), 16, Vector4(16, 14, 22, 12), LINE, 20))

	t.set_type_variation(&"HintPanel", &"PanelContainer")
	t.set_stylebox(&"panel", &"HintPanel", _flat(Color(INK, 0.62), 14, Vector4(12, 10, 14, 10), Color(LINE, 0.1), 0))

	t.set_type_variation(&"KeyCap", &"PanelContainer")
	var cap := _flat(WELL_HOVER, 6, Vector4(6, 2, 6, 3), LINE, 0)
	cap.border_width_bottom = 2
	t.set_stylebox(&"panel", &"KeyCap", cap)

	# Buttons: quiet wells that fill with amber when selected.
	var normal := _flat(WELL, 10, Vector4(10, 7, 10, 7), Color(LINE, 0.1), 0)
	var hover := _flat(WELL_HOVER, 10, Vector4(10, 7, 10, 7), LINE, 0)
	var pressed := _flat(AMBER, 10, Vector4(10, 7, 10, 7), AMBER_SOFT, 0)
	var hover_pressed := _flat(AMBER_SOFT, 10, Vector4(10, 7, 10, 7), AMBER_SOFT, 0)
	var focus := _flat(Color(0, 0, 0, 0), 11, Vector4.ZERO, AMBER, 0)
	focus.draw_center = false
	focus.set_border_width_all(2)
	focus.set_expand_margin_all(2)
	t.set_stylebox(&"normal", &"Button", normal)
	t.set_stylebox(&"hover", &"Button", hover)
	t.set_stylebox(&"pressed", &"Button", pressed)
	t.set_stylebox(&"hover_pressed", &"Button", hover_pressed)
	t.set_stylebox(&"disabled", &"Button", normal)
	t.set_stylebox(&"focus", &"Button", focus)
	t.set_font(&"font", &"Button", strong)
	t.set_font_size(&"font_size", &"Button", 13)
	t.set_color(&"font_color", &"Button", CREAM_DIM)
	t.set_color(&"font_hover_color", &"Button", CREAM)
	t.set_color(&"font_focus_color", &"Button", CREAM)
	t.set_color(&"font_pressed_color", &"Button", INK_SOLID)
	t.set_color(&"font_hover_pressed_color", &"Button", INK_SOLID)

	# Pill: small rounded toggle (AUTO / HAND, On / Off).
	t.set_type_variation(&"Pill", &"Button")
	for state: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled"]:
		var sb := (t.get_stylebox(state, &"Button") as StyleBoxFlat).duplicate() as StyleBoxFlat
		sb.set_corner_radius_all(99)
		sb.content_margin_top = 3
		sb.content_margin_bottom = 3
		if state == &"pressed" or state == &"hover_pressed":
			sb.bg_color = Color(SEA, 0.9 if state == &"pressed" else 1.0)
			sb.border_color = SEA
		t.set_stylebox(state, &"Pill", sb)
	var pill_focus := focus.duplicate() as StyleBoxFlat
	pill_focus.set_corner_radius_all(99)
	t.set_stylebox(&"focus", &"Pill", pill_focus)
	t.set_font(&"font", &"Pill", tracked)
	t.set_font_size(&"font_size", &"Pill", 10)

	# Segment: a tighter button for five-way rows (the engine telegraph).
	t.set_type_variation(&"Segment", &"Button")
	for state: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled", &"focus"]:
		var sb := (t.get_stylebox(state, &"Button") as StyleBoxFlat).duplicate() as StyleBoxFlat
		if state != &"focus":
			sb.content_margin_left = 4
			sb.content_margin_right = 4
		t.set_stylebox(state, &"Segment", sb)
	t.set_font_size(&"font_size", &"Segment", 12)

	# Sliders (settings): a cream well that fills amber, with a round grabber.
	var track := _flat(WELL_HOVER, 3, Vector4(0, 3, 0, 3), Color(0, 0, 0, 0), 0)
	var fill := _flat(AMBER, 3, Vector4(0, 3, 0, 3), Color(0, 0, 0, 0), 0)
	var fill_hover := _flat(AMBER_SOFT, 3, Vector4(0, 3, 0, 3), Color(0, 0, 0, 0), 0)
	t.set_stylebox(&"slider", &"HSlider", track)
	t.set_stylebox(&"grabber_area", &"HSlider", fill)
	t.set_stylebox(&"grabber_area_highlight", &"HSlider", fill_hover)
	t.set_icon(&"grabber", &"HSlider", _disc_texture(9, CREAM, AMBER))
	t.set_icon(&"grabber_highlight", &"HSlider", _disc_texture(10, CREAM, AMBER_SOFT))
	t.set_icon(&"grabber_disabled", &"HSlider", _disc_texture(9, MUTED, MUTED))
	t.set_icon(&"tick", &"HSlider", ImageTexture.new())
	var slider_focus := focus.duplicate() as StyleBoxFlat
	slider_focus.set_corner_radius_all(6)
	slider_focus.set_expand_margin_all(6)
	t.set_stylebox(&"focus", &"HSlider", slider_focus)

	t.set_stylebox(&"panel", &"TooltipPanel", _flat(Color(INK_SOLID, 0.96), 8, Vector4(10, 6, 10, 6), LINE, 8))
	t.set_color(&"font_color", &"TooltipLabel", CREAM)
	t.set_font_size(&"font_size", &"TooltipLabel", 12)

	_add_menu_styles(t, strong, numerals)
	return t


## Title and pause screens: ink lettering straight onto the sea haze, no panels.
static func _add_menu_styles(t: Theme, strong: Font, numerals: Font) -> void:
	var display := load(DISPLAY_FONT_PATH) as FontFile
	# Anything outside Marcellus' Latin set falls through to the UI face.
	display.fallbacks = [strong]
	var display_tracked := FontVariation.new()
	display_tracked.base_font = display
	display_tracked.spacing_glyph = 2
	var lead := FontVariation.new()
	lead.base_font = display
	lead.spacing_glyph = 9
	var item := FontVariation.new()
	item.base_font = strong
	item.spacing_glyph = 3

	_variation(t, &"DisplayTitle", &"Label", display_tracked, 60, INK_TEXT)
	_variation(t, &"DisplayLead", &"Label", lead, 18, INK_FAINT)
	_variation(t, &"MenuLine", &"Label", _system_font(500), 15, INK_FAINT)
	_variation(t, &"MenuFoot", &"Label", _system_font(500), 13, Color(INK_TEXT, 0.6))

	t.set_type_variation(&"MenuKey", &"PanelContainer")
	var key_cap := _flat(Color(HAZE, 0.35), 5, Vector4(6, 1, 6, 2), Color(INK_TEXT, 0.4), 0)
	key_cap.border_width_bottom = 2
	t.set_stylebox(&"panel", &"MenuKey", key_cap)
	_variation(t, &"MenuKeyLabel", &"Label", strong, 11, Color(INK_TEXT, 0.75))
	t.set_type_variation(&"MenuFootPanel", &"PanelContainer")
	t.set_stylebox(&"panel", &"MenuFootPanel", _flat(Color(HAZE, 0.62), 99, Vector4(16, 6, 18, 6), Color(0, 0, 0, 0), 0))


	var empty := StyleBoxEmpty.new()
	empty.content_margin_left = 12
	empty.content_margin_right = 12
	empty.content_margin_top = HorizonMenu.LABEL_TOP
	empty.content_margin_bottom = 6
	for variation: StringName in [&"HorizonItem", &"HorizonPrimary"]:
		t.set_type_variation(variation, &"Button")
		for state: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled", &"focus"]:
			t.set_stylebox(state, variation, empty)
		t.set_font(&"font", variation, item)
		t.set_color(&"font_color", variation, INK_FAINT)
		for state: StringName in [&"font_hover_color", &"font_focus_color", &"font_pressed_color", &"font_hover_pressed_color"]:
			t.set_color(state, variation, EMBER)
		# Set back (not gone) while a card is open over the menu.
		t.set_color(&"font_disabled_color", variation, Color(INK_TEXT, 0.34))
	t.set_font_size(&"font_size", &"HorizonItem", 13)
	t.set_font_size(&"font_size", &"HorizonPrimary", 16)
	t.set_color(&"font_color", &"HorizonPrimary", INK_TEXT)

	# Full-screen pages (settings, controls): the same ink on a denser sheet of haze.
	var page_title := FontVariation.new()
	page_title.base_font = display
	page_title.spacing_glyph = 5
	_variation(t, &"PageTitle", &"Label", page_title, 40, INK_TEXT)
	_variation(t, &"PageRow", &"Label", _system_font(500), 16, INK_TEXT)
	_variation(t, &"PageNote", &"Label", _system_font(500), 13, INK_FAINT)
	_variation(t, &"PageValue", &"Label", numerals, 15, EMBER)
	_variation(t, &"PageValueOff", &"Label", numerals, 15, INK_FAINT)
	_variation(t, &"PageGroup", &"Label", item, 11, INK_FAINT)
	t.set_type_variation(&"PageKey", &"PanelContainer")
	var page_cap := _flat(Color(1.0, 0.96, 0.9, 0.45), 6, Vector4(9, 3, 9, 4), Color(INK_TEXT, 0.42), 0)
	page_cap.border_width_bottom = 2
	t.set_stylebox(&"panel", &"PageKey", page_cap)
	_variation(t, &"PageKeyLabel", &"Label", strong, 13, INK_TEXT)

	# Page sliders: an inked groove that fills ember, with a cream bead.
	t.set_type_variation(&"PageSlider", &"HSlider")
	t.set_stylebox(&"slider", &"PageSlider", _flat(Color(INK_TEXT, 0.13), 3, Vector4(0, 3, 0, 3), Color(0, 0, 0, 0), 0))
	t.set_stylebox(&"grabber_area", &"PageSlider", _flat(EMBER, 3, Vector4(0, 3, 0, 3), Color(0, 0, 0, 0), 0))
	t.set_stylebox(&"grabber_area_highlight", &"PageSlider", _flat(EMBER.lightened(0.12), 3, Vector4(0, 3, 0, 3), Color(0, 0, 0, 0), 0))
	t.set_icon(&"grabber", &"PageSlider", _disc_texture(10, CREAM, EMBER))
	t.set_icon(&"grabber_highlight", &"PageSlider", _disc_texture(11, CREAM, EMBER.lightened(0.12)))
	t.set_icon(&"grabber_disabled", &"PageSlider", _disc_texture(10, HAZE, INK_FAINT))
	t.set_icon(&"tick", &"PageSlider", ImageTexture.new())
	var page_focus := _flat(Color(0, 0, 0, 0), 8, Vector4.ZERO, EMBER, 0)
	page_focus.draw_center = false
	page_focus.set_border_width_all(2)
	page_focus.set_expand_margin_all(8)
	t.set_stylebox(&"focus", &"PageSlider", page_focus)

	# Page scroll bars: a slim inked grabber on no track at all.
	var bar := StyleBoxEmpty.new()
	bar.content_margin_left = 3
	bar.content_margin_right = 3
	t.set_stylebox(&"scroll", &"VScrollBar", bar)
	t.set_stylebox(&"scroll_focus", &"VScrollBar", bar)
	t.set_stylebox(&"grabber", &"VScrollBar", _flat(Color(INK_TEXT, 0.22), 3, Vector4.ZERO, Color(0, 0, 0, 0), 0))
	t.set_stylebox(&"grabber_highlight", &"VScrollBar", _flat(Color(INK_TEXT, 0.38), 3, Vector4.ZERO, Color(0, 0, 0, 0), 0))
	t.set_stylebox(&"grabber_pressed", &"VScrollBar", _flat(EMBER, 3, Vector4.ZERO, Color(0, 0, 0, 0), 0))


static func _variation(t: Theme, type_name: StringName, base: StringName, font: Font, font_size: int, colour: Color) -> void:
	t.set_type_variation(type_name, base)
	t.set_font(&"font", type_name, font)
	t.set_font_size(&"font_size", type_name, font_size)
	t.set_color(&"font_color", type_name, colour)


static func _system_font(weight: int) -> SystemFont:
	var f := SystemFont.new()
	f.font_names = FONT_NAMES
	f.font_weight = weight
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.hinting = TextServer.HINTING_LIGHT
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return f


## margins = (left, top, right, bottom)
static func _flat(bg: Color, radius: int, margins: Vector4, border: Color, shadow: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 10
	sb.anti_aliasing = true
	sb.content_margin_left = margins.x
	sb.content_margin_top = margins.y
	sb.content_margin_right = margins.z
	sb.content_margin_bottom = margins.w
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(1)
	if shadow > 0:
		sb.shadow_color = SHADOW
		sb.shadow_size = shadow
		sb.shadow_offset = Vector2(0, shadow * 0.4)
	return sb


## An antialiased disc with a coloured ring, drawn at 2x and filtered down.
static func _disc_texture(radius: int, fill: Color, ring: Color) -> ImageTexture:
	var size := radius * 2 + 2
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(size, size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			var edge := clampf(radius - d + 0.5, 0.0, 1.0)
			var inner := clampf(radius - 2.5 - d + 0.5, 0.0, 1.0)
			var col := ring.lerp(fill, inner)
			col.a *= edge
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


# =============================================================================
# Custom-drawn widgets
# =============================================================================

## Compass rose that turns with the ship (bow always up), a wind arrow blowing in
## from the rim, a coral no-go wedge where the boat would stall head to wind, and
## a tiny boat glyph whose boom mirrors the real sheet. Angles ride on springs.
## Drawn for any size; the geometry was laid out at radius 84 and scales with k.
class WindDial extends Control:
	const STIFFNESS := 70.0
	const DAMPING := 10.0
	const NO_GO := 0.66   # half-width of the no-go wedge, radians (~38 deg)

	var heading_target := 0.0
	var wind_target := 0.0
	var strength := 0.5
	var boom := 0.0
	var _heading := 0.0
	var _heading_vel := 0.0
	var _wind := 0.0
	var _wind_vel := 0.0
	var _flow := 0.0
	var _punch := 1.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func snap(heading: float, wind: float) -> void:
		_heading = heading
		_wind = wind
		heading_target = heading
		wind_target = wind
		_heading_vel = 0.0
		_wind_vel = 0.0

	func punch() -> void:
		var tw := create_tween()
		tw.tween_property(self, "_punch", 1.35, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(self, "_punch", 1.0, 0.9).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)

	func _process(delta: float) -> void:
		delta = minf(delta, 1.0 / 30.0)
		_heading_vel += (wrapf(heading_target - _heading, -PI, PI) * STIFFNESS - _heading_vel * DAMPING) * delta
		_heading = wrapf(_heading + _heading_vel * delta, 0.0, TAU)
		_wind_vel += (wrapf(wind_target - _wind, -PI, PI) * STIFFNESS - _wind_vel * DAMPING) * delta
		_wind = wrapf(_wind + _wind_vel * delta, 0.0, TAU)
		_flow = fposmod(_flow + delta * lerpf(0.35, 1.1, strength), 1.0)
		queue_redraw()

	## Screen direction of a bearing measured clockwise from "up".
	static func _dir(bearing: float) -> Vector2:
		return Vector2(sin(bearing), -cos(bearing))

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 2.0
		var k := r / 84.0
		draw_circle(c, r, Color(0.0, 0.0, 0.0, 0.2))

		# No-go wedge around where the wind comes from.
		var from := _wind - _heading + PI
		var wedge := PackedVector2Array([c])
		for i in 13:
			wedge.append(c + _dir(from - NO_GO + 2.0 * NO_GO * float(i) / 12.0) * (r - 3.0))
		draw_colored_polygon(wedge, Color(CozyHUD.CORAL, 0.14))
		draw_arc(c, r, 0.0, TAU, 72, CozyHUD.LINE, 1.5, true)

		# Ticks every 15 degrees, longer at 90.
		for i in 24:
			var d := _dir(deg_to_rad(i * 15.0) - _heading)
			var major := i % 6 == 0
			var mid := i % 2 == 0
			var length := (9.0 if major else (6.0 if mid else 4.0)) * k + 1.0
			var colour := CozyHUD.MUTED if major or mid else CozyHUD.LINE
			draw_line(c + d * (r - 4.0 * k - length), c + d * (r - 4.0 * k), colour, 1.5 if major else 1.0, true)

		var font := get_theme_default_font()
		var font_size := clampi(roundi(13.0 * k), 10, 13)
		for i in 4:
			var letter: String = ["N", "E", "S", "W"][i]
			var bearing := i * PI * 0.5 - _heading
			var p := c + _dir(bearing) * (r - 17.0 * k - font_size * 0.8)
			var w := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var baseline := font.get_ascent(font_size) - font.get_height(font_size) * 0.5
			var colour := CozyHUD.AMBER if i == 0 else CozyHUD.CREAM_DIM
			# Letters step aside (fade) when the wind arrow passes over them.
			colour.a *= lerpf(0.12, 1.0, smoothstep(0.18, 0.42, absf(angle_difference(bearing, from))))
			draw_string(font, p + Vector2(-w * 0.5, baseline), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colour)

		# Bow marker at the top of the ring.
		draw_colored_polygon(PackedVector2Array([
			c + Vector2(0.0, -r + 3.0 * k), c + Vector2(-5.0 * k, -r + 11.0 * k), c + Vector2(5.0 * k, -r + 11.0 * k)]),
			CozyHUD.CREAM)

		# Boat glyph, bow up, with the boom showing the current trim.
		var g := maxf(k, 0.75)
		var hull := PackedVector2Array()
		for p: Vector2 in [Vector2(0, -16), Vector2(6, -6), Vector2(6.5, 7), Vector2(4, 13),
				Vector2(-4, 13), Vector2(-6.5, 7), Vector2(-6, -6)]:
			hull.append(c + p * g)
		draw_colored_polygon(hull, Color(CozyHUD.CREAM, 0.92))
		var mast := c + Vector2(0.0, -4.0) * g
		draw_line(mast, mast + Vector2(sin(boom), cos(boom)) * 14.0 * g, CozyHUD.INK_SOLID, 2.0, true)
		draw_circle(mast, 2.0, CozyHUD.INK_SOLID)

		# Wind arrow blowing in from the rim toward the boat.
		var fd := _dir(from)
		var perp := Vector2(-fd.y, fd.x)
		var tail := c + fd * (r - 16.0 * k)
		var tip := c + fd * 25.0 * g
		var width := maxf(3.0 * k, 2.0) * _punch
		var head := 12.0 * k * _punch
		var spread := 7.0 * k * _punch
		draw_line(tail, tip + fd * head * 0.8, CozyHUD.AMBER, width, true)
		draw_colored_polygon(PackedVector2Array([tip, tip + fd * head + perp * spread, tip + fd * head - perp * spread]),
			CozyHUD.AMBER)
		for n in 2:
			var base := tail - fd * (n * 6.0 * k)
			draw_line(base, base + fd * 6.0 * k + perp * 6.0 * k, CozyHUD.AMBER, 2.0, true)
			draw_line(base, base + fd * 6.0 * k - perp * 6.0 * k, CozyHUD.AMBER, 2.0, true)
		# Flow dots travel down the arrow faster in stronger wind.
		for n in 3:
			var t := fposmod(_flow + n / 3.0, 1.0)
			draw_circle(tail.lerp(tip + fd * head, t), 1.8, Color(CozyHUD.CREAM, sin(t * PI) * 0.9))


## One line of tiny gauges under the readouts:
##   sail glyph + four hoist bars | propeller glyph + astern, stop, three ahead | trim bar + AUTO/HAND
## Each pip fills on a spring when the level changes.
class RigStatus extends Control:
	const BAR_W := 7.0
	const PIP_R := 4.0
	const PIP_STEP := 12.5
	const TRIM_W := 46.0

	var trim := 1.0
	var dim_trim := false
	var auto_trim := true
	var _sail_fill: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var _engine_fill: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	var _sail_tweens: Array[Tween] = [null, null, null, null]
	var _engine_tweens: Array[Tween] = [null, null, null, null, null]
	var _trim_shown := 1.0
	var _style := StyleBoxFlat.new()

	func _init() -> void:
		custom_minimum_size = Vector2(286.0, 22.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_style.set_corner_radius_all(2)
		_style.anti_aliasing = true

	## Fills bars 1..level (level 0 = furled, nothing up).
	func set_sail(level: int, animate: bool) -> void:
		for i in 4:
			_set_fill(_sail_fill, _sail_tweens, i, 1.0 if i < level else 0.0, absf(i - level) * 0.04, animate)

	## Pip 0 = astern, 1 = stop, 2..4 = slow, half, full ahead (filled up to the level).
	func set_throttle(level: int, animate: bool) -> void:
		for i in 5:
			var on := false
			if i <= 1:
				on = i == level
			else:
				on = level >= i
			_set_fill(_engine_fill, _engine_tweens, i, 1.0 if on else 0.0, absf(i - level) * 0.04, animate)

	func _set_fill(fills: Array[float], tweens: Array[Tween], i: int, target: float, delay: float, animate: bool) -> void:
		if tweens[i] and tweens[i].is_valid():
			tweens[i].kill()
		if not animate:
			fills[i] = target
			queue_redraw()
			return
		if is_equal_approx(fills[i], target):
			return
		var tw := create_tween().set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
		tw.tween_method(func(v: float) -> void:
			fills[i] = v
			queue_redraw(), fills[i], target, 0.6).set_delay(delay)
		tweens[i] = tw

	func _process(delta: float) -> void:
		var next := lerpf(_trim_shown, trim, 1.0 - exp(-8.0 * delta))
		if absf(next - _trim_shown) > 0.0005:
			_trim_shown = next
			queue_redraw()

	func _draw() -> void:
		var mid := size.y * 0.5
		var x := 0.0
		var glyph := CozyHUD.CREAM_DIM

		# Sail glyph (mast and a triangle of canvas), then hoist bars rising left to right.
		draw_line(Vector2(x + 2.0, mid + 8.0), Vector2(x + 2.0, mid - 8.0), glyph, 1.6, true)
		draw_colored_polygon(PackedVector2Array([Vector2(x + 3.5, mid - 7.0), Vector2(x + 3.5, mid + 6.0),
			Vector2(x + 13.0, mid + 6.0)]), glyph)
		x += 20.0
		for i in 4:
			var full_h := 7.0 + i * 3.5
			var f := clampf(_sail_fill[i], 0.0, 1.2)
			var h := full_h * (0.75 + 0.25 * f)
			_style.bg_color = CozyHUD.WELL_HOVER.lerp(CozyHUD.AMBER, clampf(f, 0.0, 1.0))
			draw_style_box(_style, Rect2(x, mid + 8.0 - h, BAR_W, h))
			x += BAR_W + 3.0
		x += 14.0

		# Propeller glyph, then the telegraph: astern (coral), stop (ring), three ahead.
		var hub := Vector2(x + 7.0, mid)
		for b in 3:
			var a := b * TAU / 3.0 - PI * 0.5
			var d := Vector2(cos(a), sin(a))
			draw_line(hub + d * 1.5, hub + d * 7.5, glyph, 3.4, true)
		draw_circle(hub, 2.0, CozyHUD.INK_SOLID)
		x += 22.0
		for i in 5:
			var p := Vector2(x + PIP_R, mid)
			var f := clampf(_engine_fill[i], 0.0, 1.0)
			var lit := CozyHUD.AMBER
			if i == 0:
				lit = CozyHUD.CORAL
			elif i == 1:
				lit = CozyHUD.CREAM
			var r := PIP_R * (0.85 + 0.25 * _engine_fill[i])
			draw_circle(p, r, CozyHUD.WELL_HOVER.lerp(lit, f), true, -1.0, true)
			if i == 1:
				# Stop sits apart as a hollow ring between astern and ahead.
				draw_arc(p, PIP_R + 1.8, 0.0, TAU, 20, Color(CozyHUD.CREAM, 0.25 + 0.3 * f), 1.0, true)
			x += PIP_STEP + (3.0 if i == 1 or i == 0 else 0.0)
		x += 10.0

		# Trim: coral when the sail flogs or stalls, amber when close, sea-glass when drawing.
		var track := Rect2(x, mid - 2.5, TRIM_W, 5.0)
		_style.bg_color = CozyHUD.WELL_HOVER
		draw_style_box(_style, track)
		var colour := CozyHUD.CORAL.lerp(CozyHUD.AMBER, smoothstep(0.35, 0.7, _trim_shown)) \
			.lerp(CozyHUD.SEA, smoothstep(0.75, 0.95, _trim_shown))
		if dim_trim:
			colour = Color(colour.darkened(0.35), 0.45)
		_style.bg_color = colour
		draw_style_box(_style, Rect2(track.position, Vector2(maxf(TRIM_W * _trim_shown, 5.0), 5.0)))
		x += TRIM_W + 7.0
		var font := get_theme_default_font()
		var mode := "AUTO" if auto_trim else "HAND"
		var baseline := mid + font.get_ascent(12) * 0.5 - 1.0
		draw_string(font, Vector2(x, baseline), mode, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			CozyHUD.SEA if auto_trim else CozyHUD.MUTED)


## Trim quality: coral when the sail flogs or stalls, amber when close, sea-glass when drawing.
class TrimBar extends Control:
	var target := 1.0
	var dim := false
	var _value := 1.0
	var _style := StyleBoxFlat.new()

	func _init() -> void:
		custom_minimum_size = Vector2(70.0, 8.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_style.set_corner_radius_all(4)
		_style.anti_aliasing = true

	func _process(delta: float) -> void:
		var next := lerpf(_value, target, 1.0 - exp(-8.0 * delta))
		if absf(next - _value) > 0.0005:
			_value = next
			queue_redraw()

	func _draw() -> void:
		var track := Rect2(0.0, (size.y - 6.0) * 0.5, size.x, 6.0)
		_style.bg_color = CozyHUD.WELL_HOVER
		draw_style_box(_style, track)
		var colour := CozyHUD.CORAL.lerp(CozyHUD.AMBER, smoothstep(0.35, 0.7, _value)) \
			.lerp(CozyHUD.SEA, smoothstep(0.75, 0.95, _value))
		if dim:
			colour = Color(colour.darkened(0.35), 0.45)
		_style.bg_color = colour
		draw_style_box(_style, Rect2(track.position, Vector2(maxf(track.size.x * _value, 6.0), 6.0)))


## Round badge: a four-point compass star for discoveries, drifting gusts for wind.
class ToastIcon extends Control:
	var kind := "discovery"
	var accent := Color.WHITE

	func _init() -> void:
		custom_minimum_size = Vector2(40.0, 40.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		draw_circle(c, 20.0, Color(accent, 0.16))
		draw_arc(c, 19.5, 0.0, TAU, 48, Color(accent, 0.5), 1.0, true)
		if kind == "wind":
			for k in 3:
				var y := -6.0 + k * 6.0
				var half := 9.0 - absf(k - 1) * 2.5
				var line := PackedVector2Array()
				for s in 9:
					var x := lerpf(-half, half, s / 8.0)
					line.append(c + Vector2(x + (k - 1) * 1.5, y + sin(x * 0.45) * 1.6))
				draw_polyline(line, accent, 2.0, true)
		else:
			var star := PackedVector2Array()
			for i in 8:
				var ang := i * PI / 4.0
				var rad := 11.0 if i % 2 == 0 else 3.6
				star.append(c + Vector2(sin(ang), -cos(ang)) * rad)
			draw_colored_polygon(star, accent)
			draw_circle(c, 1.8, CozyHUD.INK_SOLID)
