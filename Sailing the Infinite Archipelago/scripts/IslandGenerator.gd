class_name IslandGenerator
extends Node3D
## One procedural island: FastNoiseLite heightmap -> flat-shaded SurfaceTool mesh
## with colour bands (sand below y = 1, grass above, rock on steep faces, baked
## crease AO), a trimesh collider so ships run aground on the shallows, and
## MultiMesh props (trees, palms, pines, grass, rocks, ruins, washed-up cargo).
##
## Small islands may keep a lamp post on the beach that lights up after dark.
##
## A great island (configure(..., true); rare, see WorldManager) is a different
## order of land: ridged highlands, two or three rivers cut into their valleys
## and running down to the sea in falls and rapids, a mountain lake at the head
## of the first, a village of lantern-lit cottages with a jetty near its mouth,
## and a lighthouse on a far headland whose beams sweep the sea at night.
##
## A massive island (configure(..., false, true); rarer still) is bigger again,
## and has rivers wide and deep enough to sail up: see MassiveIsland.
##
## The heavy maths runs on a WorkerThreadPool task; only creating the render and
## physics resources happens back on the main thread, so islands stream in
## without hitches. Everything derives from island_seed, so the same seed always
## gives the same island, name included.

signal generated

const TERRAIN_SHADER := preload("res://Sailing the Infinite Archipelago/assets/shaders/ToonLand.gdshader")
const RIVER_SHADER := preload("res://Sailing the Infinite Archipelago/assets/shaders/RiverWater.gdshader")
const BEAM_SHADER := preload("res://Sailing the Infinite Archipelago/assets/shaders/BeamGlow.gdshader")

# -- Terrain palette (sRGB; ToonLand converts) ---------------------------------
const SEABED := Color("d9c398")
const SEABED_DEEP := Color("b39b78")
const SAND := Color("eed6a6")
const GRASS_SUN := Color("a2b36f")
const GRASS := Color("8da660")
const GRASS_SHADE := Color("789657")
const DIRT := Color("a8977e")
const ROCK := Color("a3998c")
const ROCK_DARK := Color("867b71")
const RIVER_BED := Color("b8a582")

## Sand stops and grass starts at this height (spec: beaches below y = 1).
const BEACH_TOP := 1.0
## Mesh extends this far past the nominal radius, so the shallows shelve away under water.
const EXTENT_FACTOR := 1.4

const NAME_FIRST: PackedStringArray = ["Amber", "Lantern", "Honey", "Drift", "Saffron", "Willow", "Gull",
	"Ember", "Marigold", "Tide", "Copper", "Hearth", "Moss", "Fennel", "Cinder", "Pebble", "Bramble",
	"Sun", "Kettle", "Rosehip", "Clover", "Thistle", "Juniper", "Otter", "Heron", "Wren", "Plum",
	"Barley", "Tansy", "Biscuit"]
const NAME_SECOND: PackedStringArray = ["fall", "wick", "mere", "hollow", "stead", "brook", "haven",
	"more", "ford", "shore", "glen", "crest", "nook", "cove", "rest", "light"]
const NAME_KIND_SMALL: PackedStringArray = ["Cay", "Key", "Skerry", "Rock"]
const NAME_KIND_LARGE: PackedStringArray = ["Isle", "Island", "Holm", "Atoll"]
const NAME_KIND_GREAT: PackedStringArray = ["Highlands", "Mainland", "Reach", "Great Isle"]

## Great islands: terrain grid spacing, prop spacing, and the river carving.
const GREAT_CELL := 3.2
const GREAT_PROP_SPACING := 2.3
const RIVER_STEP := 3.0
## Small islands that get a lamp post on the beach.
const BEACON_CHANCE := 0.5
const LAMP_COLOUR := Color("ffb866")
## Bucket size for the clearings the prop scatter avoids.
const CLEAR_GRID := 16.0
## A massive island's props are split into tiles this wide, so far ones can be culled.
const PROP_TILE := 128.0

const FOLIAGE_KINDS: Array[StringName] = [&"broadleaf", &"pine", &"palm", &"grass"]

@export var island_seed := 1
@export_range(10.0, 120.0) var radius := 40.0
@export_range(2.0, 40.0) var peak_height := 12.0
## Terrain grid spacing in metres (bigger = chunkier facets, faster).
@export var cell_size := 2.6
@export var generate_on_ready := true

var island_name := ""
var description := ""
var has_ruins := false
var discovered := false
var is_generated := false
var great := false
var massive := false
## A massive island's landmarks, in local x/z: [{id, kind, name, at: Vector2, reach}].
var landmarks: Array = []
## A massive island's quays and landings: [{name, kind, xform, berths: [Vector3], yaw}], local.
var docks: Array = []
## What the chart shows of a great island, in local x/z: {rivers: [PackedVector2Array],
## lake: Vector3(x, z, radius), village: Vector2, lighthouse: Vector2}. Empty for small islands.
var features := {}

var _task_id := -1
var _result := {}
var _heights := PackedFloat32Array()
var _grid_n := 0
var _grid_step := 1.0
var _extent := 0.0
var _beams: Array[Node3D] = []

static var _terrain_material: ShaderMaterial
static var _foliage_material: ShaderMaterial
static var _river_material: ShaderMaterial
static var _lake_material: ShaderMaterial
static var _beam_material: ShaderMaterial


func configure(seed_value: int, island_radius: float, peak: float, is_great := false, is_massive := false) -> void:
	island_seed = seed_value
	radius = island_radius
	peak_height = peak
	great = is_great
	massive = is_massive


func _ready() -> void:
	set_process(false)
	if generate_on_ready:
		generate()


func _process(delta: float) -> void:
	# The lighthouse lamps turn all day; their beams only show after dark.
	for beam in _beams:
		beam.rotation.y += delta * 0.55


func _exit_tree() -> void:
	# Never leave a worker writing into a node that is going away.
	if _task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1


## Starts background generation; `generated` fires when the island is in place.
func generate() -> void:
	if _task_id != -1 or is_generated:
		return
	_ensure_materials()
	var params := {
		"seed": island_seed,
		"radius": radius,
		"peak": peak_height,
		"cell": cell_size,
		"great": great,
		"massive": massive,
	}
	_task_id = WorkerThreadPool.add_task(_build.bind(params), false, "Island %d" % island_seed)


## Terrain height under a world position (sea level 0), or -INF off the mesh.
func height_at(world_pos: Vector3) -> float:
	if not is_generated:
		return -INF
	var local := to_local(world_pos)
	if absf(local.x) > _extent or absf(local.z) > _extent:
		return -INF
	return _sample_surface(_heights, _grid_n, _grid_step, _extent, island_seed, local.x, local.z).x


## Horizontal distance at which the player counts as having found this island.
func get_discover_radius(padding: float) -> float:
	return radius + padding


# =============================================================================
# Worker thread: pure data, no scene or server access
# =============================================================================

func _build(params: Dictionary) -> void:
	var seed_value: int = params["seed"]
	var r: float = params["radius"]
	var peak: float = params["peak"]
	var is_great: bool = params["great"]
	var is_massive: bool = params["massive"]
	# Great and massive islands share the rules for rivers, colliders and clearings.
	var big := is_great or is_massive
	var extent := r * EXTENT_FACTOR
	var n := clampi(ceili(2.0 * extent / float(params["cell"])), 24, 80)
	if is_great:
		n = clampi(ceili(2.0 * extent / GREAT_CELL), 80, 180)
	elif is_massive:
		n = clampi(ceili(2.0 * extent / MassiveIsland.CELL), 200, 340)
	var step := 2.0 * extent / n

	var shape := FastNoiseLite.new()
	shape.seed = seed_value
	shape.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	shape.frequency = 1.5 / r
	var detail := FastNoiseLite.new()
	detail.seed = seed_value + 101
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail.fractal_octaves = 4
	detail.frequency = 2.4 / r
	var forest := FastNoiseLite.new()
	forest.seed = seed_value + 202
	forest.frequency = 0.045
	var ridges := FastNoiseLite.new()
	ridges.seed = seed_value + 909
	ridges.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ridges.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridges.fractal_octaves = 4
	ridges.frequency = 2.2 / r
	if is_massive:
		shape.frequency = 2.4 / r
		ridges.frequency = 3.2 / r

	# Heightmap.
	var heights := PackedFloat32Array()
	heights.resize((n + 1) * (n + 1))
	for j in n + 1:
		for i in n + 1:
			var x := -extent + i * step
			var z := -extent + j * step
			if is_massive:
				heights[j * (n + 1) + i] = MassiveIsland.height(x, z, r, peak, shape, ridges)
			elif is_great:
				heights[j * (n + 1) + i] = _great_height(x, z, r, peak, shape, ridges)
			else:
				heights[j * (n + 1) + i] = _terrain_height(x, z, r, peak, shape, detail)

	# Great islands: rivers and a lake cut into the land; `bed` marks the river beds
	# (1; 2 under a massive island's navigable rivers and sound).
	var bed := PackedByteArray()
	bed.resize(heights.size())
	var waters := {}
	if is_great:
		waters = _carve_waters(heights, bed, n, step, extent, r, peak, seed_value)
	elif is_massive:
		waters = MassiveIsland.carve(heights, bed, n, step, extent, r, peak, seed_value)

	# Crease AO per vertex: lower than the neighbours -> darker, ridges a touch brighter.
	var ao := PackedFloat32Array()
	ao.resize(heights.size())
	for j in n + 1:
		for i in n + 1:
			var h := heights[j * (n + 1) + i]
			var sum := 0.0
			var count := 0
			for o: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var ni := i + o.x
				var nj := j + o.y
				if ni >= 0 and nj >= 0 and ni <= n and nj <= n:
					sum += heights[nj * (n + 1) + ni]
					count += 1
			var cavity := clampf((sum / count - h) / step, -1.0, 1.0)
			ao[j * (n + 1) + i] = 1.0 - 0.3 * maxf(cavity, 0.0) + 0.06 * maxf(-cavity, 0.0)

	# Terrain mesh, flat-shaded, plus collision faces for everything near the surface.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := PackedVector3Array()
	for j in n:
		for i in n:
			var i00 := j * (n + 1) + i
			var i10 := i00 + 1
			var i01 := i00 + n + 1
			var i11 := i01 + 1
			var x0 := -extent + i * step
			var z0 := -extent + j * step
			var p00 := Vector3(x0, heights[i00], z0)
			var p10 := Vector3(x0 + step, heights[i10], z0)
			var p01 := Vector3(x0, heights[i01], z0 + step)
			var p11 := Vector3(x0 + step, heights[i11], z0 + step)
			var tris: Array
			if _cell_flipped(seed_value, i, j):
				tris = [[p00, p10, p01, i00, i10, i01], [p10, p11, p01, i10, i11, i01]]
			else:
				tris = [[p00, p10, p11, i00, i10, i11], [p00, p11, p01, i00, i11, i01]]
			for ti in tris.size():
				var t: Array = tris[ti]
				var a: Vector3 = t[0]
				var b: Vector3 = t[1]
				var c: Vector3 = t[2]
				if maxf(a.y, maxf(b.y, c.y)) < -7.5:
					continue   # deep enough to be invisible
				var normal := (b - a).cross(c - a).normalized()
				if normal.y < 0.0:
					normal = -normal
				var centre := (a + b + c) / 3.0
				var shade := (ao[t[3]] + ao[t[4]] + ao[t[5]]) / 3.0
				shade *= 0.97 + ProceduralMeshBuilder._hash01(seed_value, i * 2 + ti, j) * 0.06
				var colour := _ground_colour(centre.y, normal.y, peak, forest.get_noise_2d(centre.x, centre.z))
				if big and int(bed[t[3]] == 1) + int(bed[t[4]] == 1) + int(bed[t[5]] == 1) >= 2:
					colour = RIVER_BED
				colour = Color(colour.r * shade, colour.g * shade, colour.b * shade)
				ProceduralMeshBuilder._tri(st, a, b, c, colour, Vector3.UP)
				# Only the shallows can touch a hull; a big island's highlands need no collider.
				if maxf(a.y, maxf(b.y, c.y)) > -1.4 and (not big or minf(a.y, minf(b.y, c.y)) < 3.0):
					faces.append_array([a, b, c])
	var terrain_arrays := st.commit_to_arrays()

	# Props.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var props := {}
	for kind in ProceduralMeshBuilder.PROP_KINDS:
		props[kind] = {"xforms": [], "colours": []}
	var ruin_spots: Array[Vector3] = []
	var lights: Array = []
	var settled := {}
	if is_great:
		settled = _settle(heights, n, step, extent, r, seed_value, waters, props, lights)
	elif is_massive:
		settled = MassiveIsland.settle(heights, n, step, extent, r, seed_value, waters, props, lights)
	var keep_clear := _clear_grid(settled.get("clear", []))
	# Docks stand solid, so the boat comes up against them rather than through.
	for dock: Dictionary in settled.get("docks", []):
		for solid: Array in ProceduralMeshBuilder.dock_solids(dock["kind"]):
			faces.append_array(_box_faces(dock["xform"], solid[0], solid[1]))
	var spacing := 1.6
	if is_great:
		spacing = GREAT_PROP_SPACING
	elif is_massive:
		spacing = MassiveIsland.PROP_SPACING
	var cells := int(2.0 * extent / spacing)
	# A massive island is wooded country: denser trees, and pines further down its hills.
	var lush := 2.6 if is_massive else 1.0
	var tree_line := peak * (0.3 if is_massive else 0.5)
	for gz in cells:
		for gx in cells:
			var x := -extent + (gx + rng.randf()) * spacing
			var z := -extent + (gz + rng.randf()) * spacing
			var s := _sample_surface(heights, n, step, extent, seed_value, x, z)
			var y := s.x
			var up := Vector3(s.y, s.z, s.w)
			if y < -1.2:
				continue
			if big and _kept_clear(x, z, n, step, extent, bed, keep_clear, waters):
				continue
			var roll := rng.randf()
			var pick := rng.randf()
			var woods := forest.get_noise_2d(x, z)
			var pos := Vector3(x, y, z)

			if y < 0.8 and roll < 0.03:
				_add_rock(props, rng, pos, up, rng.randf_range(0.5, 1.4))
				continue
			if up.y < 0.62 and y > 0.5 and roll < 0.07:
				_add_rock(props, rng, pos, up, rng.randf_range(0.7, 1.9))
				continue
			if y < BEACH_TOP:
				if y > 0.2 and up.y > 0.9 and roll < 0.0025:
					_add_prop(props, &"crate" if pick < 0.5 else &"barrel", pos, rng, 0.85, 1.1, 0.12, 0.05)
				continue
			if up.y < 0.7:
				if roll < 0.012:
					_add_rock(props, rng, pos, up, rng.randf_range(0.5, 1.2))
				continue
			if y > 2.0 and y < peak * 0.85 and up.y > 0.93:
				ruin_spots.append(pos)
			if y < 2.6 and roll < 0.012:
				_add_prop(props, &"palm", pos, rng, 0.85, 1.25, 0.25, 0.12)
			elif y > tree_line and woods > -0.15 and roll < 0.055 * lush:
				_add_prop(props, &"pine", pos, rng, 0.8, 1.35, 0.15, 0.05)
			elif y >= 2.0 and woods > 0.0 and roll < 0.07 * lush:
				_add_prop(props, &"broadleaf", pos, rng, 0.8, 1.3, 0.2, 0.06)
			elif roll < 0.012:
				_add_rock(props, rng, pos, up, rng.randf_range(0.3, 0.8))
			elif pick < 0.45:
				_add_prop(props, &"grass", pos, rng, 0.8, 1.5, 0.02, 0.15)

	# Ruins: a broken gateway on a flat high spot, ringed by columns.
	var ruin_xform := Transform3D()
	var with_ruins := not ruin_spots.is_empty() and peak > 5.0 and rng.randf() < 0.45
	# A massive island's stones stand where MassiveIsland chose, within sight of a river.
	if is_massive:
		with_ruins = settled["ruins"] != null
	if with_ruins:
		var spot: Vector3 = settled["ruins"] if is_massive else ruin_spots[rng.randi_range(0, ruin_spots.size() - 1)]
		var yaw := rng.randf() * TAU
		ruin_xform = Transform3D(Basis(Vector3.UP, yaw), spot + Vector3.DOWN * 0.1)
		for k in 6:
			if rng.randf() > 0.7:
				continue
			var ang := yaw + TAU * k / 6.0 + 0.5
			var px := spot.x + cos(ang) * 4.6
			var pz := spot.z + sin(ang) * 4.6
			var ground := _sample_surface(heights, n, step, extent, seed_value, px, pz).x
			if ground < BEACH_TOP:
				continue
			var basis := Basis(Vector3.UP, rng.randf() * TAU)
			var at := Vector3(px, ground - 0.15, pz)
			if rng.randf() < 0.25:
				# Toppled: lying on its side, half sunk into the grass.
				basis = Basis(Vector3(cos(ang), 0.0, sin(ang)), PI * 0.5) * basis
				at.y = ground + 0.2
			else:
				basis = basis.scaled(Vector3(1.0, rng.randf_range(0.35, 1.0), 1.0))
			_push(props, &"column", Transform3D(basis, at), Color(1, 1, 1))

	if not big:
		_place_beacon(heights, n, step, extent, peak, seed_value, props, lights)

	var river_arrays: Array = []
	var lake_arrays: Array = []
	var chart := {}
	if big:
		var drawn: Array = []
		for river: Dictionary in waters["rivers"]:
			river_arrays.append(_river_ribbon(river, step))
			var points: PackedVector2Array = river["points"]
			var thin := PackedVector2Array()
			for k in range(0, points.size(), 2):
				thin.append(points[k])
			drawn.append(thin)
		chart["rivers"] = drawn
		var lake: Dictionary = waters["lake"]
		if not lake.is_empty():
			lake_arrays = _lake_disc(lake)
			chart["lake"] = Vector3(lake["x"], lake["z"], lake["radius"])
		if settled.has("village"):
			chart["village"] = settled["village"]
		if settled.has("lighthouse"):
			chart["lighthouse"] = settled["lighthouse"]
	if is_massive:
		var channels: Array = []
		for channel: Dictionary in waters["channels"]:
			var points: PackedVector2Array = channel["points"]
			var widths: PackedFloat32Array = channel["widths"]
			var line := PackedVector2Array()
			var line_widths := PackedFloat32Array()
			for k in range(0, int(channel["mouth"]) + 4, 3):
				line.append(points[mini(k, points.size() - 1)])
				line_widths.append(widths[mini(k, points.size() - 1)])
			channels.append({"name": channel["name"], "points": line, "widths": line_widths})
		chart["channels"] = channels
		var sound: Dictionary = waters["sound"]
		chart["sound"] = Vector3(sound["x"], sound["z"], sound["radius"])
		chart["lighthouses"] = settled["lighthouses"]
		if settled.has("town"):
			chart["village"] = settled["town"]

	_result = {
		"terrain": terrain_arrays,
		"faces": faces,
		"props": props,
		"ruins": with_ruins,
		"ruin_xform": ruin_xform,
		"heights": heights,
		"n": n,
		"step": step,
		"extent": extent,
		"rivers": river_arrays,
		"lake": lake_arrays,
		"lights": lights,
		"beams": settled.get("beams", []),
		"chart": chart,
		"landmarks": waters.get("landmarks", []),
		"docks": settled.get("docks", []),
	}
	_name_island(seed_value, r, props, with_ruins, is_great, is_massive, chart)
	_finish.call_deferred()


static func _terrain_height(x: float, z: float, r: float, peak: float, shape: FastNoiseLite, detail: FastNoiseLite) -> float:
	var reach := r * (0.84 + 0.3 * shape.get_noise_2d(x, z))
	var d := Vector2(x, z).length() / reach
	var base := 1.0 - smoothstep(0.2, 1.0, d)
	var crest := peak * (0.62 + 0.45 * (detail.get_noise_2d(x, z) * 0.5 + 0.5))
	var h := lerpf(-3.4, crest, pow(base, 1.15))
	h -= smoothstep(1.0, 1.45, d) * 5.0
	if h > 0.0 and h < 2.2:
		h = 2.2 * pow(h / 2.2, 2.3)   # wide, gently sloping beaches
	elif h >= 2.2:
		# Soft terraces: continuous, but the slope bunches into ledges.
		var t := h / 2.2
		var terraced := 2.2 * (floorf(t) + smoothstep(0.25, 0.75, t - floorf(t)))
		h = lerpf(h, terraced, 0.45 * smoothstep(2.2, 3.4, h))
	return h


## Highlands: rolling lowland to a ragged coast of bays and headlands, rising
## into ridged mountains toward the middle, with the same wide beaches and soft
## terraces as the small islands.
static func _great_height(x: float, z: float, r: float, peak: float, shape: FastNoiseLite, ridges: FastNoiseLite) -> float:
	var reach := r * (0.92 + 0.25 * shape.get_noise_2d(x * 0.8, z * 0.8))
	var d := Vector2(x, z).length() / reach
	var base := 1.0 - smoothstep(0.55, 1.0, d)
	var ridge := ridges.get_noise_2d(x, z) * 0.5 + 0.5
	var lowland := 5.0 * (0.7 + 0.6 * ridge)
	var mountains := peak * ridge * ridge * (1.0 - smoothstep(0.1, 0.75, d))
	var h := lerpf(-3.6, lowland + mountains, pow(base, 0.8))
	h -= smoothstep(1.0, 1.4, d) * 5.0
	if h > 0.0 and h < 2.2:
		h = 2.2 * pow(h / 2.2, 2.0)
	elif h >= 2.2:
		var t := h / 2.2
		var terraced := 2.2 * (floorf(t) + smoothstep(0.25, 0.75, t - floorf(t)))
		h = lerpf(h, terraced, 0.3 * smoothstep(2.2, 3.4, h))
	return h


## Lays out and cuts the great island's waters into `heights`:
##   - 2-3 rivers, each from the highest ground in its own sector, wandering out
##     to sea; the bed never runs uphill, so rises in the land become gorges and
##     drops become falls,
##   - a lake in a bowl at the head of the first river.
## Returns {rivers: [{points, beds, widths}], lake: {x, z, radius, level} or {}}.
static func _carve_waters(heights: PackedFloat32Array, bed: PackedByteArray, n: int, step: float,
		extent: float, r: float, peak: float, seed_value: int) -> Dictionary:
	var original := heights.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 303
	var meander := FastNoiseLite.new()
	meander.seed = seed_value + 404
	meander.frequency = 0.05
	var count := 2 + (1 if rng.randf() < 0.55 else 0)
	var first_aim := rng.randf() * TAU
	var rivers: Array = []
	var lake := {}
	for i in count:
		var aim := first_aim + TAU * i / count + rng.randf_range(-0.35, 0.35)
		var source := Vector2.ZERO
		var source_h := -INF
		for j in range(0, n + 1, 2):
			for ii in range(0, n + 1, 2):
				var q := Vector2(-extent + ii * step, -extent + j * step)
				var dq := q.length()
				if dq < r * 0.12 or dq > r * 0.55 or absf(angle_difference(q.angle(), aim)) > 0.6:
					continue
				var hq := original[j * (n + 1) + ii]
				if hq > source_h:
					source_h = hq
					source = q
		if source_h < peak * 0.3:
			continue
		var level := source_h - 1.2
		var heading := source.angle()
		var start := source
		if lake.is_empty():
			var lake_r := clampf(r * 0.075, 9.0, 15.0)
			var rim := INF
			for k in 16:
				var q := source + Vector2.from_angle(TAU * k / 16.0) * lake_r
				rim = minf(rim, _sample_surface(original, n, step, extent, seed_value, q.x, q.y).x)
			level = minf(level, rim - 0.5)
			lake = {"x": source.x, "z": source.y, "radius": lake_r, "level": level}
			start = source + Vector2.from_angle(heading) * lake_r * 0.8
		var points := PackedVector2Array()
		var beds := PackedFloat32Array()
		var widths := PackedFloat32Array()
		var p := start
		for k in 260:
			var ground := _sample_surface(original, n, step, extent, seed_value, p.x, p.y).x
			if k > 0:
				level = minf(level - 0.03, ground - 1.1)
			points.append(p)
			beds.append(level)
			widths.append(lerpf(2.2, 7.5, clampf(k / 80.0, 0.0, 1.0)))
			if level < -1.6:
				break
			# Wander, but keep turning back out to sea.
			heading = lerp_angle(heading, p.angle(), 0.1) + meander.get_noise_2d(k * 3.0, i * 97.0) * 0.3
			p += Vector2.from_angle(heading) * RIVER_STEP
			if absf(p.x) > extent - 3.0 or absf(p.y) > extent - 3.0:
				break
		if points.size() >= 10:
			rivers.append({"points": points, "beds": beds, "widths": widths})

	if not lake.is_empty():
		var c := Vector2(lake["x"], lake["z"])
		var lr: float = lake["radius"]
		var lv: float = lake["level"]
		_carve_around(heights, original, bed, n, step, extent, c, lr + 10.0, func(d: float, orig: float) -> float:
			if d < lr * 0.75:
				return lv - 1.3
			if d < lr:
				return lerpf(lv - 1.3, lv + 0.4, smoothstep(lr * 0.75, lr, d))
			return lerpf(lv + 0.4, orig, smoothstep(lr, lr + 10.0, d)), -1.0)
	for river: Dictionary in rivers:
		var points: PackedVector2Array = river["points"]
		var beds: PackedFloat32Array = river["beds"]
		var widths: PackedFloat32Array = river["widths"]
		for k in points.size():
			var lv := beds[k]
			var half := maxf(widths[k] * 0.5 + 0.8, step * 0.8)
			var ground := _sample_surface(original, n, step, extent, seed_value, points[k].x, points[k].y).x
			var valley := half + 6.0 + clampf((ground - lv) * 0.7, 0.0, 12.0)
			_carve_around(heights, original, bed, n, step, extent, points[k], valley, func(d: float, orig: float) -> float:
				if d <= half:
					return lv - 0.7
				return lerpf(lv + 0.25, orig, smoothstep(half, valley, d)), half)
	return {"rivers": rivers, "lake": lake}


## Lowers every grid vertex within `reach` of `centre` to profile(distance, original
## height) where that is lower; vertices within `bed_reach` are marked as river bed.
static func _carve_around(heights: PackedFloat32Array, original: PackedFloat32Array, bed: PackedByteArray,
		n: int, step: float, extent: float, centre: Vector2, reach: float, profile: Callable, bed_reach: float) -> void:
	var i0 := maxi(floori((centre.x - reach + extent) / step), 0)
	var i1 := mini(ceili((centre.x + reach + extent) / step), n)
	var j0 := maxi(floori((centre.y - reach + extent) / step), 0)
	var j1 := mini(ceili((centre.y + reach + extent) / step), n)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var d := Vector2(-extent + i * step, -extent + j * step).distance_to(centre)
			if d > reach:
				continue
			var idx := j * (n + 1) + i
			heights[idx] = minf(heights[idx], profile.call(d, original[idx]))
			if d <= bed_reach and bed[idx] == 0:
				bed[idx] = 1


## Places the great island's village, jetty and lighthouse into `props` and their
## lamps into `lights`. Returns {village, lighthouse: Vector2, beams: [Vector3],
## clear: [Vector3(x, z, radius)] (ground the trees must leave alone)}.
static func _settle(heights: PackedFloat32Array, n: int, step: float, extent: float, r: float,
		seed_value: int, waters: Dictionary, props: Dictionary, lights: Array) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 505
	var out := {}
	var clear: Array = []
	var rivers: Array = waters["rivers"]

	# The village gathers near the first river's mouth (or any shore if there is none).
	var mouth := Vector2.from_angle(rng.randf() * TAU) * r * 0.85
	if not rivers.is_empty():
		var points: PackedVector2Array = rivers[0]["points"]
		var beds: PackedFloat32Array = rivers[0]["beds"]
		for k in points.size():
			if beds[k] < 0.8:
				mouth = points[k]
				break
	var homes: Array[Vector3] = []
	for attempt in 600:
		if homes.size() >= 7:
			break
		var q := mouth + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(9.0, 80.0)
		var s := _sample_surface(heights, n, step, extent, seed_value, q.x, q.y)
		if s.x < 1.5 or s.x > 10.0 or s.z < 0.93 or _near_river(q, rivers, 5.0):
			continue
		var crowded := false
		for h in homes:
			if Vector2(h.x, h.z).distance_to(q) < 9.0:
				crowded = true
				break
		if crowded:
			continue
		# A level footprint: every corner within a metre of the middle.
		var low := s.x
		var level := true
		for corner: Vector2 in [Vector2(2.3, 2.0), Vector2(-2.3, 2.0), Vector2(2.3, -2.0), Vector2(-2.3, -2.0)]:
			var hc := _sample_surface(heights, n, step, extent, seed_value, q.x + corner.x, q.y + corner.y).x
			low = minf(low, hc)
			if absf(hc - s.x) > 1.0:
				level = false
		if level:
			homes.append(Vector3(q.x, low, q.y))
	if homes.size() >= 2:
		var middle := Vector2.ZERO
		for i in homes.size():
			var home := homes[i]
			var to_mouth := mouth - Vector2(home.x, home.z)
			var yaw := atan2(-to_mouth.x, -to_mouth.y) + rng.randf_range(-0.45, 0.45)
			var basis := Basis(Vector3.UP, yaw)
			var at := Vector3(home.x, home.y - 0.1, home.z)
			var tint := Color(rng.randf_range(0.94, 1.04), rng.randf_range(0.94, 1.02), rng.randf_range(0.9, 1.0))
			_push(props, &"cottage", Transform3D(basis, at), tint)
			_push(props, &"cottage_glow", Transform3D(basis, at), Color(1, 1, 1))
			clear.append(Vector3(home.x, home.z, 5.0))
			middle += Vector2(home.x, home.z)
			if i < 3:
				# A warm pool of light in front of the first few doors.
				lights.append([at + basis * Vector3(0.0, 2.0, -3.0), ProceduralMeshBuilder.WINDOW_GLOW, 1.3, 13.0, 0.05])
		middle /= homes.size()
		out["village"] = middle
		# Lamp posts on the lanes between neighbouring houses.
		for i in range(1, homes.size(), 2):
			var lane := (Vector2(homes[i].x, homes[i].z) + Vector2(homes[i - 1].x, homes[i - 1].z)) * 0.5
			var s := _sample_surface(heights, n, step, extent, seed_value, lane.x, lane.y)
			if s.x > 1.2 and s.z > 0.85 and not _near_river(lane, rivers, 2.0):
				var post := Vector3(lane.x, s.x - 0.1, lane.y)
				_push(props, &"beacon", Transform3D(Basis(Vector3.UP, rng.randf() * TAU), post), Color(1, 1, 1))
				_push(props, &"beacon_glow", Transform3D(Basis.IDENTITY, post), Color(1, 1, 1))
				clear.append(Vector3(lane.x, lane.y, 1.5))

		# A jetty from the shore beside the village, out over deep enough water.
		var outward := mouth.normalized()
		var side := Vector2(-outward.y, outward.x) * (14.0 if rng.randf() < 0.5 else -14.0)
		var walk := mouth + side - outward * 30.0
		for k in 60:
			var ground := _sample_surface(heights, n, step, extent, seed_value, walk.x, walk.y).x
			if ground < 0.4:
				break
			walk += outward * 1.5
		var tip := walk + outward * ProceduralMeshBuilder.JETTY_LENGTH
		var tip_ground := _sample_surface(heights, n, step, extent, seed_value, tip.x, tip.y).x
		if tip_ground < -1.0 and not _near_river(walk, rivers, 3.0):
			var root := walk - outward * 1.5
			var basis := Basis(Vector3.UP, atan2(-outward.x, -outward.y))
			_push(props, &"jetty", Transform3D(basis, Vector3(root.x, 1.05, root.y)), Color(1, 1, 1))
			var end := Vector3(tip.x, 1.0, tip.y) - Vector3(outward.x, 0.0, outward.y) * 1.5
			_push(props, &"beacon", Transform3D(basis, end), Color(1, 1, 1))
			_push(props, &"beacon_glow", Transform3D(basis, end), Color(1, 1, 1))
			lights.append([end + Vector3.UP * 2.1, LAMP_COLOUR, 1.4, 12.0, 0.1])

	# The lighthouse stands on a headland across the island from the village.
	for attempt in 24:
		var angle := mouth.angle() + PI + rng.randf_range(-1.3, 1.3)
		var dir := Vector2.from_angle(angle)
		var best := Vector2.INF
		var t := r * 0.45
		while t < extent:
			var q := dir * t
			var s := _sample_surface(heights, n, step, extent, seed_value, q.x, q.y)
			if s.x < 0.5:
				break
			if s.x >= 2.5 and s.x < 14.0 and s.z > 0.82:
				best = q
			t += 2.0
		if best == Vector2.INF or _near_river(best, rivers, 6.0):
			continue
		var ground := INF
		for corner: Vector2 in [Vector2(2.3, 2.3), Vector2(-2.3, 2.3), Vector2(2.3, -2.3), Vector2(-2.3, -2.3), Vector2.ZERO]:
			ground = minf(ground, _sample_surface(heights, n, step, extent, seed_value, best.x + corner.x, best.y + corner.y).x)
		var at := Vector3(best.x, ground - 0.2, best.y)
		var basis := Basis(Vector3.UP, atan2(-dir.x, -dir.y))
		_push(props, &"lighthouse", Transform3D(basis, at), Color(1, 1, 1))
		_push(props, &"lighthouse_glow", Transform3D(basis, at), Color(1, 1, 1))
		var lamp := at + Vector3.UP * ProceduralMeshBuilder.LIGHTHOUSE_LAMP
		lights.append([lamp, LAMP_COLOUR, 2.4, 30.0, 0.0])
		out["lighthouse"] = best
		out["beams"] = [lamp]
		clear.append(Vector3(best.x, best.y, 6.0))
		break
	out["clear"] = clear
	return out


static func _near_river(q: Vector2, rivers: Array, margin: float) -> bool:
	for river: Dictionary in rivers:
		var points: PackedVector2Array = river["points"]
		var widths: PackedFloat32Array = river["widths"]
		for k in points.size():
			if points[k].distance_squared_to(q) < pow(widths[k] * 0.5 + margin, 2.0):
				return true
	return false


## True where a big island's trees and grass must not grow: river beds, the
## lake, and the ground kept for houses, the jetty and the lighthouse
## (`keep_clear` from _clear_grid).
static func _kept_clear(x: float, z: float, n: int, step: float, extent: float, bed: PackedByteArray,
		keep_clear: Dictionary, waters: Dictionary) -> bool:
	var i := clampi(roundi((x + extent) / step), 0, n)
	var j := clampi(roundi((z + extent) / step), 0, n)
	if bed[j * (n + 1) + i] != 0:
		return true
	var lake: Dictionary = waters["lake"]
	if not lake.is_empty() and Vector2(x, z).distance_to(Vector2(lake["x"], lake["z"])) < float(lake["radius"]) + 2.0:
		return true
	for c: Vector3 in keep_clear.get(Vector2i(floori(x / CLEAR_GRID), floori(z / CLEAR_GRID)), []):
		if Vector2(x, z).distance_squared_to(Vector2(c.x, c.y)) < c.z * c.z:
			return true
	return false


## The twelve triangles of a box (centre and size in `xform`'s space), for a collider.
static func _box_faces(xform: Transform3D, centre: Vector3, size: Vector3) -> PackedVector3Array:
	var h := size * 0.5
	var c: Array[Vector3] = []
	for i in 8:
		c.append(xform * (centre + Vector3(h.x if i & 1 else -h.x, h.y if i & 2 else -h.y, h.z if i & 4 else -h.z)))
	var out := PackedVector3Array()
	for q: Array in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 2, 6, 4], [1, 5, 7, 3], [0, 4, 5, 1], [2, 3, 7, 6]]:
		out.append_array([c[q[0]], c[q[1]], c[q[2]], c[q[0]], c[q[2]], c[q[3]]])
	return out


## Buckets clearings [Vector3(x, z, radius)] by the CLEAR_GRID squares they touch,
## so the prop scatter only tests the few nearby.
static func _clear_grid(clear: Array) -> Dictionary:
	var grid := {}
	for c: Vector3 in clear:
		for gz in range(floori((c.y - c.z) / CLEAR_GRID), floori((c.y + c.z) / CLEAR_GRID) + 1):
			for gx in range(floori((c.x - c.z) / CLEAR_GRID), floori((c.x + c.z) / CLEAR_GRID) + 1):
				var key := Vector2i(gx, gz)
				if not grid.has(key):
					grid[key] = []
				(grid[key] as Array).append(c)
	return grid


## Half of the small islands keep a lamp post on a level stretch of beach.
static func _place_beacon(heights: PackedFloat32Array, n: int, step: float, extent: float, peak: float,
		seed_value: int, props: Dictionary, lights: Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 606
	if peak < 3.0 or rng.randf() > BEACON_CHANCE:
		return
	for attempt in 120:
		var q := Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.3, 0.95) * extent
		var s := _sample_surface(heights, n, step, extent, seed_value, q.x, q.y)
		if s.x < 1.0 or s.x > 2.8 or s.z < 0.9:
			continue
		var at := Vector3(q.x, s.x - 0.1, q.y)
		_push(props, &"beacon", Transform3D(Basis(Vector3.UP, rng.randf() * TAU), at), Color(1, 1, 1))
		_push(props, &"beacon_glow", Transform3D(Basis.IDENTITY, at), Color(1, 1, 1))
		lights.append([at + Vector3.UP * 2.1, LAMP_COLOUR, 1.2, 10.0, 0.1])
		return


## Water ribbon along a river: UV.x bank to bank, UV.y downstream (in widths),
## vertex alpha = how steeply the bed drops there (falls churn white).
static func _river_ribbon(river: Dictionary, step: float) -> Array:
	var points: PackedVector2Array = river["points"]
	var beds: PackedFloat32Array = river["beds"]
	var widths: PackedFloat32Array = river["widths"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := points.size()
	var left := PackedVector3Array()
	var right := PackedVector3Array()
	var vs := PackedFloat32Array()
	var steep := PackedFloat32Array()
	var along := 0.0
	for k in count:
		var prev := points[maxi(k - 1, 0)]
		var next := points[mini(k + 1, count - 1)]
		var tangent := (next - prev).normalized()
		var side := Vector2(-tangent.y, tangent.x)
		var half := maxf(widths[k] * 0.5 + 1.2, step * 0.9)
		var y := beds[k] + 0.02
		left.append(Vector3(points[k].x + side.x * half, y, points[k].y + side.y * half))
		right.append(Vector3(points[k].x - side.x * half, y, points[k].y - side.y * half))
		if k > 0:
			along += points[k].distance_to(points[k - 1]) / maxf(widths[k], 2.0)
		vs.append(along)
		steep.append(clampf((beds[maxi(k - 1, 0)] - beds[k]) / 1.2, 0.0, 1.0))
	for k in count - 1:
		if beds[k] < -0.9:
			break
		var quad := [[left[k], 0.0, vs[k], steep[k]], [right[k], 1.0, vs[k], steep[k]],
			[right[k + 1], 1.0, vs[k + 1], steep[k + 1]], [left[k + 1], 0.0, vs[k + 1], steep[k + 1]]]
		for idx: int in [0, 1, 2, 0, 2, 3]:
			var v: Array = quad[idx]
			st.set_normal(Vector3.UP)
			st.set_color(Color(1, 1, 1, v[3]))
			st.set_uv(Vector2(v[1], v[2]))
			st.add_vertex(v[0])
	return st.commit_to_arrays()


## The lake's still water: a 20-sided disc, UV.x running centre (0.5) to rim.
static func _lake_disc(lake: Dictionary) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := Vector3(lake["x"], float(lake["level"]) + 0.02, lake["z"])
	var lr: float = float(lake["radius"]) + 0.6
	for k in 20:
		var a0 := TAU * k / 20.0
		var a1 := TAU * (k + 1) / 20.0
		for v: Array in [[c, 0.5], [c + Vector3(cos(a0), 0.0, sin(a0)) * lr, 1.0], [c + Vector3(cos(a1), 0.0, sin(a1)) * lr, 1.0]]:
			st.set_normal(Vector3.UP)
			st.set_color(Color(1, 1, 1, 0))
			st.set_uv(Vector2(v[1], 0.0))
			st.add_vertex(v[0])
	return st.commit_to_arrays()


static func _ground_colour(y: float, ny: float, peak: float, woods: float) -> Color:
	if y < -0.35:
		return SEABED.lerp(SEABED_DEEP, clampf((-0.35 - y) / 3.0, 0.0, 1.0))
	if y < BEACH_TOP:
		return ROCK if ny < 0.6 else SAND
	if ny < 0.55:
		return ROCK_DARK if y > peak * 0.6 else ROCK
	if ny < 0.66:
		return DIRT
	if y > peak * 0.95 and ny < 0.86:
		return ROCK
	if woods > 0.25:
		return GRASS_SHADE
	if woods < -0.25:
		return GRASS_SUN
	return GRASS


## Which way cell (i, j) is split into triangles; a stable hash keeps the facets irregular.
static func _cell_flipped(seed_value: int, i: int, j: int) -> bool:
	return ProceduralMeshBuilder._hash01(i, j, seed_value) > 0.5


## Exact height and face normal of the triangulated surface at local (x, z):
## Vector4(height, normal.x, normal.y, normal.z).
static func _sample_surface(heights: PackedFloat32Array, n: int, step: float, extent: float,
		seed_value: int, x: float, z: float) -> Vector4:
	var fx := clampf((x + extent) / step, 0.0, n - 0.0001)
	var fz := clampf((z + extent) / step, 0.0, n - 0.0001)
	var i := int(fx)
	var j := int(fz)
	var u := fx - i
	var v := fz - j
	var h00 := heights[j * (n + 1) + i]
	var h10 := heights[j * (n + 1) + i + 1]
	var h01 := heights[(j + 1) * (n + 1) + i]
	var h11 := heights[(j + 1) * (n + 1) + i + 1]
	var a: Vector3
	var b: Vector3
	var c: Vector3
	if _cell_flipped(seed_value, i, j):
		if u + v <= 1.0:
			a = Vector3(0, h00, 0)
			b = Vector3(1, h10, 0)
			c = Vector3(0, h01, 1)
		else:
			a = Vector3(1, h10, 0)
			b = Vector3(1, h11, 1)
			c = Vector3(0, h01, 1)
	elif u >= v:
		a = Vector3(0, h00, 0)
		b = Vector3(1, h10, 0)
		c = Vector3(1, h11, 1)
	else:
		a = Vector3(0, h00, 0)
		b = Vector3(1, h11, 1)
		c = Vector3(0, h01, 1)
	# Plane through the triangle (in cell units scaled back to metres).
	a = Vector3(a.x * step, a.y, a.z * step)
	b = Vector3(b.x * step, b.y, b.z * step)
	c = Vector3(c.x * step, c.y, c.z * step)
	var normal := (b - a).cross(c - a).normalized()
	if normal.y < 0.0:
		normal = -normal
	var p := Vector3(u * step, 0.0, v * step)
	var h := a.y - (normal.x * (p.x - a.x) + normal.z * (p.z - a.z)) / maxf(normal.y, 0.001)
	return Vector4(h, normal.x, normal.y, normal.z)


static func _add_prop(props: Dictionary, kind: StringName, pos: Vector3, rng: RandomNumberGenerator,
		min_scale: float, max_scale: float, sink: float, max_tilt: float) -> void:
	var s := rng.randf_range(min_scale, max_scale)
	var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.12), s))
	var tilt_dir := rng.randf() * TAU
	basis = Basis(Vector3(cos(tilt_dir), 0.0, sin(tilt_dir)), rng.randf() * max_tilt) * basis
	var tint := Color(rng.randf_range(0.9, 1.06), rng.randf_range(0.93, 1.06), rng.randf_range(0.88, 1.0))
	_push(props, kind, Transform3D(basis, pos + Vector3.DOWN * sink * s), tint)


## Boulders squash and stretch freely and lean with the slope they sit on.
static func _add_rock(props: Dictionary, rng: RandomNumberGenerator, pos: Vector3, up: Vector3, size: float) -> void:
	var scale := Vector3(rng.randf_range(0.7, 1.5), rng.randf_range(0.5, 1.2), rng.randf_range(0.7, 1.5)) * size
	var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(scale)
	var axis := Vector3.UP.cross(up)
	if axis.length_squared() > 0.0001:
		basis = Basis(axis.normalized(), Vector3.UP.angle_to(up) * 0.7) * basis
	var shade := rng.randf_range(0.88, 1.06)
	_push(props, &"rock_a" if rng.randf() < 0.6 else &"rock_b",
		Transform3D(basis, pos + Vector3.DOWN * 0.25 * scale.y), Color(shade, shade * 0.98, shade * 0.96))


static func _push(props: Dictionary, kind: StringName, xform: Transform3D, tint: Color) -> void:
	var entry: Dictionary = props[kind]
	(entry["xforms"] as Array).append(xform)
	(entry["colours"] as Array).append(tint)


func _name_island(seed_value: int, r: float, props: Dictionary, with_ruins: bool, is_great: bool, is_massive: bool,
		chart: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + 17
	var kinds := NAME_KIND_GREAT if is_great else (NAME_KIND_SMALL if r < 30.0 else NAME_KIND_LARGE)
	if is_massive:
		kinds = MassiveIsland.NAME_KIND
	var island := "%s%s %s" % [
		NAME_FIRST[rng.randi_range(0, NAME_FIRST.size() - 1)],
		NAME_SECOND[rng.randi_range(0, NAME_SECOND.size() - 1)],
		kinds[rng.randi_range(0, kinds.size() - 1)]]
	var count := func(kind: StringName) -> int: return (props[kind]["xforms"] as Array).size()
	var about: String
	if is_massive:
		var count_words := ["No rivers", "One river", "Two rivers", "Three rivers", "Four rivers"]
		about = "%s wind inland to a harbour sound" % count_words[mini((chart["channels"] as Array).size(), 4)]
	elif is_great:
		var rivers: Array = chart.get("rivers", [])
		var count_words := ["No river", "A river", "Two rivers", "Three rivers"]
		about = "%s %s from %s%s" % [count_words[mini(rivers.size(), 3)],
			"runs" if rivers.size() == 1 else "run",
			"a mountain lake" if chart.has("lake") else "the highlands",
			" past a lantern-lit village" if chart.has("village") else " to the sea"]
	elif with_ruins:
		about = "Old stones keep watch on the ridge"
	elif count.call(&"pine") >= 8:
		about = "Pine-crowned hills above a sandy shore"
	elif count.call(&"palm") >= 4:
		about = "Palm-fringed beaches and warm shallows"
	elif count.call(&"broadleaf") >= 10:
		about = "Shady groves around a quiet cove"
	else:
		about = "A sunny sandbar, perfect for a rest"
	_result["name"] = island
	_result["description"] = about


# =============================================================================
# Main thread: build the nodes
# =============================================================================

func _finish() -> void:
	if _task_id == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	var data := _result
	_result = {}
	_apply(data)


func _apply(data: Dictionary) -> void:
	island_name = data["name"]
	description = data["description"]
	has_ruins = data["ruins"]
	features = data["chart"]
	landmarks = data["landmarks"]
	docks = data["docks"]
	_heights = data["heights"]
	_grid_n = data["n"]
	_grid_step = data["step"]
	_extent = data["extent"]

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data["terrain"])
	var terrain := MeshInstance3D.new()
	terrain.name = "Terrain"
	terrain.mesh = mesh
	terrain.material_override = _terrain_material
	add_child(terrain)

	var body := StaticBody3D.new()
	body.name = "Collision"
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(data["faces"])
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	add_child(body)

	var props: Dictionary = data["props"]
	for kind: StringName in props:
		var entry: Dictionary = props[kind]
		var xforms: Array = entry["xforms"]
		if xforms.is_empty():
			continue
		# A massive island's props go in tiles, so the far ones can be culled.
		var tiles := {}
		for k in xforms.size():
			var origin: Vector3 = (xforms[k] as Transform3D).origin
			var key := Vector2i(floori(origin.x / PROP_TILE), floori(origin.z / PROP_TILE)) if massive else Vector2i.ZERO
			if not tiles.has(key):
				tiles[key] = []
			(tiles[key] as Array).append(k)
		for key: Vector2i in tiles:
			add_child(_prop_node(kind, xforms, entry["colours"], tiles[key], key))

	if has_ruins:
		var arch := MeshInstance3D.new()
		arch.name = "Ruins"
		arch.mesh = ProceduralMeshBuilder.prop_mesh(&"ruin_arch")
		arch.material_override = _terrain_material
		arch.transform = data["ruin_xform"]
		add_child(arch)

	for arrays: Array in data["rivers"]:
		add_child(_water_node("River", arrays, _river_material))
	if not (data["lake"] as Array).is_empty():
		add_child(_water_node("Lake", data["lake"], _lake_material))

	for spec: Array in data["lights"]:
		var lamp := NightLight.new().configure(spec[1], spec[2], spec[3], spec[4])
		lamp.position = spec[0]
		add_child(lamp)

	for lamp: Vector3 in data["beams"]:
		var turner := Node3D.new()
		turner.name = "LighthouseBeam"
		turner.position = lamp
		turner.rotation.y = _beams.size() * 1.3
		for turn: float in [0.0, PI]:
			var cone := CylinderMesh.new()
			cone.top_radius = 0.5
			cone.bottom_radius = 7.0
			cone.height = 75.0
			cone.radial_segments = 12
			cone.rings = 1
			cone.cap_top = false
			cone.cap_bottom = false
			var beam := MeshInstance3D.new()
			beam.mesh = cone
			beam.material_override = _beam_material
			beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# Narrow end at the lamp, reaching out and dipping a little toward the sea.
			beam.transform = Transform3D(Basis(Vector3.UP, turn) * Basis(Vector3.RIGHT, -PI * 0.5 - 0.06),
				Vector3.ZERO).translated_local(Vector3(0.0, -cone.height * 0.5, 0.0))
			turner.add_child(beam)
		add_child(turner)
		_beams.append(turner)
	set_process(not _beams.is_empty())

	is_generated = true
	generated.emit()


## One MultiMesh of a prop kind, holding the instances listed in `picks`. A
## massive island's tiles sit at their tile's middle, so their visibility range
## counts from there.
func _prop_node(kind: StringName, xforms: Array, colours: Array, picks: Array, tile: Vector2i) -> MultiMeshInstance3D:
	var centre := Vector3((tile.x + 0.5) * PROP_TILE, 0.0, (tile.y + 0.5) * PROP_TILE) if massive else Vector3.ZERO
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = ProceduralMeshBuilder.prop_mesh(kind)
	mm.instance_count = picks.size()
	for k in picks.size():
		var xform: Transform3D = xforms[picks[k]]
		mm.set_instance_transform(k, Transform3D(xform.basis, xform.origin - centre))
		mm.set_instance_color(k, colours[picks[k]])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Props_%s" % kind if not massive else "Props_%s_%d_%d" % [kind, tile.x, tile.y]
	mmi.position = centre
	mmi.multimesh = mm
	mmi.material_override = material_for_kind(kind)
	if ProceduralMeshBuilder.GLOW_KINDS.has(kind):
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if kind == &"grass":
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = 160.0 + (PROP_TILE * 0.71 if massive else 0.0)
	elif massive:
		mmi.visibility_range_end = 560.0
	return mmi


func _water_node(node_name: String, arrays: Array, material: Material) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


## The material a prop kind is drawn with: ToonLand (foliage sways), or NightGlow for lamps and windows.
static func material_for_kind(kind: StringName) -> Material:
	_ensure_materials()
	if ProceduralMeshBuilder.GLOW_KINDS.has(kind):
		var look: Array = ProceduralMeshBuilder.GLOW_KINDS[kind]
		return ProceduralMeshBuilder.night_glow_material(look[0], look[1], look[2])
	return _foliage_material if FOLIAGE_KINDS.has(kind) else _terrain_material


static func river_material() -> ShaderMaterial:
	_ensure_materials()
	return _river_material


static func beam_material() -> ShaderMaterial:
	_ensure_materials()
	return _beam_material


## Shared ToonLand material for terrain, rocks, ruins and cargo.
static func terrain_material() -> ShaderMaterial:
	_ensure_materials()
	return _terrain_material


## Shared ToonLand material with wind sway, for trees and grass.
static func foliage_material() -> ShaderMaterial:
	_ensure_materials()
	return _foliage_material


static func _ensure_materials() -> void:
	if _terrain_material:
		return
	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = TERRAIN_SHADER
	_foliage_material = ShaderMaterial.new()
	_foliage_material.shader = TERRAIN_SHADER
	_foliage_material.set_shader_parameter(&"sway", 0.012)
	_foliage_material.set_shader_parameter(&"wet_darkening", 0.0)
	_river_material = ShaderMaterial.new()
	_river_material.shader = RIVER_SHADER
	_lake_material = ShaderMaterial.new()
	_lake_material.shader = RIVER_SHADER
	_lake_material.set_shader_parameter(&"still", 1.0)
	_beam_material = ShaderMaterial.new()
	_beam_material.shader = BEAM_SHADER
