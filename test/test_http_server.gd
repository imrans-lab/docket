extends Node

var A := AssertHelpers
var _registration_fixture_dirs: Array[String] = []


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


func test_instance_registration_preserves_first_owner_and_changed_record() -> Variant:
	var Registration = load("res://scripts/core/instance_registration.gd")
	var profile := _registration_profile()
	var registration = Registration.new(profile, OS.get_process_id(), "2026-10-09T00:00:00Z")
	var stale_file := FileAccess.open(profile.path_join("instance.json"), FileAccess.WRITE)
	stale_file.store_string(JSON.stringify({"pid":OS.get_process_id(), "stale":true}))
	stale_file.close()
	var first_status: String = registration.publish("dev", McpHandler.PROTOCOL_VERSION, 11111)
	var path := profile.path_join("instance.json")
	var first: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var updated_status: String = registration.publish("dev", McpHandler.PROTOCOL_VERSION, 22222)
	var updated: String = FileAccess.get_file_as_string(path)
	var parsed: Dictionary = JSON.parse_string(updated)
	# A distinct caller identity; the existing publisher PID is this live process.
	var loser = Registration.new(profile, OS.get_process_id() + 1, "2026-10-09T01:00:00Z")
	var loser_status: String = loser.publish("dev", McpHandler.PROTOCOL_VERSION, 33333)
	loser.close()
	var kept_winner := FileAccess.get_file_as_string(path) == updated
	var replacement := JSON.stringify({"pid":OS.get_process_id(), "replacement":true})
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(replacement)
	file.close()
	var changed_status: String = registration.publish("dev", McpHandler.PROTOCOL_VERSION, 44444)
	registration.close()
	return A.is_true(first_status == "registered" and first.pid == OS.get_process_id() and first.endpoint.port == 11111 and updated_status == "registered" and parsed.endpoint.port == 22222 and first.started_at == parsed.started_at and loser_status == "profile_occupied" and kept_winner and changed_status == "record_changed" and FileAccess.get_file_as_string(path) == replacement, "registration retains first owner, updates actual port, and never overwrites or removes changed contents")


func test_instance_registration_obeys_held_native_lock() -> Variant:
	var Registration = load("res://scripts/core/instance_registration.gd")
	var profile := _registration_profile()
	var holder := SQLite.new()
	holder.path = profile.path_join("instance.lock.sqlite")
	holder.verbosity_level = SQLite.QUIET
	var held := holder.open_db() and holder.query("BEGIN IMMEDIATE;")
	if not held:
		holder.close_db()
		return "native registration lock fixture could not acquire transaction"
	var registration = Registration.new(profile, OS.get_process_id(), "2026-10-09T00:00:00Z")
	var refused: String = registration.publish("dev", McpHandler.PROTOCOL_VERSION, 11111)
	var no_publication := not FileAccess.file_exists(profile.path_join("instance.json"))
	var released := holder.query("COMMIT;")
	holder.close_db()
	var published: String = registration.publish("dev", McpHandler.PROTOCOL_VERSION, 11111)
	registration.close()
	return A.is_true(refused == "lock_unavailable" and no_publication and released and published == "registered" and not FileAccess.file_exists(profile.path_join("instance.json")), "held native lock refuses publication, release permits it, and clean close removes own record")


func _registration_profile() -> String:
	var profile := ProjectSettings.globalize_path("user://fixtures/registration/%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	while DirAccess.dir_exists_absolute(profile):
		profile += "_"
	var error := DirAccess.make_dir_recursive_absolute(profile)
	assert(error == OK, "registration fixture directory creation failed")
	_registration_fixture_dirs.append(profile)
	return profile


func teardown() -> void:
	# Only newly-created directories recorded by this test class are owned here.
	for profile: String in _registration_fixture_dirs:
		for filename: String in DirAccess.get_files_at(profile):
			if DirAccess.remove_absolute(profile.path_join(filename)) != OK:
				push_error("Registration fixture file cleanup failed")
		if DirAccess.remove_absolute(profile) != OK:
			push_error("Registration fixture directory cleanup failed")
	_registration_fixture_dirs.clear()
