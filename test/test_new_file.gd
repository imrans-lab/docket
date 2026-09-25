extends Node
## NewFile's one protocol, walked through as a caller meets it: a stage keeps
## its own copy of the caller's bytes and their SHA-256; publishing onto a
## name another file holds changes nothing; publishing onto a free name
## leaves exactly the staged bytes there, owner-only on Unix, and the stage's
## name gone; a stage changed in place after staging is not published.

var A := AssertHelpers
var _dir := ""

const CONTENT := "staged by docket\n"
## SHA-256 of CONTENT, worked out independently of the code under test.
const CONTENT_SHA256 := "c97a397f281d17ee0b49a0ffc64047db7ed1dbe67170e27daace6b22be893dac"


func setup() -> void:
	_dir = ProjectSettings.globalize_path("user://test_new_file_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(_dir)


# Stages are dot-files, and the one refused stays, so hidden files are
# listed too.
func teardown() -> void:
	var dir := DirAccess.open(_dir)
	dir.include_hidden = true
	for file in dir.get_files():
		DirAccess.remove_absolute(_dir.path_join(file))
	DirAccess.remove_absolute(_dir)


static func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func test_publish_protocol() -> Variant:
	var input := CONTENT.to_utf8_buffer()
	var staged := NewFile.stage(_dir, input)
	if staged.has("error"):
		return "stage failed: %s" % staged.error
	input[0] = 0x58
	var r = A.eq((staged.bytes as PackedByteArray).get_string_from_utf8(), CONTENT, "the stage keeps its own copy")
	if r != true:
		return r
	r = A.eq(staged.hash, CONTENT_SHA256, "the hash is of what was staged")
	if r != true:
		return r

	var taken := _dir.path_join("taken.dct")
	_write(taken, "theirs")
	var refused := NewFile.publish(staged, taken)
	r = A.is_true(refused.status == NewFile.NOT_PUBLISHED and FileAccess.get_file_as_string(taken) == "theirs"
		and FileAccess.file_exists(staged.stage), "a taken name is left as it was, and so is the stage: %s" % refused)
	if r != true:
		return r

	var free := _dir.path_join("free.dct")
	var published := NewFile.publish(staged, free)
	r = A.is_true(published.status == NewFile.DURABLE
		and FileAccess.get_file_as_string(free) == CONTENT and not FileAccess.file_exists(staged.stage),
		"a free name receives the staged bytes and the stage's name is gone: %s" % published)
	if r != true:
		return r
	if OS.get_name() != "Windows":
		var owner_only := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER
		r = A.eq(FileAccess.get_unix_permissions(free) & 0x1ff, owner_only, "the new file is its owner's only")
		if r != true:
			return r

	var changed := NewFile.stage(_dir, CONTENT.to_utf8_buffer())
	if changed.has("error"):
		return "second stage failed: %s" % changed.error
	# Same length and same file, other bytes.
	var file := FileAccess.open(changed.stage, FileAccess.READ_WRITE)
	file.store_string(CONTENT.to_upper())
	file.close()
	var after_change := _dir.path_join("after-change.dct")
	var stopped := NewFile.publish(changed, after_change)
	return A.is_true(stopped.status == NewFile.NOT_PUBLISHED and stopped.phase == "verify_stage"
		and not FileAccess.file_exists(after_change), "a stage changed in place is not published: %s" % stopped)
