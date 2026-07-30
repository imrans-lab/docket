extends Node
## Tests for the MCP endpoint's local-origin enforcement.
##
## The server has no credential, so these checks are the only thing standing
## between a web page the user happens to visit and their work items. Each case
## below corresponds to a request a browser can actually make.

var A := AssertHelpers

var _server


func setup() -> void:
	# The guard is pure header inspection — no socket or DB needed.
	var ServerScript = load("res://scripts/mcp/http_server.gd")
	_server = ServerScript.new()


func teardown() -> void:
	if _server:
		_server.free()
		_server = null


func _req(headers: Dictionary) -> Dictionary:
	var lowered := {}
	for k in headers:
		lowered[str(k).to_lower()] = headers[k]
	return {"method": "POST", "path": "/mcp", "headers": lowered, "body": "{}"}


# -- Blocked: things only a browser does --------------------------------------

func test_origin_header_is_rejected() -> Variant:
	## Browsers always attach Origin cross-origin; MCP clients never do.
	var reason: String = _server._reject_reason(_req({
		"Host": "127.0.0.1:3010",
		"Content-Type": "application/json",
		"Origin": "https://evil.example.com",
	}))
	var r = A.is_true(not reason.is_empty(), "request with Origin is rejected")
	if r != true:
		return r
	return A.contains(reason, "cross-origin", "reason names the cause")


func test_text_plain_is_rejected() -> Variant:
	## text/plain is a CORS "simple" type — sendable with no preflight, which is
	## exactly how a drive-by POST to loopback works.
	var reason: String = _server._reject_reason(_req({
		"Host": "127.0.0.1:3010",
		"Content-Type": "text/plain",
	}))
	return A.is_true(not reason.is_empty(), "text/plain is rejected")


func test_form_urlencoded_is_rejected() -> Variant:
	var reason: String = _server._reject_reason(_req({
		"Host": "127.0.0.1:3010",
		"Content-Type": "application/x-www-form-urlencoded",
	}))
	return A.is_true(not reason.is_empty(), "form-urlencoded is rejected")


func test_multipart_is_rejected() -> Variant:
	var reason: String = _server._reject_reason(_req({
		"Host": "127.0.0.1:3010",
		"Content-Type": "multipart/form-data; boundary=xyz",
	}))
	return A.is_true(not reason.is_empty(), "multipart is rejected")


func test_non_loopback_host_is_rejected() -> Variant:
	## DNS rebinding: an attacker-controlled name resolving to 127.0.0.1.
	var reason: String = _server._reject_reason(_req({
		"Host": "docket.evil.example.com",
		"Content-Type": "application/json",
	}))
	var r = A.is_true(not reason.is_empty(), "non-loopback Host is rejected")
	if r != true:
		return r
	return A.contains(reason, "loopback", "reason names the cause")


# -- Allowed: legitimate clients must never be locked out ---------------------

func test_plain_json_client_is_allowed() -> Variant:
	return A.eq(_server._reject_reason(_req({
		"Host": "127.0.0.1:3010",
		"Content-Type": "application/json",
	})), "", "ordinary JSON client passes")


func test_charset_parameter_is_allowed() -> Variant:
	## The parameter must be stripped before comparison.
	return A.eq(_server._reject_reason(_req({
		"Host": "127.0.0.1:3010",
		"Content-Type": "application/json; charset=utf-8",
	})), "", "charset parameter does not break the check")


func test_missing_content_type_is_allowed() -> Variant:
	## A browser sending a body always sets one of the simple types, so an absent
	## Content-Type cannot be a drive-by request. Rejecting it would only break
	## hand-rolled clients.
	return A.eq(_server._reject_reason(_req({
		"Host": "127.0.0.1:3010",
	})), "", "absent Content-Type is allowed")


func test_missing_host_is_allowed() -> Variant:
	return A.eq(_server._reject_reason(_req({
		"Content-Type": "application/json",
	})), "", "absent Host is allowed")


func test_localhost_host_is_allowed() -> Variant:
	return A.eq(_server._reject_reason(_req({
		"Host": "localhost:3010",
		"Content-Type": "application/json",
	})), "", "localhost Host passes")


func test_ipv6_loopback_is_allowed() -> Variant:
	return A.eq(_server._reject_reason(_req({
		"Host": "[::1]:3010",
		"Content-Type": "application/json",
	})), "", "IPv6 loopback passes")


func test_uppercase_headers_are_handled() -> Variant:
	## HttpParser lowercases keys; values may still carry mixed case.
	return A.is_true(not _server._reject_reason(_req({
		"Host": "127.0.0.1:3010",
		"Content-Type": "TEXT/PLAIN",
	})).is_empty(), "content-type comparison is case-insensitive")
