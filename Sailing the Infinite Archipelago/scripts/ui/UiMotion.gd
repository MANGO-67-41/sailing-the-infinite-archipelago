class_name UiMotion
extends RefCounted
## Shared micro-interactions for every UI surface (HUD, title, pause).
##
## Discrete feedback springs: Tween TRANS_SPRING / EASE_OUT. A new spring on the
## same property replaces the running one (remembered as metadata on the target),
## so rapid hovers never fight. Tweens are bound to the target node when it is
## one, so they follow its process mode (the pause menu keeps animating while
## the game is paused).


## Springs `property` of `target` to `to`, replacing any spring already running on it.
static func spring(target: Object, property: NodePath, to: Variant, duration := 0.55, owner: Node = null) -> Tween:
	var key := StringName("_ui_spring_" + str(property).replace(":", "_"))
	if target.has_meta(key):
		var running: Tween = target.get_meta(key)
		if running and running.is_valid():
			running.kill()
	var host: Node = owner if owner else target as Node
	var tw := host.create_tween().set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	tw.tween_property(target, property, to, duration)
	target.set_meta(key, tw)
	return tw


## A quick swell then a springy settle, for "something changed here".
static func pulse(control: Control, amount := 1.08) -> void:
	control.pivot_offset = control.size * 0.5
	var key := &"_ui_spring_scale"
	if control.has_meta(key):
		var running: Tween = control.get_meta(key)
		if running and running.is_valid():
			running.kill()
	var tw := control.create_tween()
	tw.tween_property(control, "scale", Vector2.ONE * amount, 0.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(control, "scale", Vector2.ONE, 0.7).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	control.set_meta(key, tw)


## Hover lifts, press squashes, release springs back, focus pulses.
static func make_tactile(control: Control, hover := 1.06, press := 0.92) -> void:
	control.resized.connect(func() -> void: control.pivot_offset = control.size * 0.5)
	control.mouse_entered.connect(func() -> void: spring(control, ^"scale", Vector2.ONE * hover, 0.5))
	control.mouse_exited.connect(func() -> void: spring(control, ^"scale", Vector2.ONE, 0.6))
	control.focus_entered.connect(func() -> void: pulse(control, hover + 0.03))
	if control is BaseButton:
		var button := control as BaseButton
		button.button_down.connect(func() -> void: spring(control, ^"scale", Vector2.ONE * press, 0.2))
		button.button_up.connect(func() -> void:
			spring(control, ^"scale", Vector2.ONE * (hover if button.is_hovered() else 1.0), 0.65))


## Fades a control in or out, toggling visibility at the ends so hidden UI takes no input.
static func fade(control: CanvasItem, show: bool, duration := 0.3, delay := 0.0) -> Tween:
	var key := &"_ui_fade"
	if control.has_meta(key):
		var running: Tween = control.get_meta(key)
		if running and running.is_valid():
			running.kill()
	if show:
		control.visible = true
	var tw := control.create_tween()
	tw.tween_property(control, "modulate:a", 1.0 if show else 0.0, duration).set_delay(delay) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT if show else Tween.EASE_IN)
	if not show:
		tw.tween_callback(func() -> void: control.visible = false)
	control.set_meta(key, tw)
	return tw
