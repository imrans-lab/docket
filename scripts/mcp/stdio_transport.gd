extends RefCounted
class_name DocketStdioTransport
## Bounded newline JSON-RPC framing. Only the main thread calls the backend.
## The host owns this child: close stdin to drain replies and settle on exit.

const MAX_FRAME_BYTES := 8 * 1024 * 1024
const QUEUE_SLOTS := 2
var _thread := Thread.new()
var _mutex := Mutex.new()
var _slots := Semaphore.new()
var _frames: Array = []
var _closed := false


func start() -> Error:
	for i in QUEUE_SLOTS:
		_slots.post()
	return _thread.start(_read)


func _enqueue(frame: Variant) -> void:
	_slots.wait()
	_mutex.lock()
	_frames.append(frame)
	_mutex.unlock()


func _read() -> void:
	var pending := PackedByteArray()
	var oversized := false
	while true:
		# Larger reads wait for that many bytes, delaying interactive requests.
		var byte := OS.read_buffer_from_stdin(1)
		if byte.is_empty():
			if oversized or not pending.is_empty():
				_enqueue(null) # EOF without a newline is an incomplete frame.
			break
		if byte[0] == 10:
			_enqueue(null if oversized else pending)
			pending = PackedByteArray()
			oversized = false
		elif not oversized:
			if pending.size() == MAX_FRAME_BYTES:
				pending = PackedByteArray()
				oversized = true # Discard through newline; never grow unbounded.
			else:
				pending.append(byte[0])
	_mutex.lock()
	_closed = true
	_mutex.unlock()


func poll(handler: McpHandler) -> bool:
	_mutex.lock()
	var frames := _frames
	_frames = []
	var closed := _closed
	_mutex.unlock()
	for frame in frames:
		_slots.post()
		var response: Variant
		if frame == null:
			response = _error(-32700, "Frame exceeds limit or lacks terminating newline")
		else:
			response = _dispatch(frame, handler)
		if response != null:
			Engine.print_to_stdout = true
			print(JSON.stringify(response))
			Engine.print_to_stdout = false
	if closed:
		_thread.wait_to_finish()
	return closed


func _dispatch(bytes: PackedByteArray, handler: McpHandler) -> Variant:
	var text := bytes.get_string_from_utf8()
	# Reject invalid UTF-8 rather than silently substituting replacement bytes.
	if text.to_utf8_buffer() != bytes:
		return _error(-32700, "Invalid UTF-8")
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return _error(-32700, "Parse error")
	var request: Variant = parser.data
	if not request is Dictionary or not _valid_request(request):
		return _error(-32600, "Invalid Request")
	var response: Variant = handler.handle(request)
	if response is Dictionary and request.has("id"):
		response["id"] = request.id
	# The shared HTTP handler replies to some no-id methods. JSON-RPC stdio
	# notifications execute their work but must never receive a response.
	return response if request.has("id") else null


func _valid_request(request: Dictionary) -> bool:
	if request.get("jsonrpc") != "2.0" or not request.get("method") is String:
		return false
	if request.has("id") and request.id != null and not (request.id is String or request.id is float or request.id is int):
		return false
	if request.has("params") and not request.params is Dictionary:
		return false
	var params: Dictionary = request.get("params", {})
	if request.method == "tools/call":
		if not params.get("name", "") is String:
			return false
		if params.has("arguments") and not params.arguments is Dictionary:
			return false
	return true


func _error(code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": null, "error": {"code": code, "message": message}}
