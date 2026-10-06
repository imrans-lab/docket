extends Node
class_name DocketHttpServer
## TCPServer-based HTTP server for MCP Streamable HTTP.
## Supports multiple .dct files loaded simultaneously.

var stdio: bool = false
var host_authority: DocketHostAuthority
var _stdio: DocketStdioTransport

var port: int = 3010
var dct_path: String = "docket.dct"
var dct_paths: Array = []  # Multiple --file paths
var external_db: DocketDB = null
var external_schema: Dictionary = {}
var external_state: AppState = null  # If set, tracks file changes

var _server: TCPServer
var _handler: McpHandler
var _registry: ToolRegistry
var _clients: Array = []
var _db: DocketDB
var _project_dbs: Dictionary = {}  # project_name → DocketDB
var _schema: Dictionary
var _next_lease_check_msec: int = 0

## Interval between checks of the memory-project owner lease.
const LEASE_CHECK_INTERVAL_MS := 5000


func _ready() -> void:
	if not stdio:
		_server = TCPServer.new()
		var err := _server.listen(port, "127.0.0.1")
		if err != OK:
			push_error("Failed to listen on port %d: %s" % [port, error_string(err)])
			return
		SessionProject.set_endpoint(port)

	if external_state != null:
		# GUI mode — track AppState, stay in sync on file changes
		_db = external_state.db
		_schema = external_state.schema
		_project_dbs = external_state.get_project_dbs()
		external_state.file_changed.connect(_on_file_changed)
	elif external_db != null:
		# Shared DB passed in without state tracking
		_db = external_db
		_schema = external_schema
	else:
		# Standalone headless mode — load schema and DB from files
		_schema = TypeRegistryBootstrap.effective_schema()

		# Merge CLI --file args with any previously persisted session paths
		var paths_to_load: Array = dct_paths.duplicate() if dct_paths.size() > 0 else ([] if stdio and dct_path.is_empty() else [dct_path])
		var saved_paths := UserPrefs.load_session() if DocketRuntimeState.may_restore_session() else PackedStringArray()
		for sp in saved_paths:
			if sp not in paths_to_load:
				paths_to_load.append(sp)
		if not TypeRegistryBootstrap.opening_refusal().is_empty(): paths_to_load.clear()
		for path in paths_to_load:
			var duplicate := ProjectOpenings.path_refusal(str(path), _project_dbs)
			if not duplicate.is_empty():
				printerr("Docket: %s" % duplicate)
				continue
			var loaded_db := _open_or_create_db(str(path))
			var refusal: String = ProjectOpenings.name_refusal(loaded_db.get_project_name() if not loaded_db.get_project_name().is_empty() else str(path).get_file().get_basename(), _project_dbs) if loaded_db else ""
			if refusal.is_empty() and loaded_db: refusal = SessionProject.admit(loaded_db)
			if not refusal.is_empty():
				loaded_db.close()
				printerr("Docket: %s" % refusal)
			elif loaded_db:
				var proj_name := loaded_db.get_project_name()
				if proj_name.is_empty():
					proj_name = str(path).get_file().get_basename()
					loaded_db.set_project_name(proj_name)
				TypeRegistryBootstrap.projects_opened = true
				_project_dbs[proj_name] = loaded_db
				if _db == null:
					_db = loaded_db  # First DB is primary
			else:
				# Never start up quietly serving nothing — an unopenable file
				# (conflict markers, corruption) must be visible on stderr.
				var reason := DocketDBJsonl.last_open_error
				if reason.is_empty():
					reason = "could not open %s" % path
				printerr("Docket: FAILED to load %s — %s" % [path, reason])

	_registry = ToolRegistry.new()
	_registry.init(_schema, _db, _project_dbs)

	# Project management callables
	if external_state != null:
		_registry.add_project_fn = _gui_add_project
		_registry.remove_project_fn = _gui_remove_project
		_registry.gui_open_fn = _gui_open
	else:
		_registry.add_project_fn = _headless_add_project
		_registry.remove_project_fn = _headless_remove_project
		# gui_open_fn left as invalid Callable — tool returns "GUI not available"

	_handler = McpHandler.new()
	_handler.init_with_registry(_registry)
	if stdio:
		_handler.host_authority = host_authority
		if host_authority != null:
			host_authority.schema_adopted = _adopt_schema
			host_authority.resolve_vault = _resolve_vault
			host_authority.bootstrap_project = _bootstrap_project

	if stdio:
		_stdio = DocketStdioTransport.new()
		Engine.print_to_stdout = true
		if _stdio.start() != OK:
			printerr("Docket: could not start stdin reader")
			DocketRuntimeState.quit(get_tree(), 2)
			set_process(false)

	# Cap frame rate to avoid busy-spinning the main loop
	if DisplayServer.get_name() == "headless" and not stdio:
		Engine.max_fps = 1
	else:
		Engine.max_fps = 30


func _exit_tree() -> void:
	DocketRuntimeState.prepare_shutdown()
	DocketDBJsonl.settle_projects(_project_dbs, false)
	MemoryProject.spill_on_exit(_project_dbs)
	SessionProject.release_all()


func _adopt_schema() -> void:
	_schema = TypeRegistryBootstrap.effective_schema()
	if external_state != null:
		external_state.schema = _schema
		external_state.file_changed.emit()
	_registry.update_db(_schema, _db, _project_dbs)


func _on_file_changed() -> void:
	if external_state == null:
		return
	_db = external_state.db
	_project_dbs = external_state.get_project_dbs()
	_registry.update_db(external_state.schema, _db, _project_dbs)


func _open_or_create_db(path: String) -> DocketDB:
	## Dispatch on the actual on-disk format, mirroring AppState.load_dct.
	## is_json_dct() only distinguishes "has a SQLite header" from "doesn't", so
	## it reports JSONL as legacy JSON and sends it to the wrong migrator.
	if DocketDBMemory.is_memory_path(path):
		return DocketDBMemory.create(path.trim_prefix(DocketDBMemory.PATH_SCHEME))
	if FileAccess.file_exists(path):
		match JSONLMigration.detect_format(path):
			"jsonl":
				return DocketDBJsonl.open_jsonl(path)
			"sqlite":
				var new_db := DocketDB.new()
				new_db.open(path)
				return new_db
			"json_v1":
				return DocketMigration.migrate(path)
			_:
				push_error("http_server: unknown file format for %s" % path)
				return null
	else:
		# New files are JSONL — matches the GUI and the documented default.
		return DocketDBJsonl.create_new_jsonl(path)


# -- Project management callables ------------------------------------------

func _gui_add_project(path: String) -> Dictionary:
	# file_changed fires synchronously → _on_file_changed syncs registry
	return external_state.add_project_result(path)


func _gui_remove_project(proj_name: String) -> Dictionary:
	return external_state.remove_project(proj_name)


func _gui_open(request: Dictionary) -> Dictionary:
	if request.get("focus", false):
		get_window().grab_focus()
		if request.size() == 1:
			return {"opened": "window", "pid": OS.get_process_id(), "focused": get_window().has_focus()}
	if request.has("id"):
		var project := str(request.get("project", ""))
		external_state.open_item_requested.emit(str(request.id), project)
		return {"opened": "item", "id": str(request.id), "project":project}
	elif request.has("filter"):
		var filter_str: String = str(request.get("filter", ""))
		var label: String = str(request.get("label", "MCP Query"))
		external_state.open_query_requested.emit(filter_str, label)
		return {"opened": "query", "label": label}
	return {"error": "Invalid request"}


func _headless_add_project(path: String) -> Dictionary:
	var refusal_before_open := TypeRegistryBootstrap.opening_refusal()
	if not refusal_before_open.is_empty(): return {"error":refusal_before_open}
	var duplicate := ProjectOpenings.path_refusal(path, _project_dbs)
	if not duplicate.is_empty(): return {"error":duplicate}
	DocketDBJsonl.last_open_error = ""
	var loaded_db := _open_or_create_db(path)
	var open_error := DocketDBJsonl.last_open_error
	if not loaded_db:
		return {"error": "Failed to open: %s" % path + (": %s" % open_error if not open_error.is_empty() else "")}
	var post_open_refusal := ProjectOpenings.path_refusal(path, _project_dbs)
	if not post_open_refusal.is_empty():
		loaded_db.close()
		return {"error":post_open_refusal}
	var proj_name := loaded_db.get_project_name()
	if proj_name.is_empty():
		proj_name = path.get_file().get_basename()
		loaded_db.set_project_name(proj_name)
	var existing: DocketDB = _project_dbs.get(proj_name)
	var replaces_memory := MemoryProject.is_persist_replacement(existing, loaded_db)
	var refusal := "" if replaces_memory else ProjectOpenings.name_refusal(proj_name, _project_dbs)
	if refusal.is_empty(): refusal = SessionProject.admit(loaded_db)
	if not refusal.is_empty():
		loaded_db.close()
		return {"error": refusal}
	if _db == null or (replaces_memory and _db == existing): _db = loaded_db
	TypeRegistryBootstrap.projects_opened = true
	_project_dbs[proj_name] = loaded_db
	_registry.update_db(_schema, _db, _project_dbs)
	_persist_headless_session()
	return ProjectOpenings.descriptor(proj_name, loaded_db, _db)


func _headless_remove_project(proj_name: String) -> Dictionary:
	if not _project_dbs.has(proj_name):
		return {"error": "Project not found: %s" % proj_name}
	var closing_db: DocketDB = _project_dbs[proj_name]
	closing_db.close()
	SessionProject.release(closing_db.get_path())
	_project_dbs.erase(proj_name)
	if closing_db == _db:
		if _project_dbs.size() > 0:
			_db = _project_dbs.values()[0]
		else:
			_db = null
	_registry.update_db(_schema, _db, _project_dbs)
	_persist_headless_session()
	return {"closed": proj_name, "remaining": _project_dbs.keys()}


func _persist_headless_session() -> void:
	## Persist current project paths so they survive server restarts.
	var paths := PackedStringArray()
	for db: DocketDB in _project_dbs.values():
		if not db is DocketDBMemory:
			paths.append(db.get_path())
	UserPrefs.save_session(paths)


func _process(_delta: float) -> void:
	# Idle-debounced settle of sidecar appends made through this server.
	if external_state != null:
		external_state.settle_projects()
	else:
		DocketDBJsonl.settle_projects(_project_dbs, true)
	if _registry == null:
		return
	if Time.get_ticks_msec() >= _next_lease_check_msec:
		_next_lease_check_msec = Time.get_ticks_msec() + LEASE_CHECK_INTERVAL_MS
		_registry.enforce_memory_lease()

	if stdio:
		if _stdio.poll(_handler, _post_request):
			DocketRuntimeState.quit(get_tree())
		return
	if _server == null or not _server.is_listening():
		return

	# Accept new connections
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer:
			_clients.append({"peer": peer, "buffer": "", "started": Time.get_ticks_msec()})

	# Process existing connections
	var to_remove: Array = []
	for i in range(_clients.size()):
		var client: Dictionary = _clients[i]
		var peer: StreamPeerTCP = client.peer
		peer.poll()

		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			to_remove.append(i)
			continue

		# Drop clients that take too long to send a complete request (30s)
		if Time.get_ticks_msec() - client.started > 30000:
			to_remove.append(i)
			continue

		var available := peer.get_available_bytes()
		if available > 0:
			var data := peer.get_data(available)
			if data[0] == OK:
				client.buffer += data[1].get_string_from_utf8()

			# Only process once headers AND full body have arrived
			if _request_complete(client.buffer):
				var response := _process_request(client.buffer)
				peer.put_data(response.to_utf8_buffer())
				to_remove.append(i)

	# Remove processed clients (reverse order)
	to_remove.reverse()
	for i in to_remove:
		_clients[i].peer.disconnect_from_host()
		_clients.remove_at(i)


func _request_complete(buffer: String) -> bool:
	## Check if the buffer contains a complete HTTP request (headers + full body).
	var sep := buffer.find("\r\n\r\n")
	if sep < 0:
		return false  # Headers not yet complete
	# Extract Content-Length from headers
	var header_section := buffer.substr(0, sep)
	var content_length := 0
	for line in header_section.split("\r\n"):
		if line.to_lower().begins_with("content-length:"):
			content_length = int(line.substr(line.find(":") + 1).strip_edges())
			break
	# Headers are ASCII so char offset == byte offset; body may be multi-byte
	var body_start := sep + 4
	var body_bytes := buffer.to_utf8_buffer().size() - body_start
	return body_bytes >= content_length


func _process_request(raw: String) -> String:
	var req = HttpParser.parse_request(raw)

	# Only handle POST /mcp
	if req.path != "/mcp":
		return HttpParser.format_response(404, {}, "{\"error\":\"Not found\"}")

	# Reject browser-originated requests before doing any work. Binding to
	# loopback is not a trust boundary on its own: a web page the user visits can
	# POST to 127.0.0.1, and DNS rebinding can turn that into reads too.
	var rejection := _reject_reason(req)
	if not rejection.is_empty():
		return HttpParser.format_response(
			403,
			{"Content-Type": "application/json", "X-Content-Type-Options": "nosniff"},
			JSON.stringify({"error": "Forbidden: %s" % rejection})
		)

	if req.method == "POST":
		return _handle_post(req)
	elif req.method == "DELETE":
		return HttpParser.format_response(200, {}, "{\"ok\":true}")
	else:
		return HttpParser.format_response(405, {}, "{\"error\":\"Method not allowed\"}")


# -- Local-origin enforcement -------------------------------------------------
#
# Docket's MCP endpoint has no credential: anything that can reach it can drive
# it. That is acceptable for a same-user local tool — such a process can already
# read the .dct files and docket_prefs.json directly — but it is NOT acceptable
# for a web page, which can reach loopback while having no filesystem access.
#
# These three checks close that gap without any user configuration:
#
#   Origin  — browsers always attach it to cross-origin requests; non-browser
#             MCP clients never send one. Its mere presence means "a web page".
#   Host    — pinning to loopback literals defeats DNS rebinding, where an
#             attacker-controlled name resolves to 127.0.0.1.
#   Type    — the three CORS "simple" content types are the only ones a browser
#             can send without a preflight. Refusing them forces a preflight we
#             never answer. Anything else, including no Content-Type at all, is
#             allowed, so a legitimate client is never locked out.

## Content types a browser can send cross-origin without a CORS preflight.
const _CORS_SIMPLE_TYPES := [
	"text/plain",
	"application/x-www-form-urlencoded",
	"multipart/form-data",
]


func _reject_reason(req: Dictionary) -> String:
	## Returns "" when the request may proceed, else a human-readable reason.
	var headers: Dictionary = req.get("headers", {})

	if headers.has("origin"):
		return "cross-origin requests are not accepted (Origin: %s)" % headers["origin"]

	# An absent Host is HTTP/1.0 or a hand-rolled client; loopback-bound, so allow.
	if headers.has("host"):
		var host: String = str(headers["host"]).to_lower()
		var hostname := ""
		if host.begins_with("["):
			# IPv6 literals are bracketed — "[::1]:3010". Splitting on ":" would
			# yield "[", so take everything through the closing bracket instead.
			var close := host.find("]")
			hostname = host.substr(0, close + 1) if close > 0 else host
		else:
			hostname = host.split(":")[0]
		if hostname not in ["127.0.0.1", "localhost", "[::1]", "::1"]:
			return "unexpected Host header '%s' — expected a loopback address" % host

	if headers.has("content-type"):
		# Strip any ";charset=..." parameter before comparing.
		var ctype: String = str(headers["content-type"]).to_lower().split(";")[0].strip_edges()
		if ctype in _CORS_SIMPLE_TYPES:
			return "Content-Type '%s' is not accepted; use application/json" % ctype

	return ""


func _handle_post(req: Dictionary) -> String:
	var body: String = req.body
	var parsed = JSON.parse_string(body)
	if parsed == null:
		var err_resp := {"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}
		return HttpParser.format_response(400, {"Content-Type": "application/json"}, JSON.stringify(err_resp))

	MemoryProject.renew_from_headers(req.get("headers", {}))
	var result = _handler.handle(parsed)

	_post_request()

	if result == null:
		# Notification — no response body needed
		return HttpParser.format_response(202, {}, "")

	return HttpParser.format_response(200, {"Content-Type": "application/json"}, JSON.stringify(result))


func _post_request() -> void:
	# Both transports checkpoint even valid notifications, before replying.
	var dbs: Array = _project_dbs.values()
	if _db != null and _db not in dbs:
		dbs.append(_db)
	for db: DocketDB in dbs:
		db.checkpoint()


func _resolve_vault(path: Variant) -> DocketDB:
	if not path is String or not path.is_absolute_path(): return null
	# Consult the live authoritative map, never a caller name or stored descriptor.
	var normalized := ProjectOpenings.normalized_path(path)
	var projects := external_state.get_project_dbs() if external_state != null else _project_dbs
	for db: DocketDB in projects.values():
		if ProjectOpenings.normalized_path(db.get_path()) == normalized:
			return db
	return null


func _bootstrap_project(path: String, shipment: String) -> Dictionary:
	# Preflight uses disk metadata without opening a cache or registering a project.
	# Existing metadata wins in the disk core; shipment metadata only seeds installs.
	var parsed := JSONLParser.parse_bytes(shipment.to_utf8_buffer(), "bootstrap shipment")
	var shipment_error := MasterBootstrapPlan._validate(parsed)
	if not shipment_error.is_empty():
		return DocketHostAuthority._error(-32602, "Bootstrap shipment refused: " + shipment_error)
	var projects := external_state.get_project_dbs() if external_state != null else _project_dbs
	var live: DocketDBJsonl
	var name := ""
	for key in projects:
		var db: DocketDB = projects[key]
		if ProjectOpenings.normalized_path(db.get_path()) != path: continue
		if not db is DocketDBJsonl or not db.is_open() or not db.get_write_block_reason().is_empty() or not FileAccess.file_exists(path):
			return DocketHostAuthority._error(-32602, "Bootstrap live project unavailable or read-only: %s (%s)" % [path, db.get_write_block_reason() if not db.get_write_block_reason().is_empty() else "not open or canonical missing"])
		live = db as DocketDBJsonl
		name = str(key)
		# Finish a worker before acquisition; sliced readers leave their WAL intact.
		var settle_error := live.finish_settle()
		if not settle_error.is_empty():
			return DocketHostAuthority._error(-32602, "Bootstrap pending settle refused: %s (%s)" % [path, settle_error])
		break
	if live == null:
		var physical_refusal := ProjectOpenings.path_refusal(path, projects)
		if not physical_refusal.is_empty(): return DocketHostAuthority._error(-32602, physical_refusal)
		var metadata: Dictionary = parsed.meta
		if FileAccess.file_exists(path):
			var source := JSONLCache.read_source(path)
			var source_error := JSONLCache.last_error if source.is_empty() else MasterBootstrapPlan._validate(source.parsed)
			if not source_error.is_empty():
				return DocketHostAuthority._error(-32602, "Bootstrap current project refused: %s (%s)" % [path, source_error])
			metadata = source.parsed.meta
		name = str(metadata.get("project", ""))
		if name.is_empty(): name = path.get_file().get_basename()
		if not ProjectOpenings.name_refusal(name, projects).is_empty():
			return DocketHostAuthority._error(-32602, "Bootstrap project name already loaded: %s (%s)" % [name, path])
		if metadata.get(SessionProject.META_KEY) == SessionProject.MODE_SESSION_FILE:
			var owner := SessionProject.read_owner(path)
			var pid := int(owner.get("pid", 0))
			if not SessionProject.path_error(path).is_empty() or (pid > 0 and pid != OS.get_process_id() and FileLock.is_pid_running(pid)):
				return DocketHostAuthority._error(-32602, "Bootstrap session admission refused: %s (%s)" % [path, SessionProject.path_error(path) if not SessionProject.path_error(path).is_empty() else "owned by another live process"])
	var opening_error := ProjectOpenings.opening_refusal(live) if live != null else ""
	if not opening_error.is_empty():
		return DocketHostAuthority._error(-32602, opening_error)
	var report := MasterBootstrapApply.apply(path, shipment, TypeRegistryBootstrap.effective_schema(), live.get_meta("physical_opening", {}) if live != null else {})
	if report.status == "refused":
		return DocketHostAuthority._error(-32602, "Bootstrap disk apply refused: " + str(report.error))
	if live != null:
		if not live.reload(): return _bootstrap_committed_failure(report, "reload", name, live)
		if not ProjectOpenings.accept_replacement(live, report.get("identity", {})).is_empty():
			return _bootstrap_committed_failure(report, "identity", name, live)
		# Refresh the shared registry in place, preserving primary and map bindings.
		var registry := external_state.get_type_registry(name) if external_state != null else _registry.get_type_registry(name)
		if registry == null or not registry.get_diagnostic().is_empty():
			return _bootstrap_committed_failure(report, "registry", name, live)
		if external_state != null: external_state.data_changed.emit()
		report["project"] = ProjectOpenings.descriptor(name, live, external_state.db if external_state != null else _db)
	else:
		var opened := _gui_add_project(path) if external_state != null else _headless_add_project(path)
		if opened.has("error"): return _bootstrap_committed_failure(report, "open")
		report["project"] = opened
	return {"result":report}


func _bootstrap_committed_failure(report: Dictionary, stage: String, name: String = "", live: DocketDB = null) -> Dictionary:
	# Disk replacement has happened: preserve its report, never imply rollback.
	report["disk_committed"] = true
	report["live_status"] = "unavailable"
	report["failure_stage"] = stage
	if live != null:
		report["project"] = ProjectOpenings.descriptor(name, live, external_state.db if external_state != null else _db)
	return {"error":{"code":-32603, "message":"Bootstrap committed; live project unavailable", "data":report}}
