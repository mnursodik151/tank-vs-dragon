class_name Terrain
extends RefCounted
## Terrain types of a hex cell. Each carries the AP weight of entering it (GridBoard turns
## the weight into path cost), a display colour, and whether fire can spread into it.
## Blast craters and incendiary fires change cells at runtime (see GridBoard.set_terrain).

enum Type { GRASS, ROUGH, CRATER, FIRE, SCORCH, ROAD }

const WATER_WEIGHT := 4.0   ## wading a river cell: eight roads' worth, half a howitzer's turn

const WEIGHTS := {
	Type.GRASS: 1.0,
	Type.ROUGH: 2.0,
	Type.CRATER: 2.5,
	Type.FIRE: 2.0,
	Type.SCORCH: 1.5,
	Type.ROAD: 0.5,   # a road is the cheap way across the map
}
const COLORS := {
	Type.GRASS: Color(0.36, 0.42, 0.33),
	Type.ROUGH: Color(0.50, 0.40, 0.22),
	Type.CRATER: Color(0.20, 0.16, 0.12),
	Type.FIRE: Color(1.0, 0.5, 0.1),
	Type.SCORCH: Color(0.17, 0.17, 0.16),
	Type.ROAD: Color(0.87, 0.72, 0.53),
}


static func weight(t: Type) -> float:
	return WEIGHTS[t]


static func color(t: Type) -> Color:
	return COLORS[t]


static func label(t: Type) -> String:
	return Type.keys()[t].capitalize()


static func flammable(t: Type) -> bool:
	return t == Type.GRASS or t == Type.ROUGH
