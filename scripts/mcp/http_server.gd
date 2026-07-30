extends Node
class_name DocketHttpServer
## TCPServer-based HTTP server for MCP Streamable HTTP.
## Supports multiple .dct files loaded simultaneously.

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


func _ready() -> void:
	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("Failed to listen on port %d: %s" % [port, error_string(err)])
		return

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
		var schema_file := FileAccess.open("res://data/schema.json", FileAccess.READ)
		_schema = JSON.parse_string(schema_file.get_as_text())

		# Merge CLI --file args with any previously persisted session paths
		var paths_to_load: Array = dct_paths.duplicate() if dct_paths.size() > 0 else [dct_path]
		var saved_paths := UserPrefs.load_session()
		for sp in saved_paths:
			if sp not in paths_to_load:
				paths_to_load.append(sp)
		for path in paths_to_load:
			var loaded_db := _open_or_create_db(str(path))
			if loaded_db:
				var proj_name := loaded_db.get_project_name()
				if proj_name.is_empty():
					proj_name = str(path).get_file().get_basename()
					loaded_db.set_project_name(proj_name)
				_project_dbs[proj_name] = loaded_db
				if _db == null:
					_db = loaded_db  # First DB is primary
			else:
				# Never start up quietly serving nothing — an unopenable file
				# (conflict markers, corruption) must be visible on stdout.
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

	# Cap frame rate to avoid busy-spinning the main loop
	if DisplayServer.get_name() == "headless":
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
	external_state.add_project(path)
	# file_changed fires synchronously → _on_file_changed syncs registry
	for proj_name in external_state.get_project_dbs():
		var pdb: DocketDB = external_state.get_project_dbs()[proj_name]
		if pdb.get_path() == path:
			return {"name": proj_name, "path": path, "prefix": pdb.get_id_prefix()}
	return {"name": path.get_file().get_basename(), "path": path}


func _gui_remove_project(proj_name: String) -> Dictionary:
	return external_state.remove_project(proj_name)


func _gui_open(request: Dictionary) -> Dictionary:
	if request.has("id"):
		external_state.open_item_requested.emit(str(request.id))
		return {"opened": "item", "id": str(request.id)}
	elif request.has("filter"):
		var filter_str: String = str(request.get("filter", ""))
		var label: String = str(request.get("label", "MCP Query"))
		external_state.open_query_requested.emit(filter_str, label)
		return {"opened": "query", "label": label}
	return {"error": "Invalid request"}


func _headless_add_project(path: String) -> Dictionary:
	var loaded_db := _open_or_create_db(path)
	if not loaded_db:
		return {"error": "Failed to open: %s" % path}
	var proj_name := loaded_db.get_project_name()
	if proj_name.is_empty():
		proj_name = path.get_file().get_basename()
		loaded_db.set_project_name(proj_name)
	_project_dbs[proj_name] = loaded_db
	if _db == null:
		_db = loaded_db
	_registry.update_db(_schema, _db, _project_dbs)
	_persist_headless_session()
	return {"name": proj_name, "path": path, "prefix": loaded_db.get_id_prefix()}


func _headless_remove_project(proj_name: String) -> Dictionary:
	if not _project_dbs.has(proj_name):
		return {"error": "Project not found: %s" % proj_name}
	var closing_db: DocketDB = _project_dbs[proj_name]
	closing_db.close()
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
		paths.append(db.get_path())
	UserPrefs.save_session(paths)


func _process(_delta: float) -> void:
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
