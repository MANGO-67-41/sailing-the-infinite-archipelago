class_name MassiveIsland
extends RefCounted
## The rarest land in the archipelago: a whole country of an island, the best
## part of a kilometre across. IslandGenerator builds it when configured as
## massive (see WorldManager for how seldom that happens); this class holds the
## parts that are only its own.
##
## You can sail into it. Three or four wide rivers open from the sea in
## estuaries, each marked by a lighthouse, and wind inland between lantern-lit
## banks, through valleys and mountain gorges, to a sheltered sound near the
## middle with a harbour town on its shore. The rivers are cut down below sea
## level and deeper than the hull draws, so the sea itself fills them, and the
## swell dies away inside the coast (WorldManager publishes ocean_calm). Smaller
## streams tumble out of the mountains in falls to join them, one of them from a
## mountain lake, and old stones stand on a hill above a river.
##
## The sound, each river, the falls and the stones are landmarks: sailing close
## to one for the first time names it on the HUD and draws it on the chart.
##
## Everything here runs on IslandGenerator's worker thread: pure data, no nodes.

## Terrain grid spacing and prop spacing, in metres (coarser than a great island:
## there is a lot more of it).
const CELL := 4.0
const PROP_SPACING := 3.0
const RIVER_STEP := 4.0
## Navigable rivers: depth of the bed, and the narrowest and widest a river gets.
const CHANNEL_BED := -3.4
const CHANNEL_WIDTH := Vector2(22.0, 40.0)
## Sharpest bend a river may take per step (radians per RIVER_STEP), so the boat
## can always follow it round.
const MAX_BEND := 0.11
## Lantern posts along the banks, one every this many river points.
const LANTERN_EVERY := 14
const NAME_KIND: PackedStringArray = ["Wilds", "Hinterland", "Expanse", "Grand Isle"]


## Lowland all round a ragged coast, a ring of ridged mountains, and a gentler
## basin in the middle where the rivers meet.
static func height(x: float, z: float, r: float, peak: float, shape: FastNoiseLite, ridges: FastNoiseLite) -> float:
	var reach := r * (0.9 + 0.2 * shape.get_noise_2d(x, z))
	var d := Vector2(x, z).length() / reach
	var base := 1.0 - smoothstep(0.78, 1.0, d)
	var ridge := ridges.get_noise_2d(x, z) * 0.5 + 0.5
	var hills := 4.5 + 5.0 * ridge
	var ring := smoothstep(0.12, 0.38, d) * (1.0 - smoothstep(0.6, 0.95, d))
	var mountains := peak * pow(ridge, 2.4) * ring
	var h := lerpf(-3.6, hills + mountains, pow(base, 0.8))
	h -= smoothstep(1.0, 1.3, d) * 5.0
	if h > 0.0 and h < 2.2:
		h = 2.2 * pow(h / 2.2, 2.0)
	elif h >= 2.2:
		var t := h / 2.2
		var terraced := 2.2 * (floorf(t) + smoothstep(0.25, 0.75, t - floorf(t)))
		h = lerpf(h, terraced, 0.3 * smoothstep(2.2, 3.4, h))
	return h


## Cuts the sound, the navigable rivers and the mountain streams into `heights`.
## `bed` gets 2 under navigable water and 1 under a stream.
## Returns {sound: {x, z, radius, name}, channels: [{points, widths, mouth, name}],
## rivers: [{points, beds, widths}] (the streams), lake: {...} or {}, landmarks: [...]}.
static func carve(heights: PackedFloat32Array, bed: PackedByteArray, n: int, step: float, extent: float,
		r: float, peak: float, seed_value: int) -> Dictionary:
	var original := heights.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 303
	var names := _Namer.new(seed_value + 707)
	var meander := FastNoiseLite.new()
	meander.seed = seed_value + 404
	meander.frequency = 0.05
	var landmarks: Array = []

	# The sound: deep, still water near the middle.
	var sound_c := Vector2.from_angle(rng.randf() * TAU) * r * rng.randf_range(0.0, 0.12)
	var sound_r := rng.randf_range(62.0, 80.0)
	var sound := {"x": sound_c.x, "z": sound_c.y, "radius": sound_r, "name": names.next() + " Sound"}
	_cut(heights, original, bed, n, step, extent, sound_c, sound_r, sound_r + 34.0)
	landmarks.append({"id": "sound", "kind": "sound", "name": sound["name"], "at": sound_c, "reach": sound_r + 25.0})

	# The rivers: out from the sound, each toward its own stretch of coast.
	var channels: Array = []
	# Points of the rivers already laid, so a later one keeps its distance.
	var laid := PackedVector2Array()
	var count := 3 + (1 if rng.randf() < 0.5 else 0)
	var first := rng.randf() * TAU
	for i in count:
		var aim := first + TAU * i / count + rng.randf_range(-0.3, 0.3)
		var heading := aim
		var p := sound_c + Vector2.from_angle(aim) * sound_r * 0.6
		var points := PackedVector2Array()
		var widths := PackedFloat32Array()
		var bias := rng.randf_range(-3.0, 3.0)
		var mouth := -1
		for k in 420:
			points.append(p)
			var out := clampf(p.length() / r, 0.0, 1.0)
			widths.append(lerpf(CHANNEL_WIDTH.x, CHANNEL_WIDTH.y, out * out) + bias
				+ meander.get_noise_2d(k * 5.0, i * 31.0) * 4.0)
			var ground := IslandGenerator._sample_surface(original, n, step, extent, seed_value, p.x, p.y).x
			if mouth < 0 and p.length() > r * 0.6 and ground < -2.0:
				mouth = k
			if (mouth >= 0 and k > mouth + 6) or absf(p.x) > extent - 12.0 or absf(p.y) > extent - 12.0:
				break
			# Each river keeps its own winding course seaward, eased toward the lowest
			# ground ahead and away from the rivers already laid; MAX_BEND keeps every
			# bend wide enough to sail round.
			var want := aim + meander.get_noise_2d(k * 0.4, i * 57.0) * 1.6
			var best := heading
			var best_cost := INF
			for turn: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
				var h := heading + turn * MAX_BEND
				var ahead := p + Vector2.from_angle(h) * 28.0
				var g := IslandGenerator._sample_surface(original, n, step, extent, seed_value, ahead.x, ahead.y).x
				var off := absf(angle_difference(h, want))
				var cost := maxf(g, 0.0) * 0.35 + off * off * 30.0
				if ahead.distance_to(sound_c) > sound_r + 50.0:
					for q in laid:
						if q.distance_squared_to(ahead) < 90.0 * 90.0:
							cost += 400.0
							break
				if cost < best_cost:
					best_cost = cost
					best = h
			heading = heading + clampf(angle_difference(heading, best), -MAX_BEND, MAX_BEND)
			p += Vector2.from_angle(heading) * RIVER_STEP
		if mouth < 0:
			mouth = points.size() - 1
		var channel := {"points": points, "widths": widths, "mouth": mouth, "name": names.next(true) + " River"}
		channels.append(channel)
		for k in range(0, points.size(), 3):
			laid.append(points[k])
		# Every other point is enough: the cuts overlap well past the bed.
		for k in range(0, points.size(), 2):
			var half := widths[k] * 0.5
			var ground := IslandGenerator._sample_surface(original, n, step, extent, seed_value, points[k].x, points[k].y).x
			_cut(heights, original, bed, n, step, extent, points[k], half,
				half + 18.0 + clampf((ground - 1.0) * 1.3, 0.0, 80.0))
		var middle := points[mouth / 2]
		landmarks.append({"id": "river%d" % i, "kind": "river", "name": channel["name"], "at": middle,
			"reach": widths[mouth / 2] * 0.5 + 25.0})

	# Streams: from the high ground down to the nearest river or the sound, the
	# bed never climbing, so steps in the land become falls. The first may start
	# in a mountain lake.
	var carved := heights.duplicate()
	var targets := PackedVector2Array([sound_c])
	var target_half := PackedFloat32Array([sound_r])
	for channel: Dictionary in channels:
		var points: PackedVector2Array = channel["points"]
		var widths: PackedFloat32Array = channel["widths"]
		for k in range(0, int(channel["mouth"]), 3):
			targets.append(points[k])
			target_half.append(widths[k] * 0.5)
	var streams: Array = []
	var falls: Array = []
	var lake := {}
	var stream_count := 4 + rng.randi_range(0, 2)
	for i in stream_count:
		var aim := rng.randf() * TAU
		var source := Vector2.ZERO
		var source_h := -INF
		for j in range(0, n + 1, 3):
			for ii in range(0, n + 1, 3):
				var q := Vector2(-extent + ii * step, -extent + j * step)
				var dq := q.length()
				if dq < r * 0.25 or dq > r * 0.85 or absf(angle_difference(q.angle(), aim)) > 0.35:
					continue
				var hq := carved[j * (n + 1) + ii]
				if hq > source_h:
					source_h = hq
					source = q
		if source_h < peak * 0.35:
			continue
		var level := source_h - 1.2
		var start := source
		var target := _nearest(targets, source)
		var heading := (targets[target] - source).angle()
		if lake.is_empty():
			var lake_r := 14.0
			var rim := INF
			for k in 16:
				var q := source + Vector2.from_angle(TAU * k / 16.0) * lake_r
				rim = minf(rim, IslandGenerator._sample_surface(carved, n, step, extent, seed_value, q.x, q.y).x)
			level = minf(level, rim - 0.5)
			lake = {"x": source.x, "z": source.y, "radius": lake_r, "level": level}
			start = source + Vector2.from_angle(heading) * lake_r * 0.8
		var points := PackedVector2Array()
		var beds := PackedFloat32Array()
		var widths := PackedFloat32Array()
		var p := start
		for k in 200:
			var ground := IslandGenerator._sample_surface(carved, n, step, extent, seed_value, p.x, p.y).x
			if k > 0:
				level = minf(level - 0.03, ground - 1.1)
			points.append(p)
			beds.append(level)
			widths.append(lerpf(2.4, 8.0, clampf(k / 50.0, 0.0, 1.0)))
			target = _nearest(targets, p)
			if level < 0.4 or p.distance_to(targets[target]) < target_half[target] + 2.0:
				break
			heading = lerp_angle(heading, (targets[target] - p).angle(), 0.14) + meander.get_noise_2d(k * 3.0, i * 97.0) * 0.3
			p += Vector2.from_angle(heading) * IslandGenerator.RIVER_STEP
		if points.size() < 10:
			continue
		streams.append({"points": points, "beds": beds, "widths": widths})
		# Its tallest fall, if there is a real one.
		var drop_at := -1
		var drop := 3.0
		for k in range(3, points.size()):
			if beds[k - 3] - beds[k] > drop:
				drop = beds[k - 3] - beds[k]
				drop_at = k
		if drop_at >= 0:
			var near := _nearest(targets, points[drop_at])
			var off := points[drop_at].distance_to(targets[near]) - target_half[near]
			if off < 130.0:
				falls.append([points[drop_at], drop, off])
	if not lake.is_empty():
		var c := Vector2(lake["x"], lake["z"])
		var lr: float = lake["radius"]
		var lv: float = lake["level"]
		IslandGenerator._carve_around(heights, carved, bed, n, step, extent, c, lr + 10.0, func(d: float, orig: float) -> float:
			if d < lr * 0.75:
				return lv - 1.3
			if d < lr:
				return lerpf(lv - 1.3, lv + 0.4, smoothstep(lr * 0.75, lr, d))
			return lerpf(lv + 0.4, orig, smoothstep(lr, lr + 10.0, d)), -1.0)
	for stream: Dictionary in streams:
		var points: PackedVector2Array = stream["points"]
		var beds: PackedFloat32Array = stream["beds"]
		var widths: PackedFloat32Array = stream["widths"]
		for k in points.size():
			var lv := beds[k]
			var half := maxf(widths[k] * 0.5 + 0.8, step * 0.8)
			var ground := IslandGenerator._sample_surface(carved, n, step, extent, seed_value, points[k].x, points[k].y).x
			var valley := half + 6.0 + clampf((ground - lv) * 0.7, 0.0, 12.0)
			IslandGenerator._carve_around(heights, carved, bed, n, step, extent, points[k], valley, func(d: float, orig: float) -> float:
				if d <= half:
					return lv - 0.7
				return lerpf(lv + 0.25, orig, smoothstep(half, valley, d)), half)
	# The two tallest falls within sight of the water are landmarks.
	falls.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
	for k in mini(falls.size(), 2):
		var f: Array = falls[k]
		landmarks.append({"id": "falls%d" % k, "kind": "falls", "name": names.next() + " Falls", "at": f[0],
			"reach": float(f[2]) + 45.0})

	return {"sound": sound, "channels": channels, "rivers": streams, "lake": lake, "landmarks": landmarks,
		"stones": names.next() + " Stones"}


## The sound's and the rivers' cross-section: a flat bed, a shelving edge, a
## strip of beach at the waterline, then banks rising back to the land over
## `reach` (wide where the land is high, so the gorges never stand sheer).
## Lowers vertices only, and marks those under water as navigable.
static func _cut(heights: PackedFloat32Array, original: PackedFloat32Array, bed: PackedByteArray, n: int,
		step: float, extent: float, centre: Vector2, half: float, reach: float) -> void:
	var i0 := maxi(floori((centre.x - reach + extent) / step), 0)
	var i1 := mini(ceili((centre.x + reach + extent) / step), n)
	var j0 := maxi(floori((centre.y - reach + extent) / step), 0)
	var j1 := mini(ceili((centre.y + reach + extent) / step), n)
	var inner := half * 0.7
	for j in range(j0, j1 + 1):
		var z := -extent + j * step - centre.y
		for i in range(i0, i1 + 1):
			var x := -extent + i * step - centre.x
			var d := sqrt(x * x + z * z)
			if d > reach:
				continue
			var idx := j * (n + 1) + i
			var h: float
			if d <= inner:
				h = CHANNEL_BED
			elif d <= half:
				h = lerpf(CHANNEL_BED, -1.0, smoothstep(inner, half, d))
			elif d <= half + 5.0:
				h = lerpf(-1.0, 0.7, (d - half) / 5.0)
			else:
				h = lerpf(0.7, original[idx], smoothstep(half + 5.0, reach, d))
			if h < heights[idx]:
				heights[idx] = h
			if d <= half:
				bed[idx] = 2


static func _nearest(points: PackedVector2Array, q: Vector2) -> int:
	var best := 0
	var best_d := INF
	for k in points.size():
		var d := points[k].distance_squared_to(q)
		if d < best_d:
			best_d = d
			best = k
	return best


## True within `margin` of any river's water or the sound.
static func near_water(q: Vector2, waters: Dictionary, margin: float) -> bool:
	var sound: Dictionary = waters["sound"]
	if q.distance_to(Vector2(sound["x"], sound["z"])) < float(sound["radius"]) + margin:
		return true
	for channel: Dictionary in waters["channels"]:
		var points: PackedVector2Array = channel["points"]
		var widths: PackedFloat32Array = channel["widths"]
		for k in range(0, points.size(), 2):
			if points[k].distance_squared_to(q) < pow(widths[k] * 0.5 + margin, 2.0):
				return true
	return IslandGenerator._near_river(q, waters["rivers"], margin * 0.5)


## Places the harbour town and its two quays on the sound, a lighthouse at each
## river mouth, lantern posts along the banks, a landing on each river and the
## old stones, into `props` and `lights`.
## Returns {town: Vector2, lighthouses: [Vector2], beams: [Vector3], ruins: Vector3 or null,
## docks: [{name, kind, xform, berths: [Vector3], yaw}] (local; yaw a moored bow's
## heading, either way round), clear: [Vector3(x, z, radius)]}; adds the stones to
## waters.landmarks.
static func settle(heights: PackedFloat32Array, n: int, step: float, extent: float, r: float,
		seed_value: int, waters: Dictionary, props: Dictionary, lights: Array) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 505
	# The docks draw from their own sequence, so adding them never moved anything
	# else on an island a player had already charted.
	var dock_rng := RandomNumberGenerator.new()
	dock_rng.seed = seed_value + 808
	var out := {"lighthouses": [], "beams": []}
	var clear: Array = []
	var docks: Array = []
	var sound: Dictionary = waters["sound"]
	var sound_c := Vector2(sound["x"], sound["z"])
	var sound_r: float = sound["radius"]
	var sample := func(q: Vector2) -> Vector4:
		return IslandGenerator._sample_surface(heights, n, step, extent, seed_value, q.x, q.y)

	# The harbour town, on level ground around the sound.
	var homes: Array[Vector3] = []
	for attempt in 1400:
		if homes.size() >= 12:
			break
		var q := sound_c + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(sound_r + 12.0, sound_r + 95.0)
		var s: Vector4 = sample.call(q)
		if s.x < 1.4 or s.x > 12.0 or s.z < 0.93 or near_water(q, waters, 6.0):
			continue
		var crowded := false
		for h in homes:
			if Vector2(h.x, h.z).distance_to(q) < 9.5:
				crowded = true
				break
		if crowded:
			continue
		var low := s.x
		var level := true
		for corner: Vector2 in [Vector2(2.3, 2.0), Vector2(-2.3, 2.0), Vector2(2.3, -2.0), Vector2(-2.3, -2.0)]:
			var hc: float = (sample.call(q + corner) as Vector4).x
			low = minf(low, hc)
			if absf(hc - s.x) > 1.0:
				level = false
		if level:
			homes.append(Vector3(q.x, low, q.y))
	if homes.size() >= 2:
		var middle := Vector2.ZERO
		for i in homes.size():
			var home := homes[i]
			var to_water := sound_c - Vector2(home.x, home.z)
			var basis := Basis(Vector3.UP, atan2(-to_water.x, -to_water.y) + rng.randf_range(-0.4, 0.4))
			var at := Vector3(home.x, home.y - 0.1, home.z)
			var tint := Color(rng.randf_range(0.94, 1.04), rng.randf_range(0.94, 1.02), rng.randf_range(0.9, 1.0))
			IslandGenerator._push(props, &"cottage", Transform3D(basis, at), tint)
			IslandGenerator._push(props, &"cottage_glow", Transform3D(basis, at), Color(1, 1, 1))
			clear.append(Vector3(home.x, home.z, 5.0))
			middle += Vector2(home.x, home.z)
			if i < 4:
				lights.append([at + basis * Vector3(0.0, 2.0, -3.0), ProceduralMeshBuilder.WINDOW_GLOW, 1.3, 13.0, 0.05])
		middle /= homes.size()
		out["town"] = middle
		for i in range(1, homes.size(), 2):
			var lane := (Vector2(homes[i].x, homes[i].z) + Vector2(homes[i - 1].x, homes[i - 1].z)) * 0.5
			var s: Vector4 = sample.call(lane)
			if s.x > 1.2 and s.z > 0.85 and not near_water(lane, waters, 2.0):
				var post := Vector3(lane.x, s.x - 0.1, lane.y)
				IslandGenerator._push(props, &"beacon", Transform3D(Basis(Vector3.UP, rng.randf() * TAU), post), Color(1, 1, 1))
				IslandGenerator._push(props, &"beacon_glow", Transform3D(Basis.IDENTITY, post), Color(1, 1, 1))
				clear.append(Vector3(lane.x, lane.y, 1.5))

		# Two quays out into the sound below the town, each with a berth down either side.
		var toward := (sound_c - middle).normalized()
		var across := Vector2(-toward.y, toward.x)
		var quay := String(sound["name"]).trim_suffix(" Sound") + " Quay"
		for side: float in [-1.0, 1.0]:
			var walk := middle + across * side * 18.0
			for k in 80:
				if (sample.call(walk) as Vector4).x < 0.6:
					break
				walk += toward * 1.5
			var root := walk - toward * 1.0
			var deep := true
			for t: float in [0.35, 0.55, 0.85, 1.0]:
				for sgn: float in [-1.0, 1.0]:
					var q := root + toward * ProceduralMeshBuilder.DOCK_LENGTH * t \
						+ across * sgn * (ProceduralMeshBuilder.DOCK_WIDTH * 0.5 + ProceduralMeshBuilder.BERTH_OFFSET)
					if (sample.call(q) as Vector4).x > -1.6:
						deep = false
			if not deep:
				continue
			var basis := Basis(Vector3.UP, atan2(-toward.x, -toward.y))
			var origin := Vector3(root.x, ProceduralMeshBuilder.DOCK_DECK, root.y)
			IslandGenerator._push(props, &"dock", Transform3D(basis, origin), Color(1, 1, 1))
			var berths: Array = []
			for sgn: float in [-1.0, 1.0]:
				var b := root + toward * ProceduralMeshBuilder.DOCK_LENGTH * 0.55 \
					+ across * sgn * (ProceduralMeshBuilder.DOCK_WIDTH * 0.5 + ProceduralMeshBuilder.BERTH_OFFSET)
				berths.append(Vector3(b.x, 0.0, b.y))
			docks.append({"name": quay, "kind": &"dock", "xform": Transform3D(basis, origin), "berths": berths,
				"yaw": basis.get_euler().y})
			# A lamp at the end, and a little cargo waiting by the root.
			var end := origin + basis * Vector3(ProceduralMeshBuilder.DOCK_WIDTH * 0.5 - 0.5, 0.0,
				-ProceduralMeshBuilder.DOCK_LENGTH + 0.6)
			IslandGenerator._push(props, &"beacon", Transform3D(basis, end), Color(1, 1, 1))
			IslandGenerator._push(props, &"beacon_glow", Transform3D(basis, end), Color(1, 1, 1))
			lights.append([end + Vector3.UP * 2.1, IslandGenerator.LAMP_COLOUR, 1.4, 12.0, 0.1])
			for c in 3:
				var at := origin + basis * Vector3(-0.9 + c * 0.75, 0.0, -2.2 - (c % 2) * 0.7)
				IslandGenerator._push(props, &"crate" if c != 1 else &"barrel",
					Transform3D(basis.rotated(Vector3.UP, dock_rng.randf_range(-0.3, 0.3)), at), Color(1, 1, 1))
			clear.append(Vector3(root.x, root.y, 6.0))

	for channel: Dictionary in waters["channels"]:
		var points: PackedVector2Array = channel["points"]
		var widths: PackedFloat32Array = channel["widths"]
		var mouth: int = channel["mouth"]

		# A lighthouse on the headland beside the river mouth, to find the way in.
		var at_mouth := points[mouth]
		var outward := at_mouth.normalized()
		var across := Vector2(-outward.y, outward.x)
		var spot := Vector2.INF
		for attempt in 40:
			var side := 1.0 if attempt % 2 == 0 else -1.0
			var q := at_mouth - outward * rng.randf_range(10.0, 60.0) \
				+ across * side * (widths[mouth] * 0.5 + rng.randf_range(10.0, 45.0))
			var s: Vector4 = sample.call(q)
			if s.x >= 2.5 and s.x < 14.0 and s.z > 0.82 and not near_water(q, waters, 5.0):
				spot = q
				break
		if spot != Vector2.INF:
			var ground := INF
			for corner: Vector2 in [Vector2(2.3, 2.3), Vector2(-2.3, 2.3), Vector2(2.3, -2.3), Vector2(-2.3, -2.3), Vector2.ZERO]:
				ground = minf(ground, (sample.call(spot + corner) as Vector4).x)
			var at := Vector3(spot.x, ground - 0.2, spot.y)
			var basis := Basis(Vector3.UP, atan2(-outward.x, -outward.y))
			IslandGenerator._push(props, &"lighthouse", Transform3D(basis, at), Color(1, 1, 1))
			IslandGenerator._push(props, &"lighthouse_glow", Transform3D(basis, at), Color(1, 1, 1))
			var lamp := at + Vector3.UP * ProceduralMeshBuilder.LIGHTHOUSE_LAMP
			lights.append([lamp, IslandGenerator.LAMP_COLOUR, 2.4, 30.0, 0.0])
			(out["lighthouses"] as Array).append(spot)
			(out["beams"] as Array).append(lamp)
			clear.append(Vector3(spot.x, spot.y, 6.0))

		# Lantern posts on alternate banks, so the way upriver is lit after dark.
		var side := 1.0
		for k in range(8, mouth - 2, LANTERN_EVERY):
			side = -side
			var prev := points[maxi(k - 1, 0)]
			var tangent := (points[k + 1] - prev).normalized()
			var normal := Vector2(-tangent.y, tangent.x) * side
			for push: float in [6.5, 9.0, 12.0]:
				var q := points[k] + normal * (widths[k] * 0.5 + push)
				var s: Vector4 = sample.call(q)
				if s.x < 0.8 or s.x > 4.0 or s.z < 0.85:
					continue
				var post := Vector3(q.x, s.x - 0.1, q.y)
				IslandGenerator._push(props, &"beacon", Transform3D(Basis(Vector3.UP, rng.randf() * TAU), post), Color(1, 1, 1))
				IslandGenerator._push(props, &"beacon_glow", Transform3D(Basis.IDENTITY, post), Color(1, 1, 1))
				lights.append([post + Vector3.UP * 2.1, IslandGenerator.LAMP_COLOUR, 1.3, 13.0, 0.1])
				clear.append(Vector3(q.x, q.y, 1.5))
				break

	# A landing partway up each river, on a low bank, to tie up and look around.
	for channel: Dictionary in waters["channels"]:
		var points: PackedVector2Array = channel["points"]
		var widths: PackedFloat32Array = channel["widths"]
		var mouth: int = channel["mouth"]
		var name := String(channel["name"]).trim_suffix(" River") + " Landing"
		for attempt in 40:
			var k := int(mouth * dock_rng.randf_range(0.3, 0.7))
			k = clampi(k, 1, points.size() - 2)
			var tangent := (points[k + 1] - points[k - 1]).normalized()
			var normal := Vector2(-tangent.y, tangent.x) * (1.0 if dock_rng.randf() < 0.5 else -1.0)
			var half := widths[k] * 0.5
			var root := points[k] + normal * (half + 4.0)
			var toward := -normal
			var reach := ProceduralMeshBuilder.LANDING_WALK + ProceduralMeshBuilder.LANDING_DEPTH
			var berth := root + toward * (reach + ProceduralMeshBuilder.BERTH_OFFSET)
			var g_root: float = (sample.call(root) as Vector4).x
			var g_bank: float = (sample.call(points[k] + normal * (half + 10.0)) as Vector4).x
			if g_root < -0.3 or g_root > 1.6 or g_bank > 5.0 or (sample.call(berth) as Vector4).x > -1.8:
				continue
			var crowded := false
			for c: Vector3 in clear:
				if Vector2(c.x, c.y).distance_to(root) < c.z + 6.0:
					crowded = true
			if crowded or IslandGenerator._near_river(root, waters["rivers"], 6.0):
				continue
			var basis := Basis(Vector3.UP, atan2(-toward.x, -toward.y))
			var origin := Vector3(root.x, ProceduralMeshBuilder.DOCK_DECK, root.y)
			IslandGenerator._push(props, &"landing", Transform3D(basis, origin), Color(1, 1, 1))
			docks.append({"name": name, "kind": &"landing", "xform": Transform3D(basis, origin),
				"berths": [Vector3(berth.x, 0.0, berth.y)], "yaw": atan2(-tangent.x, -tangent.y)})
			var lamp := origin + basis * Vector3(ProceduralMeshBuilder.LANDING_SPAN * 0.5 - 0.6, 0.0, -reach + 0.5)
			IslandGenerator._push(props, &"beacon", Transform3D(basis, lamp), Color(1, 1, 1))
			IslandGenerator._push(props, &"beacon_glow", Transform3D(basis, lamp), Color(1, 1, 1))
			lights.append([lamp + Vector3.UP * 2.1, IslandGenerator.LAMP_COLOUR, 1.3, 12.0, 0.1])
			clear.append(Vector3(root.x, root.y, 6.0))
			break

	# The old stones: a level rise within sight of a river.
	var channels: Array = waters["channels"]
	out["ruins"] = null
	for attempt in 300:
		var channel: Dictionary = channels[rng.randi_range(0, channels.size() - 1)]
		var points: PackedVector2Array = channel["points"]
		var k := rng.randi_range(10, maxi(int(channel["mouth"]) - 10, 11))
		k = mini(k, points.size() - 2)
		var tangent := (points[k + 1] - points[k - 1]).normalized()
		var normal := Vector2(-tangent.y, tangent.x) * (1.0 if rng.randf() < 0.5 else -1.0)
		var off := rng.randf_range(40.0, 120.0)
		var q := points[k] + normal * off
		var s: Vector4 = sample.call(q)
		if s.x < 6.0 or s.x > 30.0 or s.z < 0.93 or near_water(q, waters, 12.0):
			continue
		out["ruins"] = Vector3(q.x, s.x, q.y)
		clear.append(Vector3(q.x, q.y, 7.0))
		(waters["landmarks"] as Array).append({"id": "stones", "kind": "stones", "name": waters["stones"],
			"at": q, "reach": off + 40.0})
		break
	out["clear"] = clear
	out["docks"] = docks
	return out


## Island-flavoured names that don't repeat within one island.
class _Namer:
	var _rng := RandomNumberGenerator.new()
	var _used := {}

	func _init(seed_value: int) -> void:
		_rng.seed = seed_value

	## A first-part name ("Heron"), or with `compound` a full one ("Heronbrook").
	func next(compound := false) -> String:
		for attempt in 40:
			var word := IslandGenerator.NAME_FIRST[_rng.randi_range(0, IslandGenerator.NAME_FIRST.size() - 1)]
			if _used.has(word):
				continue
			_used[word] = true
			if compound:
				return word + IslandGenerator.NAME_SECOND[_rng.randi_range(0, IslandGenerator.NAME_SECOND.size() - 1)]
			return word
		return "Nameless"
