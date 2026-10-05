extends SceneTree
## Independent process for the poll contract; it performs real MCP CRUD and
## exits without settling, leaving the journal as a live writer would.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 5:
		quit(2)
		return
	var path := args[0]
	var db := DocketDBJsonl.open_jsonl(path)
	if args[4] == "private" and db != null:
		# Open the real canonical, preserving its receipt, but give this writer
		# an independent SQLite cache so the shell must replay its journal.
		db.checkpoint()
		var cache_path := path + ".writer.cache"
		var cache := DocketDB.new()
		if DirAccess.copy_absolute(JSONLCache.cache_path_for(path), cache_path) != OK or not cache.open(cache_path, false):
			db.close()
			db = null
		else:
			db._db.close_db()
			db._adopt(cache)
			if db._path != cache_path or not ProjectOpenings.opening_refusal(db).is_empty() or db.is_stale():
				db.close()
				db = null
	var result := {"error": "writer could not open project"}
	if db != null:
		var tools := ToolRegistry.new()
		tools.init(TypeRegistryBootstrap.load_shipped_schema(), db, {"poll0": db})
		var input := {"id": "" if args[2] == "<no-item-id>" else args[2], "project": "poll0"}
		match args[1]:
			"create": input = {"type": "chore", "title": "row created", "project": "poll0"}
			"update": input.title = "row updated"
			"transition": input.to = "in_progress"
		result = tools.call_tool("docket_" + args[1], input)
		db._jsonl_path = ""
		db.close()
	var file := FileAccess.open(args[3], FileAccess.WRITE)
	if file == null:
		quit(3)
		return
	file.store_string(JSON.stringify(result))
	file.close()
	quit(0)
