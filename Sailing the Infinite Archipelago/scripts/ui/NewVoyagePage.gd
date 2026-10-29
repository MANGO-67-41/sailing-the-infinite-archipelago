class_name NewVoyagePage
extends MenuPage
## Asks before starting over, from the title screen's NEW VOYAGE.
##
## It says what the voyage so far holds, then offers to keep it (holding focus
## first, so a stray Enter changes nothing) or to start a new voyage: home again,
## in a new stretch of sea, with a blank chart. The old voyage is set aside as a
## backup rather than deleted (VoyageLog.start_new); the title screen does the
## restart when `confirmed` fires.

signal confirmed

const WIDTH := 560.0

var _summary: Label
var _keep: Row
var _fresh: Row


func _init() -> void:
	heading = "NEW VOYAGE"


func _build_body() -> void:
	body.custom_minimum_size.x = WIDTH
	var words := CozyHUD.make_vbox(6)
	_summary = CozyHUD.make_label("", &"PageRow")
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Wrapping text needs a width to wrap to, or it starts one letter wide.
	_summary.custom_minimum_size.x = WIDTH
	words.add_child(_summary)
	var kept := CozyHUD.make_label("The voyage you're on is set aside as a backup, not deleted.", &"PageNote")
	kept.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	kept.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kept.custom_minimum_size.x = WIDTH
	words.add_child(kept)
	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_bottom", 22)
	pad.add_child(words)
	add_row(pad)

	_keep = _choice("Keep this voyage", "Back to the title screen", false)
	_keep.activate = close
	_fresh = _choice("Start a new voyage", "Home again, in a new stretch of sea", true)
	_fresh.ruled = false
	_fresh.activate = func() -> void: confirmed.emit()


func open() -> void:
	if is_open():
		return
	var found := VoyageLog.discoveries.size()
	_summary.text = "Your chart will be cleared: %d %s, %s sailed, %s at sea." % [found,
		"island" if found == 1 else "islands", GameSettings.format_distance(VoyageLog.distance_sailed),
		GameSettings.format_duration(VoyageLog.time_at_sea)]
	super.open()


func _first_focus() -> Control:
	return _keep


func _focus_chain() -> Array[Control]:
	return [_keep, _fresh]


## A choice line: its name (inked Ember when it starts over) and what it does.
func _choice(text: String, detail: String, starts_over: bool) -> Row:
	var row := Row.new()
	row.focus_mode = Control.FOCUS_ALL
	var line := CozyHUD.make_hbox(16)
	var name_label := CozyHUD.make_label(text, &"PageRow")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if starts_over:
		name_label.add_theme_color_override(&"font_color", CozyHUD.EMBER)
	line.add_child(name_label)
	line.add_child(CozyHUD.make_label(detail, &"PageNote"))
	row.add_child(line)
	add_row(row)
	return row
