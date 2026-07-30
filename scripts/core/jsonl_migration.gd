extends RefCounted
class_name JSONLMigration
## SQLite → JSONL migration for .dct files.
## Converts an existing SQLite .dct file to JSONL format in place,
## keeping a .sqlite.bak backup of the original.


# -- Format detection ---------------------------------------------------------

static func is_sqlite_dct(path: String) -> bool:
	## Return true if the file at path starts with the SQLite magic bytes.
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


static func is_jsonl_dct(path: String) -> bool:
	## Return true if the first line of the file is a JSON object with _type == "meta".
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return false
	var first_line := f.get_line()
	f.close()
	if first_line.is_empty():
		return false
	var parsed = JSON.parse_string(first_line.strip_edges())
	if parsed == null or not parsed is Dictionary:
		return false
	return parsed.get("_type", "") == "meta"


static func detect_format(path: String) -> String:
	## Detect the format of a .dct file.
	## Returns one of: "sqlite", "jsonl", "json_v1", "unknown".
	if not FileAccess.file_exists(path):
		return "unknown"

	if is_sqlite_dct(path):
		return "sqlite"

	if is_jsonl_dct(path):
		return "jsonl"

	# Try JSON v1 (the old dict-based format used before SQLite)
	if DocketMigration.is_json_dct(path):
		return "json_v1"

	return "unknown"


# -- Migration ----------------------------------------------------------------

static func migrate_to_jsonl(sqlite_path: String) -> Dictionary:
	## Convert a SQLite .dct file to JSONL format.
	##
	## Steps:
	##   1. Verify the file is actually SQLite (magic bytes check).
	##   2. Open via DocketDB.
	##   3. Serialize everything via JSONLSerializer.serialize_all().
	##   4. Close the DB (releases SQLite lock).
	##   5. Rename sqlite_path → sqlite_path + ".sqlite.bak".
	##   6. Write JSONL text to sqlite_path.
	##   7. Verify by reparsing the written file via JSONLParser.
	##   8. Delete .dct-shm and .dct-wal artifacts if present.
	##
	## Returns: {success: bool, error: String, item_count: int, backup_path: String}

	var result := {
		"success": false,
		"error": "",
		"item_count": 0,
		"backup_path": "",
	}

	# Step 1: Verify it's actually SQLite.
	if not FileAccess.file_exists(sqlite_path):
		result["error"] = "file not found: %s" % sqlite_path
		return result

	if not is_sqlite_dct(sqlite_path):
		result["error"] = "not a SQLite file: %s" % sqlite_path
		return result

	print("JSONLMigration: migrating %s from SQLite to JSONL..." % sqlite_path)

	# Step 2: Open via DocketDB.
	var db := DocketDB.new()
	if not db.open(sqlite_path):
		result["error"] = "failed to open SQLite DB: %s" % sqlite_path
		return result

	# Step 3: Serialize everything.
	var jsonl_text := JSONLSerializer.serialize_all(db)
	if jsonl_text.is_empty():
		db.close()
		result["error"] = "serializer produced empty output for: %s" % sqlite_path
		return result

	# Count items from the serialized output (count "item" lines).
	var item_count := 0
	for line in jsonl_text.split("\n"):
		if line.begins_with('{"_type":"item"'):
			item_count += 1

	# Step 4: Close the DB before touching the file (SQLite holds a lock).
	db.close()
	db = null

	# Step 5: Rename original to .sqlite.bak.
	var backup_path := sqlite_path + ".sqlite.bak"
	var rename_err := DirAccess.rename_absolute(sqlite_path, backup_path)
	if rename_err != OK:
		result["error"] = "failed to rename %s → %s (error %d)" % [sqlite_path, backup_path, rename_err]
		return result

	result["backup_path"] = backup_path

	# Step 6: Write the JSONL text to the original path.
	var f := FileAccess.open(sqlite_path, FileAccess.WRITE)
	if not f:
		# Restore backup on write failure.
		DirAccess.rename_absolute(backup_path, sqlite_path)
		result["error"] = "failed to open %s for writing" % sqlite_path
		result["backup_path"] = ""
		return result

	f.store_string(jsonl_text)
	f.close()

	# Step 7: Verify by reparsing the written file.
	var parsed := JSONLParser.parse_file(sqlite_path)
	var parsed_item_count: int = parsed.get("items", []).size()
	if parsed_item_count != item_count:
		result["error"] = (
			"verification failed: wrote %d items but re-parsed %d from %s"
			% [item_count, parsed_item_count, sqlite_path]
		)
		# Leave the file in place; the backup is still there.
		return result

	# Also verify the meta line is valid.
	var meta: Dictionary = parsed.get("meta", {})
	if not JSONLParser.validate_meta(meta):
		result["error"] = "verification failed: meta line invalid in %s" % sqlite_path
		return result

	# Step 8: Clean up SQLite WAL artifacts (.dct-shm, .dct-wal).
	for suffix: String in ["-shm", "-wal"]:
		# Check WAL artifacts on the original path (now JSONL) and the backup.
		for p: String in [sqlite_path + suffix, backup_path + suffix]:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
				print("JSONLMigration: removed WAL artifact %s" % p)

	result["success"] = true
	result["item_count"] = item_count
	print("JSONLMigration: migration complete — %d items, backup at %s" % [item_count, backup_path])
	return result
