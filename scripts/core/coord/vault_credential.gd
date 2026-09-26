class_name VaultCredential
extends RefCounted
## The vault password in the system credential store, as the coordination
## state (CoordState) commits it. status() and password() read only the
## account the committed state names; setup() stores a first password;
## recover() ends what a crash left unfinished, and is run at startup.
## Nothing here asks the user anything, and no result carries the password
## except password()'s.
##
## setup() writes a fresh account at most once: the intent is committed
## before the write, the write's completion is recorded, the record is read
## back, and only then is it published. A setup that stops short retires its
## account for good, and the next one uses a new account, so a write that
## lands late lands where nothing reads. Retired accounts are then removed;
## one whose write may still land stays listed as fenced rather than deleted.
##
## Results are {ok: true, ...} or {error, kind}; status() and setup() also
## report `cleanup`, the retired accounts not yet known to be gone.

var _store: Object
var _state: CoordState
var _guard := CoordGuard.new()


## Over DocketCredentialStore and the account's coordination state unless
## `store` (an object with its read, write and remove) or `state` is given.
func _init(store: Object = null, state: CoordState = null) -> void:
	if store != null:
		_store = store
	elif ClassDB.class_exists("DocketCredentialStore"):
		_store = ClassDB.instantiate("DocketCredentialStore")
	_state = state if state != null else CoordState.new()


## Whether the committed password can be read now: {ok, cleanup} or {error,
## kind, cleanup}. Kinds: those of the credential store and the coordination
## state, "unconfigured", "forgotten", "pending" (an administration is
## unfinished), "corrupt" and "mismatch" (the stored record is not the
## committed one).
func status(parent: RefCounted = null) -> Dictionary:
	var opened := _guard.open_within(parent, CoordGuard.SHARED)
	if opened.has("error"):
		return opened
	var result := _active(opened.operation)
	result.erase("password")
	result["cleanup"] = _outstanding(opened.operation)
	opened.operation.close()
	return result


## {ok, password} or {error, kind} as status() reports it, read within
## `parent`, the operation that uses it.
func password(parent: RefCounted) -> Dictionary:
	if parent == null:
		return {"error": "the vault password is read only within the operation that uses it", "kind": "refused"}
	return _active(parent)


## Stores `new_password` as the first vault password, or the first after a
## Forget: {ok, cleanup} or {error, kind, cleanup}. It is refused while one is
## set up or an administration is unfinished (recover() first).
func setup(new_password: String, parent: RefCounted = null) -> Dictionary:
	if new_password.is_empty():
		return {"error": "the vault password cannot be empty", "kind": "refused"}
	if _store == null:
		return {"error": CoordGuard.NO_EXTENSION, "kind": "no_extension"}
	var opened := _guard.open_within(parent, CoordGuard.EXCLUSIVE)
	if opened.has("error"):
		return opened
	var operation: RefCounted = opened.operation
	var result := _setup(new_password, operation)
	result["cleanup"] = _remove_retired(operation)
	operation.close()
	return result


## Retires the account of an administration a crash or failure left
## unfinished, then removes what is retired: {ok, recovered, cleanup} or
## {error, kind}. Nothing unfinished is resumed: its password is asked for
## again.
func recover(parent: RefCounted = null) -> Dictionary:
	var opened := _guard.open_within(parent, CoordGuard.EXCLUSIVE)
	if opened.has("error"):
		return opened
	var operation: RefCounted = opened.operation
	var state := _state.read(operation)
	var result := {"ok": true, "recovered": false}
	if state.has("error") and state.kind != "missing":
		result = state
	elif not state.has("error") and not (state.intent as Dictionary).is_empty():
		# Whatever it reached, its write may still land: unless it was
		# acknowledged, abandon() keeps the account fenced.
		var abandoned := _state.abandon(operation, state.intent.op, CoordState.UNCERTAIN)
		result = abandoned if abandoned.has("error") else {"ok": true, "recovered": true}
	if not result.has("error"):
		result["cleanup"] = _outstanding(operation) if _store == null else _remove_retired(operation)
	operation.close()
	return result


func _setup(new_password: String, operation: RefCounted) -> Dictionary:
	var ensured := _state.ensure(operation)
	if ensured.has("error"):
		return ensured
	var refusal := CoordState.setup_refusal(ensured)
	if not refusal.is_empty():
		return refusal
	# The account the next tag names should hold nothing. That is checked
	# before the tag is reserved, so a store that cannot answer costs no tag;
	# `operation` is EXCLUSIVE, so no other process can reserve it meanwhile.
	var account := CoordRecord.account(ensured.epoch, ensured.next_tag)
	var before: Dictionary = _store.read(account, operation)
	if before.get("ok") != true and before.get("kind") != "not_found":
		return _failure(before)
	var begun := _state.begin_setup(operation)
	if begun.has("error"):
		return begun
	if begun.account != account or before.get("ok") == true:
		# Either an entry is there, from outside this state (a restored
		# coord.db, say), or the tag is not the one checked: its account is
		# kept, never removed.
		var abandoned := _state.abandon(operation, begun.op, CoordState.FOUND)
		if abandoned.has("error"):
			return abandoned
		if begun.account != account:
			return {"error": "the coordination state changed during setup", "kind": "io"}
		return {"error": "the credential store already holds an entry Docket did not write", "kind": "conflict"}
	var written: Dictionary = _store.write(account, CoordRecord.encode(begun.epoch, begun.tag, new_password), operation)
	if written.get("ok") != true:
		var outcome := CoordState.UNCERTAIN if written.get("indeterminate") == true else CoordState.UNWRITTEN
		var abandoned := _state.abandon(operation, begun.op, outcome)
		return abandoned if abandoned.has("error") else _failure(written)
	# Until this is recorded, recovery treats the write as possibly late.
	var acknowledged := _state.acknowledge(operation, begun.op)
	if acknowledged.has("error"):
		return acknowledged
	var back: Dictionary = _store.read(account, operation)
	var record := CoordRecord.decode(str(back.get("value", ""))) if back.get("ok") == true else {"error": "unread"}
	if record.has("error") or record.epoch != begun.epoch or record.tag != begun.tag or record.password != new_password:
		# Acknowledged, so abandon() retires it as completed whatever the
		# outcome given: its removal will prove it gone.
		var abandoned := _state.abandon(operation, begun.op, CoordState.UNCERTAIN)
		if abandoned.has("error"):
			return abandoned
		return _failure(back) if back.get("ok") != true \
			else {"error": "the stored vault password did not read back as written", "kind": "mismatch"}
	var published := _state.publish(operation, begun.op)
	return published if published.has("error") else {"ok": true}


func _active(operation: RefCounted) -> Dictionary:
	if _store == null:
		return {"error": CoordGuard.NO_EXTENSION, "kind": "no_extension"}
	var state := _state.read(operation)
	if state.has("error"):
		if state.kind == "missing":
			return {"error": "no vault password is set up", "kind": "unconfigured"}
		return state
	if not (state.intent as Dictionary).is_empty():
		return {"error": "a vault password administration is unfinished", "kind": "pending"}
	if state.state == CoordState.UNCONFIGURED:
		return {"error": "no vault password is set up", "kind": "unconfigured"}
	if state.state == CoordState.FORGOTTEN:
		return {"error": "the vault password was forgotten", "kind": "forgotten"}
	var stored: Dictionary = _store.read(CoordRecord.active_account(state), operation)
	if stored.get("ok") != true:
		return _failure(stored)
	var record := CoordRecord.decode(str(stored.get("value", "")))
	if record.has("error"):
		return {"error": record.error, "kind": "corrupt"}
	if not CoordRecord.accepts(record, state):
		return {"error": "the stored vault password is not the committed one", "kind": "mismatch"}
	return {"ok": true, "password": record.password}


# Removes every retired account that is awaiting removal, and records each
# removal; returns how many retired accounts are still not known to be gone,
# or -1 when they cannot be listed. A failed removal is tried again next time.
func _remove_retired(operation: RefCounted) -> int:
	var listed := _state.retired(operation)
	if listed.has("error"):
		return -1
	for entry: Dictionary in listed.retired:
		if not entry.status in [CoordState.DELETE, CoordState.DELETE_UNSETTLED]:
			continue
		var removed: Dictionary = _store.remove(entry.account, operation)
		if removed.get("ok") == true or removed.get("kind") == "not_found":
			_state.settle_removal(operation, entry.account)
	return _outstanding(operation)


func _outstanding(operation: RefCounted) -> int:
	var listed := _state.retired(operation)
	return -1 if listed.has("error") else (listed.retired as Array).size()


# A store failure as this class reports it: its message and kind only.
static func _failure(result: Dictionary) -> Dictionary:
	return {"error": str(result.get("error", "the credential store failed")), "kind": str(result.get("kind", "other"))}
