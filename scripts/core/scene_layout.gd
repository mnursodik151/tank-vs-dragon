class_name SceneLayout
extends RefCounted
## The result of a SceneComposer run: plain data describing what goes on the map. All cells are offset
## coordinates (column, row), the same convention the map data always used. Game turns it into a GridBoard.
## New composed things (spawn points, objectives, ...) get their own field here.

var seed := 0
## [Props.Kind, Vector2i cell, glTF model stem] plus an optional 4th entry, the yaw in radians of a wall/fence line - fed to GridBoard.add_prop.
var props: Array = []
## Cells of Terrain.Type.ROUGH (undergrowth, costs extra AP).
var rough: Array[Vector2i] = []
## Offset cell -> elevation level (1..GridBoard.MAX_LEVEL); cells not listed are flat ground (level 0).
var levels: Dictionary = {}
## River cells (impassable water). A bridge is NOT listed here: it is a road cell in `bridges` (and `roads`) lying on the river's course.
var water: Array[Vector2i] = []
## Where the river leaves the map: offset cells just outside the board (tile selection only).
var water_exits: Array[Vector2i] = []
## Road cells (Terrain.Type.ROAD, cheap to cross), bridges included.
var roads: Array[Vector2i] = []
## The road cells that cross the river.
var bridges: Array[Vector2i] = []


## Builds this layout into `board`: elevation, props, river, roads (bridges included) and undergrowth.
func apply(board: GridBoard) -> void:
	for o: Vector2i in levels:
		board.set_level(GridBoard.offset_to_axial(o), levels[o])
	for p: Array in props:
		board.add_prop(GridBoard.offset_to_axial(p[1]), p[0], p[2], p[3] if p.size() > 3 else NAN)
	for o in water:
		board.add_water(GridBoard.offset_to_axial(o))
	for o in water_exits:
		board.add_water_exit(GridBoard.offset_to_axial(o))
	for o in roads:
		board.set_terrain(GridBoard.offset_to_axial(o), Terrain.Type.ROAD)
	for o in bridges:
		board.add_bridge(GridBoard.offset_to_axial(o))
	for o in rough:
		board.set_terrain(GridBoard.offset_to_axial(o), Terrain.Type.ROUGH)


## "tree x15, large rock x6, ..." for logs.
func summary() -> String:
	var counts := {}
	for p: Array in props:
		counts[p[0]] = int(counts.get(p[0], 0)) + 1
	var parts := PackedStringArray()
	for kind: int in counts:
		parts.append("%s x%d" % [Props.kind_name(kind as Props.Kind), counts[kind]])
	parts.append("rough x%d" % rough.size())
	parts.append("river x%d (bridges x%d), road x%d" % [water.size(), bridges.size(), roads.size()])
	var peak := 0
	for c: Vector2i in levels:
		peak = maxi(peak, int(levels[c]))
	parts.append("high ground x%d (peak %d)" % [levels.size(), peak])
	return ", ".join(parts)
