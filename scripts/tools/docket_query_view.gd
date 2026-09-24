extends RefCounted
class_name DocketQueryView
## A query over every open project as the Docket grid shows it: the rows
## (each with its project when several are open) plus, per row, its short ID
## and type resolution. Read-only; the same run as the standalone app's grid
## (ProjectQuery.run_with_details).

func get_definition() -> Dictionary:
	return {"name":"docket_query_view","description":"Run a query over every open project as the Docket grid shows it (read-only): {rows, details}, details[i] being {short_id, resolved} for rows[i]. When several projects are open, sort and limit apply to the merged rows and a \"project\" condition selects projects.","inputSchema":{"type":"object","properties":{"filter":{"type":"object"},"sort":{"type":"array","items":{"type":"object"}},"limit":{"type":"integer"}}}}

func execute(args: Dictionary, _schema: Dictionary, db: DocketDB, project_dbs: Dictionary, registry_for: Callable) -> Dictionary:
	var query := {}
	for key in ["filter", "sort", "limit"]:
		if args.has(key):
			query[key] = args[key]
	return ProjectQuery.new(project_dbs, registry_for).run_with_details(query, db)
