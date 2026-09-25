extends RefCounted
class_name AppState
## Centralized state container for the Docket GUI.
## Holds schema, db(s), dct_path. Emits signals on file/data changes.
## Supports multiple loaded .dct projects simultaneously.

signal file_changed
signal data_changed
## Emitted when a .dct could not be opened (e.g. unresolved conflict markers).
## Carries the path and a human-readable reason.
signal load_failed(path: String, reason: String)
@warning_ignore("unused_signal")
signal open_item_requested(id: String, project: String)
@warning_ignore("unused_signal")
signal open_query_requested(filter: String, label: String)

var schema: Dictionary
var db: DocketDB  # Primary DB (first loaded)
var dct_path: String
var prefs: UserPrefs

# Multi-project support: selector → DocketDB (see ProjectSelectors)
var _project_dbs: Dictionary = {}
var _type_registries: Dictionary = {}
var registry_diagnostics: Dictionary = {}
var last_cross_project_query_error: String = ""
## Why a project could not be read as its file when reload_stale last looked
## ({ok: false, kind, project, message, retryable}, ProjectAdmission), or {}:
## for display only, never for admission.
var readiness_failure: Dictionary = {}


func load_dct(path: String) -> void:
	var located := _located(path, false)
	if located.is_empty():
		return
	path = located.path
	dct_path = path
	if db:
		db.close()
		db = null
	_project_dbs.clear()
	_type_registries.clear()
	registry_diagnostics.clear()

	if FileAccess.file_exists(path):
		match JSONLMigration.detect_format(path):
			"jsonl":
				db = DocketDBJsonl.open_jsonl(path)
			"sqlite":
				db = DocketDB.new()
				db.open(path)
			"json_v1":
				db = DocketMigration.migrate(path)
			_:
				push_error("AppState: unknown file format for %s" % path)
				load_failed.emit(path, "Unknown file format.")
				return
	else:
		# Default new files to JSONL format
		db = DocketDBJsonl.create_new_jsonl(path)

	# A refused open (conflict markers, corrupt file) must not fall through:
	# registering a null db crashes downstream, and creating a fresh one here
	# would overwrite the file the user still needs to repair.
	if db == null:
		var reason := DocketDBJsonl.last_open_error
		if reason.is_empty():
			reason = "Could not open %s." % path
		push_error("AppState: %s" % reason)
		dct_path = ""
		load_failed.emit(path, reason)
		return

	var registered := ProjectSelectors.register(_project_dbs, db, path)
	if registered.has("error"):
		push_error("AppState: %s" % registered.error)
		db = null
		dct_path = ""
		load_failed.emit(path, str(registered.error))
		return
	_type_registries[registered.selector] = _registry_for(db, registered.selector)

	file_changed.emit()


# `path` located (ProjectFile.locate), or {} when it cannot be, or when a
# file to be created already exists there (creating never replaces a file):
# load_failed then says why.
func _located(path: String, creating: bool) -> Dictionary:
	var located := ProjectFile.locate(path)
	if not located.has("error") and creating and located.has("id"):
		located = {"error": "%s already exists; open it instead" % path}
	if located.has("error"):
		push_error("AppState: %s" % located.error)
		load_failed.emit(path, str(located.error))
		return {}
	return located


func add_project(path: String) -> void:
	## Load an additional .dct project without closing the primary; a file
	## already open stays as it is.
	var located := _located(path, false)
	if located.is_empty():
		return
	path = located.path
	if not ProjectSelectors.selector_for(_project_dbs, located).is_empty():
		return
	var new_db: DocketDB
	if FileAccess.file_exists(path):
		match JSONLMigration.detect_format(path):
			"jsonl":
				new_db = DocketDBJsonl.open_jsonl(path)
			"sqlite":
				new_db = DocketDB.new()
				new_db.open(path)
			"json_v1":
				new_db = DocketMigration.migrate(path)
			_:
				push_error("AppState: unknown file format for %s" % path)
				load_failed.emit(path, "Unknown file format.")
				return
	else:
		# Default new files to JSONL format
		new_db = DocketDBJsonl.create_new_jsonl(path)

	if new_db == null:
		var reason := DocketDBJsonl.last_open_error
		if reason.is_empty():
			reason = "Could not open %s." % path
		push_error("AppState: %s" % reason)
		load_failed.emit(path, reason)
		return

	if new_db.get_project_name().is_empty():
		new_db.set_project_name(path.get_file().get_basename())
	var proj_name := new_db.get_project_name()

	# Resolve ID prefix collisions by appending chars from project name. A
	# project stored under the same name (a copy) keeps its prefix: opening it
	# changes nothing in it.
	var new_prefix := new_db.get_id_prefix()
	var collides := func() -> bool:
		for existing_name in _project_dbs:
			var existing_db: DocketDB = _project_dbs[existing_name]
			if existing_db.get_id_prefix() == new_prefix and existing_db.get_project_name() != proj_name:
				return true
		return false
	if collides.call():
		# Try alternative prefixes using more of the project name
		var upper := proj_name.to_upper().replace("-", "").replace("_", "").replace(" ", "")
		var resolved := false
		for i in range(3, upper.length()):
			new_prefix = upper.substr(0, i).right(3)
			var still_collides := false
			for existing_name in _project_dbs:
				var existing_db: DocketDB = _project_dbs[existing_name]
				if existing_db.get_id_prefix() == new_prefix and existing_db.get_project_name() != proj_name:
					still_collides = true
					break
			if not still_collides:
				resolved = true
				break
		if not resolved:
			# Last resort: append digit
			for digit in range(2, 10):
				new_prefix = new_db.get_id_prefix().left(2) + str(digit)
				var still_collides := false
				for existing_name in _project_dbs:
					var existing_db: DocketDB = _project_dbs[existing_name]
					if existing_db.get_id_prefix() == new_prefix and existing_db.get_project_name() != proj_name:
						still_collides = true
						break
				if not still_collides:
					resolved = true
					break
		if new_prefix != new_db.get_id_prefix():
			new_db.set_id_prefix(new_prefix)

	var registered := ProjectSelectors.register(_project_dbs, new_db, path)
	if registered.has("error"):
		push_error("AppState: %s" % registered.error)
		load_failed.emit(path, str(registered.error))
		return
	_type_registries[registered.selector] = _registry_for(new_db, registered.selector)

	file_changed.emit()


func get_project_dbs() -> Dictionary:
	return _project_dbs


# The type registry of `project_db`, open under `selector`, checking the
# references it writes against the open projects.
func _registry_for(project_db: DocketDB, selector: String) -> TypeRegistry:
	var registry := TypeRegistry.for_db(project_db, selector)
	registry.references = ProjectSelectors.reference_checker(_project_dbs)
	return registry


## The selector of the primary project, or "" when none is open.
func primary_selector() -> String:
	for selector in _project_dbs:
		if _project_dbs[selector] == db:
			return str(selector)
	return ""


func get_type_registry(project_name: String = "") -> TypeRegistry:
	var key: String = project_name if not project_name.is_empty() else primary_selector()
	var registry: TypeRegistry = _type_registries.get(key)
	if registry == null and _project_dbs.has(key):
		registry = _registry_for(_project_dbs[key], key)
		_type_registries[key] = registry
	if registry != null:
		var error: String = registry.refresh_if_changed()
		if error.is_empty(): registry_diagnostics.erase(key)
		else: registry_diagnostics[key] = error
	return registry


func get_db_for_project(project_name: String) -> DocketDB:
	return _project_dbs.get(project_name)

func promote_project_to_jsonl(project_name: String, exclusive_writer_confirmed: bool) -> Dictionary:
	if not exclusive_writer_confirmed:
		return {"success":false,"error":"confirm exclusive promotion workflow with incompatible writers stopped"}
	if not _project_dbs.has(project_name):
		return {"success":false,"error":"project is no longer open"}
	var old_db: DocketDB = _project_dbs[project_name]
	if old_db is DocketDBJsonl:
		return {"success":false,"error":"project is already JSONL"}
	var replaced := old_db.file_replacement()
	if not replaced.is_empty():
		return {"success":false,"error":replaced}
	var path: String = old_db.get_path()
	var was_primary: bool = old_db == db
	old_db.close()
	var result: Dictionary = JSONLMigration.migrate_to_jsonl(path)
	result["path"] = path
	var reopened: DocketDB
	if JSONLMigration.detect_format(path) == "jsonl":
		reopened = DocketDBJsonl.open_jsonl(path)
	elif JSONLMigration.detect_format(path) == "sqlite":
		reopened = DocketDB.new()
		if not reopened.open(path):
			reopened = null
	if reopened != null and not reopened.bind_file(path).is_empty():
		reopened.close()
		reopened = null
	if reopened == null:
		_project_dbs.erase(project_name)
		_type_registries.erase(project_name)
		if was_primary:
			db = null
		result["success"] = false
		result["error"] = str(result.get("error", "")) + ("; " if not str(result.get("error", "")).is_empty() else "") + "project could not be reopened"
		file_changed.emit()
		result["actual_format"] = JSONLMigration.detect_format(path)
		result["project_open"] = false
		return result
	_project_dbs[project_name] = reopened
	_type_registries[project_name] = _registry_for(reopened, project_name)
	if was_primary:
		db = reopened
		dct_path = path
	file_changed.emit()
	result["actual_format"] = JSONLMigration.detect_format(path)
	result["project_open"] = true
	result["active_path"] = reopened.get_path()
	return result

func upgrade_project_to_jsonl_v2(project_name: String, preview: Dictionary, exclusive_writer_confirmed: bool) -> Dictionary:
	if not _project_dbs.has(project_name):
		return {"ok":false,"error":"project is no longer open"}
	var old_db: DocketDB = _project_dbs[project_name]
	if not old_db is DocketDBJsonl:
		return {"ok":false,"error":"legacy SQLite must be explicitly promoted to JSONL first"}
	var replaced := old_db.file_replacement()
	if not replaced.is_empty():
		return {"ok":false,"error":replaced}
	var path: String = old_db.get_path()
	var was_primary: bool = old_db == db
	old_db.close()
	var result: Dictionary = JSONLTypeUpgrade.apply(path, preview, schema, exclusive_writer_confirmed)
	var reopened: DocketDBJsonl = DocketDBJsonl.open_jsonl(path)
	if reopened != null and not reopened.bind_file(path).is_empty():
		reopened.close()
		reopened = null
	if reopened == null:
		_project_dbs.erase(project_name)
		_type_registries.erase(project_name)
		if was_primary:
			db = null
		result.ok = false
		result.error = str(result.get("error", "")) + ("; " if not str(result.get("error", "")).is_empty() else "") + "project could not be reopened"
		file_changed.emit()
		result["actual_format"] = JSONLMigration.detect_format(path)
		result["project_open"] = false
		return result
	_project_dbs[project_name] = reopened
	_type_registries[project_name] = _registry_for(reopened, project_name)
	if was_primary:
		db = reopened
		dct_path = path
	file_changed.emit()
	result["actual_format"] = JSONLMigration.detect_format(path)
	result["project_open"] = true
	result["active_path"] = reopened.get_path()
	result["registry_legacy"] = _type_registries[project_name].is_legacy()
	return result


func find_item_db(id: String) -> DocketDB:
	## Search all loaded project DBs for an item by ID.
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb.has_item(id):
			return pdb
	return null


func get_project_name_for_item(id: String) -> String:
	## Return the project name that owns this item ID.
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb.has_item(id):
			return proj_name
	return ""


func remove_project(project_name: String) -> Dictionary:
	## Close and remove a project. Zero open projects is allowed.
	if not _project_dbs.has(project_name):
		return {"error": "Project not found: %s" % project_name}

	var closing_db: DocketDB = _project_dbs[project_name]
	closing_db.close()
	_project_dbs.erase(project_name)
	_type_registries.erase(project_name)
	registry_diagnostics.erase(project_name)

	# If we just closed the primary, promote the next one or clear
	if closing_db == db:
		if _project_dbs.size() > 0:
			var first_name: String = _project_dbs.keys()[0]
			db = _project_dbs[first_name]
			dct_path = db.get_path()
		else:
			db = null
			dct_path = ""

	file_changed.emit()
	return {"closed": project_name, "remaining": _project_dbs.keys()}


func find_children_across_projects(qualified_id: String) -> Array:
	## Search ALL loaded projects for items whose parent is item `qualified_id`
	## ("project:id", the project as its selector). A stored parent reference
	## names the parent's project by its stored name, so it counts only where
	## that name reads back as the parent's project; bare legacy parent IDs
	## belong only to the project that owns the parent.
	var parsed := DocketDB.parse_qualified_ref(qualified_id)
	var bare_id: String = parsed.id
	var owner_project: String = str(parsed.get("project", ""))
	var stored_ref := qualified_id
	if _project_dbs.has(owner_project):
		stored_ref = "%s:%s" % [(_project_dbs[owner_project] as DocketDB).get_project_name(), bare_id]
	var results: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		var parent_filters: Array = []
		var read_back := ProjectSelectors.resolve_reference(_project_dbs, str(DocketDB.parse_qualified_ref(stored_ref).project), str(proj_name))
		if owner_project.is_empty() or read_back.get("selector", "") == owner_project:
			parent_filters.append({"field":"parent", "op":"eq", "value":stored_ref})
		if owner_project.is_empty() or str(proj_name) == owner_project:
			parent_filters.append({"field":"parent", "op":"eq", "value":bare_id})
		if parent_filters.is_empty():
			continue
		var rows: Array = pdb.execute_query({"filter":{"$or":parent_filters}})
		for item in rows:
			item["project"] = proj_name
		results.append_array(rows)
	return results


func move_item(item_id: String, target_project: String, source_project: String = "") -> Dictionary:
	## The shared transfer path enforces source identity, registry pins and durable write order.
	return DocketMove.new().execute({"id":item_id,"target_project":target_project,"source_project":source_project}, schema, db, _project_dbs)


func create_dct(path: String) -> void:
	var located := _located(path, true)
	if located.is_empty():
		return
	path = located.path
	dct_path = path
	if db:
		db.close()
		db = null
	_project_dbs.clear()
	_type_registries.clear()
	registry_diagnostics.clear()
	# Default new dockets to JSONL format
	db = DocketDBJsonl.create_new_jsonl(path)
	var registered := ProjectSelectors.register(_project_dbs, db, path)
	if registered.has("error"):
		push_error("AppState: %s" % registered.error)
		db = null
		dct_path = ""
		load_failed.emit(path, str(registered.error))
		return
	_type_registries[registered.selector] = _registry_for(db, registered.selector)
	file_changed.emit()


func create_and_add_project(path: String) -> void:
	## Create a new .dct and add it alongside existing projects (does NOT replace).
	var located := _located(path, true)
	if located.is_empty():
		return
	path = located.path
	# Default new dockets to JSONL format
	var new_db := DocketDBJsonl.create_new_jsonl(path)
	if new_db == null:
		return
	if new_db.get_project_name().is_empty():
		new_db.set_project_name(path.get_file().get_basename())
	var proj_name := new_db.get_project_name()

	# Warn on prefix collision
	var new_prefix := new_db.get_id_prefix()
	for existing_name in _project_dbs:
		var existing_db: DocketDB = _project_dbs[existing_name]
		if existing_db.get_id_prefix() == new_prefix and existing_db.get_project_name() != proj_name:
			push_warning("DocketDB: ID prefix '%s' in project '%s' collides with '%s'" % [new_prefix, proj_name, existing_name])

	var registered := ProjectSelectors.register(_project_dbs, new_db, path)
	if registered.has("error"):
		push_error("AppState: %s" % registered.error)
		load_failed.emit(path, str(registered.error))
		return
	_type_registries[registered.selector] = _registry_for(new_db, registered.selector)
	file_changed.emit()


## A ProjectQuery over the open projects.
func project_query() -> ProjectQuery:
	return ProjectQuery.new(_project_dbs, get_type_registry)


## Run a query across all loaded projects (ProjectQuery.run_across); a
## failure leaves its reason in last_cross_project_query_error.
func execute_cross_project_query(query: Dictionary, detail: String = "full") -> Array:
	var runner := project_query()
	var rows := runner.run_across(query, detail)
	last_cross_project_query_error = runner.last_error
	return rows


func reload_stale() -> Array:
	## Reload any JSONL-backed project whose file changed on disk (git pull,
	## another Docket instance, the MCP server). Returns names reloaded, or
	## whose type definitions changed. One that cannot be (ProjectAdmission)
	## is kept in readiness_failure, its type registry left as it was.
	var reloaded: Array = []
	readiness_failure = {}
	for proj_name in _project_dbs:
		var access := ProjectAdmission.access({proj_name: _project_dbs[proj_name]}, func(read_again: Array) -> Array:
			return _refresh_registries([proj_name], read_again))
		if access.ok:
			reloaded.append_array(access.value)
		else:
			registry_diagnostics[proj_name] = str(access.message)
			if readiness_failure.is_empty(): readiness_failure = access
	return reloaded


## `work` run once every open project is admitted (ProjectAdmission), their
## type registries refreshed first: ProjectAdmission.access's result.
func access(work: Callable) -> Dictionary:
	return ProjectAdmission.access(_project_dbs, func(read_again: Array) -> Variant:
		_refresh_registries(_project_dbs.keys(), read_again)
		return work.call() if work.is_valid() else null)


# The type registries of `admitted` projects follow their databases: one
# read again is reloaded, the others refreshed if their definitions
# changed. The names whose registries changed.
func _refresh_registries(admitted: Array, read_again: Array) -> Array:
	var changed: Array = []
	for proj_name in admitted:
		var registry: TypeRegistry = _type_registries.get(proj_name)
		if registry == null: continue
		var previous_generation: String = registry.get_generation_token()
		var error: String = registry.reload() if proj_name in read_again else registry.refresh_if_changed()
		if not error.is_empty(): registry_diagnostics[proj_name] = error
		else:
			registry_diagnostics.erase(proj_name)
			if proj_name in read_again or registry.get_generation_token() != previous_generation: changed.append(proj_name)
	return changed


## Changes whenever an open project is read again from its file, or a
## project is opened or closed (DocketSource.reload_revision).
func reload_revision() -> String:
	var parts: PackedStringArray = []
	for selector in _project_dbs:
		var pdb: DocketDB = _project_dbs[selector]
		parts.append("%s:%d:%d" % [selector, pdb.get_instance_id(), (pdb as DocketDBJsonl).reload_revision if pdb is DocketDBJsonl else 0])
	return "|".join(parts)


func reload_all() -> Array:
	## Unconditionally re-read every JSONL project from disk, discarding cache.
	## Backs File > Reload from Disk and the docket_reload MCP tool.
	var reloaded: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb is DocketDBJsonl:
			var loaded: bool = (pdb as DocketDBJsonl).reload()
			var registry: TypeRegistry = _type_registries[proj_name]
			var error: String = registry.reload() if loaded else registry.refresh_if_changed()
			if not loaded and error.is_empty():
				error = (pdb as DocketDBJsonl).last_write_error
				if error.is_empty(): error = "canonical project could not be reloaded"
			if error.is_empty():
				registry_diagnostics.erase(proj_name)
				reloaded.append(proj_name)
			else: registry_diagnostics[proj_name] = error
	if not reloaded.is_empty():
		data_changed.emit()
	return reloaded


func flush_all() -> Array:
	## Force every JSONL project to serialize to disk. Writes are already
	## immediate, so this is a no-op in practice — it exists as an explicit
	## "settle the file before I commit" step.
	var flushed: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb is DocketDBJsonl:
			(pdb as DocketDBJsonl).flush()
			flushed.append(proj_name)
	return flushed


func save() -> void:
	# JSONL writes happen on every mutation, so this is belt-and-braces — but
	# it does now actually write, rather than only emitting a signal.
	flush_all()
	data_changed.emit()


func load_schema() -> void:
	var sf := FileAccess.open("res://data/schema.json", FileAccess.READ)
	schema = JSON.parse_string(sf.get_as_text())
	prefs = UserPrefs.load_prefs()
