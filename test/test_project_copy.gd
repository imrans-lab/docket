extends Node
## ProjectCopy on real JSONL owners: a copy is the source's exact bytes and
## its audit's exact bytes, a torn last line included, the source untouched;
## a destination whose audit name is already an entry (a directory, and off
## Windows a dangling link) is refused and left alone. The audited source
## İ.dct copied to i.dct, a name apart only by a letter whose lowercase
## differs between Godot and Rust (where the volume keeps the two apart),
## writes nothing while i.dct's audit lock is held through a handle of its
## own; once free, i.dct takes an unaudited source's project, and the
## audited source copied after it is refused, adding no audit beside it.
## Two names apart only in case, where the volume keeps them apart, copy
## without the copy waiting on its own lock.

var A := AssertHelpers
var _dir := ""
var _owners: Array[DocketDB] = []

const TORN_AUDIT := "{\"event\": \"secret_read\", \"ok\": true}\n{\"event\": \"torn"


func setup() -> void:
	_dir = ProjectSettings.globalize_path("user://test_project_copy_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_dir)


# Owners are closed first; every file (stages and caches are dot-files or
# companions), link and directory in the test directory goes, the dangling
# link by name, as a listing may not show it.
func teardown() -> void:
	for owner in _owners:
		owner.close()
	DirAccess.remove_absolute(_dir.path_join("linked.dct") + AuditLog.SUFFIX)
	var dir := DirAccess.open(_dir)
	dir.include_hidden = true
	for file in dir.get_files():
		DirAccess.remove_absolute(_dir.path_join(file))
	for sub in dir.get_directories():
		DirAccess.remove_absolute(_dir.path_join(sub))
	DirAccess.remove_absolute(_dir)


# An open owner of a new project `name` whose file is rewritten with a space
# after its first brace (valid, but not as Docket writes it), and, when
# `audit` is given, that audit beside it: [owner, its file's bytes].
func _source(name: String, audit: String = "") -> Array:
	var path := _dir.path_join(name)
	var created := DocketDBJsonl.create_new_jsonl(path)
	created.close()
	var text := FileAccess.get_file_as_string(path)
	var brace := text.find("{")
	text = text.substr(0, brace + 1) + " " + text.substr(brace + 1)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	if not audit.is_empty():
		file = FileAccess.open(path + AuditLog.SUFFIX, FileAccess.WRITE)
		file.store_string(audit)
		file.close()
	var owner := DocketDBJsonl.open_jsonl(path)
	_owners.append(owner)
	return [owner, FileAccess.get_file_as_bytes(path)]


# Whether `path` is the very file `other` is (one file under two names),
# by the operating system's identity of each.
static func _is_same_file(path: String, other: String) -> bool:
	var here := ProjectFile.entry(path)
	return not here.has("error") and here.get("id") == ProjectFile.entry(other).get("id")


func test_copy_is_exact() -> Variant:
	var source := _source("exact.dct", TORN_AUDIT)
	var dest := _dir.path_join("exact-copy.dct")
	var receipt := ProjectCopy.copy_jsonl("exact", source[0], dest)
	var r = A.eq(receipt.status, ProjectCopy.COPIED, "a saved project copies: %s" % receipt)
	if r != true:
		return r
	var copied := FileAccess.get_file_as_bytes(dest)
	r = A.is_true(copied == source[1] and copied.get_string_from_utf8().begins_with("{ "),
		"the copy is the source's bytes, not rewritten")
	if r != true:
		return r
	r = A.eq(FileAccess.get_file_as_bytes(dest + AuditLog.SUFFIX), TORN_AUDIT.to_utf8_buffer(), "the audit is copied exactly, its torn line too")
	if r != true:
		return r
	return A.is_true(FileAccess.get_file_as_bytes(_dir.path_join("exact.dct")) == source[1]
		and FileAccess.get_file_as_bytes(_dir.path_join("exact.dct") + AuditLog.SUFFIX) == TORN_AUDIT.to_utf8_buffer(),
		"the source and its audit are untouched")


func test_taken_audit_name_is_refused() -> Variant:
	var source := _source("plain.dct")
	var blocked := _dir.path_join("blocked.dct")
	var r = A.eq(DirAccess.make_dir_absolute(blocked + AuditLog.SUFFIX), OK, "the directory is made")
	if r != true:
		return r
	var receipt := ProjectCopy.copy_jsonl("plain", source[0], blocked)
	r = A.is_true(receipt.status == ProjectCopy.NOT_COPIED and not FileAccess.file_exists(blocked)
		and DirAccess.dir_exists_absolute(blocked + AuditLog.SUFFIX),
		"a directory at the audit name refuses the copy and stays: %s" % receipt)
	if r != true or OS.get_name() == "Windows":
		return r
	var linked := _dir.path_join("linked.dct")
	var made := DirAccess.open(_dir).create_link(_dir.path_join("nowhere"), linked + AuditLog.SUFFIX)
	r = A.eq(made, OK, "the dangling link is made")
	if r != true:
		return r
	receipt = ProjectCopy.copy_jsonl("plain", source[0], linked)
	return A.is_true(receipt.status == ProjectCopy.NOT_COPIED and not FileAccess.file_exists(linked)
		and DirAccess.open(_dir).is_link(linked.get_file() + AuditLog.SUFFIX),
		"a dangling link at the audit name refuses the copy and stays: %s" % receipt)


func test_one_destination_never_mixes_two_sources() -> Variant:
	var audited := _source("İ.dct", TORN_AUDIT)
	var plain := _source("other.dct")
	var dest := _dir.path_join("i.dct")
	# Where a volume folds İ.dct and i.dct into one name, the destination is
	# the source itself; the collision is then shown on an ordinary name, and
	# the Unicode lock key goes unexercised on that volume.
	if ProjectFile.vacant(dest).has("error"):
		if not _is_same_file(dest, _dir.path_join("İ.dct")):
			return "%s is taken, and not by its source" % dest
		print("note: İ.dct and i.dct are one file on this volume; the Unicode lock key is not exercised")
		dest = _dir.path_join("shared.dct")

	# The destination's audit lock held through a handle of its own, an OS
	# lock independent of the copy's: the oracle is that the copy takes that
	# same lock (by its native key) and so writes nothing while it is held.
	var io: Object = ClassDB.instantiate("DocketFileIO")
	var held: Dictionary = io.audit_lock(dest, 0)
	var waited := ProjectCopy.copy_jsonl("İ", audited[0], dest)
	if held.has("guard"):
		held.guard.release()
	var r = A.is_true(held.has("guard") and waited.status == ProjectCopy.NOT_COPIED and waited.phase == "lock_audit"
		and not FileAccess.file_exists(dest) and not FileAccess.file_exists(dest + AuditLog.SUFFIX),
		"a copy to a destination another holds writes nothing: %s" % waited)
	if r != true:
		return r

	# Once free, the destination takes one project; the audited source that
	# comes after finds it taken and adds no audit beside it.
	var first := ProjectCopy.copy_jsonl("other", plain[0], dest)
	var second := ProjectCopy.copy_jsonl("İ", audited[0], dest)
	r = A.is_true(first.status == ProjectCopy.COPIED and second.status == ProjectCopy.NOT_COPIED
		and FileAccess.get_file_as_bytes(dest) == plain[1] and not FileAccess.file_exists(dest + AuditLog.SUFFIX),
		"the destination keeps the first project and gets no audit of the other: %s %s" % [first, second])
	if r != true:
		return r

	# Names apart only in case share one lock key; the copy takes it once.
	# Where the volume folds case they are one file, and there is no copy.
	var cased := _source("Case.dct", TORN_AUDIT)
	var lower_path := _dir.path_join("case.dct")
	if ProjectFile.vacant(lower_path).has("error"):
		if not _is_same_file(lower_path, _dir.path_join("Case.dct")):
			return "%s is taken, and not by its source" % lower_path
		print("note: Case.dct and case.dct are one file on this volume; the shared lock key is not exercised")
		return true
	var lower := ProjectCopy.copy_jsonl("Case", cased[0], lower_path)
	return A.eq(lower.status, ProjectCopy.COPIED, "a copy to its own name in other case does not wait on itself: %s" % lower)
