extends Node
## Ensures the custom runner waits for coroutine hooks and test results before
## recording outcomes. A nested runner contains expected failures so the outer
## suite can verify failure accounting without intentionally failing itself.

var A := AssertHelpers

class AsyncFixture extends Node:
	var order: Array = []
	var should_pass := true

	func before_each() -> void:
		await get_tree().process_frame
		order.append("before")

	func delayed_result() -> Variant:
		await get_tree().process_frame
		order.append("test")
		return true if should_pass else "delayed failure"

	func after_each() -> void:
		await get_tree().process_frame
		order.append("after")


func test_runner_awaits_async_hooks_and_success() -> Variant:
	var runner := TestRunner.new()
	var fixture := AsyncFixture.new()
	add_child(runner)
	runner.add_child(fixture)
	await runner._run_test(fixture, "delayed_result")
	var r = A.eq(fixture.order, ["before", "test", "after"], "hooks and result complete in order")
	if r != true: runner.queue_free(); return r
	r = A.eq(runner._pass_count, 1, "delayed true counts as pass")
	runner.queue_free()
	return r


func test_runner_counts_async_error_as_failure_after_await() -> Variant:
	var runner := TestRunner.new()
	var fixture := AsyncFixture.new()
	fixture.should_pass = false
	add_child(runner)
	runner.add_child(fixture)
	await runner._run_test(fixture, "delayed_result")
	var r = A.eq(fixture.order, ["before", "test", "after"], "failure is awaited before teardown")
	if r != true: runner.queue_free(); return r
	r = A.eq(runner._fail_count, 1, "delayed error counts as failure")
	runner.queue_free()
	return r
