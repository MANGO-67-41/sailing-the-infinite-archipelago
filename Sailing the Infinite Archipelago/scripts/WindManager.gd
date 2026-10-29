extends Node
## Autoload "WindManager": one global wind for sails, flags, the HUD and the sea.
##
## Bearings are radians clockwise from north (-Z): 0 = north, PI/2 = east (+X).
## `angle` is the bearing the wind blows TOWARD, so get_wind_vector() points
## downwind. Sailors name a wind by where it comes FROM; get_from_bearing() and
## get_from_cardinal() give that.
##
## The wind drifts between targets with eased shifts, a slow noise wobble and the
## odd gust. This node also owns ocean time and swell and publishes them, with the
## wave set, as global shader uniforms so CozyOcean.gdshader and wave_height()
## always describe the same sea. The uniforms are declared in project.godot
## ([shader_globals]) so the editor can preview the ocean too.

signal wind_shift_started(target_angle: float, target_strength: float)
signal wind_shift_finished(angle: float, strength: float)
signal gust_started(peak_strength: float)

const GRAVITY := 9.81
## What is left of the swell inside a calm ring (see set_calm).
const CALM_FLOOR := 0.12
const CARDINALS: PackedStringArray = ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"]
const CARDINALS_SHORT: PackedStringArray = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

## Wave set: Vector4(direction x, direction z, wavelength m, amplitude m).
## Directions are fixed in world space on purpose: rotating them would make the
## phase race far from the origin. Normalised in _ready().
const WAVES: Array[Vector4] = [
	Vector4(1.0, 0.35, 38.0, 0.42),
	Vector4(-0.4, 1.0, 22.0, 0.24),
	Vector4(0.8, -0.9, 13.0, 0.11),
	Vector4(-1.0, -0.2, 7.5, 0.05),
]

@export_group("Wind")
@export_range(0.0, 360.0) var initial_angle_deg := 90.0
@export_range(0.0, 1.0) var initial_strength := 0.62
@export_range(0.0, 1.0) var min_strength := 0.32
@export_range(0.0, 1.0) var max_strength := 0.95
## Seconds between shifts (random in range).
@export var shift_interval := Vector2(30.0, 75.0)
## Seconds a shift takes to blend in (random in range).
@export var shift_duration := Vector2(7.0, 14.0)
@export_range(0.0, 180.0) var max_shift_deg := 75.0
## Constant small wobble on the direction, in degrees.
@export var flutter_deg := 4.0
@export var gusts_per_minute := 1.4
@export_range(0.0, 0.5) var gust_strength := 0.2
@export var gust_duration := 4.5

@export_group("Ocean")
## Multiplies how fast the waves travel (1 = real deep-water speed).
@export var wave_speed := 0.5
@export var swell_calm := 0.65
@export var swell_rough := 1.15
## Wave heights are pulled toward multiples of this, for a stepped low-poly sea.
@export var step_height := 0.16
@export_range(0.0, 1.0) var step_mix := 0.4
## How fast surface ripples and foam drift with the wind (m/s at full strength).
@export var drift_speed := 0.6

## Current downwind bearing, including wobble.
var angle := 0.0
## Current strength 0..1, including gusts.
var strength := 0.0
## Smooth values without wobble or gusts.
var base_angle := 0.0
var base_strength := 0.0
var ocean_time := 0.0
var swell := 1.0
var drift := Vector2.ZERO

var _waves: Array[Vector4] = []
var _noise := FastNoiseLite.new()
var _time := 0.0
var _shift_from := Vector2.ZERO   # (angle, strength)
var _shift_to := Vector2.ZERO
var _shift_elapsed := 0.0
var _shift_length := 0.0
var _shifting := false
var _next_shift := 0.0
var _gust_elapsed := -1.0
## The calm ring set by set_calm (x, z, inner, outer); w <= 0 means none.
var calm := Vector4.ZERO
var _gust_peak := 0.0


func _ready() -> void:
	process_priority = -100   # update before ships and the HUD read the wind
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.08
	_noise.seed = randi()
	base_angle = deg_to_rad(initial_angle_deg)
	base_strength = initial_strength
	angle = base_angle
	strength = base_strength
	swell = _target_swell()
	_next_shift = randf_range(shift_interval.x, shift_interval.y)
	for w in WAVES:
		var dir := Vector2(w.x, w.y).normalized()
		_waves.append(Vector4(dir.x, dir.y, w.z, w.w))
	_publish_waves()
	_publish_ocean()


func _process(delta: float) -> void:
	_time += delta
	_update_shift(delta)
	var gust := _update_gust(delta)

	var wobble := _noise.get_noise_1d(_time * 6.0) * deg_to_rad(flutter_deg)
	angle = wrapf(base_angle + wobble, 0.0, TAU)
	var breath := _noise.get_noise_1d(_time * 3.0 + 500.0) * 0.04
	strength = clampf(base_strength + gust + breath, 0.0, 1.0)

	ocean_time += delta * wave_speed
	swell = lerpf(swell, _target_swell(), 1.0 - exp(-0.25 * delta))
	drift += get_wind_vector_2d() * strength * drift_speed * delta
	_publish_ocean()


# -- Public API ---------------------------------------------------------------

## Stills the swell inside a ring (x, z, inner radius, outer radius): calm
## within the inner radius, full sea beyond the outer. Vector4.ZERO for none.
## A massive island's rivers and sound use it. Mirrored by ocean_calm in CozyOcean.
func set_calm(ring: Vector4) -> void:
	calm = ring
	RenderingServer.global_shader_parameter_set(&"ocean_calm", ring)


## How much of the swell is left at a world position (CALM_FLOOR inside a calm ring, 1 at sea).
func calm_factor(world: Vector3) -> float:
	if calm.w <= 0.0:
		return 1.0
	var d := Vector2(world.x - calm.x, world.z - calm.y).length()
	return lerpf(CALM_FLOOR, 1.0, clampf((d - calm.z) / maxf(calm.w - calm.z, 0.001), 0.0, 1.0))


## Unit vector on the XZ plane pointing downwind.
func get_wind_vector() -> Vector3:
	return Vector3(sin(angle), 0.0, -cos(angle))


## get_wind_vector() as (x, z).
func get_wind_vector_2d() -> Vector2:
	return Vector2(sin(angle), -cos(angle))


## Bearing the wind comes FROM (how sailors name it).
func get_from_bearing() -> float:
	return wrapf(angle + PI, 0.0, TAU)


func get_from_cardinal(short := false) -> String:
	return bearing_to_cardinal(get_from_bearing(), short)


func get_strength_name() -> String:
	return strength_name(strength)


## Blend to a new wind over `duration` seconds (for scripted moments).
func shift_wind_to(target_angle: float, target_strength: float, duration := 10.0) -> void:
	_shift_from = Vector2(base_angle, base_strength)
	_shift_to = Vector2(wrapf(target_angle, 0.0, TAU), clampf(target_strength, min_strength, max_strength))
	_shift_elapsed = 0.0
	_shift_length = maxf(duration, 0.01)
	_shifting = true
	wind_shift_started.emit(_shift_to.x, _shift_to.y)


## Sea surface height at a world position. Mirrors ocean_height() in CozyOcean.gdshader.
func wave_height(world: Vector3) -> float:
	var h := 0.0
	for i in _waves.size():
		var w := _waves[i]
		var k := TAU / w.z
		var c := sqrt(GRAVITY / k)
		h += w.w * sin(k * (w.x * world.x + w.y * world.z - c * ocean_time) + float(i) * 1.7)
	h *= swell * calm_factor(world)
	var step := maxf(step_height, 0.001)
	var stepped := roundf(h / step) * step
	return lerpf(h, stepped, step_mix)


static func bearing_to_cardinal(bearing: float, short := false) -> String:
	var index := int(roundf(wrapf(bearing, 0.0, TAU) / (TAU / 8.0))) % 8
	return CARDINALS_SHORT[index] if short else CARDINALS[index]


static func strength_name(value: float) -> String:
	if value < 0.42:
		return "Light breeze"
	if value < 0.58:
		return "Gentle breeze"
	if value < 0.74:
		return "Fresh breeze"
	if value < 0.88:
		return "Strong breeze"
	return "Near gale"


# -- Internals ----------------------------------------------------------------

func _update_shift(delta: float) -> void:
	if not _shifting:
		_next_shift -= delta
		if _next_shift <= 0.0:
			var turn := deg_to_rad(randf_range(-max_shift_deg, max_shift_deg))
			shift_wind_to(base_angle + turn, randf_range(min_strength, max_strength),
				randf_range(shift_duration.x, shift_duration.y))
		return
	_shift_elapsed += delta
	var t := clampf(_shift_elapsed / _shift_length, 0.0, 1.0)
	var eased := t * t * (3.0 - 2.0 * t)
	base_angle = wrapf(lerp_angle(_shift_from.x, _shift_to.x, eased), 0.0, TAU)
	base_strength = lerpf(_shift_from.y, _shift_to.y, eased)
	if t >= 1.0:
		_shifting = false
		_next_shift = randf_range(shift_interval.x, shift_interval.y)
		wind_shift_finished.emit(base_angle, base_strength)


## Returns the extra strength the current gust adds (0 when calm).
func _update_gust(delta: float) -> float:
	if _gust_elapsed < 0.0:
		if randf() < gusts_per_minute / 60.0 * delta:
			_gust_elapsed = 0.0
			_gust_peak = gust_strength * randf_range(0.6, 1.0)
			gust_started.emit(clampf(base_strength + _gust_peak, 0.0, 1.0))
		return 0.0
	_gust_elapsed += delta
	var t := _gust_elapsed / gust_duration
	if t >= 1.0:
		_gust_elapsed = -1.0
		return 0.0
	# Quick rise, slow fall.
	return _gust_peak * sin(PI * pow(t, 0.6))


func _target_swell() -> float:
	return lerpf(swell_calm, swell_rough, clampf(inverse_lerp(min_strength, max_strength, base_strength), 0.0, 1.0))


func _publish_waves() -> void:
	for i in _waves.size():
		RenderingServer.global_shader_parameter_set(StringName("ocean_wave_%d" % i), _waves[i])


func _publish_ocean() -> void:
	RenderingServer.global_shader_parameter_set(&"ocean_time", ocean_time)
	RenderingServer.global_shader_parameter_set(&"ocean_shape", Vector4(swell, maxf(step_height, 0.001), step_mix, 0.0))
	RenderingServer.global_shader_parameter_set(&"ocean_drift", drift)
