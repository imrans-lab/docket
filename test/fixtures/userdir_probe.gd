extends SceneTree
## Prove the engine-selected user directory before fixture secret traffic.
func _initialize() -> void:
	quit(0 if check(OS.get_cmdline_user_args()[0]) else 1)

static func check(base: String) -> bool:
	var actual := ProjectSettings.globalize_path('user://').simplify_path()
	if not actual.is_absolute_path():
		actual = DirAccess.open('.').get_current_dir().path_join(actual).simplify_path()
	if not actual.begins_with(base + '/'):
		return false
	var marker := FileAccess.open('user://docket-fixture-userdir.txt', FileAccess.WRITE)
	if marker == null:
		return false
	marker.store_string('private fixture marker')
	marker.close()
	var report := FileAccess.open(base.path_join('userdir-report.json'), FileAccess.WRITE)
	if report == null:
		return false
	report.store_string(JSON.stringify(actual))
	report.close()
	return true
