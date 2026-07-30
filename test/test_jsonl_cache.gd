extends Node
## Unit tests for JSONLCache.

var A := AssertHelpers
var _test_dir := "user://test_jsonl_cache"


# -- Setup / teardown ---------------------------------------------------------

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(_test_dir)


func teardown() -> void:
	_cleanup_dir(_test_dir)


func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var full := dir_path + "/" + fname
		if dir.current_is_dir():
			_cleanup_dir(full)
			DirAccess.remove_absolute(full)
		else:
			DirAccess.remove_absolute(full)
		fname = dir.get_next()
	DirAccess.remove_absolute(dir_path)


# -- JSONL helpers ------------------------------------------------------------

static func _write_file(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(content)
		f.close()


static func _minimal_jsonl() -> String:
	return (
		'{"_type":"meta","version":"1.0.0","counter":3,"id_prefix":"MNV","project":"minerva"}\n'
		+ '{"_type":"item","id":"MNV-0001","type":"bug","status":"active","title":"Crash on empty config","created_at":"2026-03-15T10:30:00Z","updated_at":"2026-03-20T14:22:00Z","created_by":"imran","priority":2,"tags":["crash","config"]}\n'
		+ '{"_type":"item","id":"MNV-0002","type":"chore","status":"open","title":"Update dependencies","created_at":"2026-03-16T08:00:00Z","updated_at":"2026-03-16T08:00:00Z","created_by":"imran","tags":["maintenance"]}\n'
		+ '{"_type":"event","item_id":"MNV-0001","seq":1,"event_type":"created","actor":"imran","timestamp":"2026-03-15T10:30:00Z","note":"Item created"}\n'
		+ '{"_type":"event","item_id":"MNV-0001","seq":2,"event_type":"status_changed","actor":"imran","timestamp":"2026-03-16T09:00:00Z","note":"new -> active"}\n'
		+ '{"_type":"comment","id":1,"item_id":"MNV-0001","author":"dana","text":"Reproduced on Linux.","created_at":"2026-03-19T15:30:00Z"}\n'
		+ '{"_type":"comment","id":2,"item_id":"MNV-0001","author":"imran","text":"Thanks.","created_at":"2026-03-19T16:00:00Z","parent_id":1}\n'
		+ '{"_type":"link","from_id":"MNV-0002","to_id":"MNV-0001","relation":"follow_up"}\n'
		+ '{"_type":"saved_query","name":"open-bugs","query":{"filter":{"type":"bug","status__ne":"closed"}}}\n'
	)


static func _close_db(db: DocketDB) -> void:
	if db:
		db.close()


static func _delete_db(path: String) -> void:
	for suffix: String in ["", "-wal", "-shm"]:
		DirAccess.remove_absolute(path + suffix)


# -- rebuild_cache: basic success ---------------------------------------------

func test_rebuild_cache_returns_open_db() -> Variant:
	var jsonl_path := _test_dir + "/basic.dct.jsonl"
	var cache_path := _test_dir + "/basic.dct.jsonl.cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db returned")
	if r is String:
		_close_db(db)
		return r
	r = A.is_true(db.is_open(), "db is open")
	_close_db(db)
	return r


func test_rebuild_cache_file_exists_after_build() -> Variant:
	var jsonl_path := _test_dir + "/exists.dct.jsonl"
	var cache_path := _test_dir + "/exists.dct.jsonl.cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	_close_db(db)
	return A.is_true(FileAccess.file_exists(cache_path), "cache file created")


# -- rebuild_cache: meta values -----------------------------------------------

func test_rebuild_sets_counter() -> Variant:
	var jsonl_path := _test_dir + "/meta_counter.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(db.get_counter(), 3, "counter=3")
	_close_db(db)
	return r


func test_rebuild_sets_id_prefix() -> Variant:
	var jsonl_path := _test_dir + "/meta_prefix.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(db.get_id_prefix(), "MNV", "id_prefix=MNV")
	_close_db(db)
	return r


func test_rebuild_sets_project_name() -> Variant:
	var jsonl_path := _test_dir + "/meta_project.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(db.get_project_name(), "minerva", "project=minerva")
	_close_db(db)
	return r


func test_rebuild_stores_jsonl_hash() -> Variant:
	var jsonl_path := _test_dir + "/meta_hash.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r
	var stored_hash := db.get_meta_value("jsonl_hash", "")
	r = A.is_true(not stored_hash.is_empty(), "jsonl_hash stored")
	_close_db(db)
	return r


# -- rebuild_cache: items -----------------------------------------------------

func test_rebuild_inserts_items() -> Variant:
	var jsonl_path := _test_dir + "/items.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r

	var item1 := db.get_item("MNV-0001")
	r = A.is_false(item1.is_empty(), "MNV-0001 exists")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(item1["title"], "Crash on empty config", "title")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(item1["type"], "bug", "type")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(item1["status"], "active", "status")
	if r is String:
		_close_db(db)
		return r

	var item2 := db.get_item("MNV-0002")
	r = A.is_false(item2.is_empty(), "MNV-0002 exists")
	_close_db(db)
	return r


func test_rebuild_inserts_item_tags() -> Variant:
	var jsonl_path := _test_dir + "/tags.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r

	var item := db.get_item("MNV-0001")
	r = A.has_key(item, "tags", "has tags key")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(item["tags"].size(), 2, "2 tags")
	if r is String:
		_close_db(db)
		return r
	r = A.contains(item["tags"], "crash", "crash tag")
	if r is String:
		_close_db(db)
		return r
	r = A.contains(item["tags"], "config", "config tag")
	_close_db(db)
	return r


func test_rebuild_inserts_item_priority() -> Variant:
	var jsonl_path := _test_dir + "/priority.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r
	var item := db.get_item("MNV-0001")
	r = A.eq(int(item.get("priority", 0)), 2, "priority=2")
	_close_db(db)
	return r


# -- rebuild_cache: events ----------------------------------------------------

func test_rebuild_inserts_events() -> Variant:
	var jsonl_path := _test_dir + "/events.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r

	var events := db.get_events("MNV-0001")
	r = A.eq(events.size(), 2, "2 events for MNV-0001")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(events[0]["event_type"], "created", "first event type")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(events[0]["actor"], "imran", "first event actor")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(events[0]["note"], "Item created", "first event note")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(events[1]["event_type"], "status_changed", "second event type")
	_close_db(db)
	return r


# -- rebuild_cache: comments --------------------------------------------------

func test_rebuild_inserts_comments() -> Variant:
	var jsonl_path := _test_dir + "/comments.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r

	var comments := db.list_comments("MNV-0001")
	r = A.eq(comments.size(), 2, "2 comments")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(comments[0]["id"], 1, "comment id=1 preserved")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(comments[0]["author"], "dana", "author")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(comments[1]["id"], 2, "comment id=2 preserved")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(comments[1]["parent_id"], 1, "parent_id threading preserved")
	_close_db(db)
	return r


# -- rebuild_cache: links -----------------------------------------------------

func test_rebuild_inserts_links() -> Variant:
	var jsonl_path := _test_dir + "/links.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r

	var links := db.get_links("MNV-0002")
	r = A.eq(links.size(), 1, "1 link from MNV-0002")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(links[0]["to"], "MNV-0001", "to_id")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(links[0]["relation"], "follow_up", "relation")
	_close_db(db)
	return r


# -- rebuild_cache: saved queries ---------------------------------------------

func test_rebuild_inserts_saved_queries() -> Variant:
	var jsonl_path := _test_dir + "/queries.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r

	var q := db.load_query("open-bugs")
	r = A.is_false(q.is_empty(), "saved query loaded")
	if r is String:
		_close_db(db)
		return r
	r = A.has_key(q, "filter", "has filter")
	_close_db(db)
	return r


# -- rebuild_cache: attachments -----------------------------------------------

func test_rebuild_inserts_attachments() -> Variant:
	# "hello" in base64 = "aGVsbG8="
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"item","id":"T-0001","type":"chore","status":"open","title":"X","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
		+ '{"_type":"attachment","id":3,"item_id":"T-0001","filename":"hello.txt","data":"aGVsbG8=","created_at":"2026-01-01T00:00:00Z","mime_type":"text/plain","size_bytes":5}\n'
	)
	var jsonl_path := _test_dir + "/att.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, jsonl)

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r

	var att := db.get_attachment(3)
	r = A.is_false(att.is_empty(), "attachment found by id=3")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(att["filename"], "hello.txt", "filename")
	if r is String:
		_close_db(db)
		return r
	var expected := PackedByteArray([104, 101, 108, 108, 111])  # "hello"
	r = A.eq(att["data"], expected, "binary data correct")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(att["mime_type"], "text/plain", "mime_type")
	_close_db(db)
	return r


# -- rebuild_cache: secrets ---------------------------------------------------

func test_rebuild_inserts_secrets() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"item","id":"T-0001","type":"secret","status":"active","title":"S","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
		+ '{"_type":"secret","handle":"T-0001","ciphertext":"Y2lwaGVy","iv":"aXY=","mac":"bWFj","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}\n'
	)
	var jsonl_path := _test_dir + "/secrets.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, jsonl)

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r

	var s := db.get_secret_raw("T-0001")
	r = A.is_false(s.is_empty(), "secret found")
	if r is String:
		_close_db(db)
		return r
	r = A.is_true(s["ciphertext"] is PackedByteArray, "ciphertext is bytes")
	if r is String:
		_close_db(db)
		return r
	var expected_ct := Marshalls.base64_to_raw("Y2lwaGVy")
	r = A.eq(s["ciphertext"], expected_ct, "ciphertext bytes match")
	if r is String:
		_close_db(db)
		return r
	r = A.is_false(s["requires_2fa"], "requires_2fa=false by default")
	_close_db(db)
	return r


func test_rebuild_inserts_secret_requires_2fa() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"item","id":"T-0001","type":"secret","status":"active","title":"S","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
		+ '{"_type":"secret","handle":"T-0001","ciphertext":"Y2lwaGVy","iv":"aXY=","mac":"bWFj","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","requires_2fa":true}\n'
	)
	var jsonl_path := _test_dir + "/secrets_2fa.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, jsonl)

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r
	var s := db.get_secret_raw("T-0001")
	r = A.is_true(s["requires_2fa"], "requires_2fa=true")
	_close_db(db)
	return r


func test_rebuild_inserts_secret_versions() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"T"}\n'
		+ '{"_type":"item","id":"T-0001","type":"secret","status":"active","title":"S","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n'
		+ '{"_type":"secret","handle":"T-0001","ciphertext":"Y2lwaGVy","iv":"aXY=","mac":"bWFj","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}\n'
		+ '{"_type":"secret_version","handle":"T-0001","version":1,"ciphertext":"b2xkY3Q=","iv":"b2xkaXY=","mac":"b2xkbWFj","created_at":"2026-01-01T00:00:00Z","rotated_by":"imran"}\n'
	)
	var jsonl_path := _test_dir + "/secret_versions.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, jsonl)

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r

	var versions := db.get_secret_versions("T-0001")
	r = A.eq(versions.size(), 1, "1 version")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(versions[0]["version"], 1, "version=1")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(versions[0]["rotated_by"], "imran", "rotated_by")
	_close_db(db)
	return r


# -- rebuild_cache: vault meta ------------------------------------------------

func test_rebuild_sets_vault_salt_and_verify() -> Variant:
	var jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":0,"id_prefix":"T","vault_salt":"c2FsdA==","vault_verify":"dmVyaWZ5"}\n'
	)
	var jsonl_path := _test_dir + "/vault_meta.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, jsonl)

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(db.get_meta_value("vault_salt", ""), "c2FsdA==", "vault_salt stored")
	if r is String:
		_close_db(db)
		return r
	r = A.eq(db.get_meta_value("vault_verify", ""), "dmVyaWZ5", "vault_verify stored")
	_close_db(db)
	return r


# -- rebuild_cache: replaces stale cache --------------------------------------

func test_rebuild_replaces_existing_cache() -> Variant:
	var jsonl_path := _test_dir + "/replace.dct.jsonl"
	var cache_path := jsonl_path + ".cache"

	# First build
	_write_file(jsonl_path, _minimal_jsonl())
	var db1 := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	_close_db(db1)

	# Modify JSONL — change item title
	var jsonl2 := (
		'{"_type":"meta","version":"1.0.0","counter":1,"id_prefix":"MNV"}\n'
		+ '{"_type":"item","id":"MNV-0001","type":"bug","status":"closed","title":"UPDATED TITLE","created_at":"2026-03-15T10:30:00Z","updated_at":"2026-03-21T00:00:00Z"}\n'
	)
	_write_file(jsonl_path, jsonl2)
	var db2 := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(db2, "db2 not null")
	if r is String:
		_close_db(db2)
		return r
	var item := db2.get_item("MNV-0001")
	r = A.eq(item["title"], "UPDATED TITLE", "title updated after rebuild")
	if r is String:
		_close_db(db2)
		return r
	r = A.eq(item["status"], "closed", "status updated after rebuild")
	_close_db(db2)
	return r


# -- is_cache_valid -----------------------------------------------------------

func test_is_cache_valid_false_when_no_cache() -> Variant:
	var jsonl_path := _test_dir + "/nocache.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())
	return A.is_false(JSONLCache.is_cache_valid(jsonl_path, cache_path), "no cache → invalid")


func test_is_cache_valid_true_after_rebuild() -> Variant:
	var jsonl_path := _test_dir + "/valid.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	_close_db(db)
	return A.is_true(JSONLCache.is_cache_valid(jsonl_path, cache_path), "valid after rebuild")


func test_is_cache_valid_false_after_jsonl_change() -> Variant:
	var jsonl_path := _test_dir + "/stale.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	_close_db(db)

	# Overwrite the JSONL with different content (different size → different fingerprint)
	_write_file(jsonl_path, _minimal_jsonl() + '{"_type":"item","id":"MNV-0099","type":"chore","status":"open","title":"Extra","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}\n')
	return A.is_false(JSONLCache.is_cache_valid(jsonl_path, cache_path), "stale after JSONL change")


func test_is_cache_valid_false_when_cache_missing_hash() -> Variant:
	## A cache created without a jsonl_hash (e.g. manually) is treated as invalid.
	var jsonl_path := _test_dir + "/nohash.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	# Create a cache but remove the jsonl_hash key
	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	db._exec("DELETE FROM docket_meta WHERE key='jsonl_hash';")
	_close_db(db)

	return A.is_false(JSONLCache.is_cache_valid(jsonl_path, cache_path), "no hash → invalid")


# -- open_or_rebuild ----------------------------------------------------------

func test_open_or_rebuild_creates_cache_when_missing() -> Variant:
	var jsonl_path := _test_dir + "/openorrebuild.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	var db := JSONLCache.open_or_rebuild(jsonl_path)
	var r = A.not_null(db, "db not null")
	if r is String:
		_close_db(db)
		return r
	r = A.is_true(db.is_open(), "db is open")
	if r is String:
		_close_db(db)
		return r
	r = A.is_true(FileAccess.file_exists(cache_path), "cache file created")
	_close_db(db)
	return r


func test_open_or_rebuild_reuses_valid_cache() -> Variant:
	var jsonl_path := _test_dir + "/reuse.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	_write_file(jsonl_path, _minimal_jsonl())

	# Build cache the first time
	var db1 := JSONLCache.open_or_rebuild(jsonl_path)
	_close_db(db1)

	# Second call should reuse — data should still be present
	var db2 := JSONLCache.open_or_rebuild(jsonl_path)
	var r = A.not_null(db2, "db2 not null")
	if r is String:
		_close_db(db2)
		return r
	var item := db2.get_item("MNV-0001")
	r = A.is_false(item.is_empty(), "item found in reused cache")
	_close_db(db2)
	return r


func test_open_or_rebuild_rebuilds_stale_cache() -> Variant:
	var jsonl_path := _test_dir + "/rebuild_stale.dct.jsonl"
	_write_file(jsonl_path, _minimal_jsonl())

	# Build initial cache
	var db1 := JSONLCache.open_or_rebuild(jsonl_path)
	_close_db(db1)

	# Now update JSONL with a new item
	var new_jsonl := (
		'{"_type":"meta","version":"1.0.0","counter":4,"id_prefix":"MNV"}\n'
		+ '{"_type":"item","id":"MNV-0001","type":"bug","status":"active","title":"Crash on empty config","created_at":"2026-03-15T10:30:00Z","updated_at":"2026-03-20T14:22:00Z"}\n'
		+ '{"_type":"item","id":"MNV-NEWONE","type":"chore","status":"open","title":"Brand new item","created_at":"2026-03-26T00:00:00Z","updated_at":"2026-03-26T00:00:00Z"}\n'
	)
	_write_file(jsonl_path, new_jsonl)

	var db2 := JSONLCache.open_or_rebuild(jsonl_path)
	var r = A.not_null(db2, "db2 not null")
	if r is String:
		_close_db(db2)
		return r
	var new_item := db2.get_item("MNV-NEWONE")
	r = A.is_false(new_item.is_empty(), "new item present after rebuild")
	if r is String:
		_close_db(db2)
		return r
	r = A.eq(new_item["title"], "Brand new item", "new item title correct")
	_close_db(db2)
	return r


# -- Roundtrip: serialize → parse → rebuild → query --------------------------

func test_roundtrip_items_match() -> Variant:
	## Build a DB, serialize it to JSONL, rebuild cache from JSONL, verify items match.
	var src_db_path := _test_dir + "/roundtrip_src.dct"
	var jsonl_path := _test_dir + "/roundtrip.dct.jsonl"
	var cache_path := jsonl_path + ".cache"

	# Create source database
	var src_db := DocketDB.create_new(src_db_path)
	src_db.set_id_prefix("RT")
	src_db.set_project_name("roundtrip-test")
	src_db.set_counter(0)
	src_db.insert_item("RT-0001", {
		"type": "bug", "status": "active",
		"title": "Roundtrip bug", "description": "A bug for roundtrip testing",
		"created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-02T00:00:00Z",
		"created_by": "alice", "priority": 1,
		"tags": ["roundtrip", "test"]
	})
	src_db.insert_item("RT-0002", {
		"type": "chore", "status": "open",
		"title": "Roundtrip chore",
		"created_at": "2026-01-03T00:00:00Z", "updated_at": "2026-01-03T00:00:00Z",
	})
	src_db._exec("INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
		["RT-0001", "created", "alice", "2026-01-01T00:00:00Z", "Item created"])
	src_db._exec("INSERT INTO comments (id, item_id, parent_id, author, text, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
		[1, "RT-0001", 0, "bob", "Looks broken.", "open", "2026-01-04T00:00:00Z"])
	src_db._exec("INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
		["RT-0002", "RT-0001", "blocks"])
	src_db.save_query("my-bugs", {"filter": {"type": "bug"}})

	# Serialize to JSONL
	var jsonl_content := JSONLSerializer.serialize_all(src_db)
	src_db.close()
	_write_file(jsonl_path, jsonl_content)

	# Rebuild cache from JSONL
	var rebuilt := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	var r = A.not_null(rebuilt, "rebuilt db not null")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r

	# Verify items
	var i1 := rebuilt.get_item("RT-0001")
	r = A.is_false(i1.is_empty(), "RT-0001 exists in rebuilt")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.eq(i1["title"], "Roundtrip bug", "title")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.eq(i1["description"], "A bug for roundtrip testing", "description")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.eq(int(i1.get("priority", 0)), 1, "priority")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.contains(i1.get("tags", []), "roundtrip", "roundtrip tag")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r

	# Verify events
	var events := rebuilt.get_events("RT-0001")
	r = A.eq(events.size(), 1, "1 event for RT-0001")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.eq(events[0]["event_type"], "created", "event_type")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r

	# Verify comments
	var comments := rebuilt.list_comments("RT-0001")
	r = A.eq(comments.size(), 1, "1 comment")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.eq(comments[0]["id"], 1, "comment id=1")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.eq(comments[0]["text"], "Looks broken.", "comment text")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r

	# Verify links
	var links := rebuilt.get_links("RT-0002")
	r = A.eq(links.size(), 1, "1 link from RT-0002")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.eq(links[0]["to"], "RT-0001", "link to RT-0001")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.eq(links[0]["relation"], "blocks", "link relation")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r

	# Verify saved query
	var q := rebuilt.load_query("my-bugs")
	r = A.is_false(q.is_empty(), "saved query loaded")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r

	# Verify meta
	r = A.eq(rebuilt.get_id_prefix(), "RT", "id_prefix")
	if r is String:
		_close_db(rebuilt)
		_delete_db(src_db_path)
		return r
	r = A.eq(rebuilt.get_project_name(), "roundtrip-test", "project name")

	_close_db(rebuilt)
	_delete_db(src_db_path)
	return r


# -- Error cases --------------------------------------------------------------

func test_rebuild_returns_null_for_missing_jsonl() -> Variant:
	var db := JSONLCache.rebuild_cache(
		_test_dir + "/nonexistent.dct.jsonl",
		_test_dir + "/nonexistent.dct.jsonl.cache"
	)
	var r = A.is_null(db, "null returned for missing JSONL")
	_close_db(db)
	return r


func test_is_cache_valid_false_for_missing_jsonl() -> Variant:
	## If JSONL doesn't exist, fingerprint is empty → always invalid.
	var jsonl_path := _test_dir + "/ghost.dct.jsonl"
	var cache_path := jsonl_path + ".cache"
	# Create a dummy cache but leave JSONL absent
	_write_file(jsonl_path, _minimal_jsonl())
	var db := JSONLCache.rebuild_cache(jsonl_path, cache_path)
	_close_db(db)
	DirAccess.remove_absolute(jsonl_path)
	return A.is_false(JSONLCache.is_cache_valid(jsonl_path, cache_path), "invalid when JSONL missing")
