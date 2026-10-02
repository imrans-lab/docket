extends Node
## Real JSON fixtures and MCP initialize share the generated BuildInfo reader.

var A := AssertHelpers
const DIR := "user://test_build_info"
var _saved_path: String

func setup() -> void:
	_saved_path = BuildInfo.resource_path
	DirAccess.make_dir_recursive_absolute(DIR)
	BuildInfo.resource_path = DIR + "/build_info.json"

func teardown() -> void:
	DirAccess.remove_absolute(BuildInfo.resource_path)
	DirAccess.remove_absolute(DIR)
	BuildInfo.resource_path = _saved_path

func test_generated_resource_and_missing_resource_share_mcp_identity() -> Variant:
	DirAccess.remove_absolute(BuildInfo.resource_path)
	var handler: McpHandler = McpHandler.new()
	var dev: Dictionary = handler.handle({"method":"initialize", "id":1})
	var result: Variant = A.is_true(BuildInfo.read() == {"version":"dev", "commit":""} and BuildInfo.identity() == "dev" and dev.result.serverInfo.version == "dev", "missing resource is dev: %s" % dev)
	if result is String: return result
	var fixture: Dictionary = {"version":"v0.3.0-rc.12", "commit":"1234567890abcdef1234567890abcdef12345678", "macos_short_version":"0.3.0", "macos_version":"1.3.0", "windows_version":"0.3.0.0"}
	var file: FileAccess = FileAccess.open(BuildInfo.resource_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(fixture)); file.close()
	var built: Dictionary = handler.handle({"method":"initialize", "id":2})
	var expected: String = fixture.version + "+" + fixture.commit
	return A.is_true(BuildInfo.read() == fixture and BuildInfo.identity() == expected and built.result.serverInfo.version == expected, "reader/MCP share exact generated identity: %s" % built)
