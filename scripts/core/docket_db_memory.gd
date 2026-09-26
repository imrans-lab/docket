extends DocketDBJsonl
class_name DocketDBMemory
## A project held only in this process: an in-memory SQLite database with no
## canonical file. It reuses DocketDBJsonl's checked mutation path (transaction,
## rollback on error) with the file steps removed, so every item, comment and
## query API behaves as it does on a file-backed project.
##
## get_path() returns "memory://<name>", which names the project in listings and
## never refers to a file. Creating or importing an item past max_items is
## refused with the limit in the message; nothing is evicted. MemoryProject owns
## the lease, the spill to a file, and the registration of these projects.

const PATH_SCHEME := "memory://"
const DEFAULT_MAX_ITEMS := 1000

## Items this project may hold; insert_item refuses the next item past it.
var max_items: int = DEFAULT_MAX_ITEMS
## Bumped after every committed mutation, so observers can see change without a file.
var revision: int = 0


static func create(project_name: String, item_limit: int = DEFAULT_MAX_ITEMS) -> DocketDBMemory:
	## A new, empty memory project seeded with the shipped type definitions.
	var wrapper := DocketDBMemory.new()
	wrapper._jsonl_path = PATH_SCHEME + project_name
	wrapper.max_items = item_limit
	var cache_db := DocketDB.create_new(":memory:")
	if cache_db == null:
		DocketDBJsonl.last_open_error = "could not open an in-memory database"
		return null
	wrapper._adopt(cache_db)
	var error := wrapper._exec_checked("INSERT OR REPLACE INTO docket_meta(key,value) VALUES('project',?);", [project_name])
	if error.is_empty(): error = wrapper._exec_checked("INSERT OR REPLACE INTO docket_meta(key,value) VALUES('id_prefix',?);", [DocketDB._derive_prefix(project_name)])
	if error.is_empty(): error = wrapper._exec_checked("INSERT OR REPLACE INTO docket_meta(key,value) VALUES(?,?);", [SessionProject.META_KEY, SessionProject.MODE_MEMORY])
	if error.is_empty(): error = TypeRegistryBootstrap.seed_cache(wrapper)
	if not error.is_empty():
		DocketDBJsonl.last_open_error = error
		wrapper.close()
		return null
	DocketDBJsonl.last_open_error = ""
	return wrapper


static func is_memory_path(path: String) -> bool:
	return path.begins_with(PATH_SCHEME)


func item_count() -> int:
	var rows := _exec_select("SELECT COUNT(*) AS cnt FROM items;")
	return int(rows[0].cnt) if rows.size() > 0 else 0


func usage() -> Dictionary:
	return {"items": item_count(), "max_items": max_items}


func insert_item(id: String, item: Dictionary) -> String:
	var refusal := _limit_refusal()
	return refusal if not refusal.is_empty() else super.insert_item(id, item)


func import_item_full_checked(new_id: String, exported: Dictionary) -> String:
	## Imports (docket_move and friends) honour the same bound as creation.
	var refusal := _limit_refusal()
	return refusal if not refusal.is_empty() else super.import_item_full_checked(new_id, exported)


func _limit_refusal() -> String:
	var count := item_count()
	if count < max_items:
		return ""
	return "Refused: memory project %s is at its limit of %d items (%d held). Nothing was evicted; persist it with docket_project_persist or discard items first." % [get_project_name(), max_items, count]


func serialize_as(mode: String) -> String:
	## The project's JSONL text with its storage mode recorded as `mode`. The
	## in-memory mode key is restored afterwards. Returns "" on a read failure.
	_last_sql_error = ""
	var error := _exec_checked("UPDATE docket_meta SET value=? WHERE key=?;", [mode, SessionProject.META_KEY])
	var text := JSONLSerializer.serialize_all(self) if error.is_empty() else ""
	var read_error := _last_sql_error
	_exec_checked("UPDATE docket_meta SET value=? WHERE key=?;", [SessionProject.MODE_MEMORY, SessionProject.META_KEY])
	return "" if not read_error.is_empty() else text


# -- File steps of DocketDBJsonl, replaced ------------------------------------

func is_stale() -> bool:
	return false


func reload() -> bool:
	## Nothing on disk to re-read; the database is already current.
	return true


func _mutation_precheck() -> String:
	return last_write_error if _write_blocked else ""


func _flush_jsonl() -> String:
	if _mutation_depth > 0:
		return ""
	revision += 1
	return ""
