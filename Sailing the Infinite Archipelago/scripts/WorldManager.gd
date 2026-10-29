class_name WorldManager
extends Node3D
## Streams an endless archipelago around the player.
##
## The sea is split into square cells (chunk_size). Each cell is hashed from its
## coordinates and world_seed into a plan: open water, or one island with a seed,
## radius, peak and position kept far enough from the cell edge that neighbours
## never touch. Loaded cells live in a spatial hash (Vector2i -> island), so
## lookups and nearest-island queries only touch a few cells.
##
## Cells within render_radius are spawned closest-first, a few per frame, and
## generate on worker threads; cells beyond render_radius + unload_margin are
## freed. The fog in main.tscn ends inside render_radius, so islands appear and
## vanish behind it. Reaching an island for the first time announces it on the HUD.
##
## Every once in a while the sea holds a great island instead: each block of
## GREAT_BLOCK x GREAT_BLOCK cells may hide one (great_chance), filling a 3x3 run of
## cells around its centre cell, so no small island crowds it. It rises out of
## the fog higher and slower than the rest.
##
## Far rarer is a massive island: each block of MASSIVE_BLOCK x MASSIVE_BLOCK
## cells may hide one (massive_chance), filling a MASSIVE_RUN x MASSIVE_RUN run of
## cells, with rivers you can sail up (see MassiveIsland). Big islands load as
## soon as any cell of their run comes into range, not just their centre. While
## one is loaded the swell fades out inside its coast (WindManager.set_calm), and
## sailing near one of its landmarks names it and puts it on the chart.
##
## The seed belongs to the saved voyage (VoyageLog), so the same archipelago grows
## back every time the game is opened. This node also keeps the voyage saved: the
## track sailed, each discovery as it happens, and an autosave while at sea. New
## islands rise out of the sea on a spring, only ever seen when one loads close by.

signal island_spawned(island: IslandGenerator)
signal island_discovered(island: IslandGenerator)

const ISLAND_SCENE := preload("res://Sailing the Infinite Archipelago/scenes/island_chunk.tscn")
## Great islands are planned per block of this many cells square.
const GREAT_BLOCK := 4
## Massive islands: planned per block of this many cells square, each filling a
## run this many cells square.
const MASSIVE_BLOCK := 12
const MASSIVE_RUN := 5

@export var world_seed := 20261028
@export var chunk_size := 260.0
@export var render_radius := 430.0
@export var unload_margin := 90.0
@export_range(0.0, 1.0) var island_chance := 0.62
@export var radius_range := Vector2(22.0, 56.0)
@export var peak_range := Vector2(5.0, 17.0)
## No island may come closer than this to the world origin (the starting berth).
@export var start_clearing := 70.0
## Extra distance beyond an island's radius at which it counts as discovered.
@export var discovery_padding := 30.0
## How far below the surface a freshly generated island starts its rise.
@export var rise_depth := 9.0
@export_group("Great islands")
@export_range(0.0, 1.0) var great_chance := 0.4
@export var great_radius_range := Vector2(150.0, 185.0)
@export var great_peak_range := Vector2(34.0, 48.0)
## No great island is centred closer than this to the starting berth.
@export var great_clearing := 700.0
@export_group("Massive islands")
@export_range(0.0, 1.0) var massive_chance := 0.75
@export var massive_radius_range := Vector2(420.0, 450.0)
@export var massive_peak_range := Vector2(62.0, 80.0)
## No massive island is centred closer than this to the starting berth.
@export var massive_clearing := 1500.0
@export_group("")
@export var max_spawns_per_frame := 1
## Islands allowed to be generating on worker threads at once.
@export var max_generating := 3
@export var scan_interval := 0.25

## Loaded cells: Vector2i -> IslandGenerator, or null for open water.
var _cells := {}
## Cells whose island has been discovered, so returning later stays quiet.
var _discovered := {}
var _spawn_queue: Array[Vector2i] = []
var _generating := 0
var _scan_timer := 0.0
## Block (Vector2i) -> that block's great island plan, or {} for none.
var _great_plans := {}
## Block (Vector2i) -> that block's massive island plan, or {} for none.
var _massive_plans := {}
## The loaded massive island, if any (they lie kilometres apart).
var _massive: IslandGenerator
var _autosave_timer := VoyageLog.AUTOSAVE_INTERVAL
var _player: Node3D


func _enter_tree() -> void:
	add_to_group("world")


func _ready() -> void:
	GameSettings.ensure_loaded()
	GameSettings.apply(get_tree())
	VoyageLog.ensure_loaded()
	world_seed = VoyageLog.world_seed
	# WindManager outlives a scene reload; no massive island is loaded in this one yet.
	WindManager.set_calm(Vector4.ZERO)
	for entry in VoyageLog.discoveries:
		var c: Array = entry["cell"]
		_discovered[Vector2i(int(c[0]), int(c[1]))] = true
	_player = get_tree().get_first_node_in_group("player_ship") as Node3D
	# Prop meshes are shared by every island; build them once on the main thread.
	for kind in ProceduralMeshBuilder.PROP_KINDS:
		ProceduralMeshBuilder.prop_mesh(kind)
	_warm_shaders()
	_scan()


func _process(delta: float) -> void:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player_ship") as Node3D
		if _player == null:
			return
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = scan_interval
		_scan()
		_check_discoveries()
		_log_voyage()
	_spawn_from_queue()
	var ship := _player as ShipController
	if ship and ship.controls_enabled:
		_autosave_timer -= delta
		if _autosave_timer <= 0.0:
			save_voyage()


func _notification(what: int) -> void:
	# In a browser the tab can close without warning, so leaving it saves too.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or (what == NOTIFICATION_APPLICATION_FOCUS_OUT and OS.has_feature("web")):
		save_voyage()


# =============================================================================
# Public queries
# =============================================================================

func world_to_cell(world_pos: Vector3) -> Vector2i:
	return Vector2i(floori(world_pos.x / chunk_size), floori(world_pos.z / chunk_size))


## The loaded island whose cell contains world_pos, if any.
func get_island_in_cell(world_pos: Vector3) -> IslandGenerator:
	return _cells.get(world_to_cell(world_pos)) as IslandGenerator


## Closest loaded island (by horizontal distance to its centre), or null.
func get_nearest_island(world_pos: Vector3, max_distance := INF) -> IslandGenerator:
	var best: IslandGenerator = null
	var best_d := max_distance
	var centre := world_to_cell(world_pos)
	var reach := ceili(minf(max_distance, render_radius) / chunk_size) + 1
	for cz in range(centre.y - reach, centre.y + reach + 1):
		for cx in range(centre.x - reach, centre.x + reach + 1):
			var island := _cells.get(Vector2i(cx, cz)) as IslandGenerator
			if island == null:
				continue
			var d := Vector2(island.position.x - world_pos.x, island.position.z - world_pos.z).length()
			if d < best_d:
				best_d = d
				best = island
	return best


## Terrain height at a world position (sea level 0), or -INF over open sea.
func terrain_height_at(world_pos: Vector3) -> float:
	# A massive island reaches further from its centre than any neighbour's does.
	if _massive and _massive.is_generated:
		var h := _massive.height_at(world_pos)
		if h != -INF:
			return h
	var island := get_nearest_island(world_pos, chunk_size * 1.25)
	return island.height_at(world_pos) if island else -INF


## The nearest berth on a massive island's quays and landings within `reach` of
## a world position: {name, position (at sea level), yaw} or {} if none.
func nearest_berth(world_pos: Vector3, reach: float) -> Dictionary:
	if _massive == null or not _massive.is_generated:
		return {}
	var best := {}
	var best_d := reach
	for dock: Dictionary in _massive.docks:
		for berth: Vector3 in dock["berths"]:
			var at := _massive.to_global(berth)
			at.y = 0.0
			var d := Vector2(at.x - world_pos.x, at.z - world_pos.z).length()
			if d < best_d:
				best_d = d
				best = {"name": dock["name"], "position": at, "yaw": float(dock["yaw"]) + _massive.rotation.y}
	return best


func discovered_count() -> int:
	return _discovered.size()


## Writes the voyage as it stands (boat, log, discoveries, track) to disk.
func save_voyage() -> void:
	_autosave_timer = VoyageLog.AUTOSAVE_INTERVAL
	VoyageLog.capture(_player as ShipController)
	VoyageLog.save()


## What a cell holds, without loading it. Empty Dictionary = open water (or
## part of a big island that belongs to its centre cell).
func plan_cell(cell: Vector2i) -> Dictionary:
	var massive := massive_plan_for(cell)
	if not massive.is_empty() and _in_run(cell, massive["corner"], MASSIVE_RUN):
		return massive if cell == massive["centre"] else {}
	var great := great_plan_for(cell)
	if not great.is_empty():
		var corner: Vector2i = great["corner"]
		if cell.x >= corner.x and cell.x <= corner.x + 2 and cell.y >= corner.y and cell.y <= corner.y + 2:
			return great if cell == corner + Vector2i.ONE else {}
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(cell.x, cell.y, world_seed))
	# The cell just ahead of the starting berth always has an island to sail to.
	var guaranteed := cell == Vector2i(0, -1)
	if not guaranteed and rng.randf() > island_chance:
		return {}
	var r := rng.randf_range(radius_range.x, radius_range.y)
	var margin := r * IslandGenerator.EXTENT_FACTOR + 2.0
	if margin * 2.0 >= chunk_size:
		r = (chunk_size * 0.5 - 2.0) / IslandGenerator.EXTENT_FACTOR - 1.0
		margin = chunk_size * 0.5 - 1.0
	var origin := Vector2(cell.x * chunk_size, cell.y * chunk_size)
	var pos := origin + Vector2(rng.randf_range(margin, chunk_size - margin), rng.randf_range(margin, chunk_size - margin))
	if pos.length() < start_clearing + r * IslandGenerator.EXTENT_FACTOR:
		if not guaranteed:
			return {}
		pos = pos.normalized() * (start_clearing + r * IslandGenerator.EXTENT_FACTOR)
	return {
		"seed": rng.randi(),
		"radius": r,
		# Small islands stay low and rounded; only the big ones grow real hills.
		"peak": minf(rng.randf_range(peak_range.x, peak_range.y), r * 0.3),
		"position": Vector3(pos.x, 0.0, pos.y),
	}


## The great island planned for the block that holds `cell`, or {} if none.
func great_plan_for(cell: Vector2i) -> Dictionary:
	var block := Vector2i(floori(cell.x / float(GREAT_BLOCK)), floori(cell.y / float(GREAT_BLOCK)))
	if _great_plans.has(block):
		return _great_plans[block]
	var plan := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector4i(block.x, block.y, world_seed, 7))
	if rng.randf() < great_chance:
		var corner := block * GREAT_BLOCK + Vector2i(rng.randi_range(0, 1), rng.randi_range(0, 1))
		var centre := corner + Vector2i.ONE
		var pos := Vector2((centre.x + 0.5) * chunk_size, (centre.y + 0.5) * chunk_size) \
			+ Vector2(rng.randf_range(-25.0, 25.0), rng.randf_range(-25.0, 25.0))
		# An island already found in its way wins: the world never takes back a discovery.
		var blocked := false
		for dz in 3:
			for dx in 3:
				var c := corner + Vector2i(dx, dz)
				if c != centre and VoyageLog.is_discovered(c):
					blocked = true
		# A massive island wins over a great one, with a cell of sea between them.
		for dz in range(-1, 4):
			for dx in range(-1, 4):
				var c := corner + Vector2i(dx, dz)
				var massive := massive_plan_for(c)
				if not massive.is_empty() and _in_run(c, massive["corner"], MASSIVE_RUN):
					blocked = true
		if pos.length() >= great_clearing and not blocked:
			plan = {
				"seed": rng.randi(),
				"radius": rng.randf_range(great_radius_range.x, great_radius_range.y),
				"peak": rng.randf_range(great_peak_range.x, great_peak_range.y),
				"position": Vector3(pos.x, 0.0, pos.y),
				"great": true,
				"corner": corner,
				"centre": centre,
			}
	_great_plans[block] = plan
	return plan


## The massive island planned for the block that holds `cell`, or {} if none.
func massive_plan_for(cell: Vector2i) -> Dictionary:
	var block := Vector2i(floori(cell.x / float(MASSIVE_BLOCK)), floori(cell.y / float(MASSIVE_BLOCK)))
	if _massive_plans.has(block):
		return _massive_plans[block]
	var plan := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector4i(block.x, block.y, world_seed, 11))
	if rng.randf() < massive_chance:
		var corner := block * MASSIVE_BLOCK + Vector2i(rng.randi_range(0, MASSIVE_BLOCK - MASSIVE_RUN),
			rng.randi_range(0, MASSIVE_BLOCK - MASSIVE_RUN))
		var centre := corner + Vector2i.ONE * (MASSIVE_RUN / 2)
		var pos := Vector2((centre.x + 0.5) * chunk_size, (centre.y + 0.5) * chunk_size)
		# Anything already found on or around its ground wins (a great island's
		# run can reach two cells out); only the massive island itself may be there.
		var blocked := false
		for dz in range(-2, MASSIVE_RUN + 2):
			for dx in range(-2, MASSIVE_RUN + 2):
				var c := corner + Vector2i(dx, dz)
				var found := VoyageLog.entry_for(c)
				if not found.is_empty() and not (c == centre and found.get("massive", false)):
					blocked = true
		if pos.length() >= massive_clearing and not blocked:
			plan = {
				"seed": rng.randi(),
				"radius": rng.randf_range(massive_radius_range.x, massive_radius_range.y),
				"peak": rng.randf_range(massive_peak_range.x, massive_peak_range.y),
				"position": Vector3(pos.x, 0.0, pos.y),
				"massive": true,
				"corner": corner,
				"centre": centre,
			}
	_massive_plans[block] = plan
	return plan


static func _in_run(cell: Vector2i, corner: Vector2i, run: int) -> bool:
	return cell.x >= corner.x and cell.x < corner.x + run and cell.y >= corner.y and cell.y < corner.y + run


## The cell that loads whatever covers `cell`: a big island's centre cell, or itself.
func _owner_cell(cell: Vector2i) -> Vector2i:
	var massive := massive_plan_for(cell)
	if not massive.is_empty() and _in_run(cell, massive["corner"], MASSIVE_RUN):
		return massive["centre"]
	var great := great_plan_for(cell)
	if not great.is_empty() and _in_run(cell, great["corner"], 3):
		return great["centre"]
	return cell


## Distance from a world position to the ground a cell's island may cover: its
## whole run for a big island's centre cell, otherwise the cell itself.
func _footprint_distance(cell: Vector2i, world_pos: Vector3) -> float:
	var massive := massive_plan_for(cell)
	if not massive.is_empty() and cell == massive["centre"]:
		return _rect_distance(massive["corner"], MASSIVE_RUN, world_pos)
	var great := great_plan_for(cell)
	if not great.is_empty() and cell == great["centre"]:
		return _rect_distance(great["corner"], 3, world_pos)
	return _rect_distance(cell, 1, world_pos)


# =============================================================================
# Streaming
# =============================================================================

func _scan() -> void:
	if _player == null:
		return
	var here := _player.global_position
	var centre := world_to_cell(here)
	var reach := ceili(render_radius / chunk_size)

	for cz in range(centre.y - reach, centre.y + reach + 1):
		for cx in range(centre.x - reach, centre.x + reach + 1):
			var cell := Vector2i(cx, cz)
			if _cell_distance(cell, here) > render_radius:
				continue
			# Any cell of a big island's run in range brings in the whole island.
			for c: Vector2i in [cell, _owner_cell(cell)]:
				if not _cells.has(c) and not _spawn_queue.has(c):
					_spawn_queue.append(c)

	var unload_at := render_radius + unload_margin
	for cell: Vector2i in _cells.keys():
		if _footprint_distance(cell, here) > unload_at:
			var island := _cells[cell] as IslandGenerator
			if island:
				if not island.is_generated:
					_generating -= 1
				if island == _massive:
					_massive = null
					WindManager.set_calm(Vector4.ZERO)
				island.queue_free()
			_cells.erase(cell)
	_spawn_queue = _spawn_queue.filter(func(c: Vector2i) -> bool: return _footprint_distance(c, here) <= unload_at)
	_spawn_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _footprint_distance(a, here) < _footprint_distance(b, here))


func _spawn_from_queue() -> void:
	var spawned := 0
	while not _spawn_queue.is_empty() and spawned < max_spawns_per_frame and _generating < max_generating:
		var cell: Vector2i = _spawn_queue.pop_front()
		var plan := plan_cell(cell)
		if plan.is_empty():
			_cells[cell] = null
			continue
		var island := ISLAND_SCENE.instantiate() as IslandGenerator
		island.name = "Island_%d_%d" % [cell.x, cell.y]
		island.configure(plan["seed"], plan["radius"], plan["peak"], plan.get("great", false), plan.get("massive", false))
		island.position = plan["position"]
		island.discovered = _discovered.has(cell)
		island.generated.connect(_on_island_generated.bind(island))
		_cells[cell] = island
		_generating += 1
		add_child(island)
		spawned += 1


func _on_island_generated(island: IslandGenerator) -> void:
	_generating -= 1
	var rest := island.position.y
	# A great island heaves up out of the fog: deeper and slower; a massive one more so.
	var depth := 4.0 if island.massive else (3.0 if island.great else 1.0)
	island.position.y = rest - rise_depth * depth
	island.create_tween().tween_property(island, "position:y", rest, 5.5 if island.massive else (4.0 if island.great else 2.4)) \
		.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	if island.massive:
		_massive = island
		# The swell dies away inside the coast, so the rivers and the sound lie still.
		WindManager.set_calm(Vector4(island.position.x, island.position.z, island.radius * 0.55, island.radius * 0.95))
	island_spawned.emit(island)


func _check_discoveries() -> void:
	var here := _player.global_position
	for cell: Vector2i in _cells:
		var island := _cells[cell] as IslandGenerator
		if island == null or not island.is_generated or island.discovered:
			continue
		var d := Vector2(island.position.x - here.x, island.position.z - here.z).length()
		if d <= island.get_discover_radius(discovery_padding):
			island.discovered = true
			_discovered[cell] = true
			VoyageLog.record_discovery(cell, island)
			save_voyage()
			island_discovered.emit(island)
			var from_home := GameSettings.format_distance(Vector2(island.position.x, island.position.z).length())
			var kind := "Massive island" if island.massive else ("Great island" if island.great else "New island")
			get_tree().call_group("cozy_hud", "announce_discovery", island.island_name,
				"%s · %s from home" % [island.description, from_home], kind)
	if _massive and _massive.is_generated and _massive.discovered:
		_check_landmarks(_massive, here)


## Names each of a massive island's landmarks the first time the boat comes near.
func _check_landmarks(island: IslandGenerator, here: Vector3) -> void:
	var cell := world_to_cell(island.position)
	var at := Vector2(here.x - island.position.x, here.z - island.position.z)
	for mark: Dictionary in island.landmarks:
		if at.distance_to(mark["at"]) > float(mark["reach"]) or VoyageLog.has_found(cell, mark["id"]):
			continue
		VoyageLog.mark_found(cell, mark["id"])
		save_voyage()
		var detail: String
		match String(mark["kind"]):
			"sound":
				detail = "A harbour town at the heart of %s" % island.island_name
			"river":
				detail = "Winds inland through %s" % island.island_name
			"falls":
				detail = "Tumbling down from the mountains"
			_:
				detail = "Old stones above the river"
		var found := VoyageLog.found_count(cell)
		get_tree().call_group("cozy_hud", "announce_discovery", mark["name"],
			"%s · %d of %d found" % [detail, found, island.landmarks.size()], "Landmark")


## Lays the track for the chart while the player has the helm (not behind the title).
func _log_voyage() -> void:
	var ship := _player as ShipController
	if ship and ship.controls_enabled:
		VoyageLog.note_position(ship.global_position)


## Draws every island material once, hidden under the sea ahead of the ship, so the renderer
## compiles those shaders while the HUD intro plays instead of mid-voyage
## (the first island to come into view used to cost a ~130 ms frame).
func _warm_shaders() -> void:
	var holder := Node3D.new()
	holder.name = "ShaderWarmup"
	add_child(holder)
	# Just under the surface ahead of the bow: inside the opening camera's view and shadow range.
	var at := Vector3(0.0, -4.0, -24.0)
	if _player:
		at = _player.global_transform * at
	for kind in ProceduralMeshBuilder.PROP_KINDS:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = ProceduralMeshBuilder.prop_mesh(kind)
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D(Basis.IDENTITY, at))
		mm.set_instance_color(0, Color.WHITE)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = IslandGenerator.material_for_kind(kind)
		holder.add_child(mmi)
	# River water and lighthouse beams too, for the first great island.
	for mat: Material in [IslandGenerator.river_material(), IslandGenerator.beam_material()]:
		var quad := MeshInstance3D.new()
		quad.mesh = QuadMesh.new()
		quad.material_override = mat
		quad.position = at
		holder.add_child(quad)
	var plain := MeshInstance3D.new()
	plain.mesh = ProceduralMeshBuilder.prop_mesh(&"rock_a")
	plain.material_override = IslandGenerator.terrain_material()
	plain.position = at
	holder.add_child(plain)
	get_tree().create_timer(0.5).timeout.connect(holder.queue_free)


## Distance from a world position to the nearest point of a cell (0 if inside).
func _cell_distance(cell: Vector2i, world_pos: Vector3) -> float:
	return _rect_distance(cell, 1, world_pos)


## Distance from a world position to a run of cells `run` square from `corner` (0 if inside).
func _rect_distance(corner: Vector2i, run: int, world_pos: Vector3) -> float:
	var min_x := corner.x * chunk_size
	var min_z := corner.y * chunk_size
	var span := chunk_size * run
	var dx := maxf(maxf(min_x - world_pos.x, 0.0), world_pos.x - (min_x + span))
	var dz := maxf(maxf(min_z - world_pos.z, 0.0), world_pos.z - (min_z + span))
	return Vector2(dx, dz).length()
