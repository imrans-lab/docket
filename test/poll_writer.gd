extends SceneTree
## Independent process for the poll contract; it performs real MCP CRUD and
## exits without settling, leaving the journal as a live writer would.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 5:
		quit(2)
		return
	var path := args[0]
	var db: DocketDBJsonl
	if args[4] == "private":
		var cache := JSONLCache.rebuild_cache(path, path + ".writer.cache")
		if cache != null:
			db = DocketDBJsonl.new()
			db._jsonl_path = path
			db._adopt(cache)
	else: db = DocketDBJsonl.open_jsonl(path)
	var result := {"error": "writer could not open project"}
	if db != null:
		var tools := ToolRegistry.new()
		tools.init(TypeRegistryBootstrap.load_shipped_schema(), db, {"poll0": db})
		var input := {"id": args[2], "project": "poll0"}
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
