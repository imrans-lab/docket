extends RefCounted
class_name JSONLValidator
## Structural checks on a .dct JSONL file, without opening it as a database.
##
## This deliberately works on files Docket refuses to open — after resolving a
## git merge conflict by hand (or with an agent), this is how you confirm the
## result is well-formed *before* committing it.


static func validate_file(path: String) -> Dictionary:
	## Returns:
	##   ok:       true if the file is safe to open
	##   errors:   problems that make the file unopenable
	##   warnings: problems that Docket tolerates but that usually mean a
	##             botched merge (dangling references, skipped lines)
	##   counts:   per-type line counts, for a sanity check against expectations
	var report := {
		"path": path,
		"ok": false,
		"errors": [],
		"warnings": [],
		"counts": {},
	}

	if not FileAccess.file_exists(path):
		report["errors"].append("file not found: %s" % path)
		return report

	var parsed := JSONLParser.parse_file(path)

	var parse_error: String = str(parsed.get("error", ""))
	if not parse_error.is_empty():
		report["errors"].append(parse_error)
		# Conflict markers abort parsing, so nothing below would be meaningful.
		return report

	for issue in parsed.get("issues", []):
		report["warnings"].append(str(issue))

	report["counts"] = {
		"items": parsed["items"].size(),
		"events": parsed["events"].size(),
		"comments": parsed["comments"].size(),
		"links": parsed["links"].size(),
		"attachments": parsed["attachments"].size(),
		"secrets": parsed["secrets"].size(),
		"secret_versions": parsed["secret_versions"].size(),
		"saved_queries": parsed["saved_queries"].size(),
	}

	# -- Meta ------------------------------------------------------------------
	var meta: Dictionary = parsed["meta"]
	if meta.is_empty():
		report["errors"].append("no meta line — Docket cannot open this file")
	elif not JSONLParser.validate_meta(meta):
		report["errors"].append(
			"meta line is missing required fields (version, counter, id_prefix)"
		)

	# -- Items -----------------------------------------------------------------
	# A duplicate id is the signature of a merge that kept both sides of an
	# edited item. Docket would silently keep only one.
	var seen_ids := {}
	for item in parsed["items"]:
		var id: String = str(item.get("id", ""))
		if id.is_empty():
			report["errors"].append("item with empty id")
			continue
		if seen_ids.has(id):
			report["errors"].append("duplicate item id: %s" % id)
		seen_ids[id] = true

	# -- Dangling references ---------------------------------------------------
	_check_orphans(parsed["events"], "item_id", seen_ids, "event", report)
	_check_orphans(parsed["comments"], "item_id", seen_ids, "comment", report)
	_check_orphans(parsed["attachments"], "item_id", seen_ids, "attachment", report)
	_check_orphans(parsed["links"], "from_id", seen_ids, "link", report)

	# Link targets may be cross-project ("project:ID"), which we cannot resolve
	# from a single file — only check bare local ids.
	for lnk in parsed["links"]:
		var to_id: String = str(lnk.get("to_id", ""))
		if to_id.is_empty() or to_id.contains(":"):
			continue
		if not seen_ids.has(to_id):
			report["warnings"].append("link points at unknown item: %s" % to_id)

	report["ok"] = report["errors"].is_empty()
	return report


static func _check_orphans(
	rows: Array, field: String, valid_ids: Dictionary, label: String, report: Dictionary
) -> void:
	## Records referencing an item that is not in the file. Docket drops these
	## on load, so they are silent data loss rather than a hard failure.
	var orphans := {}
	for row in rows:
		var ref: String = str(row.get(field, ""))
		if ref.is_empty() or valid_ids.has(ref):
			continue
		orphans[ref] = int(orphans.get(ref, 0)) + 1
	for ref in orphans:
		report["warnings"].append(
			"%d %s(s) reference missing item %s — these are dropped on load"
			% [orphans[ref], label, ref]
		)


static func format_report(report: Dictionary) -> String:
	## Human-readable rendering for the CLI.
	var lines: PackedStringArray = []
	var status := "OK" if report["ok"] else "FAILED"
	lines.append("%s: %s" % [status, report["path"]])

	for err in report["errors"]:
		lines.append("  ERROR:   %s" % err)
	for warn in report["warnings"]:
		lines.append("  WARNING: %s" % warn)

	var counts: Dictionary = report["counts"]
	if not counts.is_empty():
		var parts: PackedStringArray = []
		for key in counts:
			parts.append("%s=%d" % [key, counts[key]])
		lines.append("  " + ", ".join(parts))

	return "\n".join(lines)
