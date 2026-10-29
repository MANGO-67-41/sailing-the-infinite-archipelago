class_name ShipController
extends CharacterBody3D
## The player's sailboat.
##
## Speed comes from the wind. The dot product between the bow and the downwind
## vector picks a spot on a polar curve (no-go zone -> close-hauled -> beam reach
## -> run), scaled by how much canvas is hoisted, how well the sheet is trimmed
## and how hard the wind blows. The body stays level at sea level so collisions
## stay stable; heel, turn lean, pitch and wave bob go on the Model child.
##
## A small auxiliary engine works alongside the sails. Its telegraph runs
## Astern / Stop / Slow / Half / Full; its thrust adds to the sails' drive, its
## prop wash keeps the rudder biting at low speed, and going astern backs the
## boat off a beach. It puffs toon smoke from the stack in time with its revs.
##
## Controls: W/S hoist or lower sail (with the sails down S keeps going: the
## engine eases back and then goes astern, and W stops it again), A/D helm, Q/E
## haul in or ease the sheet (switches to hand trim), T back to auto-trim, R/F
## engine ahead or astern, Space moor at a nearby dock or cast off, drag to
## look, wheel to zoom. Until controls_enabled is set (the title screen hands
## over the helm) the boat just rides at its mooring.
##
## Mooring: near a dock's berth (a massive island's quays and river landings,
## see WorldManager.nearest_berth) and slow enough, Space eases the boat in
## alongside, furls the sails, stops the engine and saves the voyage. Space, W,
## S, R or F casts off again.

signal sail_level_changed(level: int)
signal trim_mode_changed(is_auto: bool)
signal throttle_changed(level: int)

enum SailLevel { FURLED, REEFED, HALF, FULL }
enum Throttle { ASTERN, STOP, SLOW, HALF, FULL }

const SAIL_LEVEL_NAMES: PackedStringArray = ["Furled", "Reefed", "Half sail", "Full sail"]
## How much canvas is up at each level (0..1).
const SAIL_HOIST: PackedFloat32Array = [0.0, 0.42, 0.7, 1.0]
const THROTTLE_NAMES: PackedStringArray = ["Astern", "Stop", "Slow ahead", "Half ahead", "Full ahead"]
## Engine power at each telegraph position (negative = astern).
const THROTTLE_POWER: PackedFloat32Array = [-0.5, 0.0, 0.35, 0.65, 1.0]
const PUFF_COUNT := 18
## Mooring: slower than this (m/s, about 13 km/h) to tie up, within BERTH_REACH
## metres of the berth; the boat eases in over MOOR_TIME seconds.
const MOOR_SPEED := 3.6
const BERTH_REACH := 22.0
const MOOR_TIME := 2.4
const MIN_SHEET := 0.105   # 6 degrees
const MAX_SHEET := 1.535   # 88 degrees

@export_group("Sailing")
## Top speed in m/s: full sail, beam reach, strongest wind (10.6 m/s is about 38 km/h).
@export var max_speed := 10.6
## How quickly the boat picks up speed, per second.
@export var acceleration := 0.55
## How quickly it bleeds speed when the sails lose power, per second.
@export var coast_drag := 0.22
## Fraction of full canvas hoisted or lowered per second.
@export var hoist_speed := 0.55
@export var turn_rate_deg := 34.0
## Fraction of the turn rate available when stopped (the rudder needs water flow).
@export_range(0.0, 1.0) var min_steerage := 0.18
## Sideways slip from the wind, as a fraction of max speed.
@export_range(0.0, 0.3) var leeway := 0.06
@export var auto_trim := true
@export var sheet_speed_deg := 50.0
@export var start_sail_level: SailLevel = SailLevel.HALF

@export_group("Engine")
## Speed the engine alone gives at Full ahead, m/s (4.6 m/s is about 17 km/h).
@export var engine_max_speed := 5.75
## How fast the revs follow the telegraph, as a fraction of full power per second.
@export var engine_spool := 0.9
@export var start_throttle: Throttle = Throttle.STOP

@export_group("Buoyancy")
@export var hull_length := 6.4
@export var hull_beam := 2.2
@export var ride_height := 0.0
@export var heel_max_deg := 13.0
@export var turn_lean_deg := 5.0
@export var buoyancy_stiffness := 26.0
@export var buoyancy_damping := 6.5

@export_group("Camera")
@export var camera_distance := 16.0
@export var camera_min_distance := 8.0
@export var camera_max_distance := 34.0
@export_range(-80.0, 10.0) var camera_pitch_deg := -17.0
@export var camera_height := 2.4
@export var camera_follow := 6.0
@export var orbit_sensitivity := 0.006
## Seconds after the player stops orbiting before the camera drifts back astern.
@export var orbit_recenter_delay := 2.5

# -- State the HUD reads ------------------------------------------------------
var sail_level: int = SailLevel.HALF
## Speed through the water along the bow, m/s.
var speed := 0.0
## Canvas currently up, 0..1 (eases toward SAIL_HOIST[sail_level]).
var hoist := 0.0
## How far the boom is let out from the centreline, radians (always positive).
var sheet_angle := 0.5
var ideal_sheet_angle := 0.5
## 1 = perfectly trimmed, lower = luffing or stalled.
var trim_efficiency := 1.0
## 0 = sails drawing, 1 = sails flogging (eased too far, or head to wind).
var luff := 0.0
## Angle between the bow and where the wind comes from: 0 = head to wind, PI = dead run.
var wind_off_bow := 0.0
var point_of_sail := ""
## +1 when the wind blows toward starboard (boom swings out to starboard), -1 to port.
var leeward_side := 1.0
## Compass heading, radians clockwise from north.
var heading := 0.0
## Rendered boom angle (positive = out to starboard), radians.
var boom_angle := 0.0
var rudder := 0.0
var throttle_level: int = Throttle.STOP
## Current engine revs, -0.5 (full astern) .. 1 (full ahead); eases toward the telegraph.
var engine_rpm := 0.0
## False while the title screen owns the view: no helm, sail or engine input.
var controls_enabled := true
## True while tied up alongside a dock.
var moored := false
## The berth in reach, from WorldManager.nearest_berth ({} for none): {name, position, yaw}.
var berth_near := {}

# -- Voyage log (pause screen, chart; saved in VoyageLog) ---------------------
## Metres sailed over the ground on this voyage.
var distance_sailed := 0.0
## Fastest speed through the water so far, m/s.
var top_speed := 0.0
var time_at_sea := 0.0

@onready var _model: Node3D = $Model
@onready var _camera_pivot: Node3D = $CameraPivot
@onready var _camera_pitch: Node3D = $CameraPivot/CameraPitch
@onready var _camera: Camera3D = $CameraPivot/CameraPitch/Camera3D

var _ship: Node3D
var _rudder_node: Node3D
var _sail_pivot: Node3D
var _sail: Node3D
var _jib_pivot: Node3D
var _jib: Node3D
var _flag_pivot: Node3D
var _flag: Node3D
var _lantern_light: OmniLight3D
var _propeller: Node3D
var _exhaust: Node3D
var _forestay := Vector3.UP

var _puffs: Array[MeshInstance3D] = []
var _puff_velocity := PackedVector3Array()
var _puff_age := PackedFloat32Array()
var _puff_life := PackedFloat32Array()
var _puff_size := PackedFloat32Array()
var _puff_next := 0
var _puff_timer := 0.0
var _cough := 0

var _yaw_rate := 0.0
var _heel_force := 0.0
var _boom_velocity := 0.0
var _bob := Vector3.ZERO          # (height, pitch, roll)
var _bob_velocity := Vector3.ZERO
var _time := 0.0
var _cam_yaw := 0.0
var _cam_pitch := 0.0
var _cam_distance := 0.0
## How far the camera may sit right now before the land gets in the way.
var _cam_fit := 16.0
var _moor_tween: Tween
var _berth_timer := 0.0
var _world: WorldManager
var _orbit_idle := 99.0
var _dragging := false


func _ready() -> void:
	add_to_group("player_ship")
	_ensure_input_actions()
	# Back where the saved voyage left off (log included) before anything reads the transform.
	VoyageLog.restore(self)

	_ship = ProceduralMeshBuilder.build_sailboat()
	_model.add_child(_ship)
	_rudder_node = _ship.get_node("Rudder")
	_sail_pivot = _ship.get_node("SailPivot")
	_sail = _sail_pivot.get_node("Sail")
	_jib_pivot = _ship.get_node("JibPivot")
	_jib = _jib_pivot.get_node("Jib")
	_flag_pivot = _ship.get_node("FlagPivot")
	_flag = _flag_pivot.get_node("Flag")
	_lantern_light = _ship.get_node("LanternLight")
	_propeller = _ship.get_node("Propeller")
	_exhaust = _ship.get_node("Exhaust")
	_forestay = ProceduralMeshBuilder.forestay_axis()
	_build_puff_pool()

	# The model is posed every rendered frame, so it must not be physics-interpolated.
	_model.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_camera_pivot.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_camera_pivot.top_level = true

	sail_level = start_sail_level
	hoist = SAIL_HOIST[sail_level]
	throttle_level = start_throttle
	engine_rpm = THROTTLE_POWER[throttle_level]
	_update_wind_geometry()
	sheet_angle = ideal_sheet_angle
	boom_angle = sheet_angle * leeward_side

	_cam_yaw = rotation.y
	_cam_pitch = deg_to_rad(camera_pitch_deg)
	_cam_distance = camera_distance
	_camera_pivot.global_position = global_position + Vector3.UP * camera_height

	var h := _sample_hull_heights(global_transform)
	_bob = _buoyancy_target(h)
	_apply_pose()


# =============================================================================
# Input
# =============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not controls_enabled:
		return
	if event.is_action_pressed("moor", false, true):
		if moored:
			cast_off()
		elif can_moor():
			moor_at(berth_near)
		return
	if moored:
		for action: StringName in [&"sail_raise", &"sail_lower", &"throttle_up", &"throttle_down"]:
			if event.is_action_pressed(action, false, true):
				cast_off()
	if event.is_action_pressed("sail_raise", false, true):
		# Going astern, W first stops the engine; then it hoists sail.
		if throttle_level == Throttle.ASTERN:
			set_throttle(Throttle.STOP)
		else:
			set_sail_level(sail_level + 1)
	elif event.is_action_pressed("sail_lower", false, true):
		# Once the sails are furled, S eases the engine back, then goes astern.
		if sail_level > SailLevel.FURLED:
			set_sail_level(sail_level - 1)
		else:
			set_throttle(throttle_level - 1)
	elif event.is_action_pressed("trim_auto", false, true):
		set_auto_trim(not auto_trim)
	elif event.is_action_pressed("throttle_up", false, true):
		set_throttle(throttle_level + 1)
	elif event.is_action_pressed("throttle_down", false, true):
		set_throttle(throttle_level - 1)

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = clampf(camera_distance * 0.9, camera_min_distance, camera_max_distance)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = clampf(camera_distance * 1.1, camera_min_distance, camera_max_distance)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var look := orbit_sensitivity * GameSettings.look_speed
		var pitch_sign := -1.0 if GameSettings.invert_look_y else 1.0
		_cam_yaw -= mm.relative.x * look
		_cam_pitch = clampf(_cam_pitch - mm.relative.y * look * pitch_sign, deg_to_rad(-70.0), deg_to_rad(5.0))
		_orbit_idle = 0.0


func set_sail_level(level: int) -> void:
	level = clampi(level, SailLevel.FURLED, SailLevel.FULL)
	if level == sail_level:
		return
	sail_level = level
	sail_level_changed.emit(sail_level)


func set_auto_trim(enabled: bool) -> void:
	if enabled == auto_trim:
		return
	auto_trim = enabled
	trim_mode_changed.emit(auto_trim)


func set_throttle(level: int) -> void:
	level = clampi(level, Throttle.ASTERN, Throttle.FULL)
	if level == throttle_level:
		return
	if throttle_level == Throttle.STOP:
		_cough = 3   # a few quick puffs as the engine catches
	throttle_level = level
	throttle_changed.emit(throttle_level)


## Slow enough, and near enough a berth, to tie up.
func can_moor() -> bool:
	return not moored and not berth_near.is_empty() and absf(speed) < MOOR_SPEED


## Brings the boat in alongside a berth ({name, position, yaw} in world space).
func moor_at(berth: Dictionary) -> void:
	moored = true
	set_sail_level(SailLevel.FURLED)
	set_throttle(Throttle.STOP)
	if _moor_tween:
		_moor_tween.kill()
	# Berths take a boat either way round: come in bow first, whichever way that is.
	var yaw: float = berth["yaw"]
	if absf(angle_difference(rotation.y, yaw)) > PI * 0.5:
		yaw += PI
	var target_yaw := rotation.y + angle_difference(rotation.y, yaw)
	_moor_tween = create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_moor_tween.tween_property(self, "global_position", berth["position"] as Vector3, MOOR_TIME)
	_moor_tween.tween_property(self, "rotation:y", target_yaw, MOOR_TIME)
	_moor_tween.chain().tween_callback(func() -> void:
		var world := get_tree().get_first_node_in_group("world") as WorldManager
		if world:
			world.save_voyage()
		get_tree().call_group("cozy_hud", "show_toast", "Moored at %s" % berth["name"],
			"Your voyage is saved · Space to cast off", "discovery"))


func _find_berth() -> void:
	berth_near = {}
	if not controls_enabled or moored:
		return
	if _world == null:
		_world = get_tree().get_first_node_in_group("world") as WorldManager
	if _world:
		berth_near = _world.nearest_berth(global_position, BERTH_REACH)


func cast_off() -> void:
	if not moored:
		return
	moored = false
	if _moor_tween:
		_moor_tween.kill()
		_moor_tween = null


func get_throttle_name() -> String:
	return THROTTLE_NAMES[throttle_level]


## Signed: negative while going astern.
func get_speed_kmh() -> float:
	return GameSettings.to_kmh(speed)


## True while the player is actively dragging the camera around.
func is_orbiting() -> bool:
	return _dragging and _orbit_idle < 0.4


## Forget a drag in progress (its release may never arrive, e.g. across a pause).
func cancel_drag() -> void:
	_dragging = false


## The chase camera (the title screen swings its own camera into this one).
func get_camera() -> Camera3D:
	return _camera


func get_sail_level_name() -> String:
	return SAIL_LEVEL_NAMES[sail_level]


# =============================================================================
# Sailing physics
# =============================================================================

## Fraction of top speed available on a heading, from d = bow . downwind
## (+1 dead run, 0 beam reach, -1 head to wind).
static func polar_speed(d: float) -> float:
	var drive := smoothstep(-0.94, -0.62, d)                   # no-go zone -> close-hauled
	var pinch := lerpf(0.68, 1.0, smoothstep(-0.7, -0.05, d))  # close-hauled is slower than a reach
	var run := 1.0 - 0.3 * smoothstep(0.2, 1.0, d)             # a dead run is slower than a reach
	return drive * pinch * run


func _physics_process(delta: float) -> void:
	_berth_timer -= delta
	if _berth_timer <= 0.0:
		_berth_timer = 0.2
		_find_berth()
	var wind_strength: float = WindManager.strength
	var d := _update_wind_geometry()
	var forward := -global_basis.z
	var right := global_basis.x

	hoist = move_toward(hoist, SAIL_HOIST[sail_level], hoist_speed * delta)

	# Sheet trim: auto eases toward the ideal angle; Q/E take over by hand.
	var sheet_input := Input.get_axis("sheet_in", "sheet_out") if controls_enabled else 0.0
	if sheet_input != 0.0:
		set_auto_trim(false)
		sheet_angle += sheet_input * deg_to_rad(sheet_speed_deg) * delta
	elif auto_trim:
		sheet_angle = move_toward(sheet_angle, ideal_sheet_angle, deg_to_rad(sheet_speed_deg) * delta)
	sheet_angle = clampf(sheet_angle, MIN_SHEET, MAX_SHEET)

	# Eased past ideal -> the sail luffs; hauled in too hard -> it stalls.
	var over := sheet_angle - ideal_sheet_angle
	var luffing := smoothstep(deg_to_rad(8.0), deg_to_rad(38.0), over)
	var stalling := smoothstep(deg_to_rad(10.0), deg_to_rad(55.0), -over)
	var in_irons := 1.0 - smoothstep(-0.94, -0.72, d)
	trim_efficiency = (1.0 - 0.85 * luffing) * (1.0 - 0.55 * stalling)
	luff = maxf(luffing, in_irons)

	var power := hoist * polar_speed(d) * trim_efficiency
	var sail_speed := max_speed * lerpf(0.3, 1.0, wind_strength) * power

	# Engine thrust adds to the sails (motor-sailing tops out just past sail-only speed).
	engine_rpm = move_toward(engine_rpm, THROTTLE_POWER[throttle_level], engine_spool * delta)
	var target_speed := minf(sail_speed + engine_max_speed * engine_rpm, max_speed * 1.05)
	# Speed builds when driven harder the way we're already going (or when the
	# engine works against our motion); otherwise it just coasts down.
	var same_way := signf(target_speed) == signf(speed) or absf(speed) < 0.05
	var driven := (same_way and absf(target_speed) > absf(speed)) or (not same_way and absf(target_speed) > 0.05)
	var rate := acceleration if driven else coast_drag
	speed = lerpf(speed, target_speed, 1.0 - exp(-rate * delta))

	# The sails press the boat over to leeward hardest on a reach, barely on a run.
	_heel_force = hoist * wind_strength * clampf(1.0 - d, 0.0, 1.2) / 1.2 * (1.0 - 0.7 * luff)

	if moored:
		# Tied up: the lines hold her; only the swell moves her (on the Model).
		speed = 0.0
		_heel_force = 0.0
		_yaw_rate = 0.0
		rudder = move_toward(rudder, 0.0, delta * 2.6)
		velocity = Vector3.ZERO
		heading = wrapf(-rotation.y, 0.0, TAU)
		return

	# Helm: the rudder needs water flowing past it to bite.
	var steer := Input.get_axis("steer_right", "steer_left") if controls_enabled else 0.0
	rudder = move_toward(rudder, steer, delta * 2.6)
	var flow := clampf(absf(speed) / (max_speed * 0.45), 0.0, 1.0)
	# Prop wash running ahead pushes water over the rudder even when barely moving.
	var steerage := maxf(lerpf(min_steerage, 1.0, flow), maxf(engine_rpm, 0.0) * 0.75)
	# Going astern the rudder works backwards, like reversing a car.
	var direction := lerpf(-1.0, 1.0, smoothstep(-0.6, 0.0, speed))
	_yaw_rate = rudder * deg_to_rad(turn_rate_deg) * steerage * direction
	rotate_y(_yaw_rate * delta)

	var lateral := WindManager.get_wind_vector().dot(right)
	velocity = forward * speed + right * (lateral * leeway * max_speed * hoist * wind_strength)
	velocity.y = 0.0
	var before := global_position
	move_and_slide()
	if controls_enabled:
		distance_sailed += Vector2(global_position.x - before.x, global_position.z - before.z).length()
		top_speed = maxf(top_speed, absf(speed))
		time_at_sea += delta
	if get_slide_collision_count() > 0:
		var along := get_real_velocity().dot(forward)
		speed = minf(speed, maxf(0.0, along)) if speed > 0.0 else maxf(speed, minf(0.0, along))
	global_position.y = 0.0
	heading = wrapf(-rotation.y, 0.0, TAU)


## Updates wind_off_bow, leeward_side, ideal_sheet_angle and point_of_sail.
## Returns d = bow . downwind.
func _update_wind_geometry() -> float:
	var wind: Vector3 = WindManager.get_wind_vector()
	var forward := -global_basis.z
	var d := forward.dot(wind)
	wind_off_bow = acos(clampf(-d, -1.0, 1.0))
	var lateral := wind.dot(global_basis.x)
	if absf(lateral) > 0.12:   # hysteresis so a dead run doesn't flip the boom every frame
		leeward_side = signf(lateral)
	var off_deg := rad_to_deg(wind_off_bow)
	ideal_sheet_angle = deg_to_rad(remap(clampf(off_deg, 40.0, 180.0), 40.0, 180.0, 12.0, 86.0))
	point_of_sail = _point_of_sail_name(off_deg)
	return d


static func _point_of_sail_name(off_deg: float) -> String:
	if off_deg < 38.0:
		return "In irons"
	if off_deg < 62.0:
		return "Close-hauled"
	if off_deg < 80.0:
		return "Close reach"
	if off_deg < 105.0:
		return "Beam reach"
	if off_deg < 150.0:
		return "Broad reach"
	return "Running"


# =============================================================================
# Visuals: buoyancy, rigging, camera
# =============================================================================

func _process(delta: float) -> void:
	delta = minf(delta, 1.0 / 30.0)
	_time += delta
	var xf := get_global_transform_interpolated()
	var wind_strength: float = WindManager.strength

	var target := _buoyancy_target(_sample_hull_heights(xf))
	_bob_velocity += ((target - _bob) * buoyancy_stiffness - _bob_velocity * buoyancy_damping) * delta
	_bob += _bob_velocity * delta

	# Boom on a soft spring, so a gybe swings across instead of snapping.
	var boom_target := sheet_angle * leeward_side
	_boom_velocity += ((boom_target - boom_angle) * 14.0 - _boom_velocity * 4.2) * delta
	boom_angle += _boom_velocity * delta

	_apply_pose()
	_pose_sails(wind_strength)
	_pose_flag(wind_strength)
	_propeller.rotate_z(engine_rpm * 38.0 * delta)
	_update_exhaust(delta, wind_strength)
	_update_camera(xf, delta)


## Wave heights under bow, stern, port and starboard, plus the centre.
func _sample_hull_heights(xf: Transform3D) -> PackedFloat32Array:
	var fwd := -xf.basis.z
	var rgt := xf.basis.x
	var o := xf.origin
	var half_l := hull_length * 0.5
	var half_b := hull_beam * 0.5
	return PackedFloat32Array([
		WindManager.wave_height(o + fwd * half_l),
		WindManager.wave_height(o - fwd * half_l),
		WindManager.wave_height(o - rgt * half_b),
		WindManager.wave_height(o + rgt * half_b),
		WindManager.wave_height(o),
	])


## (height, pitch, roll) the hull wants to settle at.
func _buoyancy_target(h: PackedFloat32Array) -> Vector3:
	var bow := h[0]
	var stern := h[1]
	var port := h[2]
	var starboard := h[3]
	var centre := h[4]
	var y := (bow + stern + port + starboard) * 0.15 + centre * 0.4 + ride_height
	# Bow lifts with speed and squats a little more under engine power.
	var pitch := atan2(bow - stern, hull_length) + speed / max_speed * 0.03 + engine_rpm * 0.02
	var roll := atan2(starboard - port, hull_beam)
	roll -= leeward_side * deg_to_rad(heel_max_deg) * _heel_force
	var turn := _yaw_rate / deg_to_rad(turn_rate_deg)
	roll -= turn * deg_to_rad(turn_lean_deg) * clampf(absf(speed) / max_speed * 1.5, 0.0, 1.0)
	return Vector3(y, pitch, roll)


func _apply_pose() -> void:
	_model.position = Vector3(0.0, _bob.x, 0.0)
	# A faint engine shudder while the engine runs.
	var shake := absf(engine_rpm) * 0.0035
	_model.rotation = Vector3(_bob.y + sin(_time * 53.0) * shake, 0.0, _bob.z + sin(_time * 61.0) * shake)
	if _rudder_node:
		_rudder_node.rotation.y = -rudder * 0.5


func _pose_sails(wind_strength: float) -> void:
	_sail_pivot.rotation.y = boom_angle
	var side := signf(boom_angle) if absf(boom_angle) > 0.02 else leeward_side

	# Fill: full and round when drawing, flat and flogging when luffing.
	var fill := lerpf(1.0, 0.18, luff) * lerpf(0.55, 1.0, wind_strength)
	var flog := (sin(_time * 23.0) * 0.5 + sin(_time * 37.0) * 0.3) * 0.35 * luff
	var belly := (fill + flog) * side
	if absf(belly) < 0.06:
		belly = 0.06 * (side if side != 0.0 else 1.0)
	_sail.scale = Vector3(belly, lerpf(0.05, 1.0, hoist), 1.0)

	# The jib rolls down its stay at low hoist and swings around the forestay.
	var jib_hoist := clampf((hoist - 0.35) / 0.65, 0.0, 1.0)
	var jib_size := lerpf(0.04, 1.0, jib_hoist)
	_jib_pivot.basis = Basis(_forestay, boom_angle * 0.75)
	_jib.scale = Vector3(belly * 0.9, jib_size, jib_size)
	_jib.visible = jib_hoist > 0.0


func _pose_flag(wind_strength: float) -> void:
	# The pennant streams along the apparent wind (true wind minus our own motion).
	var apparent: Vector3 = WindManager.get_wind_vector() * wind_strength * 9.0 - velocity
	apparent.y = 0.0
	if apparent.length_squared() > 0.01:
		_flag_pivot.global_basis = Basis.looking_at(-apparent.normalized(), Vector3.UP)
	var snap := lerpf(0.08, 0.22, wind_strength)
	_flag.rotation = Vector3(sin(_time * 7.0) * 0.06, sin(_time * 11.0) * snap, 0.0)
	# A small warm glow by day; after dark it lights the deck and the water around the boat.
	var dark := DayNightCycle.night
	_lantern_light.light_energy = (0.85 + sin(_time * 5.3) * 0.05 + sin(_time * 13.1) * 0.03) * lerpf(0.35, 1.9, dark)
	_lantern_light.omni_range = lerpf(5.5, 11.0, dark)


## Toon smoke: puffs leave the stack with the boat's own motion plus an upward
## push, then the air takes them downwind. Each one swells quickly and shrinks
## away (no transparency needed). Puff rate follows the revs: putt... putt-putt.
func _update_exhaust(delta: float, wind_strength: float) -> void:
	var revs := absf(engine_rpm)
	if revs > 0.02 or _cough > 0:
		_puff_timer -= delta
		if _puff_timer <= 0.0:
			_emit_puff(revs)
			if _cough > 0:
				_cough -= 1
				_puff_timer = 0.1
			else:
				_puff_timer = 1.0 / lerpf(2.2, 7.5, revs)
	var air := WindManager.get_wind_vector() * wind_strength * 1.6 + Vector3.UP * 0.35
	for i in PUFF_COUNT:
		var puff := _puffs[i]
		if not puff.visible:
			continue
		_puff_age[i] += delta
		var t := _puff_age[i] / _puff_life[i]
		if t >= 1.0:
			puff.visible = false
			continue
		_puff_velocity[i] = _puff_velocity[i].lerp(air, 1.0 - exp(-1.6 * delta))
		puff.global_position += _puff_velocity[i] * delta
		puff.rotate_y(delta * 0.7)
		puff.scale = Vector3.ONE * maxf(_puff_size[i] * sin(PI * pow(t, 0.45)), 0.001)


func _emit_puff(revs: float) -> void:
	var i := _puff_next
	_puff_next = (_puff_next + 1) % PUFF_COUNT
	var puff := _puffs[i]
	puff.visible = true
	puff.global_position = _exhaust.global_position
	puff.rotation = Vector3(0.0, randf() * TAU, 0.0)
	puff.scale = Vector3.ONE * 0.001
	_puff_age[i] = 0.0
	_puff_life[i] = randf_range(1.6, 2.4)
	_puff_size[i] = randf_range(0.5, 0.8) * lerpf(0.75, 1.15, revs) * (1.4 if _cough > 0 else 1.0)
	_puff_velocity[i] = velocity + Vector3.UP * lerpf(1.3, 2.4, revs)


func _build_puff_pool() -> void:
	var mesh := ProceduralMeshBuilder.build_smoke_puff_mesh()
	var material := ProceduralMeshBuilder.toon_material()
	for i in PUFF_COUNT:
		var puff := MeshInstance3D.new()
		puff.name = "Puff%d" % i
		puff.mesh = mesh
		puff.material_override = material
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		puff.top_level = true
		puff.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		puff.visible = false
		add_child(puff)
		_puffs.append(puff)
	_puff_velocity.resize(PUFF_COUNT)
	_puff_age.resize(PUFF_COUNT)
	_puff_life.resize(PUFF_COUNT)
	_puff_size.resize(PUFF_COUNT)
	_puff_life.fill(1.0)


func _update_camera(xf: Transform3D, delta: float) -> void:
	_orbit_idle += delta
	if _orbit_idle > orbit_recenter_delay and not _dragging:
		var ship_yaw := xf.basis.get_euler().y
		_cam_yaw = lerp_angle(_cam_yaw, ship_yaw, 1.0 - exp(-1.2 * delta))
		_cam_pitch = lerpf(_cam_pitch, deg_to_rad(camera_pitch_deg), 1.0 - exp(-1.2 * delta))
	_cam_distance = lerpf(_cam_distance, camera_distance, 1.0 - exp(-8.0 * delta))
	var anchor := xf.origin + Vector3.UP * camera_height
	_camera_pivot.global_position = _camera_pivot.global_position.lerp(anchor, 1.0 - exp(-camera_follow * delta))
	_camera_pivot.global_rotation = Vector3(0.0, _cam_yaw, 0.0)
	_camera_pitch.rotation = Vector3(_cam_pitch, 0.0, 0.0)
	_camera.position = Vector3(0.0, 0.0, minf(_cam_distance, _fit_camera(delta)))


## Up a river the hills crowd in close: shortens the camera's reach so it never
## sinks into the land behind the boat, and lets it back out once clear.
func _fit_camera(delta: float) -> float:
	if _world == null:
		_world = get_tree().get_first_node_in_group("world") as WorldManager
		if _world == null:
			return _cam_distance
	var pivot := _camera_pivot.global_position
	var back := _camera_pitch.global_basis.z
	var fit := _cam_distance
	for k in range(1, 5):
		var p := pivot + back * (_cam_distance * k / 4.0)
		if _world.terrain_height_at(p) > p.y - 1.5:
			fit = maxf(_cam_distance * (k - 1) / 4.0, 3.0)
			break
	# In quickly, back out gently.
	_cam_fit = lerpf(_cam_fit, fit, 1.0 - exp(-(12.0 if fit < _cam_fit else 1.5) * delta))
	return _cam_fit


# =============================================================================
# Setup
# =============================================================================

## Registers default key bindings unless the project already defines the actions.
static func _ensure_input_actions() -> void:
	var bindings := {
		&"sail_raise": [KEY_W, KEY_UP],
		&"sail_lower": [KEY_S, KEY_DOWN],
		&"steer_left": [KEY_A, KEY_LEFT],
		&"steer_right": [KEY_D, KEY_RIGHT],
		&"sheet_in": [KEY_Q],
		&"sheet_out": [KEY_E],
		&"trim_auto": [KEY_T],
		&"throttle_up": [KEY_R],
		&"throttle_down": [KEY_F],
		&"moor": [KEY_SPACE],
	}
	for action: StringName in bindings:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key: Key in bindings[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
