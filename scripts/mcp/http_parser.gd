extends RefCounted
class_name HttpParser
## Pure parse/format functions for HTTP requests and responses.

const STATUS_TEXTS := {
	200: "OK",
	202: "Accepted",
	204: "No Content",
	400: "Bad Request",
	404: "Not Found",
	405: "Method Not Allowed",
	500: "Internal Server Error",
}


static func parse_request(raw: String) -> Dictionary:
	var result := {
		"method": "",
		"path": "",
		"version": "",
		"headers": {},
		"body": "",
	}

	var header_body := raw.split("\r\n\r\n", true, 1)
	var header_section := header_body[0]
	if header_body.size() > 1:
		result.body = header_body[1]

	var lines := header_section.split("\r\n")
	if lines.size() == 0:
		return result

	# Request line
	var parts := lines[0].split(" ")
	if parts.size() >= 3:
		result.method = parts[0]
		result.path = parts[1]
		result.version = parts[2]

	# Headers
	for i in range(1, lines.size()):
		var line: String = lines[i]
		var colon := line.find(":")
		if colon > 0:
			var key := line.substr(0, colon).strip_edges().to_lower()
			var val := line.substr(colon + 1).strip_edges()
			result.headers[key] = val

	return result


static func format_response(status_code: int, headers: Dictionary, body: String) -> String:
	var status_text: String = STATUS_TEXTS.get(status_code, "Unknown")
	var resp := "HTTP/1.1 %d %s\r\n" % [status_code, status_text]

	if not headers.has("Content-Length") and body.length() > 0:
		headers["Content-Length"] = str(body.to_utf8_buffer().size())

	for key in headers:
		resp += "%s: %s\r\n" % [key, headers[key]]

	resp += "\r\n"
	resp += body
	return resp
