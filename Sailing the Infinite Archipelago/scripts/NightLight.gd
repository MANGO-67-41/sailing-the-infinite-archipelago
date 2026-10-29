class_name NightLight
extends OmniLight3D
## A lamp's real light (island beacons, village windows, the lighthouse): off by
## day, fading up through dusk with DayNightCycle.night, with an optional flicker.
## Set it up with configure(); distance fade keeps far-off lamps from costing a pass.

var base_energy := 1.0
var flicker := 0.0
var _time := 0.0


func configure(colour: Color, energy: float, reach: float, flicker_amount := 0.08) -> NightLight:
	light_color = colour
	base_energy = energy
	omni_range = reach
	omni_attenuation = 1.3
	flicker = flicker_amount
	shadow_enabled = false
	distance_fade_enabled = true
	distance_fade_begin = 140.0
	distance_fade_length = 50.0
	light_energy = 0.0
	visible = false
	return self


func _ready() -> void:
	_time = randf() * 10.0


func _process(delta: float) -> void:
	_time += delta
	var on := smoothstep(0.25, 0.75, DayNightCycle.night)
	visible = on > 0.01
	if visible:
		light_energy = base_energy * on * (1.0 + flicker * (sin(_time * 7.1) * 0.6 + sin(_time * 12.9) * 0.4))
