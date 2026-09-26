extends Node
## VaultCredential over the real coordination lock and a coord.db of the
## test's own, with a credential store double that can hold a write back and
## let it land later (the way a timed-out Secret Service write can):
## - a write whose outcome is unknown retires its account; the next setup
##   uses a new one, and when the held write lands later the committed
##   password is still the second, read from the second account;
## - a crash before the write, after it, or after its acknowledgement is
##   recovered by retiring that account: nothing is written to it again,
##   nothing is published from it, and an operation id from before the crash
##   is refused;
## - malformed account names are refused by the native store without being
##   quoted; an entry already in the account setup would write stops setup
##   and is kept; a stored record of another epoch or tag, an unreadable
##   record, a duplicate entry and an unreadable intent each leave the
##   password unavailable; no result other than password()'s, and no byte of
##   coord.db, holds a password.
## The native checks need the library built from this revision.
## The class's files are kept after it runs (the directory is printed).

var A := AssertHelpers
var _dir := ""


## The credential store's read, write and remove, in memory. `hold_writes`
## makes each write answer as a timed-out one does, keeping it in `held`
## until land() carries it out; `several` makes reads of that account answer
## as a store holding two entries does. Every account's writes are counted.
class StoreDouble:
	extends RefCounted
	var entries := {}
	var writes := {}
	var held: Array = []
	var hold_writes := false
	var several := ""

	func read(account: String, _operation: RefCounted) -> Dictionary:
		var answer := {"ok": true, "value": entries[account]} if entries.has(account) \
			else {"error": "no such credential is stored", "kind": "not_found"}
		if account == several:
			answer = {"error": "several such credentials are stored", "kind": "other"}
		return answer

	func write(account: String, value: String, _operation: RefCounted) -> Dictionary:
		writes[account] = writes.get(account, 0) + 1
		var answer := {"ok": true}
		if hold_writes:
			held.append([account, value])
			answer = {"error": "the Secret Service did not answer in time", "kind": "unreachable", "indeterminate": true}
		else:
			entries[account] = value
		return answer

	func remove(account: String, _operation: RefCounted) -> Dictionary:
		return {"ok": true} if entries.erase(account) else {"error": "no such credential is stored", "kind": "not_found"}

	func land() -> void:
		for pending: Array in held:
			entries[pending[0]] = pending[1]
		held.clear()


func setup() -> void:
	_dir = OS.get_cache_dir().path_join("docket_vault_credential_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_dir)


func teardown() -> void:
	print("  test files kept at %s" % _dir)


# {status of each retired account}, or {"error": ...}.
static func _retired(state: CoordState) -> Dictionary:
	var listed := state.retired()
	if listed.has("error"):
		return {"error": listed.error}
	var statuses := {}
	for entry: Dictionary in listed.retired:
		statuses[entry.account] = entry.status
	return statuses


# The password as password() reads it within an operation of its own.
static func _password(credential: VaultCredential) -> Dictionary:
	var opened := CoordGuard.new().open(CoordGuard.SHARED)
	if opened.has("error"):
		return opened
	var result := credential.password(opened.operation)
	opened.operation.close()
	return result


# The accounts written more than once, "" for none.
static func _rewritten(store: StoreDouble) -> String:
	return ", ".join(PackedStringArray(store.writes.keys().filter(func(account: String) -> bool: return store.writes[account] > 1)))


func test_a_late_write_lands_on_a_retired_account_and_never_becomes_active() -> Variant:
	var store := StoreDouble.new()
	var state := CoordState.new(_dir.path_join("late.db"))
	var credential := VaultCredential.new(store, state)
	var r = A.eq(credential.status().get("kind"), "unconfigured", "nothing is set up at first")
	if r is String: return r

	store.hold_writes = true
	var first := credential.setup("first-password")
	r = A.eq(first.get("kind"), "unreachable", "a write with no answer fails setup")
	if r is String: return r
	r = A.eq(credential.status().get("kind"), "unconfigured", "and publishes nothing")
	if r is String: return r
	var late_account: String = store.held[0][0]
	r = A.eq(_retired(state), {late_account: CoordState.FENCED}, "its account is retired, removed once, and still fenced")
	if r is String: return r

	store.hold_writes = false
	var second := credential.setup("second-password")
	r = A.eq(second, {"ok": true, "cleanup": 1}, "a second setup succeeds, with the fenced account still outstanding")
	if r is String: return r
	store.land()
	r = A.eq(store.entries.has(late_account), true, "the held write has landed")
	if r is String: return r
	r = A.eq(_password(credential), {"ok": true, "password": "second-password"}, "the committed password is still the second")
	if r is String: return r
	var committed := state.read()
	r = A.neq(CoordRecord.active_account(committed), late_account, "read from an account of its own")
	if r is String: return r
	r = A.eq(credential.setup("third-password").get("kind"), "refused", "a second setup over a committed password is refused")
	if r is String: return r
	return A.eq(_rewritten(store), "", "no account was written twice")


func test_a_crash_at_each_step_retires_the_account_and_nothing_is_published_from_it() -> Variant:
	var store := StoreDouble.new()
	var state := CoordState.new(_dir.path_join("crash.db"))
	var credential := VaultCredential.new(store, state)
	var opened := CoordGuard.new().open(CoordGuard.EXCLUSIVE)
	if opened.has("error"):
		return "no coordination operation: %s" % opened.error
	var operation: RefCounted = opened.operation
	state.ensure(operation)

	# Before its write, after it, and after its acknowledgement: each "crash"
	# leaves the intent where that step left it, and recovery ends it.
	var accounts: Array = []
	var ops: Array = []
	for step in ["begun", "written", "acknowledged"]:
		var begun := state.begin_setup(operation)
		if begun.has("error"):
			operation.close()
			return "setup could not begin after '%s': %s" % [step, begun.error]
		accounts.append(begun.account)
		ops.append(begun.op)
		if step != "begun":
			store.write(begun.account, CoordRecord.encode(begun.epoch, begun.tag, "lost-password"), operation)
		if step == "acknowledged":
			state.acknowledge(operation, begun.op)
		var recovered := credential.recover(operation)
		if recovered.get("recovered") != true:
			operation.close()
			return "recovery after '%s' did not end the intent: %s" % [step, recovered]
	var stale := [state.acknowledge(operation, ops[0]).get("kind"), state.publish(operation, ops[2]).get("kind")]
	operation.close()

	var r = A.eq(stale, ["refused", "refused"], "an operation id from before a crash is refused")
	if r is String: return r
	r = A.eq(credential.status().get("kind"), "unconfigured", "nothing was published from a crashed setup")
	if r is String: return r
	# Only the acknowledged write is known to have completed, so only its
	# removal proves it gone.
	r = A.eq(_retired(state), {accounts[0]: CoordState.FENCED, accounts[1]: CoordState.FENCED},
		"the unacknowledged accounts stay fenced; the acknowledged one is gone")
	if r is String: return r
	r = A.eq(store.entries.keys(), [], "every written account was removed")
	if r is String: return r

	r = A.eq(credential.setup("new-password").get("ok"), true, "a later setup succeeds")
	if r is String: return r
	r = A.is_false(CoordRecord.active_account(state.read()) in accounts, "on an account none of the crashed ones used")
	if r is String: return r
	return A.eq(_rewritten(store), "", "no account was written twice")


func test_malformed_names_records_and_state_fail_closed_without_leaking() -> Variant:
	var epoch := "0123456789abcdef0123456789abcdef"
	if not ClassDB.class_exists("DocketCredentialStore"):
		return "the native extension is not loaded"
	var native: Object = ClassDB.instantiate("DocketCredentialStore")
	var opened := CoordGuard.new().open(CoordGuard.SHARED)
	if opened.has("error"):
		return "no coordination operation: %s" % opened.error
	var refusals: Array = []
	for name in ["vault-password", "vault-rotation-old", "vault-password/%s/01" % epoch, "vault-password/%s/0" % epoch,
			"vault-password/%s/1" % epoch.to_upper(), "vault-password/%s/1/x" % epoch, "vault-password/%s/1234567890123456789" % epoch]:
		var answer: Dictionary = native.read(name, opened.operation)
		if answer.get("kind") != "refused" or str(answer.get("error")).contains(name):
			refusals.append("%s: %s" % [name, answer])
	var unbound: Dictionary = native.write("vault-password/%s/1" % epoch, "x", null)
	opened.operation.close()
	var r = A.eq(refusals, [], "every malformed account is refused, unquoted")
	if r is String: return r
	r = A.eq(unbound.get("kind"), "refused", "a well-formed account outside an operation is refused")
	if r is String: return r

	var store := StoreDouble.new()
	var path := _dir.path_join("closed.db")
	var state := CoordState.new(path)
	var credential := VaultCredential.new(store, state)
	var fresh := state.ensure()
	if fresh.has("error"):
		return "the coordination state could not be set up: %s" % fresh.error
	var foreign := CoordRecord.account(fresh.epoch, fresh.next_tag)
	store.entries[foreign] = "an entry from elsewhere"
	r = A.eq(credential.setup("kept-password").get("kind"), "conflict", "an entry in the account setup would write stops it")
	if r is String: return r
	r = A.eq([_retired(state), store.entries.get(foreign)], [{foreign: CoordState.KEPT}, "an entry from elsewhere"],
		"and is kept as it was, its account retired but never removed")
	if r is String: return r
	var results: Array = [credential.setup("kept-password")]
	r = A.eq(results[0].get("ok"), true, "setup then succeeds on the next account")
	if r is String: return r
	var committed := state.read()
	var account := CoordRecord.active_account(committed)
	var kinds: Array = []
	store.entries[account] = CoordRecord.encode("fedcba9876543210fedcba9876543210", committed.generation, "other-password")
	results.append(credential.status())
	store.entries[account] = CoordRecord.encode(committed.epoch, committed.generation + 1, "other-password")
	results.append(credential.status())
	store.entries[account] = "not a record"
	results.append(credential.status())
	store.several = account
	results.append(credential.status())
	for result: Dictionary in results.slice(1):
		kinds.append(result.get("kind"))
	r = A.eq(kinds, ["mismatch", "mismatch", "corrupt", "other"],
		"another epoch's record, another tag's, an unreadable one and a duplicate entry are each unavailable")
	if r is String: return r

	var db := SQLite.new()
	db.path = path
	db.verbosity_level = SQLite.QUIET
	var damaged := db.open_db() and db.query("UPDATE coord_state SET intent = '{\"v\":\"1\"}' WHERE id = 1;")
	db.close_db()
	r = A.is_true(damaged, "the intent was damaged")
	if r is String: return r
	results.append(credential.status())
	results.append(credential.recover())
	r = A.eq([results[-2].get("kind"), results[-1].get("kind")], ["corrupt", "corrupt"],
		"an unreadable intent is reported, not repaired or cleared")
	if r is String: return r

	# Compared as hex, since coord.db's bytes are not text.
	var leaked: Array = []
	for text in [JSON.stringify(results).to_utf8_buffer().hex_encode(), FileAccess.get_file_as_bytes(path).hex_encode()]:
		for secret in ["kept-password", "other-password"]:
			if text.contains(secret.to_utf8_buffer().hex_encode()):
				leaked.append(secret)
	return A.eq(leaked, [], "no result and no byte of coord.db holds a password")
