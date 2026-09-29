extends Node
## GUI frame-time probe for File → Save. main.gd adds it only when the
## DOCKET_FRAME_PROBE_OUT environment variable names an output file; otherwise
## it does not exist in the tree.
##
## A frame is the main-thread interval between two consecutive _process ticks,
## so it includes anything that blocks the main thread, a synchronous save
## included. Every "save" action on the menu bar opens a window: the frames
## just before it (baseline) and the next POST_FRAMES frames, the first of which
## contains the save. When a window fills, the probe rewrites the output file as
## JSON listing every window so far.
##
## A driver can request a save without a click by creating "<out>.save". The
## probe deletes it and emits the same menu action File → Save emits, so the
## save runs through the menu's own handler. With DOCKET_FRAME_PROBE_QUIT=1 the
## probe quits the application after the first window is written.

const OUT_ENV := "DOCKET_FRAME_PROBE_OUT"
const QUIT_ENV := "DOCKET_FRAME_PROBE_QUIT"
const TRIGGER_SUFFIX := ".save"
const SLOW_FRAME_MS := 100.0
const PRE_FRAMES := 30
const POST_FRAMES := 120

var _out_path := ""
var _trigger_path := ""
var _quit_after_window := false
var _menu: MenuBuilder
var _last_usec := 0
var _recent: Array[float] = []
var _windows: Array[Dictionary] = []
var _open: Dictionary = {}
var _next_source := "menu"


static func enabled() -> bool:
	return not OS.get_environment(OUT_ENV).is_empty()


func watch(menu: MenuBuilder) -> void:
	_out_path = OS.get_environment(OUT_ENV)
	_trigger_path = _out_path + TRIGGER_SUFFIX
	_quit_after_window = OS.get_environment(QUIT_ENV) == "1"
	_menu = menu
	_menu.action_triggered.connect(_on_menu_action)
	# Written at once so a driver can confirm where user:// resolved before any save.
	_write()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		_record((now - _last_usec) / 1000.0)
	_last_usec = now
	if not _trigger_path.is_empty() and FileAccess.file_exists(_trigger_path):
		DirAccess.remove_absolute(_trigger_path)
		_triggered_save()


func _triggered_save() -> void:
	# The probe's listener runs inside emit(), after the shell's handler, so the
	# window it opens is the one this call's duration belongs to.
	_next_source = "trigger"
	var start := Time.get_ticks_usec()
	_menu.action_triggered.emit("save")
	var call_ms := (Time.get_ticks_usec() - start) / 1000.0
	_next_source = "menu"
	if not _open.is_empty():
		_open["save_call_ms"] = call_ms


func _on_menu_action(action: String) -> void:
	if action != "save":
		return
	if not _open.is_empty():
		_close()
	_open = {
		"source": _next_source,
		"opened_at_usec": Time.get_ticks_usec(),
		"save_call_ms": null,
		"baseline_ms": _recent.duplicate(),
		"frames_ms": [],
	}


func _record(frame_ms: float) -> void:
	_recent.append(frame_ms)
	if _recent.size() > PRE_FRAMES:
		_recent.pop_front()
	if _open.is_empty():
		return
	(_open["frames_ms"] as Array).append(frame_ms)
	if (_open["frames_ms"] as Array).size() >= POST_FRAMES:
		_close()


func _close() -> void:
	var frames: Array = _open["frames_ms"]
	var longest := 0.0
	var slow := 0
	for f in frames:
		longest = maxf(longest, float(f))
		if float(f) > SLOW_FRAME_MS:
			slow += 1
	var baseline_longest := 0.0
	for f in _open["baseline_ms"]:
		baseline_longest = maxf(baseline_longest, float(f))
	_open["longest_frame_ms"] = longest
	_open["frames_over_slow_ms"] = slow
	_open["baseline_longest_ms"] = baseline_longest
	_open["complete"] = frames.size() >= POST_FRAMES
	_windows.append(_open)
	_open = {}
	_write()
	if _quit_after_window:
		get_tree().quit()


func _write() -> void:
	var report := {
		"user_data_dir": OS.get_user_data_dir(),
		"pid": OS.get_process_id(),
		"slow_frame_ms": SLOW_FRAME_MS,
		"pre_frames": PRE_FRAMES,
		"post_frames": POST_FRAMES,
		"saves": _windows,
	}
	# Temp file then rename, so a polling driver never reads a half-written report.
	var tmp := _out_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("frame probe: cannot write %s" % tmp)
		return
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	DirAccess.rename_absolute(tmp, _out_path)
