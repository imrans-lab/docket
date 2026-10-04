extends SceneTree
## Prove the engine-selected user directory before fixture secret traffic.
func _initialize() -> void:
	var base := OS.get_cmdline_user_args()[0]
	var actual := ProjectSettings.globalize_path('user://').simplify_path()
	if not actual.is_absolute_path():
		actual = DirAccess.open('.').get_current_dir().path_join(actual).simplify_path()
	if not actual.begins_with(base + '/'):
		quit(1)
		return
	var marker := FileAccess.open('user://docket-fixture-userdir.txt', FileAccess.WRITE)
	if marker == null:
		quit(1)
		return
	marker.store_string('private fixture marker')
	marker.close()
	var report := FileAccess.open(base.path_join('userdir-report.json'), FileAccess.WRITE)
	if report == null:
		quit(1)
		return
	report.store_string(JSON.stringify(actual))
	report.close()
	quit(0)
