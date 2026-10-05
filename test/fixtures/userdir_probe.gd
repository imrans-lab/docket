extends SceneTree
## Prove the engine-selected user directory before fixture secret traffic.
func _initialize() -> void:
	quit(0 if check(OS.get_cmdline_user_args()[0]) else 1)

static func check(base: String) -> bool:
	base = base.replace("\\", "/").simplify_path()
	var actual := ProjectSettings.globalize_path('user://').simplify_path()
	if not actual.is_absolute_path():
		actual = DirAccess.open('.').get_current_dir().path_join(actual).simplify_path()
	if not actual.begins_with(base + '/'):
		return _refuse("outside_base", actual)
	if OS.get_name() == "macOS":
		var app := OS.get_executable_path().get_base_dir().get_base_dir().get_base_dir()
		if app.ends_with(".app") and (actual == app or actual.begins_with(app + "/")):
			return _refuse("inside_app", actual)
	var marker := FileAccess.open('user://docket-fixture-userdir.txt', FileAccess.WRITE)
	if marker == null:
		return _refuse("marker_write", actual)
	marker.store_string('private fixture marker')
	marker.close()
	var report := FileAccess.open(base.path_join('userdir-report.json'), FileAccess.WRITE)
	if report == null:
		return _refuse("report_write", actual)
	report.store_string(JSON.stringify(actual))
	report.close()
	return true

static func _refuse(reason: String, actual: String) -> bool:
	printerr("USERDIR_PROBE_REFUSAL reason=" + reason)
	printerr("USERDIR_PROBE_ACTUAL path=" + actual)
	return false
