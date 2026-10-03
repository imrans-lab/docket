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
		# Open an identical sibling source through the supported entry point so
		# the process has a genuinely separate cache, then append to the source
		# watched by the shell. This fixture starts with no pending journal.
		var copy_path := path + ".writer.dct"
		if not JSONLSidecar.has_content(JSONLSidecar.path_for(path)):
			var copy := FileAccess.open(copy_path, FileAccess.WRITE)
			if copy != null:
				copy.store_buffer(FileAccess.get_file_as_bytes(path))
				copy.close()
				db = DocketDBJsonl.open_jsonl(copy_path)
				if db != null:
					db._jsonl_path = path
					db._freshness.forget()
					# A mismatch would make mutation reload the shared cache and
					# erase the independent-cache oracle; refuse that setup.
					if db.is_stale():
						db._jsonl_path = ""
						db.close()
						db = null
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
