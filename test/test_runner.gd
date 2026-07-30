extends Node
class_name TestRunner
## Discovers and runs test_* methods from registered test scripts.
## Returns true/String from each test. Supports setup/teardown and async tests.

var _pass_count := 0
var _fail_count := 0
var _test_classes: Array = []


func _ready() -> void:
	_test_classes = [
		preload("res://test/test_data_model.gd"),
		preload("res://test/test_state_machine.gd"),
		preload("res://test/test_file_manager.gd"),
		preload("res://test/test_docket_db.gd"),
		preload("res://test/test_migration.gd"),
		preload("res://test/test_attachments.gd"),
		preload("res://test/test_http_server.gd"),
		preload("res://test/test_http_origin_guard.gd"),
		preload("res://test/test_mcp_handler.gd"),
		preload("res://test/test_mcp_tools.gd"),
		preload("res://test/test_integration.gd"),
		preload("res://test/test_vault_crypto.gd"),
		preload("res://test/test_vault_kdf_migration.gd"),
		preload("res://test/test_audit_log.gd"),
		preload("res://test/test_query_field_validation.gd"),
		preload("res://test/test_meta_roundtrip.gd"),
		preload("res://test/test_user_prefs.gd"),
		preload("res://test/test_jsonl_serializer.gd"),
		preload("res://test/test_jsonl_parser.gd"),
		preload("res://test/test_jsonl_migration.gd"),
		preload("res://test/test_jsonl_cache.gd"),
		preload("res://test/test_docket_db_jsonl.gd"),
		preload("res://test/test_file_lock.gd"),
		preload("res://test/test_jsonl_freshness.gd"),
		preload("res://test/test_jsonl_e2e.gd"),
		preload("res://test/test_secret_unified_set.gd"),
		preload("res://test/test_knowledge_types.gd"),
		preload("res://test/test_quality_scoring.gd"),
		preload("res://test/test_project_meta.gd"),
		preload("res://test/test_functional_cross.gd"),
		preload("res://test/test_functional_lifecycle.gd"),
		preload("res://test/test_functional_roundtrip.gd"),
	]


func run_all() -> int:
	print("")
	for test_script in _test_classes:
		var test_instance = test_script.new()
		add_child(test_instance)

		var script_name: String = test_script.resource_path.get_file().get_basename()
		print("=== %s ===" % script_name)

		if test_instance.has_method("setup"):
			var setup_result = test_instance.setup()
			if setup_result is Signal:
				await setup_result

		var methods: Array[Dictionary] = test_instance.get_method_list()
		for method in methods:
			var name: String = method["name"]
			if name.begins_with("test_"):
				await _run_test(test_instance, name)

		if test_instance.has_method("teardown"):
			var td_result = test_instance.teardown()
			if td_result is Signal:
				await td_result

		test_instance.queue_free()
		print("")

	_print_summary()
	return 0 if _fail_count == 0 else 1


func _run_test(instance: Node, method_name: String) -> void:
	# Per-test setup
	if instance.has_method("before_each"):
		var be = instance.before_each()
		if be is Signal:
			await be

	var result: Variant = instance.call(method_name)

	if result is Object and result.has_method("is_valid"):
		result = await result
	elif result is Signal:
		result = await result

	# Every test method is declared `-> Variant` and returns true (pass) or an
	# error String (fail). null is therefore NEVER a legitimate result: GDScript
	# returns null from a function that hit a runtime error — a call to a
	# nonexistent method, a method on a Nil instance — and execution continues.
	# Treating null as a pass turned every thrown exception into a silent green
	# tick, which is precisely the failure a test suite exists to prevent.
	if result is bool and result == true:
		_pass_count += 1
		print("  PASS: %s" % method_name)
	else:
		_fail_count += 1
		if result == null:
			print("  FAIL: %s — returned null (runtime error, or missing return)" % method_name)
		elif result is String:
			print("  FAIL: %s — %s" % [method_name, result])
		else:
			print("  FAIL: %s — unexpected result type %s" % [method_name, type_string(typeof(result))])

	# Per-test teardown
	if instance.has_method("after_each"):
		var ae = instance.after_each()
		if ae is Signal:
			await ae


func _print_summary() -> void:
	var total := _pass_count + _fail_count
	print("========================================")
	print("Results: %d total, %d passed, %d failed" % [total, _pass_count, _fail_count])
	if _fail_count == 0:
		print("ALL TESTS PASSED")
	else:
		print("SOME TESTS FAILED")
	print("========================================")
