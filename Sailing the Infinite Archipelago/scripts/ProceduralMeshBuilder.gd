class_name ProceduralMeshBuilder
extends RefCounted
## Builds the game's 3D models from code: flat-shaded, vertex-coloured low-poly
## geometry made with SurfaceTool. One toon material colours a whole model
## through its vertex colours, so a full sailboat is only a handful of draw calls.
##
## Conventions: metres, +Y up, bow / forward toward -Z, waterline at y = 0.
## Godot treats clockwise triangles as front faces. Every helper here takes an
## outward "hint" vector and fixes the winding itself, so callers never have to.

# -- Palette: sun-warmed paint, honey timber and cream canvas -----------------
const WALNUT := Color("5c3725")
const TIMBER := Color("8a5539")
const GOLD_TRIM := Color("e8b04e")
const TERRACOTTA := Color("b9533b")
const DECK_A := Color("cf9a62")
const DECK_B := Color("bb8452")
const CREAM := Color("f4e4c4")
const MAST_WOOD := Color("8f5c3d")
const IRON := Color("3b2c27")
const CANVAS := Color("f7ecd6")
const CANVAS_SHADE := Color("ead6b4")
const CANVAS_BAND := Color("d9825a")
const PENNANT := Color("e2604a")
const LANTERN_GLOW := Color("ffc477")
# Nature: honeyed greens, warm stone and sun-bleached sandstone.
const LEAF_TOP := Color("adc967")
const LEAF_SIDE := Color("7ea452")
const PINE_DARK := Color("4e7c4b")
const PINE_MID := Color("5b8a52")
const PINE_LIGHT := Color("6c9b59")
const PALM_LEAF := Color("85b153")
const PALM_LEAF_DARK := Color("6c9946")
const BARK := Color("7a5236")
const PALM_BARK_A := Color("a5794f")
const PALM_BARK_B := Color("8b6340")
const STONE_TOP := Color("bba68f")
const STONE_SIDE := Color("917b68")
const GRASS_BASE := Color("7ea44d")
const GRASS_TIP := Color("c9d073")
const SANDSTONE := Color("dcc6a2")
const SANDSTONE_DARK := Color("c3a983")
const MOSS := Color("8aa857")
const SMOKE_TOP := Color("f4ecdd")
const SMOKE_SIDE := Color("c9bcaa")
# Settlements: lime-washed walls, clay roofs, a striped lighthouse.
const PLASTER := Color("efe0c4")
const PLASTER_SHADE := Color("dcc7a6")
const ROOF := Color("b4553f")
const ROOF_DARK := Color("8f3f31")
const BEACON_WHITE := Color("f2ead8")
const BEACON_STRIPE := Color("d25b45")
const WINDOW_GLOW := Color("ffbf6e")
const MAST_LIGHT := Color("fff0d0")

const NIGHT_GLOW_SHADER := preload("res://Sailing the Infinite Archipelago/assets/shaders/NightGlow.gdshader")
## Height of the lighthouse lamp above its foot.
const LIGHTHOUSE_LAMP := 13.7
## Length of the jetty, from the shore out over the water (-Z).
const JETTY_LENGTH := 16.0
## A massive island's docks, where the boat can moor. Both run out along -Z from
## their origin on the shore, decks at DOCK_DECK above the sea:
##   dock: a harbour pier DOCK_LENGTH x DOCK_WIDTH, with a berth down either side;
##   landing: a gangway LANDING_WALK long to a stage LANDING_SPAN x LANDING_DEPTH
##     lying along a river bank, with a berth along its outer edge.
const DOCK_DECK := 1.05
const DOCK_LENGTH := 24.0
const DOCK_WIDTH := 3.6
const LANDING_WALK := 5.0
const LANDING_SPAN := 12.0
const LANDING_DEPTH := 3.4
## Gap between a dock's edge and a moored hull's middle (half the beam plus a fender's width).
const BERTH_OFFSET := 1.75

## Kinds accepted by prop_mesh().
const PROP_KINDS: Array[StringName] = [&"broadleaf", &"pine", &"palm", &"rock_a", &"rock_b",
	&"grass", &"column", &"ruin_arch", &"crate", &"barrel", &"cottage", &"cottage_glow",
	&"beacon", &"beacon_glow", &"jetty", &"lighthouse", &"lighthouse_glow", &"dock", &"landing"]
## Kinds drawn with a NightGlow material (they light up after dark) and how:
## [daytime level, night level, flicker].
const GLOW_KINDS := {
	&"cottage_glow": [0.4, 3.0, 0.06],
	&"beacon_glow": [0.85, 3.6, 0.12],
	&"lighthouse_glow": [0.9, 4.2, 0.0],
}

## Paint bands on the hull, from keel to gunwale (one per ring segment).
const HULL_BANDS := [TERRACOTTA, TERRACOTTA, TIMBER, GOLD_TRIM, WALNUT]

# -- Sailboat layout -----------------------------------------------------------
## Hull cross-sections from stern (+Z) to bow (-Z):
## [z, half beam, gunwale height, bilge height, keel height]
const HULL_STATIONS := [
	[3.35, 0.98, 0.86, -0.12, -0.30],
	[2.30, 1.16, 0.78, -0.36, -0.56],
	[0.90, 1.24, 0.74, -0.44, -0.64],
	[-0.70, 1.18, 0.76, -0.42, -0.62],
	[-2.10, 0.92, 0.86, -0.28, -0.50],
	[-3.20, 0.46, 1.00, -0.04, -0.28],
	[-3.85, 0.0, 1.12, 0.40, 0.22],
]
const DECK_DROP := 0.13        ## deck sits this far below the gunwale
const BULWARK_INSET := 0.9     ## inner face of the bulwark, as a fraction of half beam
const DECK_PLANKS := 7
const MAST_Z := -0.55
const MAST_TOP := 7.4
const BOOM_Y := 1.75           ## height of the boom (and the mainsail pivot)
const BOOM_LENGTH := 3.7
const BOWSPRIT_ROOT := Vector3(0.0, 1.0, -3.55)
const BOWSPRIT_TIP := Vector3(0.0, 1.34, -4.75)
const JIB_HEAD := Vector3(0.0, 6.35, -0.69)
const JIB_CLEW := Vector3(0.0, 0.42, 2.5)   ## relative to BOWSPRIT_TIP
const RUDDER_POST := Vector3(0.0, 0.0, 3.36)
const LANTERN_POS := Vector3(0.78, 1.42, 3.0)
## Little engine stack on the port quarter; its top stays under the boom's sweep.
const STACK_POS := Vector3(-0.72, 0.0, 2.85)
const STACK_TOP := 1.55
const EXHAUST_POS := Vector3(-0.72, 1.6, 2.85)
const PROPELLER_POS := Vector3(0.0, -0.6, 3.02)

static var _materials := {}
static var _prop_meshes := {}


# =============================================================================
# Sailboat
# =============================================================================

## Builds the complete sailboat. Animated parts are separate nodes so the ship
## controller can move them:
##   Hull, Rudder (Y pivot at the stern post), SailPivot (Y pivot on the mast at
##   boom height: Boom + Sail), JibPivot (at the bowsprit tip; rotate it around
##   forestay_axis()), FlagPivot (masthead), Propeller (spin on Z), Exhaust
##   (marker at the stack mouth), Lantern + LanternLight.
static func build_sailboat() -> Node3D:
	var root := Node3D.new()
	root.name = "ShipModel"
	var wood := toon_material()
	var canvas := toon_material(true)

	root.add_child(_mesh_node("Hull", build_hull_mesh(), wood))

	var rudder := Node3D.new()
	rudder.name = "Rudder"
	rudder.position = RUDDER_POST
	rudder.add_child(_mesh_node("RudderMesh", build_rudder_mesh(), wood))
	root.add_child(rudder)

	var sail_pivot := Node3D.new()
	sail_pivot.name = "SailPivot"
	sail_pivot.position = Vector3(0.0, BOOM_Y, MAST_Z)
	sail_pivot.add_child(_mesh_node("Boom", build_boom_mesh(), wood))
	var main_head := Vector3(0.0, MAST_TOP - BOOM_Y - 0.55, 0.16)
	var main_clew := Vector3(0.0, 0.08, BOOM_LENGTH - 0.15)
	var mainsail := build_sail_mesh(Vector3(0.0, 0.06, 0.16), main_head, main_clew, 8, 5, PackedInt32Array([4]))
	sail_pivot.add_child(_mesh_node("Sail", mainsail, canvas))
	root.add_child(sail_pivot)

	var jib_pivot := Node3D.new()
	jib_pivot.name = "JibPivot"
	jib_pivot.position = BOWSPRIT_TIP
	var jib := build_sail_mesh(Vector3.ZERO, JIB_HEAD - BOWSPRIT_TIP, JIB_CLEW, 7, 4, PackedInt32Array([3]))
	jib_pivot.add_child(_mesh_node("Jib", jib, canvas))
	root.add_child(jib_pivot)

	var flag_pivot := Node3D.new()
	flag_pivot.name = "FlagPivot"
	flag_pivot.position = Vector3(0.0, MAST_TOP + 0.3, MAST_Z)
	flag_pivot.add_child(_mesh_node("Flag", build_pennant_mesh(), canvas))
	root.add_child(flag_pivot)

	var propeller := Node3D.new()
	propeller.name = "Propeller"
	propeller.position = PROPELLER_POS
	propeller.add_child(_mesh_node("PropellerMesh", build_propeller_mesh(), wood))
	root.add_child(propeller)

	var exhaust := Marker3D.new()
	exhaust.name = "Exhaust"
	exhaust.position = EXHAUST_POS
	root.add_child(exhaust)

	var lantern := _mesh_node("Lantern", build_lantern_glass_mesh(), night_glow_material(1.0, 3.4, 0.1))
	lantern.position = LANTERN_POS
	lantern.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(lantern)

	var light := OmniLight3D.new()
	light.name = "LanternLight"
	light.position = LANTERN_POS + Vector3(0.0, 0.05, 0.0)
	light.light_color = LANTERN_GLOW
	light.light_energy = 0.9
	light.omni_range = 5.5
	light.omni_attenuation = 1.4
	light.shadow_enabled = false
	root.add_child(light)

	# Cabin windows and a masthead light: paint by day, lit at night.
	var lights := _mesh_node("NightLights", build_ship_lights_mesh(), night_glow_material(0.55, 3.0, 0.0))
	lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(lights)

	return root


## Axis of the forestay (bowsprit tip to the jib head), in JibPivot space.
## Rotating JibPivot around this axis swings the jib while its luff stays on the stay.
static func forestay_axis() -> Vector3:
	return (JIB_HEAD - BOWSPRIT_TIP).normalized()


## Everything rigid on the boat merged into one mesh: hull shell, deck, bulwarks,
## transom, cabin, mast, crow's nest, bowsprit, standing rigging and deck cargo.
static func build_hull_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rings: Array[PackedVector3Array] = []
	for station: Array in HULL_STATIONS:
		rings.append(_hull_ring(station))

	# Outer shell, painted in horizontal bands, mirrored to port.
	for i in rings.size() - 1:
		var a := rings[i]
		var b := rings[i + 1]
		for j in a.size() - 1:
			var colour: Color = HULL_BANDS[j]
			for side: float in [1.0, -1.0]:
				var m := Vector3(side, 1.0, 1.0)
				_quad(st, a[j] * m, a[j + 1] * m, b[j + 1] * m, b[j] * m, colour, Vector3(side, 0.0, 0.0))

	# Deck planks, inner bulwarks and the cream rail cap.
	for i in HULL_STATIONS.size() - 1:
		var sa: Array = HULL_STATIONS[i]
		var sb: Array = HULL_STATIONS[i + 1]
		var za: float = sa[0]
		var zb: float = sb[0]
		var top_a: float = sa[2]
		var top_b: float = sb[2]
		var deck_a := top_a - DECK_DROP
		var deck_b := top_b - DECK_DROP
		var hw_a: float = sa[1]
		var hw_b: float = sb[1]
		var in_a := hw_a * BULWARK_INSET
		var in_b := hw_b * BULWARK_INSET
		for k in DECK_PLANKS:
			var x0 := lerpf(-1.0, 1.0, float(k) / DECK_PLANKS)
			var x1 := lerpf(-1.0, 1.0, float(k + 1) / DECK_PLANKS)
			var plank := DECK_A if k % 2 == 0 else DECK_B
			_quad(st,
				Vector3(x0 * in_a, deck_a, za), Vector3(x1 * in_a, deck_a, za),
				Vector3(x1 * in_b, deck_b, zb), Vector3(x0 * in_b, deck_b, zb),
				plank, Vector3.UP)
		for side: float in [1.0, -1.0]:
			_quad(st,
				Vector3(side * in_a, deck_a, za), Vector3(side * in_b, deck_b, zb),
				Vector3(side * in_b, top_b, zb), Vector3(side * in_a, top_a, za),
				TIMBER, Vector3(-side, 0.0, 0.0))
			_quad(st,
				Vector3(side * in_a, top_a, za), Vector3(side * hw_a, top_a, za),
				Vector3(side * hw_b, top_b, zb), Vector3(side * in_b, top_b, zb),
				CREAM, Vector3.UP)

	# Transom: fan the stern ring closed from its centre.
	var stern := rings[0]
	var s0: Array = HULL_STATIONS[0]
	var stern_z: float = s0[0]
	var stern_top: float = s0[2]
	var stern_hw: float = s0[1]
	var stern_centre := Vector3(0.0, (stern_top + float(s0[4])) * 0.5, stern_z)
	for j in stern.size() - 1:
		for side: float in [1.0, -1.0]:
			var m := Vector3(side, 1.0, 1.0)
			_tri(st, stern_centre, stern[j] * m, stern[j + 1] * m, WALNUT, Vector3.BACK)
	_tri(st, stern_centre, Vector3(stern_hw, stern_top, stern_z), Vector3(-stern_hw, stern_top, stern_z), WALNUT, Vector3.BACK)
	_box(st, Vector3(0.0, stern_top - 0.22, stern_z + 0.01), Vector3(0.9, 0.12, 0.02), GOLD_TRIM)

	# Cabin with warm lit windows and a cream roof.
	var cabin_z := 1.3
	var cabin_deck := deck_height_at(cabin_z)
	_box(st, Vector3(0.0, cabin_deck + 0.25, cabin_z), Vector3(1.3, 0.5, 1.4), TIMBER)
	_box(st, Vector3(0.0, cabin_deck + 0.545, cabin_z), Vector3(1.48, 0.09, 1.58), CREAM)
	_box(st, Vector3(0.0, cabin_deck + 0.2, cabin_z - 0.715), Vector3(0.38, 0.36, 0.03), WALNUT)
	for side: float in [1.0, -1.0]:
		for wz: float in [cabin_z - 0.32, cabin_z + 0.32]:
			_box(st, Vector3(side * 0.66, cabin_deck + 0.3, wz), Vector3(0.03, 0.17, 0.26), LANTERN_GLOW)

	# Mast, crow's nest and masthead finial.
	var mast_base := deck_height_at(MAST_Z)
	_prism(st, Vector3(0.0, mast_base, MAST_Z), Vector3(0.0, MAST_TOP, MAST_Z), 0.15, 0.08, 8, MAST_WOOD)
	_prism(st, Vector3(0.0, 6.92, MAST_Z), Vector3(0.0, 7.16, MAST_Z), 0.34, 0.37, 8, TIMBER)
	_prism(st, Vector3(0.0, 7.12, MAST_Z), Vector3(0.0, 7.19, MAST_Z), 0.385, 0.385, 8, GOLD_TRIM)
	_prism(st, Vector3(0.0, MAST_TOP, MAST_Z), Vector3(0.0, MAST_TOP + 0.62, MAST_Z), 0.025, 0.02, 4, IRON)
	_prism(st, Vector3(0.0, MAST_TOP + 0.6, MAST_Z), Vector3(0.0, MAST_TOP + 0.74, MAST_Z), 0.06, 0.0, 6, GOLD_TRIM)

	# Bowsprit and standing rigging: thin dark lines give a crisp silhouette.
	_prism(st, BOWSPRIT_ROOT, BOWSPRIT_TIP, 0.085, 0.055, 6, MAST_WOOD)
	_prism(st, BOWSPRIT_TIP, JIB_HEAD, 0.02, 0.02, 4, IRON, false)
	_prism(st, Vector3(0.0, MAST_TOP - 0.15, MAST_Z), Vector3(0.0, 0.95, 3.25), 0.02, 0.02, 4, IRON, false)
	var shroud_z := MAST_Z + 0.4
	var shroud_hw := half_beam_at(shroud_z)
	var shroud_y := gunwale_height_at(shroud_z)
	for side: float in [1.0, -1.0]:
		_prism(st, Vector3(side * 0.09, 6.9, MAST_Z), Vector3(side * (shroud_hw - 0.04), shroud_y, shroud_z), 0.018, 0.018, 4, IRON, false)

	# Engine: stack on the port quarter and the shaft running out under the stern.
	var stack_base := Vector3(STACK_POS.x, deck_height_at(STACK_POS.z), STACK_POS.z)
	_prism(st, stack_base, stack_base + Vector3.UP * 0.1, 0.18, 0.17, 8, IRON)
	_prism(st, stack_base, Vector3(STACK_POS.x, STACK_TOP - 0.13, STACK_POS.z), 0.11, 0.105, 8, TERRACOTTA)
	_prism(st, Vector3(STACK_POS.x, 1.08, STACK_POS.z), Vector3(STACK_POS.x, 1.15, STACK_POS.z), 0.12, 0.12, 8, GOLD_TRIM)
	_prism(st, Vector3(STACK_POS.x, STACK_TOP - 0.15, STACK_POS.z), Vector3(STACK_POS.x, STACK_TOP, STACK_POS.z), 0.12, 0.16, 8, IRON)
	_prism(st, Vector3(0.0, -0.4, 2.45), PROPELLER_POS + Vector3(0.0, 0.0, -0.08), 0.035, 0.035, 6, IRON)

	# Deck cargo and the lantern post.
	for spot: Vector3 in [Vector3(0.5, 0.0, -1.85), Vector3(-0.46, 0.0, -2.12)]:
		_barrel(st, Vector3(spot.x, deck_height_at(spot.z), spot.z), 0.22, 0.5)
	var crate_z := 0.1
	var crate_deck := deck_height_at(crate_z)
	_box(st, Vector3(0.6, crate_deck + 0.225, crate_z), Vector3(0.45, 0.45, 0.45), DECK_B, Basis(Vector3.UP, 0.25))
	_box(st, Vector3(0.6, crate_deck + 0.455, crate_z), Vector3(0.47, 0.03, 0.12), WALNUT, Basis(Vector3.UP, 0.25))
	var post_base := Vector3(LANTERN_POS.x, gunwale_height_at(LANTERN_POS.z), LANTERN_POS.z)
	_prism(st, post_base, LANTERN_POS + Vector3(0.0, -0.1, 0.0), 0.035, 0.03, 6, IRON)
	_box(st, LANTERN_POS + Vector3(0.0, 0.135, 0.0), Vector3(0.2, 0.05, 0.2), IRON)
	_box(st, LANTERN_POS + Vector3(0.0, -0.11, 0.0), Vector3(0.2, 0.03, 0.2), IRON)

	return st.commit()


static func build_rudder_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(0.0, -0.28, 0.24), Vector3(0.08, 0.86, 0.42), TIMBER)
	_box(st, Vector3(0.0, -0.69, 0.24), Vector3(0.09, 0.05, 0.43), TERRACOTTA)
	_prism(st, Vector3(0.0, -0.1, 0.04), Vector3(0.0, 1.03, 0.04), 0.045, 0.045, 6, WALNUT)
	_prism(st, Vector3(0.0, 1.0, 0.04), Vector3(0.0, 1.12, -1.0), 0.04, 0.028, 6, MAST_WOOD)
	return st.commit()


static func build_boom_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_prism(st, Vector3(0.0, 0.0, 0.1), Vector3(0.0, 0.0, BOOM_LENGTH), 0.075, 0.055, 6, MAST_WOOD)
	_box(st, Vector3(0.0, 0.0, 0.14), Vector3(0.2, 0.12, 0.12), IRON)
	return st.commit()


## A three-cornered sail. The luff runs tack -> head, the leech clew -> head, and
## the cloth bellies toward +X with a camber that scales with the local chord.
## Rows alternate two canvas tones like sewn panels; band_rows get the accent stripe.
static func build_sail_mesh(tack: Vector3, head: Vector3, clew: Vector3, rows: int, cols: int,
		band_rows := PackedInt32Array(), camber := 0.13) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var grid: Array[PackedVector3Array] = []
	for r in rows + 1:
		var v := float(r) / rows
		var luff := tack.lerp(head, v)
		var leech := clew.lerp(head, v)
		var chord := luff.distance_to(leech)
		var row := PackedVector3Array()
		for c in cols + 1:
			var u := float(c) / cols
			var p := luff.lerp(leech, u)
			p.x += camber * chord * sin(PI * pow(u, 0.8))
			row.append(p)
		grid.append(row)
	for r in rows:
		var colour := CANVAS_BAND if band_rows.has(r) else (CANVAS if r % 2 == 0 else CANVAS_SHADE)
		for c in cols:
			_quad(st, grid[r][c], grid[r][c + 1], grid[r + 1][c + 1], grid[r + 1][c], colour, Vector3.RIGHT)
	return st.commit()


## Swallow-free pennant streaming toward +Z from its pivot.
static func build_pennant_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(0.0, 0.0, 0.0)
	var b := Vector3(0.0, -0.44, 0.0)
	var c := Vector3(0.0, -0.31, 0.66)
	var d := Vector3(0.0, -0.13, 0.66)
	var tip := Vector3(0.0, -0.22, 1.32)
	_quad(st, a, b, c, d, PENNANT, Vector3.RIGHT)
	_tri(st, d, c, tip, GOLD_TRIM, Vector3.RIGHT)
	return st.commit()


## Three-bladed bronze propeller turning about Z (the shaft axis).
static func build_propeller_mesh() -> ArrayMesh:
	var st := _begin()
	_prism(st, Vector3(0.0, 0.0, -0.08), Vector3(0.0, 0.0, 0.12), 0.065, 0.02, 6, GOLD_TRIM)
	for b in 3:
		var ang := TAU * b / 3.0
		var basis := Basis(Vector3.BACK, ang) * Basis(Vector3.RIGHT, 0.55)
		_box(st, Vector3(cos(ang), sin(ang), 0.0) * 0.13, Vector3(0.2, 0.025, 0.12), GOLD_TRIM, basis)
	return st.commit()


## One soft toon smoke puff, centred on its origin so it can grow in place.
static func build_smoke_puff_mesh() -> ArrayMesh:
	var st := _begin()
	_blob(st, Vector3.ZERO, Vector3(0.5, 0.44, 0.5), SMOKE_TOP, SMOKE_SIDE, 41, 3, 6, 0.2)
	return st.commit()


static func build_lantern_glass_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3.ZERO, Vector3(0.15, 0.2, 0.15), LANTERN_GLOW)
	return st.commit()


## The boat's lights other than the lantern: glowing cabin windows (just proud of
## the painted ones) and a masthead light under the crow's nest.
static func build_ship_lights_mesh() -> ArrayMesh:
	var st := _begin()
	var cabin_z := 1.3
	var cabin_deck := deck_height_at(cabin_z)
	for side: float in [1.0, -1.0]:
		for wz: float in [cabin_z - 0.32, cabin_z + 0.32]:
			_box(st, Vector3(side * 0.668, cabin_deck + 0.3, wz), Vector3(0.012, 0.15, 0.22), WINDOW_GLOW)
	_box(st, Vector3(0.0, 6.62, MAST_Z - 0.17), Vector3(0.12, 0.14, 0.12), MAST_LIGHT)
	return st.commit()


# -- Hull lookups (used for placing parts on deck) ------------------------------

static func half_beam_at(z: float) -> float:
	return float(_station_lerp(z)[1])


static func gunwale_height_at(z: float) -> float:
	return float(_station_lerp(z)[2])


static func deck_height_at(z: float) -> float:
	return gunwale_height_at(z) - DECK_DROP


## Linear blend of the two hull stations around z (stations run +Z to -Z).
static func _station_lerp(z: float) -> Array:
	for i in HULL_STATIONS.size() - 1:
		var a: Array = HULL_STATIONS[i]
		var b: Array = HULL_STATIONS[i + 1]
		if z <= float(a[0]) and z >= float(b[0]):
			var t := inverse_lerp(float(a[0]), float(b[0]), z)
			var out: Array = []
			for k in a.size():
				out.append(lerpf(float(a[k]), float(b[k]), t))
			return out
	return HULL_STATIONS[0] if z > float(HULL_STATIONS[0][0]) else HULL_STATIONS[-1]


## Starboard half of one hull cross-section, keel to gunwale.
static func _hull_ring(station: Array) -> PackedVector3Array:
	var z: float = station[0]
	var hw: float = station[1]
	var top: float = station[2]
	var bilge: float = station[3]
	var keel: float = station[4]
	var waterline := clampf(0.02, bilge + 0.04, top - 0.4)
	return PackedVector3Array([
		Vector3(0.0, keel, z),
		Vector3(hw * 0.58, bilge, z),
		Vector3(hw * 0.88, waterline, z),
		Vector3(hw * 0.97, top - 0.3, z),
		Vector3(hw * 0.99, top - 0.17, z),
		Vector3(hw, top, z),
	])


# =============================================================================
# Island props (all stand on y = 0, sized in metres, shared by every island)
# =============================================================================

## Cached prop mesh by kind (see PROP_KINDS). Call from the main thread; islands
## warm the cache before handing work to their generation threads.
static func prop_mesh(kind: StringName) -> ArrayMesh:
	if _prop_meshes.has(kind):
		return _prop_meshes[kind]
	var mesh: ArrayMesh
	match kind:
		&"broadleaf":
			mesh = build_broadleaf_tree_mesh()
		&"pine":
			mesh = build_pine_tree_mesh()
		&"palm":
			mesh = build_palm_tree_mesh()
		&"rock_a":
			mesh = build_rock_mesh(11, Vector3(1.0, 0.62, 0.88))
		&"rock_b":
			mesh = build_rock_mesh(29, Vector3(0.78, 1.0, 0.72))
		&"grass":
			mesh = build_grass_tuft_mesh()
		&"column":
			mesh = build_column_mesh()
		&"ruin_arch":
			mesh = build_ruin_arch_mesh()
		&"crate":
			mesh = build_crate_mesh()
		&"barrel":
			mesh = build_barrel_mesh()
		&"cottage":
			mesh = build_cottage_mesh()
		&"cottage_glow":
			mesh = build_cottage_windows_mesh()
		&"beacon":
			mesh = build_beacon_mesh()
		&"beacon_glow":
			mesh = build_beacon_glass_mesh()
		&"jetty":
			mesh = build_jetty_mesh()
		&"dock":
			mesh = build_dock_mesh()
		&"landing":
			mesh = build_landing_mesh()
		&"lighthouse":
			mesh = build_lighthouse_mesh()
		&"lighthouse_glow":
			mesh = build_lighthouse_lamp_mesh()
		_:
			push_error("ProceduralMeshBuilder: unknown prop kind '%s'" % kind)
			return null
	_prop_meshes[kind] = mesh
	return mesh


## Round-canopied tree: a tapered trunk under three lumpy leaf clusters, lit
## lighter on top so the canopy reads as painted even before lighting.
static func build_broadleaf_tree_mesh() -> ArrayMesh:
	var st := _begin()
	_prism(st, Vector3(0.0, -0.3, 0.0), Vector3(0.0, 2.0, 0.0), 0.22, 0.13, 6, BARK)
	_prism(st, Vector3(0.0, 1.3, 0.0), Vector3(0.55, 2.1, 0.2), 0.08, 0.05, 5, BARK)
	_blob(st, Vector3(0.0, 2.55, 0.0), Vector3(1.55, 1.25, 1.5), LEAF_TOP, LEAF_SIDE, 3)
	_blob(st, Vector3(0.75, 2.25, 0.35), Vector3(0.95, 0.85, 0.95), LEAF_TOP, LEAF_SIDE, 7)
	_blob(st, Vector3(-0.55, 3.05, -0.3), Vector3(0.9, 0.8, 0.9), LEAF_TOP, LEAF_SIDE, 13)
	return st.commit()


## Three stacked cones on a short trunk.
static func build_pine_tree_mesh() -> ArrayMesh:
	var st := _begin()
	_prism(st, Vector3(0.0, -0.3, 0.0), Vector3(0.0, 1.1, 0.0), 0.17, 0.11, 6, BARK)
	_prism(st, Vector3(0.0, 0.7, 0.0), Vector3(0.0, 2.6, 0.0), 1.35, 0.0, 7, PINE_DARK)
	_prism(st, Vector3(0.0, 1.7, 0.0), Vector3(0.0, 3.4, 0.0), 1.05, 0.0, 7, PINE_MID)
	_prism(st, Vector3(0.0, 2.6, 0.0), Vector3(0.0, 4.15, 0.0), 0.74, 0.0, 7, PINE_LIGHT)
	return st.commit()


## Leaning banded trunk with seven arching, drooping fronds (two-sided).
static func build_palm_tree_mesh() -> ArrayMesh:
	var st := _begin()
	var height := 4.4
	var lean := 0.95
	var segments := 6
	var prev := Vector3(0.0, -0.3, 0.0)
	for i in segments:
		var t := float(i + 1) / segments
		var p := Vector3(lean * t * t, -0.3 + height * t, 0.0)
		var r0 := lerpf(0.19, 0.1, float(i) / segments)
		var r1 := lerpf(0.19, 0.1, t)
		_prism(st, prev, p, r0, r1, 6, PALM_BARK_A if i % 2 == 0 else PALM_BARK_B)
		prev = p
	var top := prev
	_blob(st, top + Vector3(0.0, 0.05, 0.0), Vector3(0.28, 0.22, 0.28), PALM_BARK_B, BARK, 5, 3, 5, 0.1)
	for f in 7:
		var yaw := TAU * f / 7.0 + 0.3
		var dir := Vector3(cos(yaw), 0.0, sin(yaw))
		var side := dir.cross(Vector3.UP)
		var colour := PALM_LEAF if f % 2 == 0 else PALM_LEAF_DARK
		var steps := 5
		var left := PackedVector3Array()
		var right := PackedVector3Array()
		var spine := PackedVector3Array()
		for k in steps + 1:
			var s := float(k) / steps
			var c := top + dir * (s * 2.3) + Vector3.UP * (0.55 * s - 1.25 * s * s)
			var w := 0.42 * sin(PI * clampf(s * 0.9 + 0.1, 0.0, 1.0))
			spine.append(c + Vector3.UP * 0.07)
			left.append(c + side * w)
			right.append(c - side * w)
		for k in steps:
			for face_up: float in [1.0, -1.0]:
				var hint := Vector3.UP * face_up
				_quad(st, spine[k], left[k], left[k + 1], spine[k + 1], colour, hint)
				_quad(st, spine[k], right[k], right[k + 1], spine[k + 1], colour, hint)
	return st.commit()


## Lumpy boulder, sunk a little so it sits into the ground.
static func build_rock_mesh(seed_value: int, radii: Vector3) -> ArrayMesh:
	var st := _begin()
	_blob(st, Vector3(0.0, radii.y * 0.55, 0.0), radii, STONE_TOP, STONE_SIDE, seed_value, 4, 6, 0.24)
	return st.commit()


## Five slim blades fanning out from one root (two-sided).
static func build_grass_tuft_mesh() -> ArrayMesh:
	var st := _begin()
	for b in 5:
		var yaw := TAU * b / 5.0 + _hash01(b, 3, 7) * 0.8
		var out := Vector3(cos(yaw), 0.0, sin(yaw))
		var side := out.cross(Vector3.UP) * 0.05
		var h := 0.42 + _hash01(b, 9, 2) * 0.28
		var tip := out * (0.18 + _hash01(b, 4, 4) * 0.12) + Vector3.UP * h
		var root := out * 0.03
		for face: float in [1.0, -1.0]:
			_tri(st, root - side, root + side, tip, GRASS_BASE if b % 2 == 0 else GRASS_TIP, out * face)
	return st.commit()


## Weathered sandstone column with a mossy foot, 3.1 m tall.
static func build_column_mesh() -> ArrayMesh:
	var st := _begin()
	_box(st, Vector3(0.0, 0.12, 0.0), Vector3(0.95, 0.5, 0.95), SANDSTONE_DARK)
	_prism(st, Vector3(0.0, 0.37, 0.0), Vector3(0.0, 0.55, 0.0), 0.37, 0.355, 8, MOSS)
	_prism(st, Vector3(0.0, 0.37, 0.0), Vector3(0.0, 2.9, 0.0), 0.33, 0.29, 8, SANDSTONE)
	_box(st, Vector3(0.0, 3.0, 0.0), Vector3(0.86, 0.22, 0.86), SANDSTONE_DARK)
	return st.commit()


## A broken gateway on a low platform: one full pillar holding a snapped lintel,
## one pillar sheared off, and rubble at their feet.
static func build_ruin_arch_mesh() -> ArrayMesh:
	var st := _begin()
	_box(st, Vector3(0.0, -0.1, 0.0), Vector3(5.2, 0.6, 2.6), SANDSTONE_DARK)
	_box(st, Vector3(0.0, 0.22, 0.0), Vector3(4.6, 0.06, 2.0), MOSS)
	_box(st, Vector3(-1.6, 2.1, 0.0), Vector3(0.72, 3.8, 0.72), SANDSTONE)
	_box(st, Vector3(-0.75, 4.15, 0.0), Vector3(2.6, 0.5, 0.86), SANDSTONE_DARK, Basis(Vector3.BACK, -0.06))
	_box(st, Vector3(1.6, 1.25, 0.0), Vector3(0.72, 2.1, 0.72), SANDSTONE)
	_box(st, Vector3(1.6, 2.36, 0.05), Vector3(0.6, 0.18, 0.6), SANDSTONE_DARK, Basis(Vector3(1, 0, 1).normalized(), 0.35))
	_box(st, Vector3(2.5, 0.45, 0.9), Vector3(0.62, 0.45, 0.5), SANDSTONE, Basis(Vector3.UP, 0.5))
	_box(st, Vector3(0.9, 0.42, -0.95), Vector3(0.5, 0.36, 0.45), SANDSTONE_DARK, Basis(Vector3.UP, -0.3))
	_box(st, Vector3(-2.55, 0.4, -0.7), Vector3(0.45, 0.32, 0.4), SANDSTONE, Basis(Vector3.UP, 0.9))
	return st.commit()


static func build_crate_mesh() -> ArrayMesh:
	var st := _begin()
	_box(st, Vector3(0.0, 0.32, 0.0), Vector3(0.64, 0.64, 0.64), DECK_B)
	for y: float in [0.06, 0.58]:
		_box(st, Vector3(0.0, y, 0.0), Vector3(0.67, 0.08, 0.67), WALNUT)
	return st.commit()


static func build_barrel_mesh() -> ArrayMesh:
	var st := _begin()
	_barrel(st, Vector3.ZERO, 0.3, 0.75)
	return st.commit()


## A lime-washed cottage on a stone footing, gable roof along X, door and two
## windows at the front (-Z), two at the back, one in each gable. Origin at
## the ground under its centre. The window glass is build_cottage_windows_mesh().
static func build_cottage_mesh() -> ArrayMesh:
	var st := _begin()
	_box(st, Vector3(0.0, -0.05, 0.0), Vector3(4.3, 0.8, 3.7), STONE_SIDE)
	_box(st, Vector3(0.0, 1.5, 0.0), Vector3(4.0, 2.4, 3.4), PLASTER)
	for cx: float in [-1.95, 1.95]:
		for cz: float in [-1.65, 1.65]:
			_box(st, Vector3(cx, 1.5, cz), Vector3(0.22, 2.42, 0.22), TIMBER)
	_box(st, Vector3(0.0, 2.68, 0.0), Vector3(4.12, 0.14, 3.52), TIMBER)
	# Gable ends, then the two roof slopes (with undersides for the eaves).
	for gx: float in [-2.0, 2.0]:
		_tri(st, Vector3(gx, 2.7, -1.7), Vector3(gx, 2.7, 1.7), Vector3(gx, 4.25, 0.0), PLASTER_SHADE, Vector3(gx, 0.0, 0.0))
	for side: float in [-1.0, 1.0]:
		var ridge_a := Vector3(-2.35, 4.3, 0.0)
		var ridge_b := Vector3(2.35, 4.3, 0.0)
		var eave_a := Vector3(-2.35, 2.5, side * 2.1)
		var eave_b := Vector3(2.35, 2.5, side * 2.1)
		var colour := ROOF if side < 0.0 else ROOF_DARK
		_quad(st, ridge_a, ridge_b, eave_b, eave_a, colour, Vector3(0.0, 1.0, side))
		_quad(st, ridge_a + Vector3.DOWN * 0.12, ridge_b + Vector3.DOWN * 0.12, eave_b + Vector3.DOWN * 0.12,
			eave_a + Vector3.DOWN * 0.12, ROOF_DARK, Vector3(0.0, -1.0, -side))
	_box(st, Vector3(0.0, 4.32, 0.0), Vector3(4.8, 0.14, 0.24), ROOF_DARK)
	_box(st, Vector3(1.2, 4.0, 0.75), Vector3(0.55, 1.6, 0.55), STONE_SIDE)
	_box(st, Vector3(1.2, 4.84, 0.75), Vector3(0.66, 0.1, 0.66), IRON)
	_box(st, Vector3(-0.2, 1.05, -1.72), Vector3(0.82, 1.55, 0.06), WALNUT)
	for w: Vector3 in _cottage_windows():
		var size := Vector3(0.86, 0.86, 0.04) if absf(w.z) > 1.0 else Vector3(0.04, 0.86, 0.86)
		# The frame sits just behind the glass.
		var inward := Vector3(-signf(w.x) * 0.012, 0.0, 0.0) if absf(w.z) < 1.0 else Vector3(0.0, 0.0, -signf(w.z) * 0.012)
		_box(st, w + inward, size, WALNUT)
	return st.commit()


static func build_cottage_windows_mesh() -> ArrayMesh:
	var st := _begin()
	for w: Vector3 in _cottage_windows():
		var size := Vector3(0.66, 0.66, 0.04) if absf(w.z) > 1.0 else Vector3(0.04, 0.66, 0.66)
		_box(st, w, size, WINDOW_GLOW)
	return st.commit()


## Window centres on the cottage walls, just proud of the plaster.
static func _cottage_windows() -> Array[Vector3]:
	return [Vector3(1.1, 1.65, -1.73), Vector3(-1.25, 1.65, -1.73), Vector3(0.9, 1.65, 1.73),
		Vector3(-0.9, 1.65, 1.73), Vector3(2.03, 1.65, 0.0), Vector3(-2.03, 1.65, 0.0)]


## A lamp post on a little cairn: lights the beaches of small islands and the
## village lanes. Origin at its foot; the glass is build_beacon_glass_mesh().
static func build_beacon_mesh() -> ArrayMesh:
	var st := _begin()
	_blob(st, Vector3(0.0, 0.1, 0.0), Vector3(0.55, 0.35, 0.55), STONE_TOP, STONE_SIDE, 41, 3, 6, 0.12)
	_prism(st, Vector3(0.0, 0.2, 0.0), Vector3(0.0, 2.15, 0.0), 0.08, 0.06, 6, TIMBER)
	_box(st, Vector3(0.0, 2.32, 0.0), Vector3(0.38, 0.06, 0.38), IRON)
	_box(st, Vector3(0.0, 1.88, 0.0), Vector3(0.34, 0.05, 0.34), IRON)
	_prism(st, Vector3(0.0, 2.35, 0.0), Vector3(0.0, 2.5, 0.0), 0.2, 0.03, 4, IRON)
	return st.commit()


static func build_beacon_glass_mesh() -> ArrayMesh:
	var st := _begin()
	_box(st, Vector3(0.0, 2.1, 0.0), Vector3(0.28, 0.38, 0.28), LANTERN_GLOW)
	return st.commit()


## A plank jetty on pairs of posts, running JETTY_LENGTH out along -Z from the
## shore. Origin at the shore end, deck level.
static func build_jetty_mesh() -> ArrayMesh:
	var st := _begin()
	var z := 0.0
	var k := 0
	while z < JETTY_LENGTH:
		_box(st, Vector3(0.0, -0.06, -z - 0.24), Vector3(2.2 + (0.08 if k % 3 == 0 else 0.0), 0.12, 0.44),
			DECK_A if k % 2 == 0 else DECK_B)
		z += 0.5
		k += 1
	for side: float in [-1.0, 1.0]:
		_box(st, Vector3(side * 1.08, 0.05, -JETTY_LENGTH * 0.5), Vector3(0.12, 0.1, JETTY_LENGTH), TIMBER)
		var pz := 0.4
		while pz < JETTY_LENGTH:
			_prism(st, Vector3(side * 1.0, -4.0, -pz), Vector3(side * 1.0, 0.35, -pz), 0.14, 0.13, 6, TIMBER)
			pz += 3.8
	return st.commit()


## A harbour pier: a broad plank deck on heavy piles, edge beams, iron bollards
## and fenders down both sides for boats to lie against.
static func build_dock_mesh() -> ArrayMesh:
	var st := _begin()
	_deck(st, Vector3(0.0, 0.0, -DOCK_LENGTH * 0.5), DOCK_WIDTH, DOCK_LENGTH, false)
	for side: float in [-1.0, 1.0]:
		var x := side * DOCK_WIDTH * 0.5
		_box(st, Vector3(x - side * 0.06, 0.05, -DOCK_LENGTH * 0.5), Vector3(0.14, 0.14, DOCK_LENGTH), TIMBER)
		var z := 0.6
		while z < DOCK_LENGTH:
			_prism(st, Vector3(x, -4.0, -z), Vector3(x, 0.45, -z), 0.19, 0.17, 6, TIMBER)
			z += 4.6
		_mooring_edge(st, x, side, 2.0, DOCK_LENGTH - 1.0)
	return st.commit()


## A river landing: a narrow gangway from the bank out to a stage that lies
## along the water, with bollards and fenders on its outer edge.
static func build_landing_mesh() -> ArrayMesh:
	var st := _begin()
	_deck(st, Vector3(0.0, -0.02, -LANDING_WALK * 0.5), 1.8, LANDING_WALK, false)
	for side: float in [-1.0, 1.0]:
		_box(st, Vector3(side * 0.88, 0.32, -LANDING_WALK * 0.5), Vector3(0.08, 0.08, LANDING_WALK), TIMBER)
		_prism(st, Vector3(side * 0.88, -0.4, -0.3), Vector3(side * 0.88, 0.38, -0.3), 0.06, 0.06, 4, TIMBER)
		_prism(st, Vector3(side * 0.88, -2.5, -LANDING_WALK + 0.3), Vector3(side * 0.88, 0.38, -LANDING_WALK + 0.3), 0.06, 0.06, 4, TIMBER)
	var stage := Vector3(0.0, 0.0, -LANDING_WALK - LANDING_DEPTH * 0.5)
	_deck(st, stage, LANDING_SPAN, LANDING_DEPTH, true)
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var at := stage + Vector3(corner.x * LANDING_SPAN * 0.5, 0.0, corner.y * LANDING_DEPTH * 0.5)
		_prism(st, Vector3(at.x, -4.0, at.z), Vector3(at.x, 0.5, at.z), 0.19, 0.17, 6, TIMBER)
	var outer := -LANDING_WALK - LANDING_DEPTH
	_box(st, Vector3(0.0, 0.05, outer + 0.06), Vector3(LANDING_SPAN, 0.14, 0.14), TIMBER)
	for x: float in [-LANDING_SPAN * 0.3, LANDING_SPAN * 0.3]:
		_bollard(st, Vector3(x, 0.0, outer + 0.4))
	var x := -LANDING_SPAN * 0.5 + 1.0
	while x < LANDING_SPAN * 0.5:
		_box(st, Vector3(x, -0.45, outer - 0.06), Vector3(0.38, 0.9, 0.12), WALNUT)
		x += 1.9
	return st.commit()


## Planks laid across a deck centred on `centre`, `width` wide and `length` long
## (planks run along X, or along Z with `along_x`).
static func _deck(st: SurfaceTool, centre: Vector3, width: float, length: float, along_x: bool) -> void:
	var span := width if along_x else length
	var cross := length if along_x else width
	var t := 0.0
	var k := 0
	while t < span - 0.01:
		var plank := minf(0.44, span - t)
		var along := -span * 0.5 + t + plank * 0.5
		var size := Vector3(cross + (0.08 if k % 3 == 0 else 0.0), 0.14, plank)
		var at := centre + Vector3(0.0, -0.07, along)
		if along_x:
			size = Vector3(plank, 0.14, cross + (0.08 if k % 3 == 0 else 0.0))
			at = centre + Vector3(along, -0.07, 0.0)
		_box(st, at, size, DECK_A if k % 2 == 0 else DECK_B)
		t += 0.5
		k += 1


## Bollards and fenders along one long side of a pier, from z0 to z1 out (-Z).
static func _mooring_edge(st: SurfaceTool, x: float, side: float, z0: float, z1: float) -> void:
	var z := z0
	while z < z1:
		_bollard(st, Vector3(x - side * 0.4, 0.0, -z))
		z += 5.5
	z = z0
	while z < z1:
		_box(st, Vector3(x + side * 0.06, -0.45, -z), Vector3(0.12, 0.9, 0.38), WALNUT)
		z += 1.9


static func _bollard(st: SurfaceTool, at: Vector3) -> void:
	_prism(st, at, at + Vector3(0.0, 0.42, 0.0), 0.15, 0.12, 6, IRON)
	_prism(st, at + Vector3(0.0, 0.42, 0.0), at + Vector3(0.0, 0.5, 0.0), 0.2, 0.2, 6, IRON)


## Where a dock kind stands solid, for the island's collider: [[centre, size]...] in its own space.
static func dock_solids(kind: StringName) -> Array:
	var depth := 3.2
	if kind == &"dock":
		return [[Vector3(0.0, -depth * 0.5 + 0.15, -DOCK_LENGTH * 0.5), Vector3(DOCK_WIDTH, depth, DOCK_LENGTH)]]
	return [[Vector3(0.0, -depth * 0.5 + 0.15, -LANDING_WALK * 0.5), Vector3(1.8, depth, LANDING_WALK)],
		[Vector3(0.0, -depth * 0.5 + 0.15, -LANDING_WALK - LANDING_DEPTH * 0.5), Vector3(LANDING_SPAN, depth, LANDING_DEPTH)]]


## A striped lighthouse on a stone plinth: white and coral bands, an iron
## gallery, the lamp room's posts and a red cap. Origin at its foot; the lamp
## glass is build_lighthouse_lamp_mesh().
static func build_lighthouse_mesh() -> ArrayMesh:
	var st := _begin()
	_box(st, Vector3(0.0, 0.1, 0.0), Vector3(4.6, 1.6, 4.6), STONE_SIDE)
	_box(st, Vector3(0.0, 0.94, 0.0), Vector3(4.8, 0.12, 4.8), STONE_TOP)
	var bands := 6
	for b in bands:
		var y0 := 1.0 + 11.5 * b / bands
		var y1 := 1.0 + 11.5 * (b + 1) / bands
		var r0 := lerpf(1.95, 1.2, float(b) / bands)
		var r1 := lerpf(1.95, 1.2, float(b + 1) / bands)
		_prism(st, Vector3(0.0, y0, 0.0), Vector3(0.0, y1, 0.0), r0, r1, 10,
			BEACON_WHITE if b % 2 == 0 else BEACON_STRIPE, b == 0)
	_box(st, Vector3(0.0, 3.2, -1.78), Vector3(0.7, 1.3, 0.3), WALNUT)
	_prism(st, Vector3(0.0, 12.45, 0.0), Vector3(0.0, 12.8, 0.0), 1.85, 1.85, 10, IRON)
	for i in 10:
		var a := TAU * (i + 0.5) / 10.0
		_prism(st, Vector3(cos(a) * 1.75, 12.8, sin(a) * 1.75), Vector3(cos(a) * 1.75, 13.5, sin(a) * 1.75), 0.04, 0.04, 4, IRON)
	_prism(st, Vector3(0.0, 13.45, 0.0), Vector3(0.0, 13.55, 0.0), 1.8, 1.8, 10, IRON, false)
	for i in 6:
		var a := TAU * i / 6.0
		_prism(st, Vector3(cos(a) * 0.98, 12.8, sin(a) * 0.98), Vector3(cos(a) * 0.98, 14.6, sin(a) * 0.98), 0.06, 0.06, 4, IRON)
	_prism(st, Vector3(0.0, 14.55, 0.0), Vector3(0.0, 14.75, 0.0), 1.25, 1.25, 10, ROOF_DARK)
	_prism(st, Vector3(0.0, 14.75, 0.0), Vector3(0.0, 16.1, 0.0), 1.15, 0.08, 10, BEACON_STRIPE)
	_prism(st, Vector3(0.0, 16.0, 0.0), Vector3(0.0, 16.6, 0.0), 0.06, 0.03, 4, IRON)
	return st.commit()


static func build_lighthouse_lamp_mesh() -> ArrayMesh:
	var st := _begin()
	_prism(st, Vector3(0.0, 12.85, 0.0), Vector3(0.0, 14.5, 0.0), 0.9, 0.9, 6, LANTERN_GLOW)
	return st.commit()


# =============================================================================
# Materials
# =============================================================================

## Shared toon material: vertex colours as albedo, stepped diffuse and specular,
## and a soft rim so silhouettes catch a warm edge highlight.
static func toon_material(double_sided := false) -> StandardMaterial3D:
	var key := "toon_2" if double_sided else "toon_1"
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	mat.specular_mode = BaseMaterial3D.SPECULAR_TOON
	mat.roughness = 0.88
	mat.metallic_specular = 0.22
	mat.rim_enabled = true
	mat.rim = 0.3
	mat.rim_tint = 0.6
	if double_sided:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials[key] = mat
	return mat


## Lamp glass and lit windows that brighten as night falls (NightGlow shader),
## cached per look.
static func night_glow_material(day_level: float, night_level: float, flicker: float) -> ShaderMaterial:
	var key := "night_%s_%s_%s" % [day_level, night_level, flicker]
	if _materials.has(key):
		return _materials[key]
	var mat := ShaderMaterial.new()
	mat.shader = NIGHT_GLOW_SHADER
	mat.set_shader_parameter(&"day_level", day_level)
	mat.set_shader_parameter(&"night_level", night_level)
	mat.set_shader_parameter(&"flicker", flicker)
	_materials[key] = mat
	return mat


# =============================================================================
# Geometry primitives
# =============================================================================

static func _mesh_node(node_name: String, mesh: Mesh, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = material
	return mi


## One flat-shaded triangle. The winding is flipped if needed so the face points
## along `hint`; degenerate (zero-area) triangles are skipped.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, colour: Color, hint: Vector3) -> void:
	# With clockwise front faces, (c - a) x (b - a) is the outward normal.
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-10:
		return
	if n.dot(hint) < 0.0:
		var swap := b
		b = c
		c = swap
		n = -n
	n = n.normalized()
	st.set_color(colour)
	st.set_normal(n)
	st.add_vertex(a)
	st.set_color(colour)
	st.set_normal(n)
	st.add_vertex(b)
	st.set_color(colour)
	st.set_normal(n)
	st.add_vertex(c)


## Quad from four corners listed in order around its edge.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, colour: Color, hint: Vector3) -> void:
	_tri(st, a, b, c, colour, hint)
	_tri(st, a, c, d, colour, hint)


static func _box(st: SurfaceTool, centre: Vector3, size: Vector3, colour: Color, basis := Basis.IDENTITY) -> void:
	var h := size * 0.5
	var p: Array[Vector3] = []
	for i in 8:
		var local := Vector3(
			h.x if i & 1 else -h.x,
			h.y if i & 2 else -h.y,
			h.z if i & 4 else -h.z)
		p.append(centre + basis * local)
	_quad(st, p[0], p[2], p[6], p[4], colour, basis * Vector3.LEFT)
	_quad(st, p[1], p[3], p[7], p[5], colour, basis * Vector3.RIGHT)
	_quad(st, p[0], p[1], p[5], p[4], colour, basis * Vector3.DOWN)
	_quad(st, p[2], p[3], p[7], p[6], colour, basis * Vector3.UP)
	_quad(st, p[0], p[1], p[3], p[2], colour, basis * Vector3.FORWARD)
	_quad(st, p[4], p[5], p[7], p[6], colour, basis * Vector3.BACK)


## Tapered n-sided prism from `from` to `to` (radius r0 -> r1), optionally capped.
static func _prism(st: SurfaceTool, from: Vector3, to: Vector3, r0: float, r1: float, sides: int,
		colour: Color, caps := true) -> void:
	var axis := to - from
	var length := axis.length()
	if length < 1e-5:
		return
	axis /= length
	var ref := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var u := axis.cross(ref).normalized()
	var w := axis.cross(u)
	var ring0 := PackedVector3Array()
	var ring1 := PackedVector3Array()
	for i in sides:
		var ang := TAU * (float(i) + 0.5) / float(sides)
		var dir := u * cos(ang) + w * sin(ang)
		ring0.append(from + dir * r0)
		ring1.append(to + dir * r1)
	var middle := (from + to) * 0.5
	for i in sides:
		var j := (i + 1) % sides
		var face_mid := (ring0[i] + ring0[j] + ring1[i] + ring1[j]) * 0.25
		_quad(st, ring0[i], ring0[j], ring1[j], ring1[i], colour, face_mid - middle)
	if caps:
		for i in sides:
			var j := (i + 1) % sides
			_tri(st, from, ring0[j], ring0[i], colour, -axis)
			_tri(st, to, ring1[i], ring1[j], colour, axis)


## Bellied barrel with two iron hoops, standing on `base`.
static func _barrel(st: SurfaceTool, base: Vector3, radius: float, height: float) -> void:
	var up := Vector3.UP * height
	_prism(st, base, base + up * 0.5, radius * 0.86, radius, 8, TIMBER)
	_prism(st, base + up * 0.5, base + up, radius, radius * 0.86, 8, TIMBER)
	_prism(st, base + up * 0.12, base + up * 0.2, radius * 0.96, radius * 0.97, 8, IRON)
	_prism(st, base + up * 0.8, base + up * 0.88, radius * 0.97, radius * 0.96, 8, IRON)


## Lumpy low-poly ellipsoid (leaf clusters, boulders). Vertices are pushed in and
## out by a stable hash, and faces blend from side_colour to top_colour by how
## much they face the sky.
static func _blob(st: SurfaceTool, centre: Vector3, radii: Vector3, top_colour: Color, side_colour: Color,
		seed_value: int, rings := 4, segments := 6, jitter := 0.18) -> void:
	var grid: Array[PackedVector3Array] = []
	for r in rings + 1:
		var theta := PI * float(r) / rings
		var row := PackedVector3Array()
		for s in segments:
			var phi := TAU * float(s) / segments + (PI / segments if r % 2 == 1 else 0.0)
			var dir := Vector3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
			# Poles share one jitter so they stay a single point.
			var key := s if r > 0 and r < rings else 0
			var bump := 1.0 + (_hash01(seed_value, r, key) - 0.5) * 2.0 * jitter
			row.append(centre + dir * radii * bump)
		grid.append(row)
	for r in rings:
		for s in segments:
			var s1 := (s + 1) % segments
			var a := grid[r][s]
			var b := grid[r][s1]
			var c := grid[r + 1][s1]
			var d := grid[r + 1][s]
			var mid := (a + b + c + d) * 0.25
			var up := clampf((mid - centre).normalized().y * 0.5 + 0.5, 0.0, 1.0)
			var colour := side_colour.lerp(top_colour, smoothstep(0.45, 0.95, up))
			_quad(st, a, b, c, d, colour, mid - centre)


static func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


## Stable pseudo-random 0..1 from three integers (same answer on every run and thread).
static func _hash01(a: int, b: int, c: int) -> float:
	var h := (a * 374761393 + b * 668265263 + c * 1274126177) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	h = h ^ (h >> 16)
	return float(h & 0xffff) / 65535.0
