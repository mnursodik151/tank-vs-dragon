class_name BattleConfig
extends RefCounted
## What the start menu decides and `Game` reads: 1 player vs the AI or 2 players on one screen (hot seat), which side
## Player 1 (= "you" against the AI) takes, and the tint of each side. Static, so it survives `reload_current_scene`
## (rematch) and the trip back to the menu. Defaults reproduce the old hard-coded game: you = team 0, blue, vs red AI.
##
## Team numbers stay 0 (north spawns) and 1 (south spawns); "Player 1" / "Player 2" are the two roles that pick a side. Each role also picks a
## faction (`Factions`): the roster its side fields, so the factions may be mixed.

const PALETTE: Array[Color] = [
	Color(0.25, 0.55, 1.00),   # blue
	Color(0.95, 0.35, 0.30),   # red
	Color(0.35, 0.80, 0.40),   # green
	Color(0.98, 0.78, 0.25),   # yellow
	Color(0.70, 0.45, 0.95),   # purple
	Color(0.98, 0.58, 0.20),   # orange
	Color(0.30, 0.85, 0.85),   # cyan
	Color(0.92, 0.92, 0.95),   # white
]

static var two_player := false          ## hot seat instead of vs the AI
static var p1_team := 0                 ## the side Player 1 / you play (the other side is Player 2 / the AI)
static var p1_color := PALETTE[0]
static var p2_color := PALETTE[1]
static var p1_faction := Factions.Id.MODERN
static var p2_faction := Factions.Id.MODERN


static func reset() -> void:
	two_player = false
	p1_team = 0
	p1_color = PALETTE[0]
	p2_color = PALETTE[1]
	p1_faction = Factions.Id.MODERN
	p2_faction = Factions.Id.MODERN


static func other(team: int) -> int:
	return 1 - team


## Teams a person plays: both in hot seat, only Player 1's side against the AI.
static func human_teams() -> Array[int]:
	var out: Array[int] = [p1_team]
	if two_player:
		out.append(other(p1_team))
	return out


static func is_human(team: int) -> bool:
	return human_teams().has(team)


static func color_of(team: int) -> Color:
	return p1_color if team == p1_team else p2_color


## The faction `team` fields (Factions.Id).
static func faction_of(team: int) -> int:
	return p1_faction if team == p1_team else p2_faction


static func name_of(team: int) -> String:
	if team == p1_team:
		return "PLAYER 1" if two_player else "YOU"
	return "PLAYER 2" if two_player else "AI"


static func side_name(team: int) -> String:
	return "NORTH" if team == 0 else "SOUTH"
