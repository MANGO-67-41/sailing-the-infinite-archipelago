class_name PauseMenu
extends Control
## Esc at sea: the world freezes, the camera eases aside so the boat moves out
## from behind the lettering, a band of sea haze settles across the middle, the
## voyage so far is written on it in ink, and the choices sit on the same
## waterline as the title.
##
##   Resume        (Esc again does the same)
##   Discoveries   a page with the chart of every island found so far
##   Settings      the shared settings page
##   Controls      a page of every key, so the in-game hints can stay tucked away
##   Title screen  saved; Set Sail there carries on from here
##   Quit
##
## Pausing saves the voyage, and so does leaving by either way out.
##
## Runs with PROCESS_MODE_ALWAYS so it animates while the tree is paused.

const HEADING_LINE := 0.445
const WATERLINE := 0.535
## How far the camera turns away (left) and tilts up while paused.
const ASIDE_YAW_DEG := 33.0
const ASIDE_PITCH_DEG := 8.0
const ASIDE_TIME := 0.9

var _ship: ShipController
var _world: WorldManager
var _hud: CozyHUD
var _mist: Control
var _camera: Camera3D
var _camera_tween: Tween
var _head: VBoxContainer
var _log: Label
var _menu: HorizonMenu
var _settings: SettingsPage
var _controls: ControlsPage
var _discoveries: DiscoveriesPage
var _open := false
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = CozyHUD.build_theme()
	_build()
	visible = false
	_connect.call_deferred()


func _connect() -> void:
	_ship = get_tree().get_first_node_in_group("player_ship") as ShipController
	_world = get_tree().get_first_node_in_group("world") as WorldManager
	_hud = get_tree().get_first_node_in_group("cozy_hud") as CozyHUD


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.physical_keycode != KEY_ESCAPE:
		return
	# The title screen (and its settings page) handles its own Esc.
	if not _open and not get_tree().get_nodes_in_group("title_screen").is_empty():
		return
	get_viewport().set_input_as_handled()
	if not _open:
		open()
	elif _page_showing():
		return   # an open page takes its own Esc; this one is a page still fading out
	else:
		close()


# =============================================================================
# Layout
# =============================================================================

func _build() -> void:
	# A faint warm wash over everything (the world is resting) and a denser band of
	# haze behind the lettering; the frozen sea stays readable above and below it.
	_mist = Control.new()
	_mist.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_mist)
	_mist.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var wash := ColorRect.new()
	wash.color = Color(CozyHUD.HAZE, 0.16)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mist.add_child(wash)
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var band := TextureRect.new()
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.texture = _band_texture()
	band.stretch_mode = TextureRect.STRETCH_SCALE
	_mist.add_child(band)
	band.anchor_right = 1.0
	band.anchor_top = 0.2
	band.anchor_bottom = 0.76

	_head = CozyHUD.make_vbox(10)
	var heading := CozyHUD.make_label("ANCHORED", &"DisplayTitle")
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_head.add_child(heading)
	_log = CozyHUD.make_label("", &"MenuLine")
	_log.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_head.add_child(_log)
	add_child(_head)
	_anchor_at(_head, HEADING_LINE, Control.GROW_DIRECTION_BEGIN)

	_menu = HorizonMenu.new()
	_menu.line_span = 0.62
	add_child(_menu)
	_menu.anchor_left = 0.0
	_menu.anchor_right = 1.0
	_menu.anchor_top = WATERLINE
	_menu.anchor_bottom = WATERLINE
	_menu.offset_top = -HorizonMenu.WATER_Y
	_menu.offset_bottom = _menu.custom_minimum_size.y - HorizonMenu.WATER_Y
	_menu.add_item(&"resume", "RESUME", true).detail = "Esc also weighs anchor"
	_menu.add_item(&"discoveries", "DISCOVERIES", false, &"cairn").detail = "Your chart so far"
	_menu.add_item(&"settings", "SETTINGS", false, &"light")
	_menu.add_item(&"controls", "CONTROLS", false, &"palm")
	_menu.add_item(&"title", "TITLE SCREEN", false, &"twin").detail = "Your voyage is saved"
	if not OS.has_feature("web"):
		_menu.add_item(&"quit", "QUIT", false, &"stack")
	_menu.chosen.connect(_on_chosen)

	# Discoveries, Settings and Controls are full pages over the frozen sea.
	_discoveries = DiscoveriesPage.new()
	add_child(_discoveries)
	_discoveries.closed.connect(func() -> void: _back_to_menu(&"discoveries"))
	_settings = SettingsPage.new()
	add_child(_settings)
	_settings.closed.connect(func() -> void: _back_to_menu(&"settings"))
	_controls = ControlsPage.new()
	add_child(_controls)
	_controls.closed.connect(func() -> void: _back_to_menu(&"controls"))


func _anchor_at(c: Control, y: float, grow: Control.GrowDirection) -> void:
	c.anchor_left = 0.5
	c.anchor_right = 0.5
	c.anchor_top = y
	c.anchor_bottom = y
	c.grow_horizontal = Control.GROW_DIRECTION_BOTH
	c.grow_vertical = grow


## The haze band: clear at both edges, densest under the heading and the waterline.
static func _band_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.3, 0.5, 0.68, 1.0])
	g.colors = PackedColorArray([
		Color(CozyHUD.HAZE, 0.0), Color(CozyHUD.HAZE, 0.62), Color(CozyHUD.HAZE, 0.74),
		Color(CozyHUD.HAZE, 0.58), Color(CozyHUD.HAZE, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	tex.width = 4
	tex.height = 256
	return tex


# =============================================================================
# Open / close
# =============================================================================

func open() -> void:
	if _open or _busy:
		return
	_open = true
	get_tree().paused = true
	if _world:
		_world.save_voyage()
	if _ship:
		_ship.cancel_drag()
	_log.text = _voyage_line()
	visible = true
	_ease_camera_aside()
	_calm_sea(true)

	_mist.modulate.a = 0.0
	_mist.create_tween().tween_property(_mist, "modulate:a", 1.0, 0.45).set_trans(Tween.TRANS_SINE)
	_head.modulate.a = 0.0
	_head.pivot_offset = Vector2(_head.size.x * 0.5, _head.size.y)
	_head.scale = Vector2(0.96, 0.96)
	UiMotion.fade(_head, true, 0.35, 0.1)
	UiMotion.spring(_head, ^"scale", Vector2.ONE, 0.9)
	_menu.set_interactive(true)
	_menu.reveal(0.1)
	if _hud:
		create_tween().tween_property(_hud, "modulate:a", 0.0, 0.25)
	get_tree().create_timer(0.4).timeout.connect(func() -> void:
		if _open and not _page_open():
			_menu.focus_first())


func close() -> void:
	if not _open or _busy:
		return
	_busy = true
	_settings.dismiss()
	_controls.dismiss()
	_discoveries.dismiss()
	_menu.conceal(0.3)
	UiMotion.fade(_head, false, 0.25)
	_ease_camera_back()
	_calm_sea(false)
	var tw := _mist.create_tween()
	tw.tween_property(_mist, "modulate:a", 0.0, 0.35).set_delay(0.1).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(func() -> void:
		get_tree().paused = false
		visible = false
		_open = false
		_busy = false
		if _ship:
			_ship.cancel_drag())
	if _hud:
		create_tween().tween_property(_hud, "modulate:a", 1.0, 0.4).set_delay(0.2)


## A camera of our own takes over from the (paused) chase camera and turns away
## from the boat, so it rides at the right edge instead of behind the heading.
func _ease_camera_aside() -> void:
	if _ship == null:
		return
	var chase := _ship.get_camera()
	if _camera == null:
		_camera = Camera3D.new()
		_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(_camera)
	_camera.fov = chase.fov
	_camera.near = chase.near
	_camera.far = chase.far
	var from := chase.global_transform
	var aside := from
	aside.basis = Basis(Vector3.UP, deg_to_rad(ASIDE_YAW_DEG)) * aside.basis * Basis(Vector3.RIGHT, deg_to_rad(ASIDE_PITCH_DEG))
	_camera.global_transform = from
	_camera.make_current()
	_tween_camera(from, aside, ASIDE_TIME)


func _ease_camera_back() -> void:
	if _ship == null or _camera == null:
		return
	var chase := _ship.get_camera()
	_tween_camera(_camera.global_transform, chase.global_transform, 0.5)
	_camera_tween.tween_callback(func() -> void: chase.make_current())


## The sun's stepped glints read as white blotches behind a menu, so they fade
## out while anchored and come back on resume (the day/night cycle owns the glint).
func _calm_sea(calm: bool) -> void:
	var cycle := get_tree().get_first_node_in_group("day_night") as DayNightCycle
	if cycle:
		create_tween().tween_property(cycle, "glint_mute", 1.0 if calm else 0.0, 0.5).set_trans(Tween.TRANS_SINE)


func _tween_camera(from: Transform3D, to: Transform3D, duration: float) -> void:
	if _camera_tween and _camera_tween.is_valid():
		_camera_tween.kill()
	_camera_tween = create_tween()
	_camera_tween.tween_method(func(t: float) -> void:
		_camera.global_transform = from.interpolate_with(to, t), 0.0, 1.0, duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _on_chosen(id: StringName) -> void:
	if _busy:
		return
	match id:
		&"resume":
			close()
		&"settings":
			_open_page(_settings)
		&"controls":
			_open_page(_controls)
		&"title":
			_busy = true
			get_tree().paused = false
			if _world:
				_world.save_voyage()
			get_tree().reload_current_scene()
		&"discoveries":
			_open_page(_discoveries)
		&"quit":
			if _world:
				_world.save_voyage()
			get_tree().quit()


func _open_page(page: MenuPage) -> void:
	_menu.conceal(0.35)
	UiMotion.fade(_head, false, 0.25)
	page.open()


func _page_showing() -> bool:
	return _settings.visible or _controls.visible or _discoveries.visible


## Whether a page is open (a closing page stays showing while it fades, but no
## longer wants focus, so the menu may take it back).
func _page_open() -> bool:
	return _settings.is_open() or _controls.is_open() or _discoveries.is_open()


func _back_to_menu(from: StringName) -> void:
	UiMotion.fade(_head, true, 0.4, 0.1)
	_menu.set_interactive(true)
	_menu.reveal(0.0)
	get_tree().create_timer(0.45).timeout.connect(func() -> void:
		var item := _menu.get_item(from)
		if _open and item and not _page_open():
			item.grab_focus())


## "4.2 km sailed · 3 islands found · top speed 22 km/h · 12 min at sea"
func _voyage_line() -> String:
	var parts: PackedStringArray = []
	if _ship:
		parts.append("%s sailed" % GameSettings.format_distance(_ship.distance_sailed))
	if _world:
		var n := _world.discovered_count()
		parts.append("%d %s found" % [n, "island" if n == 1 else "islands"])
	if _ship:
		parts.append("top speed %d km/h" % roundi(GameSettings.to_kmh(_ship.top_speed)))
		parts.append("%s at sea" % GameSettings.format_duration(_ship.time_at_sea))
	return "  ·  ".join(parts)
