class_name ControlsPage
extends MenuPage
## Every key and mouse control, grouped the way you use them at sea, so the
## in-game hints can stay tucked away.

const KEY_COLUMN := 96.0

## [group name, [[keys], what it does]..., note under the group]
const LEFT := [
	["Sailing", [
		[["W", "S"], "Hoist / lower sail"],
		[["A", "D"], "Steer"],
		[["Q", "E"], "Trim the sails by hand"],
		[["T"], "Auto-trim on / off"],
		[["Space"], "Moor at a dock / cast off"],
	], "With the sails down, S keeps going and backs you up; W stops. The arrow keys work too."],
	["Engine", [
		[["R"], "One notch ahead"],
		[["F"], "One notch astern"],
	], "Five notches: astern, stop, slow, half and full."],
]
const RIGHT := [
	["Camera", [
		[["Drag"], "Look around"],
		[["Wheel"], "Zoom in / out"],
	], "Look speed and invert are in Settings."],
	["Interface", [
		[["H"], "Show / hide key hints"],
		[["Esc"], "Pause"],
		[["W", "S"], "Move through a menu"],
		[["Enter"], "Choose"],
	], "A and D (or the arrow keys) step along the title and pause menus."],
]


func _init() -> void:
	heading = "CONTROLS"


func _build_body() -> void:
	var columns := CozyHUD.make_hbox(64)
	columns.add_child(_column(LEFT))
	columns.add_child(_column(RIGHT))
	body.add_child(columns)


func _column(groups: Array) -> VBoxContainer:
	var col := CozyHUD.make_vbox(0)
	col.custom_minimum_size.x = 360.0
	for g in groups.size():
		var group: Array = groups[g]
		if g > 0:
			col.add_child(CozyHUD.make_gap(22))
		var name_label := CozyHUD.make_label(String(group[0]).to_upper(), &"PageGroup")
		var head := MarginContainer.new()
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		head.add_theme_constant_override("margin_left", 16)
		head.add_theme_constant_override("margin_bottom", 2)
		head.add_child(name_label)
		col.add_child(head)
		_rows.append(head)
		var lines: Array = group[1]
		for i in lines.size():
			var entry: Array = lines[i]
			var row := MenuPage.Row.new(false)
			var line := CozyHUD.make_hbox(6)
			row.add_child(line)
			var keys := CozyHUD.make_hbox(5)
			keys.custom_minimum_size.x = KEY_COLUMN
			for key: String in entry[0]:
				keys.add_child(_key(key))
			line.add_child(keys)
			var what := CozyHUD.make_label(entry[1], &"PageRow")
			what.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.add_child(what)
			col.add_child(row)
			_rows.append(row)
		var note := CozyHUD.make_label(group[2], &"PageNote")
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size.x = 330.0
		var pad := MarginContainer.new()
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pad.add_theme_constant_override("margin_left", 16)
		pad.add_theme_constant_override("margin_top", 8)
		pad.add_child(note)
		col.add_child(pad)
		_rows.append(pad)
	return col


static func _key(text: String) -> PanelContainer:
	var cap := PanelContainer.new()
	cap.theme_type_variation = &"PageKey"
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.custom_minimum_size.x = 30.0
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var label := CozyHUD.make_label(text, &"PageKeyLabel")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_child(label)
	return cap
