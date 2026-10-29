class_name GameSettings
extends RefCounted
## Player settings and the game's metric formatting.
##
## Everything is static so the title screen, pause menu, HUD and ship share one
## copy, and it survives reload_current_scene() (returning to the title screen).
## Settings persist to user://settings.cfg. (The voyage itself is VoyageLog.)

const PATH := "user://settings.cfg"
const MS_TO_KMH := 3.6

## Multiplies the whole 2D interface (HUD and menus).
static var interface_scale := 1.0
## Multiplies the camera's drag-to-look speed.
static var look_speed := 1.0
static var invert_look_y := false
static var fullscreen := false

static var _loaded := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_add_menu_keys()
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	interface_scale = clampf(cfg.get_value("interface", "scale", 1.0), 0.8, 1.3)
	look_speed = clampf(cfg.get_value("camera", "look_speed", 1.0), 0.4, 2.0)
	invert_look_y = cfg.get_value("camera", "invert_y", false)
	fullscreen = cfg.get_value("display", "fullscreen", false)


static func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("interface", "scale", interface_scale)
	cfg.set_value("camera", "look_speed", look_speed)
	cfg.set_value("camera", "invert_y", invert_look_y)
	cfg.set_value("display", "fullscreen", fullscreen)
	cfg.save(PATH)


## W, A, S and D walk the menus as well as the arrow keys. Menus only take
## these while one of their items has focus, and the boat only answers the
## keys while no menu is up, so the two never fight over a press.
static func _add_menu_keys() -> void:
	for pair: Array in [[&"ui_up", KEY_W], [&"ui_down", KEY_S], [&"ui_left", KEY_A], [&"ui_right", KEY_D]]:
		var ev := InputEventKey.new()
		ev.physical_keycode = pair[1]
		if InputMap.has_action(pair[0]) and not InputMap.action_has_event(pair[0], ev):
			InputMap.action_add_event(pair[0], ev)


## Pushes the display settings to the window.
static func apply(tree: SceneTree) -> void:
	tree.root.content_scale_factor = interface_scale
	var mode := DisplayServer.window_get_mode()
	var is_full := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if fullscreen != is_full:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)


# =============================================================================
# Metric formatting
# =============================================================================

## Speed in m/s -> km/h.
static func to_kmh(metres_per_second: float) -> float:
	return metres_per_second * MS_TO_KMH


## "640 m" under a kilometre, then "1.4 km", then "23 km".
static func format_distance(metres: float) -> String:
	metres = absf(metres)
	if metres < 995.0:
		return "%d m" % (roundi(metres / 10.0) * 10)
	if metres < 9950.0:
		return "%.1f km" % (metres / 1000.0)
	return "%d km" % roundi(metres / 1000.0)


## "45 s", "12 min", "1 h 05 min".
static func format_duration(seconds: float) -> String:
	var s := int(seconds)
	if s < 60:
		return "%d s" % s
	if s < 3600:
		return "%d min" % (s / 60)
	return "%d h %02d min" % [s / 3600, (s % 3600) / 60]
