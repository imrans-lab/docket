extends Node
class_name DocketHttpServer
## MCP server over one of two transports, sharing the projects, tool registry
## and JSON-RPC handler:
##   - "http": TCPServer-based MCP Streamable HTTP (POST /mcp on 127.0.0.1);
##   - "stdio": newline-delimited JSON-RPC on stdin/stdout, for a host that
##     runs Docket as its child process. Only responses and notifications
##     reach stdout then (run Godot with --no-header to keep its banner off
##     it; --quiet would silence every reply, so stdio refuses it;
##     project.godot flushes stdout on every print, so each line is sent);
##     the process exits when the host closes stdin.
## Supports multiple .dct files loaded simultaneously.

## Method and event name of the host notifications sent with host_events.
const HOST_EVENT_METHOD := "minerva/plugin_event"
const ITEM_CHANGED_EVENT := "item_changed"
## How often (ms) the stdio server checks for changes made to a project file
## by another process.
const STALE_CHECK_MS := 2000
## Longest stdio request line accepted (bytes); a longer one is dropped and
## answered with an error, so a runaway writer cannot exhaust memory.
const MAX_STDIO_LINE_BYTES := 64 * 1024 * 1024

var transport: String = "http"
## With the stdio transport: send a HOST_EVENT_METHOD notification for every
## item change a project commits (ITEM_CHANGED_EVENT, see _on_items_changed).
var host_events: bool = false
## Run by a host that decides which projects are open: only dct_paths are
## opened at start (none is a healthy empty server), and the standalone
## session (UserPrefs) is neither restored nor saved.
var host_managed: bool = false
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
var _project_dbs: Dictionary = {}  # selector → DocketDB (ProjectSelectors)
var _schema: Dictionary
# stdio: lines read by the stdin thread, waiting for the main thread.
var _stdin_thread: Thread
var _stdin_lock := Mutex.new()
var _stdin_lines: Array[String] = []
var _stdin_closed := false
var _next_stale_check := 0


func _ready() -> void:
	if transport == "stdio":
		# --quiet/-q (or application/run/disable_stdout) turns print_to_stdout
		# off; the engine strips the flag from OS.get_cmdline_args.
		if not Engine.print_to_stdout:
			printerr("Docket: --stdio cannot run with --quiet, which silences its replies; use --no-header")
			set_process(false)
			get_tree().quit(1)
			return
		_stdin_thread = Thread.new()
		if _stdin_thread.start(_read_stdin) != OK:
			printerr("Docket: could not start the stdin reader for --stdio")
			set_process(false)
			get_tree().quit(1)
			return
	else:
		_server = TCPServer.new()
		var err := _server.listen(port, "127.0.0.1")
		if err != OK:
			push_error("Failed to listen on port %d: %s" % [port, error_string(err)])
			return
	_open_projects()


## The projects to serve, the tool registry over them, and the handler.
func _open_projects() -> void:
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
		# Standalone headless mode — the schema this process reads projects by
		# (a host may declare its own before opening any), and DBs from files
		_schema = TypeRegistryBootstrap.effective_schema()

		var paths_to_load: Array = dct_paths.duplicate()
		if not host_managed:
			# Merge CLI --file args with any previously persisted session paths
			if paths_to_load.is_empty():
				paths_to_load.append(dct_path)
			for sp in UserPrefs.load_session():
				if sp not in paths_to_load:
					paths_to_load.append(sp)
		for path in paths_to_load:
			# A host names files that exist; a missing one is its mistake to
			# see, not a new project to create.
			if host_managed and not FileAccess.file_exists(str(path)):
				printerr("Docket: FAILED to load %s — no such file" % path)
				continue
			var located := ProjectFile.locate(str(path))
			if located.has("error"):
				printerr("Docket: FAILED to load %s — %s" % [path, located.error])
				continue
			if not ProjectSelectors.selector_for(_project_dbs, located).is_empty():
				continue  # the same file named twice
			var loaded_db := _open_or_create_db(located.path)
			if loaded_db:
				var registered := _register_project(loaded_db, located.path)
				if registered.has("error"):
					printerr("Docket: FAILED to load %s — %s" % [path, registered.error])
			else:
				# Never start up quietly serving nothing — an unopenable file
				# (conflict markers, corruption) must be visible on stdout.
				var reason := DocketDBJsonl.last_open_error
				if reason.is_empty():
					reason = "could not open %s" % path
				printerr("Docket: FAILED to load %s — %s" % [path, reason])

	_registry = ToolRegistry.new()
	_registry.init(_schema, _db, _project_dbs)
	_registry.allow_no_project = host_managed

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
	# Only a host running this process as its child can have given it the
	# panel secret; any other run just drops it from the environment.
	if transport == "stdio":
		_handler.panel_authority = McpHandler.PanelAuthority.from_environment(_registry)
	else:
		OS.unset_environment(McpHandler.PanelAuthority.SECRET_VARIABLE)
	for proj_name in _project_dbs:
		_watch_project(proj_name, _project_dbs[proj_name])

	# Cap frame rate to avoid busy-spinning the main loop. A stdio host waits
	# on each reply, which is read once a frame.
	if DisplayServer.get_name() == "headless" and transport != "stdio":
		Engine.max_fps = 1
	else:
		Engine.max_fps = 30


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
	var located := ProjectFile.locate(path)
	if located.has("error"):
		return located
	var open_as := ProjectSelectors.selector_for(external_state.get_project_dbs(), located)
	if not open_as.is_empty():
		return ProjectSelectors.describe(external_state.get_project_dbs(), open_as, _db).merged({"already_open": true})
	external_state.add_project(located.path)
	# file_changed fires synchronously → _on_file_changed syncs registry
	var added := ProjectSelectors.selector_for(external_state.get_project_dbs(), {"path": located.path})
	if added.is_empty():
		return {"error": "Failed to open: %s" % path}
	return ProjectSelectors.describe(external_state.get_project_dbs(), added, _db)


func _gui_remove_project(proj_name: String) -> Dictionary:
	return external_state.remove_project(proj_name)


func _gui_open(request: Dictionary) -> Dictionary:
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


## Opens the project at `path` under a selector of its own (a file already
## open is that project again, not a second opening): its description, with
## already_open when it was open, or {error}.
func _headless_add_project(path: String) -> Dictionary:
	var located := ProjectFile.locate(path)
	if located.has("error"):
		return located
	var open_as := ProjectSelectors.selector_for(_project_dbs, located)
	if not open_as.is_empty():
		return ProjectSelectors.describe(_project_dbs, open_as, _db).merged({"already_open": true})
	var loaded_db := _open_or_create_db(located.path)
	if not loaded_db:
		return {"error": "Failed to open: %s" % path}
	var registered := _register_project(loaded_db, located.path)
	if registered.has("error"):
		return registered
	_schema = TypeRegistryBootstrap.effective_schema()
	_registry.update_db(_schema, _db, _project_dbs)
	_watch_project(registered.selector, loaded_db)
	_persist_headless_session()
	return ProjectSelectors.describe(_project_dbs, registered.selector, _db)


# `loaded_db` under a new selector (see ProjectSelectors.register); the first
# project is the primary.
func _register_project(loaded_db: DocketDB, path: String) -> Dictionary:
	var registered := ProjectSelectors.register(_project_dbs, loaded_db, path)
	if not registered.has("error") and _db == null:
		_db = loaded_db
	return registered


func _headless_remove_project(proj_name: String) -> Dictionary:
	if not _project_dbs.has(proj_name):
		return {"error": "Project not found: %s" % proj_name}
	var closing_db: DocketDB = _project_dbs[proj_name]
	if _handler.panel_authority != null:
		_handler.panel_authority.revoke_opening(str(closing_db.get_instance_id()))
	closing_db.close()
	_project_dbs.erase(proj_name)
	if closing_db == _db:
		if _project_dbs.size() > 0:
			_db = _project_dbs.values()[0]
		else:
			_db = null
	_schema = TypeRegistryBootstrap.effective_schema()
	_registry.update_db(_schema, _db, _project_dbs)
	_persist_headless_session()
	return {"closed": proj_name, "remaining": _project_dbs.keys()}


func _persist_headless_session() -> void:
	## Persist current project paths so they survive server restarts; a
	## host-managed server leaves that to its host.
	if host_managed:
		return
	var paths := PackedStringArray()
	for db: DocketDB in _project_dbs.values():
		paths.append(db.get_path())
	UserPrefs.save_session(paths)


func _process(_delta: float) -> void:
	if transport == "stdio":
		_process_stdio()
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

	var result = _handler.handle(parsed)

	# Checkpoint WAL so other processes (e.g. GUI) can see writes immediately
	if _db:
		_db.checkpoint()
	for proj_db in _project_dbs.values():
		proj_db.checkpoint()

	if result == null:
		# Notification — no response body needed
		return HttpParser.format_response(202, {}, "")

	return HttpParser.format_response(200, {"Content-Type": "application/json"}, JSON.stringify(result))


# -- stdio transport ----------------------------------------------------------

## Stdin thread: gather bytes into lines (decoded whole, so a character is
## never cut in two) and hand each to the main thread; mark EOF. One byte per
## read: a larger read blocks until it is full (fread), which a request that
## ends sooner never makes it; stdin is buffered, so this stays cheap.
func _read_stdin() -> void:
	var pending := PackedByteArray()
	var oversized := false
	while true:
		var byte := OS.read_buffer_from_stdin(1)
		if byte.is_empty():
			break  # EOF (or a read error): the host has gone
		if byte[0] != 10:
			if pending.size() < MAX_STDIO_LINE_BYTES:
				pending.append(byte[0])
			else:
				oversized = true
			continue
		# An oversized line is answered as an invalid request (an empty object).
		var line := "{}" if oversized else pending.get_string_from_utf8().strip_edges()
		pending = PackedByteArray()
		oversized = false
		if not line.is_empty():
			_stdin_lock.lock()
			_stdin_lines.append(line)
			_stdin_lock.unlock()
	_stdin_lock.lock()
	_stdin_closed = true
	_stdin_lock.unlock()


func _process_stdio() -> void:
	_stdin_lock.lock()
	var lines := _stdin_lines
	_stdin_lines = []
	var closed := _stdin_closed
	_stdin_lock.unlock()
	for line in lines:
		var json := JSON.new()
		var parsed := json.parse(line) == OK
		var request = json.data if parsed else null
		# A JSON-RPC response (the host never needs one answered) is ignored.
		if request is Dictionary and not request.has("method") and (request.has("result") or request.has("error")):
			continue
		var response = _handler.handle(request) if request is Dictionary and request.has("method") \
			else {"jsonrpc": "2.0", "id": null, "error": {"code": -32600, "message": "Invalid Request"}} if parsed \
			else {"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "Parse error"}}
		if response != null:
			_write_stdio(response)
	# Another process may change a project file; the registry reloads it,
	# which reports the change (items_changed "reloaded").
	if Time.get_ticks_msec() >= _next_stale_check:
		_next_stale_check = Time.get_ticks_msec() + STALE_CHECK_MS
		_registry.refresh_stale_dbs()
	if closed:
		_stdin_thread.wait_to_finish()
		get_tree().quit()


func _write_stdio(message: Dictionary) -> void:
	print(JSON.stringify(message))


func _watch_project(proj_name: String, pdb: DocketDB) -> void:
	if host_events and transport == "stdio" and pdb != null:
		pdb.items_changed.connect(_on_items_changed.bind(proj_name, pdb.get_path(), str(pdb.get_instance_id())))


## One ITEM_CHANGED_EVENT per recorded change (an item can have several):
## {project, project_path, open_generation, id, change, event, cause, origin,
## operation_id, stream, sequence[, baseline]}, where `project` is the
## project's selector, `project_path` and `open_generation` the opening it
## was made in (as docket_project_list names them), `change` is created |
## updated | transitioned | comment_added | deleted | reloaded (the whole
## project, id ""), `event` the item event recorded, `cause` "mutation" for a
## change a request made, with the origin and operation id it was made with
## (its "provenance"), or "external_reload" for a project read again from its
## file, which names neither, even when a request's check for a changed file
## did it; `stream` and `sequence` place the event on this process's event
## stream (McpHandler.event_sequence). `baseline`, on the one change that
## describes an ordinary call of a baseline tool, is that call's descriptor
## (DocketDBConnection.with_baseline).
func _on_items_changed(changes: Array, proj_name: String, project_path: String, open_generation: String) -> void:
	for change: Dictionary in changes:
		_write_stdio({"jsonrpc": "2.0", "method": HOST_EVENT_METHOD, "params": {
			"event": ITEM_CHANGED_EVENT, "payload": host_event(change, proj_name, _handler, project_path, open_generation)}})


## The next event of `handler`'s stream for `change` of `project`, in the
## opening `project_path` and `open_generation` name (see above; without
## them, the opening is not named).
static func host_event(change: Dictionary, project: String, handler: McpHandler, project_path: String = "", open_generation: String = "") -> Dictionary:
	var reloaded := str(change.event) == "reloaded"
	var provenance: Dictionary = {} if reloaded else change.get("provenance", {})
	handler.event_sequence += 1
	var event := {"project": project, "id": str(change.id), "change": _change_kind(str(change.event)),
		"event": str(change.event), "cause": "external_reload" if reloaded else "mutation",
		"origin": str(provenance.get("origin", "")), "operation_id": str(provenance.get("operation_id", "")),
		"stream": handler.stream_id, "sequence": handler.event_sequence}
	if not project_path.is_empty():
		event["project_path"] = project_path
		event["open_generation"] = open_generation
	if change.get("baseline") is Dictionary:
		event["baseline"] = change.baseline.duplicate()
	return event


static func _change_kind(event: String) -> String:
	match event:
		"created", "deleted", "reloaded":
			return event
		"transition":
			return "transitioned"
		"comment_added", "comment_reply":
			return "comment_added"
	return "updated"
