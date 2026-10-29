class_name VoyageLog
extends RefCounted
## The saved voyage: where the boat lies, how far it has come, every island
## found so far (with its coastline traced for the chart) and the track sailed.
##
## Everything is static so the ship, world, menus and map share one copy, and it
## survives reload_current_scene() (returning to the title screen). It is written
## to user://voyage.json on every discovery, every AUTOSAVE_INTERVAL seconds at
## sea, on pausing, and on leaving. The archipelago itself is never saved: it
## grows again from the voyage's world seed, which the player never sees.

const PATH := "user://voyage.json"
## Where the voyage before goes when the player starts over (one step back, no more).
const PREVIOUS_PATH := "user://voyage.previous.json"
const VERSION := 1
const FIRST_SEED := 20261028
## A first voyage starts mid-afternoon, a few minutes before the first sunset.
const FIRST_HOUR := 15.0
const AUTOSAVE_INTERVAL := 20.0
## A new track point is laid once the boat is this far from the last one.
const TRACK_STEP := 40.0
const TRACK_MAX := 4000
## Rays cast from an island's centre to trace its coast for the chart.
const COAST_RAYS := 40

static var world_seed := FIRST_SEED
## True once the player has set sail at least once.
static var started := false
static var ship_position := Vector3.ZERO
static var ship_yaw := 0.0
static var distance_sailed := 0.0
static var top_speed := 0.0
static var time_at_sea := 0.0
## Game hour (0-24), advanced by DayNightCycle.
static var time_of_day := FIRST_HOUR
## In the order found: {cell: [x, y], name, description, x, z, radius, coast: [radii...], found_at}.
## Great islands add great: true and, in world x/z, rivers: [[x, z, x, z...]...], lake: [x, z, radius],
## village: [x, z] and lighthouse: [x, z]. Massive islands add massive: true, the same rivers
## (its streams), lake and village (its harbour town), and channels: [{name, line: [x, z, w, ...]}]
## (the rivers you can sail, w their width), sound: [x, z, radius], lighthouses: [[x, z]...],
## landmarks: [{id, kind, name, x, z}] and found: [landmark ids].
static var discoveries: Array[Dictionary] = []
## World x/z of the path sailed, one point per TRACK_STEP metres.
static var track := PackedVector2Array()

static var _loaded := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not data is Dictionary or int(data.get("version", 0)) != VERSION:
		return
	world_seed = int(data.get("world_seed", FIRST_SEED))
	started = bool(data.get("started", false))
	var ship: Dictionary = data.get("ship", {})
	ship_position = Vector3(float(ship.get("x", 0.0)), 0.0, float(ship.get("z", 0.0)))
	ship_yaw = float(ship.get("yaw", 0.0))
	distance_sailed = float(data.get("distance_sailed", 0.0))
	top_speed = float(data.get("top_speed", 0.0))
	time_at_sea = float(data.get("time_at_sea", 0.0))
	time_of_day = fposmod(float(data.get("time_of_day", FIRST_HOUR)), 24.0)
	discoveries.clear()
	for entry: Variant in data.get("discoveries", []):
		if entry is Dictionary:
			discoveries.append(entry)
	track.clear()
	var flat: Array = data.get("track", [])
	for i in range(0, flat.size() - 1, 2):
		track.append(Vector2(float(flat[i]), float(flat[i + 1])))


static func save() -> void:
	if not started:
		return
	var flat: Array[float] = []
	for p in track:
		flat.append(snappedf(p.x, 0.1))
		flat.append(snappedf(p.y, 0.1))
	var data := {
		"version": VERSION,
		"world_seed": world_seed,
		"started": started,
		"ship": {"x": ship_position.x, "z": ship_position.z, "yaw": ship_yaw},
		"distance_sailed": distance_sailed,
		"top_speed": top_speed,
		"time_at_sea": time_at_sea,
		"time_of_day": snappedf(time_of_day, 0.001),
		"discoveries": discoveries,
		"track": flat,
	}
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))


## Starts over: the voyage so far is moved aside to PREVIOUS_PATH (replacing any
## older one), and everything returns to a first voyage's, in a new stretch of
## sea. Reload the scene afterwards so the world grows from the new seed.
static func start_new() -> void:
	ensure_loaded()
	if FileAccess.file_exists(PATH):
		var from := ProjectSettings.globalize_path(PATH)
		var to := ProjectSettings.globalize_path(PREVIOUS_PATH)
		if FileAccess.file_exists(PREVIOUS_PATH):
			DirAccess.remove_absolute(to)
		DirAccess.rename_absolute(from, to)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	world_seed = rng.randi_range(1, 2_000_000_000)
	started = false
	ship_position = Vector3.ZERO
	ship_yaw = 0.0
	distance_sailed = 0.0
	top_speed = 0.0
	time_at_sea = 0.0
	time_of_day = FIRST_HOUR
	discoveries.clear()
	track.clear()


## Copies the boat's live state in (call before save()).
static func capture(ship: ShipController) -> void:
	if ship == null:
		return
	ship_position = Vector3(ship.global_position.x, 0.0, ship.global_position.z)
	ship_yaw = ship.global_rotation.y
	distance_sailed = ship.distance_sailed
	top_speed = ship.top_speed
	time_at_sea = ship.time_at_sea


## Puts a loaded voyage back on the boat. Called from the ship's _ready, before
## anything reads its transform.
static func restore(ship: ShipController) -> void:
	ensure_loaded()
	if not started:
		return
	ship.position = Vector3(ship_position.x, ship.position.y, ship_position.z)
	ship.rotation.y = ship_yaw
	ship.distance_sailed = distance_sailed
	ship.top_speed = top_speed
	ship.time_at_sea = time_at_sea


static func note_position(world_pos: Vector3) -> void:
	var p := Vector2(world_pos.x, world_pos.z)
	if not track.is_empty() and track[track.size() - 1].distance_to(p) < TRACK_STEP:
		return
	track.append(p)
	if track.size() > TRACK_MAX:
		# Keep the whole voyage at half the detail rather than forget its start.
		var thinned := PackedVector2Array()
		for i in range(0, track.size(), 2):
			thinned.append(track[i])
		track = thinned


static func is_discovered(cell: Vector2i) -> bool:
	return not entry_for(cell).is_empty()


## The discovery recorded for a cell, or {}.
static func entry_for(cell: Vector2i) -> Dictionary:
	for entry in discoveries:
		var c: Array = entry["cell"]
		if int(c[0]) == cell.x and int(c[1]) == cell.y:
			return entry
	return {}


## Whether a massive island's landmark has been found.
static func has_found(cell: Vector2i, id: String) -> bool:
	return (entry_for(cell).get("found", []) as Array).has(id)


static func mark_found(cell: Vector2i, id: String) -> void:
	var entry := entry_for(cell)
	if entry.is_empty():
		return
	if not entry.has("found"):
		entry["found"] = []
	if not (entry["found"] as Array).has(id):
		(entry["found"] as Array).append(id)


static func found_count(cell: Vector2i) -> int:
	return (entry_for(cell).get("found", []) as Array).size()


## Records a newly found island, tracing its coastline from the terrain.
static func record_discovery(cell: Vector2i, island: IslandGenerator) -> void:
	if is_discovered(cell):
		return
	var centre := island.global_position
	var reach := island.radius * IslandGenerator.EXTENT_FACTOR
	var stride := 3.0 if island.massive else (2.0 if island.great else 1.5)
	var rays := COAST_RAYS * 3 if island.massive else COAST_RAYS
	var coast: Array[float] = []
	for i in rays:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, -TAU * i / rays)
		var shore := 0.0
		if island.massive:
			# Walk in from the open sea to the first land: from the middle, a ray
			# would start in the sound and follow the rivers out.
			var r := reach
			while r > stride:
				if island.height_at(centre + dir * r) > 0.0:
					shore = r
					break
				r -= stride
		else:
			# Walk out from the centre to the first point that is under water.
			var r := 0.0
			while r < reach:
				if island.height_at(centre + dir * r) <= 0.0:
					break
				shore = r
				r += stride
		coast.append(snappedf(maxf(shore, 2.0), 0.1))
	var entry := {
		"cell": [cell.x, cell.y],
		"name": island.island_name,
		"description": island.description,
		"x": snappedf(centre.x, 0.1),
		"z": snappedf(centre.z, 0.1),
		"radius": snappedf(island.radius, 0.1),
		"coast": coast,
		"found_at": time_at_sea,
	}
	if island.great or island.massive:
		var at := Vector2(centre.x, centre.z)
		var place := func(local: Vector2) -> Array: return [snappedf(at.x + local.x, 0.1), snappedf(at.y + local.y, 0.1)]
		if island.great:
			entry["great"] = true
		var rivers: Array = []
		for river: PackedVector2Array in island.features.get("rivers", []):
			var flat: Array = []
			for p in river:
				flat.append_array(place.call(p))
			rivers.append(flat)
		entry["rivers"] = rivers
		if island.features.has("lake"):
			var lake: Vector3 = island.features["lake"]
			entry["lake"] = place.call(Vector2(lake.x, lake.y)) + [snappedf(lake.z, 0.1)]
		for key: String in ["village", "lighthouse"]:
			if island.features.has(key):
				entry[key] = place.call(island.features[key])
		if island.massive:
			entry["massive"] = true
			var channels: Array = []
			for channel: Dictionary in island.features["channels"]:
				var points: PackedVector2Array = channel["points"]
				var widths: PackedFloat32Array = channel["widths"]
				var line: Array = []
				for k in points.size():
					line.append_array(place.call(points[k]) + [snappedf(widths[k], 0.1)])
				channels.append({"name": channel["name"], "line": line})
			entry["channels"] = channels
			var sound: Vector3 = island.features["sound"]
			entry["sound"] = place.call(Vector2(sound.x, sound.y)) + [snappedf(sound.z, 0.1)]
			var lighthouses: Array = []
			for spot: Vector2 in island.features["lighthouses"]:
				lighthouses.append(place.call(spot))
			entry["lighthouses"] = lighthouses
			var marks: Array = []
			for mark: Dictionary in island.landmarks:
				var p: Array = place.call(mark["at"])
				marks.append({"id": mark["id"], "kind": mark["kind"], "name": mark["name"], "x": p[0], "z": p[1]})
			entry["landmarks"] = marks
			entry["found"] = []
	discoveries.append(entry)


## Coastline of a recorded island as world x/z points.
static func coast_points(entry: Dictionary) -> PackedVector2Array:
	var points := PackedVector2Array()
	var radii: Array = entry["coast"]
	var c := Vector2(float(entry["x"]), float(entry["z"]))
	for i in radii.size():
		# Same rays as record_discovery: from north, turning clockwise.
		var dir := Vector2(0.0, -1.0).rotated(TAU * i / radii.size())
		points.append(c + dir * float(radii[i]))
	return points
