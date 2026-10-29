class_name TitleScreen
extends Control
## The opening: the live sea and the moored boat, the name lettered in ink on the
## horizon haze, and the choices laid along a waterline as tiny islands.
##
##   Set Sail      swing the camera down behind the boat, hoist sail, hand over the
##                 helm (the saved voyage carries on from wherever the boat lies)
##   New Voyage    (once a voyage exists) a full page asking first, then home
##                 again in a new stretch of sea; the old voyage is kept as a backup
##   Discoveries   a full page: the chart of every island found so far
##   Settings      a full page: interface size, look speed, invert look, fullscreen
##   Quit
##
## While the title is up the ship's controls are off, the HUD is held back and a
## title camera of its own frames the horizon.

const HORIZON := 0.445          # where the title's baseline sits, as a fraction of height
const WATERLINE := 0.49         # the menu's drawn waterline, laid on the real horizon
const SWING_TIME := 2.8
const TITLE_FOV := 50.0

var _ship: ShipController
var _world: WorldManager
var _hud: CozyHUD
var _camera: Camera3D
var _haze: TextureRect
var _title: VBoxContainer
var _menu: HorizonMenu
var _settings: SettingsPage
var _discoveries: DiscoveriesPage
var _new_voyage: NewVoyagePage
var _foot: PanelContainer
var _time := 0.0
var _anchor := Transform3D.IDENTITY
var _leaving := false


func _ready() -> void:
	add_to_group("title_screen")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = CozyHUD.build_theme()
	GameSettings.ensure_loaded()

	_ship = get_tree().get_first_node_in_group("player_ship") as ShipController
	_world = get_tree().get_first_node_in_group("world") as WorldManager
	_hud = get_tree().get_first_node_in_group("cozy_hud") as CozyHUD
	if _hud:
		_hud.hold_intro()
	if _ship:
		_ship.controls_enabled = false
		_ship.set_sail_level(ShipController.SailLevel.FURLED)
		_ship.hoist = 0.0
		_ship.set_throttle(ShipController.Throttle.STOP)
		_anchor = Transform3D(Basis(Vector3.UP, _ship.global_rotation.y), _ship.global_position)

	_build()
	_make_camera()
	_play_intro()


func _process(delta: float) -> void:
	_time += delta
	if _leaving or _camera == null:
		return
	_camera.global_transform = _title_pose()


# =============================================================================
# Layout
# =============================================================================

func _build() -> void:
	# A band of sea haze behind the lettering keeps the ink readable whatever is on the horizon.
	_haze = TextureRect.new()
	_haze.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_haze.texture = _haze_texture()
	_haze.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_haze)
	_haze.anchor_left = 0.0
	_haze.anchor_right = 1.0
	_haze.anchor_top = 0.2
	_haze.anchor_bottom = 0.74

	_title = CozyHUD.make_vbox(4)
	var lead := CozyHUD.make_label("SAILING THE", &"DisplayLead")
	lead.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_child(lead)
	var name_label := CozyHUD.make_label("INFINITE ARCHIPELAGO", &"DisplayTitle")
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_child(name_label)
	add_child(_title)
	_anchor_at(_title, HORIZON, Control.GROW_DIRECTION_BEGIN)

	_menu = HorizonMenu.new()
	_menu.line_span = 0.62
	add_child(_menu)
	_menu.anchor_left = 0.0
	_menu.anchor_right = 1.0
	_menu.anchor_top = WATERLINE
	_menu.anchor_bottom = WATERLINE
	_menu.offset_top = -HorizonMenu.WATER_Y
	_menu.offset_bottom = _menu.custom_minimum_size.y - HorizonMenu.WATER_Y
	_menu.add_item(&"sail", "SET SAIL", true).detail = \
		"Carry on from where you anchored" if VoyageLog.started else "Hoist sail and head out"
	# Starting over only means something once there is a voyage to leave behind.
	if VoyageLog.started:
		_menu.add_item(&"new", "NEW VOYAGE", false, &"palm").detail = "Start over in a new stretch of sea"
	var found := VoyageLog.discoveries.size()
	_menu.add_item(&"discoveries", "DISCOVERIES", false, &"cairn").detail = \
		("%d %s on your chart" % [found, "island" if found == 1 else "islands"]) if found > 0 else "Your chart, still blank"
	_menu.add_item(&"settings", "SETTINGS", false, &"light")
	# A browser tab can't quit itself; closing the tab is the way out there.
	if not OS.has_feature("web"):
		_menu.add_item(&"quit", "QUIT", false, &"stack")
	_menu.chosen.connect(_on_chosen)

	var keys := CozyHUD.make_hbox(6)
	keys.add_child(_menu_key(CozyHUD.make_label("A", &"MenuKeyLabel")))
	keys.add_child(_menu_key(CozyHUD.make_label("D", &"MenuKeyLabel")))
	keys.add_child(_foot_label("or"))
	keys.add_child(_menu_key(KeyArrow.new(-1.0)))
	keys.add_child(_menu_key(KeyArrow.new(1.0)))
	keys.add_child(_foot_label("choose"))
	keys.add_child(CozyHUD.make_gap(14))
	var enter := CozyHUD.make_label("Enter", &"MenuKeyLabel")
	keys.add_child(_menu_key(enter))
	keys.add_child(_foot_label("select"))
	# A pill of haze behind the keys keeps the ink readable over a dark night sea.
	var foot_ground := PanelContainer.new()
	foot_ground.theme_type_variation = &"MenuFootPanel"
	foot_ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot_ground.add_child(keys)
	_foot = foot_ground
	add_child(_foot)
	_foot.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 22)
	_foot.grow_horizontal = Control.GROW_DIRECTION_BOTH

	# Pages cover the whole screen; the title steps back while one is open.
	_settings = SettingsPage.new()
	add_child(_settings)
	_settings.closed.connect(_on_page_closed.bind(&"settings"))
	_discoveries = DiscoveriesPage.new()
	add_child(_discoveries)
	_discoveries.closed.connect(_on_page_closed.bind(&"discoveries"))
	_new_voyage = NewVoyagePage.new()
	add_child(_new_voyage)
	_new_voyage.closed.connect(_on_page_closed.bind(&"new"))
	_new_voyage.confirmed.connect(_start_new_voyage)


func _menu_key(content: Control) -> PanelContainer:
	var cap := PanelContainer.new()
	cap.theme_type_variation = &"MenuKey"
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.custom_minimum_size = Vector2(24.0, 0.0)
	content.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cap.add_child(content)
	return cap


func _foot_label(text: String) -> Label:
	var label := CozyHUD.make_label(text, &"MenuFoot")
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return label


## Centres a control horizontally with one edge pinned to a fraction of the height.
func _anchor_at(c: Control, y: float, grow: Control.GrowDirection) -> void:
	c.anchor_left = 0.5
	c.anchor_right = 0.5
	c.anchor_top = y
	c.anchor_bottom = y
	c.grow_horizontal = Control.GROW_DIRECTION_BOTH
	c.grow_vertical = grow


static func _haze_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.32, 0.52, 0.7, 1.0])
	g.colors = PackedColorArray([
		Color(CozyHUD.HAZE, 0.0), Color(CozyHUD.HAZE, 0.42), Color(CozyHUD.HAZE, 0.62),
		Color(CozyHUD.HAZE, 0.38), Color(CozyHUD.HAZE, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.0, 1.0)
	tex.width = 4
	tex.height = 256
	return tex


# =============================================================================
# Camera
# =============================================================================

func _make_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "TitleCamera"
	_camera.fov = TITLE_FOV
	_camera.near = 0.1
	_camera.far = 700.0
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# A child of this Control: no 3D parent, so its transform is simply global.
	add_child(_camera)
	_camera.global_transform = _title_pose()
	_camera.make_current()


## Low over the water off the boat's port quarter, looking out past it to the
## horizon, so the boat rides at the right edge clear of the lettering. It drifts
## a little so the frame breathes.
func _title_pose() -> Transform3D:
	var eye := _anchor * Vector3(-16.0 + sin(_time * 0.05) * 1.0, 3.6 + sin(_time * 0.37) * 0.12, 25.0)
	var look := _anchor * Vector3(-13.0, 1.6, -60.0)
	return Transform3D(Basis.looking_at(look - eye, Vector3.UP), eye)


# =============================================================================
# Flow
# =============================================================================

func _play_intro() -> void:
	# Containers lay out on the first frame; animate from the settled positions.
	modulate.a = 0.0
	await get_tree().process_frame
	modulate.a = 1.0
	_haze.modulate.a = 0.0
	_haze.create_tween().tween_property(_haze, "modulate:a", 1.0, 1.2).set_trans(Tween.TRANS_SINE)
	var i := 0
	for child: Control in _title.get_children():
		child.modulate.a = 0.0
		var tw := child.create_tween().set_parallel()
		var d := 0.25 + i * 0.18
		tw.tween_property(child, "modulate:a", 1.0, 0.7).set_delay(d).set_trans(Tween.TRANS_SINE)
		tw.tween_property(child, "position:y", child.position.y, 1.1).from(child.position.y + 14.0).set_delay(d) \
			.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
		i += 1
	_menu.reveal(0.55)
	_foot.modulate.a = 0.0
	UiMotion.fade(_foot, true, 0.8, 1.4)
	get_tree().create_timer(1.1).timeout.connect(func() -> void:
		if not _leaving and not _page_open():
			_menu.focus_first())


func _on_chosen(id: StringName) -> void:
	if _leaving:
		return
	match id:
		&"sail":
			_set_sail()
		&"new":
			_open_page(_new_voyage)
		&"discoveries":
			_open_page(_discoveries)
		&"settings":
			_open_page(_settings)
		&"quit":
			get_tree().quit()


func _open_page(page: MenuPage) -> void:
	_menu.conceal(0.35)
	UiMotion.fade(_title, false, 0.25)
	UiMotion.fade(_foot, false, 0.15)
	page.open()


func _on_page_closed(from: StringName) -> void:
	UiMotion.fade(_title, true, 0.4, 0.1)
	UiMotion.fade(_foot, true, 0.3, 0.3)
	_menu.set_interactive(true)
	_menu.reveal(0.0)
	get_tree().create_timer(0.45).timeout.connect(func() -> void:
		if not _leaving and not _page_open():
			_menu.get_item(from).grab_focus())


## Whether a page is open (a closing page stays showing while it fades, but no
## longer wants focus, so the menu may take it back).
func _page_open() -> bool:
	return _settings.is_open() or _discoveries.is_open() or _new_voyage.is_open()


## Sets the old voyage aside and opens the title again on a fresh sea.
func _start_new_voyage() -> void:
	_leaving = true
	VoyageLog.start_new()
	get_tree().reload_current_scene()


func _set_sail() -> void:
	_leaving = true
	_menu.conceal(0.45)
	UiMotion.fade(_foot, false, 0.3)
	var out := _title.create_tween().set_parallel()
	out.tween_property(_title, "modulate:a", 0.0, 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	out.tween_property(_title, "position:y", _title.position.y - 28.0, 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_haze.create_tween().tween_property(_haze, "modulate:a", 0.0, 1.4).set_delay(0.3).set_trans(Tween.TRANS_SINE)

	if _ship == null:
		_finish()
		return
	get_tree().create_timer(0.35).timeout.connect(func() -> void:
		_ship.set_sail_level(ShipController.SailLevel.HALF))

	var from := _camera.global_transform
	var target_cam := _ship.get_camera()
	var swing := create_tween()
	swing.tween_method(func(t: float) -> void:
		_camera.global_transform = from.interpolate_with(target_cam.global_transform, t)
		_camera.fov = lerpf(TITLE_FOV, target_cam.fov, t), 0.0, 1.0, SWING_TIME) \
		.set_delay(0.25).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	swing.tween_callback(_finish)
	get_tree().create_timer(SWING_TIME - 0.4).timeout.connect(func() -> void:
		if _hud:
			_hud.play_intro())


func _finish() -> void:
	VoyageLog.started = true
	if _world:
		_world.save_voyage()
	if _ship:
		_ship.get_camera().make_current()
		_ship.controls_enabled = true
	if _hud:
		_hud.play_intro()
	queue_free()


## A drawn arrow for a key cap (left = -1, right = +1), inked like the menu.
class KeyArrow extends Control:
	var direction := 1.0

	func _init(dir: float) -> void:
		direction = dir
		custom_minimum_size = Vector2(10.0, 14.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var d := direction
		var ink := Color(CozyHUD.INK_TEXT, 0.7)
		draw_line(c + Vector2(-4.0 * d, 0.0), c + Vector2(4.0 * d, 0.0), ink, 1.5, true)
		draw_polyline(PackedVector2Array([c + Vector2(0.5 * d, -3.5), c + Vector2(4.0 * d, 0.0),
			c + Vector2(0.5 * d, 3.5)]), ink, 1.5, true)
