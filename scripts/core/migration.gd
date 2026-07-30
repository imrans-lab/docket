extends RefCounted
class_name DocketMigration
## One-shot JSON→SQLite migration for .dct files.
## Detects format, migrates in a single transaction, creates .json.bak backup.


static func is_json_dct(path: String) -> bool:
	## Check if a .dct file is JSON format (not SQLite).
	## SQLite files start with "SQLite format 3\000".
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return false
	var header := f.get_buffer(16)
	f.close()
	if header.size() < 6:
		# Very small file, likely JSON (possibly empty or {})
		return true
	var header_str := header.get_string_from_utf8()
	return not header_str.begins_with("SQLite format 3")


static func is_sqlite_dct(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return false
	var header := f.get_buffer(16)
	f.close()
	if header.size() < 16:
		return false
	var header_str := header.get_string_from_utf8()
	return header_str.begins_with("SQLite format 3")


static func migrate(json_path: String) -> DocketDB:
	## Migrate a JSON .dct to SQLite .dct. Returns the opened DocketDB.
	## Creates a .json.bak backup of the original file.
	print("DocketMigration: migrating %s from JSON to SQLite..." % json_path)

	# Load JSON data
	var json_data: Dictionary = FileManager.load_file(json_path)
	if json_data.has("error"):
		push_error("DocketMigration: failed to load JSON: %s" % json_data.error)
		return null

	# Create backup
	var backup_path := json_path + ".json.bak"
	var src := FileAccess.open(json_path, FileAccess.READ)
	if src:
		var content := src.get_as_text()
		src.close()
		var dst := FileAccess.open(backup_path, FileAccess.WRITE)
		if dst:
			dst.store_string(content)
			dst.close()
		print("DocketMigration: backup saved to %s" % backup_path)

	# Delete old JSON file so SQLite can create fresh
	DirAccess.remove_absolute(json_path)

	# Create new SQLite DB
	var db := DocketDB.create_new(json_path)
	if db == null:
		push_error("DocketMigration: failed to create SQLite DB")
		return null

	# Set counter
	var counter: int = int(json_data.get("counter", 0))
	db.set_counter(counter)

	# Migrate items in a transaction
	db._begin()
	var items: Dictionary = json_data.get("items", {})
	var migrated_count := 0
	for id in items:
		var item: Dictionary = items[id]
		db.insert_item(id, item)
		migrated_count += 1
	db._commit()

	# Migrate saved queries
	var queries: Dictionary = json_data.get("queries", {})
	for name in queries:
		db.save_query(name, queries[name])

	print("DocketMigration: migrated %d items, %d saved queries" % [migrated_count, queries.size()])

	# Verify
	var rows := db._exec_select("SELECT count(*) as cnt FROM items;")
	var db_count: int = int(rows[0].cnt) if rows.size() > 0 else 0
	if db_count != migrated_count:
		push_warning("DocketMigration: count mismatch! expected %d, got %d" % [migrated_count, db_count])
	else:
		print("DocketMigration: verified %d items in SQLite" % db_count)

	return db
