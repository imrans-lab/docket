extends Node

var A := AssertHelpers


func test_parse_post_request() -> Variant:
	var raw := "POST /mcp HTTP/1.1\r\nHost: localhost:3010\r\nContent-Type: application/json\r\nContent-Length: 14\r\n\r\n{\"test\":\"data\"}"
	var req = HttpParser.parse_request(raw)
	var r = A.eq(req.method, "POST")
	if r is String: return r
	r = A.eq(req.path, "/mcp")
	if r is String: return r
	r = A.eq(req.headers["content-type"], "application/json")
	if r is String: return r
	return A.eq(req.body, "{\"test\":\"data\"}")


func test_parse_get_request() -> Variant:
	var raw := "GET /mcp HTTP/1.1\r\nHost: localhost:3010\r\n\r\n"
	var req = HttpParser.parse_request(raw)
	var r = A.eq(req.method, "GET")
	if r is String: return r
	return A.eq(req.path, "/mcp")


func test_parse_delete_request() -> Variant:
	var raw := "DELETE /mcp HTTP/1.1\r\nHost: localhost:3010\r\n\r\n"
	var req = HttpParser.parse_request(raw)
	return A.eq(req.method, "DELETE")


func test_format_200_response() -> Variant:
	var resp = HttpParser.format_response(200, {"Content-Type": "application/json"}, "{\"ok\":true}")
	var r = A.contains(resp, "HTTP/1.1 200 OK")
	if r is String: return r
	r = A.contains(resp, "Content-Type: application/json")
	if r is String: return r
	return A.contains(resp, "{\"ok\":true}")


func test_format_202_response() -> Variant:
	var resp = HttpParser.format_response(202, {}, "")
	return A.contains(resp, "HTTP/1.1 202 Accepted")


func test_extract_content_length() -> Variant:
	var raw := "POST /mcp HTTP/1.1\r\nContent-Length: 42\r\n\r\n"
	var req = HttpParser.parse_request(raw)
	return A.eq(req.headers.get("content-length", ""), "42")
