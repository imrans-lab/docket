extends Node
## Real JSON fixtures and MCP initialize share the generated BuildInfo reader.

var A := AssertHelpers
const DIR := "user://test_build_info"
var _saved_path: String

func setup() -> void:
	_saved_path = BuildInfo.source_path
	DirAccess.make_dir_recursive_absolute(DIR)
	BuildInfo.source_path = DIR + "/build_info.json"

func teardown() -> void:
	DirAccess.remove_absolute(BuildInfo.source_path)
	DirAccess.remove_absolute(DIR)
	BuildInfo.source_path = _saved_path

func test_generated_resource_and_missing_resource_share_mcp_identity() -> Variant:
	DirAccess.remove_absolute(BuildInfo.source_path)
	var handler: McpHandler = McpHandler.new()
	var dev: Dictionary = handler.handle({"method":"initialize", "id":1})
	var result: Variant = A.is_true(BuildInfo.read() == {"version":"dev", "commit":""} and BuildInfo.identity() == "dev" and dev.result.serverInfo.version == "dev", "missing resource is dev: %s" % dev)
	if result is String: return result
	var fixture: Dictionary = {"version":"v0.3.0-rc.12", "commit":"1234567890abcdef1234567890abcdef12345678", "macos_short_version":"0.3.0", "macos_version":"1.3.0", "windows_version":"0.3.0.0"}
	var file: FileAccess = FileAccess.open(BuildInfo.source_path, FileAccess.WRITE)
	if file == null: return "Could not open build info fixture: %s" % error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(fixture))
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK: return "Could not write build info fixture: %s" % error_string(write_error)
	result = A.is_true(FileAccess.file_exists(BuildInfo.source_path), "written build info fixture exists at %s" % BuildInfo.source_path)
	if result is String: return result
	result = A.eq(BuildInfo.read(), fixture, "reader returns written fixture")
	if result is String: return result
	var built: Dictionary = handler.handle({"method":"initialize", "id":2})
	var expected: String = fixture.version + "+" + fixture.commit
	result = A.eq(BuildInfo.identity(), expected, "reader formats full generated identity")
	if result is String: return result
	return A.eq(built.result.serverInfo.version, expected, "MCP initialize reports generated identity")
