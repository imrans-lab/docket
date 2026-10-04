extends RefCounted
class_name JSONLCheckedCommit
## Synchronous settle/bootstrap share one marker → replacement → retirement
## protocol. Caller holds FileLock. The background job retains its prefix/tail
## protocol. POSIX rename provides atomic visibility; Windows stages a backup
## with an absent-target window. Neither promises power-loss fsync durability.

## Bounded disk-failure seam; tests operate on actual temporary files.
static var stage_hook: Callable

static func replace(path: String, text: String, verify: Callable, write_hook: Callable = Callable()) -> Dictionary:
	var temp := ""
	var error := ""
	if not write_hook.is_valid():
		var written := DocketDBJsonl._write_temp(path, text)
		temp = str(written.path)
		error = str(written.error)
	if error.is_empty() and stage_hook.is_valid(): error = str(stage_hook.call("before_verify", path, temp))
	if error.is_empty(): error = str(verify.call())
	var sidecar := JSONLSidecar.path_for(path)
	if error.is_empty() and JSONLSidecar.has_content(sidecar):
		error = JSONLSidecar.append(sidecar, JSONLSidecar.settle_marker(text.sha256_text()))
	if error.is_empty() and stage_hook.is_valid(): error = str(stage_hook.call("before_rename", path, temp))
	var identity := ProjectOpenings.inspect(temp) if not temp.is_empty() else {}
	if error.is_empty():
		error = str(write_hook.call(path, text)) if write_hook.is_valid() else DocketDBJsonl._rename_over(temp, path)
	if not error.is_empty():
		if not temp.is_empty(): DirAccess.remove_absolute(temp)
		return {"error":error, "committed":false, "warning":""}
	var warning := str(stage_hook.call("after_rename", path, temp)) if stage_hook.is_valid() else ""
	if warning.is_empty(): warning = JSONLSidecar.remove(sidecar)
	if not warning.is_empty(): push_warning("JSONLCheckedCommit: " + warning)
	return {"error":"", "committed":true, "warning":warning, "identity":identity}
