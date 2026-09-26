class_name MasterBootstrap
extends RefCounted
## A host's shipped project (such as Minerva's master) installed at a path it
## names, or brought up to date there, by this process as the project's one
## owner. The host hands over the shipped bytes; it never writes the file.
##
## Absent, the project is written as shipped, whole (its events included).
## Present, its items are merged against the shipped bytes last applied
## there (kept beside it as `<path>.shipped`), each compared as Docket reads
## and writes it (key), not by its bytes: an item still as that baseline
## shipped it takes the new shipped line; an item changed or deleted since,
## or one with no baseline to judge it by, is left as it is and reported as
## a conflict; an item the shipment adds is appended with its events.
## Nothing the project has that the shipment lacks is touched or removed;
## only items and a new item's events are merged, not comments, links or
## attachments. An item the project lacks that any shipment applied here
## carried (`<path>.shipped-ids`) was deleted, and is reported, never added
## back. An item taking a new shipped line keeps its own read count. Before
## the file is changed its bytes are kept as `<path>.pre-update-<hash>`; the
## file is replaced only if it is still the one read (its identity and
## bytes), and the new baseline is written only once it is. A run cut short
## is safe to repeat: what was merged then reads as already shipped.
##
## The work runs in an EXCLUSIVE coordination operation, so no other Docket
## process writes the file meanwhile, and only while this process has the
## project closed; the host opens it afterwards. Files are written as every
## project file is (DocketDBJsonl._atomic_write).

const BASELINE_SUFFIX := ".shipped"
## Every item id any shipment applied here has carried, one per line: an
## item the project lacks that one of them is was deleted, and stays so.
const SHIPPED_IDS_SUFFIX := ".shipped-ids"
const ORIGINAL_SUFFIX := ".pre-update-"
## Counts a person's reads change, not their content; they never make a
## shipped item customized.
const VOLATILE_FIELDS := ["retrieval_count"]


## The project at `destination` (absolute) installed or updated from
## `shipped`, while `open_dbs` (selector → DocketDB) has it closed:
## {status: "installed" | "updated" | "unchanged", path, digest, inserted,
## updated, conflicts: [{id, reason}], original} or {error, kind}. `digest`
## is the SHA-256 of the shipped bytes now applied; `original` names the
## kept pre-update bytes, when the file was changed.
static func apply(destination: String, shipped: PackedByteArray, open_dbs: Dictionary, parent: RefCounted = null) -> Dictionary:
	var digest := _sha256(shipped)
	if not destination.is_absolute_path() or destination.get_extension().to_lower() != "dct":
		return _refused("the destination must be an absolute path to a .dct file", "bad_destination")
	var shipped_text := shipped.get_string_from_utf8()
	var shipped_lines := _records(shipped_text)
	if shipped_lines.has("error"):
		return _refused("the shipped project is not readable: %s" % shipped_lines.error, "bad_shipment")
	if shipped_lines.items.is_empty():
		return _refused("the shipped project has no items", "bad_shipment")
	var located := ProjectFile.locate(destination)
	if located.has("error"):
		return _refused(str(located.error), "bad_destination")
	if not ProjectSelectors.selector_for(open_dbs, located).is_empty():
		return _refused("%s is open; it is brought up to date before it is opened" % located.path, "open")
	var opened := CoordGuard.new().open_within(parent, CoordGuard.EXCLUSIVE)
	if opened.has("error"):
		return _refused("Docket cannot coordinate with its other processes now: %s" % opened.error, "coordination")
	var result := _apply_exclusive(str(located.path), shipped_text, shipped_lines, digest)
	opened.operation.close()
	return result


static func _apply_exclusive(path: String, shipped_text: String, shipped: Dictionary, digest: String) -> Dictionary:
	var report := {"status": "unchanged", "path": path, "digest": digest, "inserted": [], "updated": [], "conflicts": [], "original": ""}
	var ever_shipped := _shipped_ids(path)
	if ever_shipped.has("error"):
		return _refused(str(ever_shipped.error), "read")
	if not FileAccess.file_exists(path):
		var installed := DocketDBJsonl._atomic_write(path, shipped_text)
		if not installed.is_empty():
			return _refused("cannot write %s: %s" % [path, installed], "write")
		report.status = "installed"
		report.inserted = shipped.order.duplicate()
		return _committed(report, path, shipped_text, shipped.order, ever_shipped.ids)

	var read_as := ProjectFile.entry(path)
	if read_as.has("error"):
		return _refused("cannot identify %s: %s" % [path, read_as.error], "read")
	var current_text := FileAccess.get_file_as_string(path)
	if current_text.is_empty() and FileAccess.get_open_error() != OK:
		return _refused("cannot read %s" % path, "read")
	var current := _records(current_text)
	if current.has("error"):
		return _refused("%s is not readable: %s" % [path, current.error], "read")
	var baseline := {"items": {}}
	var baseline_text := FileAccess.get_file_as_string(path + BASELINE_SUFFIX) if FileAccess.file_exists(path + BASELINE_SUFFIX) else ""
	if not baseline_text.is_empty():
		baseline = _records(baseline_text)
		if baseline.has("error"):
			baseline = {"items": {}}  # unreadable: judge nothing pristine
	var same_format := str(current.meta.get("version", "")) == str(shipped.meta.get("version", ""))

	var lines: Array = current.lines.duplicate()
	var appended: Array[String] = []
	for id in shipped.order:
		var offered: Dictionary = shipped.items[id]
		var before: Dictionary = baseline.items.get(id, {})
		if not current.items.has(id):
			if not before.is_empty() or ever_shipped.ids.has(id):
				report.conflicts.append({"id": id, "reason": "deleted since it was shipped"})
				continue
			if not same_format:
				report.conflicts.append({"id": id, "reason": "the project's format differs from the shipment's"})
				continue
			appended.append(offered.line)
			for event_line in shipped.events.get(id, []):
				appended.append(event_line)
			report.inserted.append(id)
			continue
		var existing: Dictionary = current.items[id]
		if existing.key == offered.key:
			continue
		if before.is_empty():
			report.conflicts.append({"id": id, "reason": "no shipped baseline shows whether it was customized"})
		elif existing.key != before.key:
			report.conflicts.append({"id": id, "reason": "customized since it was shipped"})
		elif not same_format:
			report.conflicts.append({"id": id, "reason": "the project's format differs from the shipment's"})
		else:
			lines[existing.index] = _with_count(offered.line, existing.count)
			report.updated.append(id)

	if report.inserted.is_empty() and report.updated.is_empty():
		return _committed(report, path, shipped_text, shipped.order, ever_shipped.ids)
	var merged := "\n".join(PackedStringArray(lines)).strip_edges(false, true)
	for line in appended:
		merged += "\n" + line
	merged += "\n"
	var check := JSONLParser.parse_text(merged, path)
	if not str(check.get("error", "")).is_empty():
		return _refused("the merged project would not be readable: %s" % check.error, "merge")
	# The file must still be the one read: another writer (a git checkout, an
	# editor) may have saved over it meanwhile, which is not overwritten.
	var now := ProjectFile.entry(path)
	if now.get("id") != read_as.get("id") or FileAccess.get_file_as_string(path) != current_text:
		return _refused("%s changed while it was being brought up to date; nothing was written" % path, "changed")
	var original := "%s%s%s" % [path, ORIGINAL_SUFFIX, _sha256(current_text.to_utf8_buffer()).substr(0, 16)]
	if not FileAccess.file_exists(original) or FileAccess.get_file_as_string(original) != current_text:
		var kept := DocketDBJsonl._atomic_write(original, current_text)
		if not kept.is_empty():
			return _refused("cannot keep the original of %s: %s" % [path, kept], "write")
	report.original = original
	var written := DocketDBJsonl._atomic_write(path, merged)
	if not written.is_empty():
		return _refused("cannot write %s (its original is kept at %s): %s" % [path, original, written], "write")
	report.status = "updated"
	return _committed(report, path, shipped_text, shipped.order, ever_shipped.ids)


# `report` once the shipped bytes are recorded as applied at `path`: the ids
# they carry join those shipped before (`known`), then the baseline is
# written, last, so a failure before it leaves the merge to be made again.
static func _committed(report: Dictionary, path: String, shipped_text: String, carried: Array, known: Dictionary) -> Dictionary:
	var ids := known.duplicate()
	for id in carried:
		ids[id] = true
	if ids.size() != known.size() or not FileAccess.file_exists(path + SHIPPED_IDS_SUFFIX):
		var listed := PackedStringArray(ids.keys())
		listed.sort()
		var kept := DocketDBJsonl._atomic_write(path + SHIPPED_IDS_SUFFIX, "\n".join(listed) + "\n")
		if not kept.is_empty():
			var refused := _refused("%s was written but its shipped ids were not: %s" % [path, kept], "write")
			refused["report"] = report
			return refused
	var baseline_path := path + BASELINE_SUFFIX
	if FileAccess.file_exists(baseline_path) and FileAccess.get_file_as_string(baseline_path) == shipped_text:
		return report
	var recorded := DocketDBJsonl._atomic_write(baseline_path, shipped_text)
	if not recorded.is_empty():
		var refused := _refused("%s was written but its shipped baseline was not: %s" % [path, recorded], "write")
		refused["report"] = report
		return refused
	return report


# The JSONL `text` by record: {meta, lines, order (item ids as they come),
# items: id → {line, index, key}, events: item id → [line]} or {error}.
static func _records(text: String) -> Dictionary:
	var parsed := JSONLParser.parse_text(text, "")
	if not str(parsed.get("error", "")).is_empty():
		return {"error": str(parsed.error)}
	var keys := {}
	var counts := {}
	for item in parsed.get("items", []):
		keys[str(item.get("id", ""))] = _key(item)
		counts[str(item.get("id", ""))] = int(item.get("retrieval_count", 0))
	var records := {"meta": parsed.get("meta", {}), "lines": [], "order": [], "items": {}, "events": {}}
	var index := -1
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		records.lines.append(raw)
		index += 1
		if line.is_empty():
			continue
		var value = JSON.parse_string(line)
		if not value is Dictionary:
			continue
		match str(value.get("_type", "")):
			"item":
				var id := str(value.get("id", ""))
				if id.is_empty() or records.items.has(id) or not keys.has(id):
					return {"error": "item line %d has no usable id or repeats one" % (index + 1)}
				records.items[id] = {"line": raw, "index": index, "key": keys[id], "count": counts[id]}
				records.order.append(id)
			"event":
				var owner := str(value.get("item_id", ""))
				if not records.events.has(owner):
					records.events[owner] = []
				records.events[owner].append(raw)
	return records


# What an item (as JSONLParser reads it) is, the way Docket keeps it, as
# sorted-key JSON: its own text as stored (DocketDB._normalize_text), tags
# once each and sorted, and none of the empty or zero columns a rewrite omits; its
# `fields` and `extras` exactly as they are, since they are stored whole.
# VOLATILE_FIELDS are left out. The shipped line and Docket's rewrite of
# the same item have the same key.
static func _key(item: Dictionary) -> String:
	var kept := {}
	for field in item:
		if field == "_type" or field in VOLATILE_FIELDS:
			continue
		var value = item[field]
		if field in ["fields", "extras"]:
			kept[field] = value
			continue
		if value is String:
			value = DocketDB._normalize_text(value)
		if field == "tags" and value is Array:
			# Stored once each (item_tags), in order.
			var tags: Array = []
			for tag in value:
				if not tags.has(str(tag)):
					tags.append(str(tag))
			tags.sort()
			value = tags
		if value == null or (value is String and value.is_empty()) or ((value is int or value is float) and value == 0) \
				or ((value is Array or value is Dictionary) and value.is_empty()):
			continue
		kept[field] = value
	return JSON.stringify(kept, "", true)


# The shipped `line` with the item's own read `count` in place of the
# shipped one; the line as shipped when there is none to keep.
static func _with_count(line: String, count: int) -> String:
	if count == 0:
		return line
	var value = JSON.parse_string(line)
	value["retrieval_count"] = count
	return JSON.stringify(value)


# The ids shipments applied at `path` have carried: {ids: id → true}, or
# {error} when the record of them cannot be read.
static func _shipped_ids(path: String) -> Dictionary:
	var ids := {}
	if not FileAccess.file_exists(path + SHIPPED_IDS_SUFFIX):
		return {"ids": ids}
	var text := FileAccess.get_file_as_string(path + SHIPPED_IDS_SUFFIX)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		return {"error": "cannot read %s%s" % [path, SHIPPED_IDS_SUFFIX]}
	for line in text.split("\n", false):
		ids[line.strip_edges()] = true
	return {"ids": ids}


## What the effective schema (TypeRegistryBootstrap), compiled as it is
## for a new project, has that the project `registry` reads by lacks:
## [{slug, missing_type}] or [{slug, missing_fields, mismatched_fields:
## [{key, declared, persisted}], missing_states}], or [{error}] when its
## types cannot be read. A legacy (1.0) project is read by that schema
## itself and lacks nothing; a versioned one keeps its own definitions,
## which are reported against, never replaced.
static func capability_gaps(registry: TypeRegistry) -> Array:
	var gaps: Array = []
	if registry == null or registry.is_legacy():
		return gaps
	var listed := registry.list_types(true)
	if not listed.is_empty() and listed[0].has("error"):
		return [{"error": str(listed[0].error)}]
	var compiled := {}
	for revision in TypeRegistryBootstrap.records(TypeRegistryBootstrap.effective_schema()).type_def_versions:
		compiled[str(revision.definition.slug)] = revision.definition
	var slugs := compiled.keys()
	slugs.sort()
	for slug in slugs:
		var persisted := registry.get_type(slug)
		if persisted.has("error"):
			gaps.append({"slug": slug, "missing_type": true})
			continue
		var kinds := {}
		for descriptor in persisted.definition.get("fields", []):
			kinds[str(descriptor.get("key", ""))] = str(descriptor.get("type", ""))
		var missing_fields: Array = []
		var mismatched: Array = []
		for descriptor in compiled[slug].fields:
			var key := str(descriptor.key)
			if not kinds.has(key):
				missing_fields.append(key)
			elif kinds[key] != str(descriptor.type):
				mismatched.append({"key": key, "declared": str(descriptor.type), "persisted": kinds[key]})
		var states := {}
		for state in persisted.definition.get("lifecycle", {}).get("states", []):
			states[str(state.get("key", ""))] = true
		var missing_states: Array = []
		for state in compiled[slug].lifecycle.states:
			if not states.has(str(state.key)):
				missing_states.append(str(state.key))
		if not (missing_fields.is_empty() and mismatched.is_empty() and missing_states.is_empty()):
			gaps.append({"slug": slug, "missing_fields": missing_fields, "mismatched_fields": mismatched, "missing_states": missing_states})
	return gaps


static func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()


static func _refused(message: String, kind: String) -> Dictionary:
	return {"error": message, "kind": kind}
