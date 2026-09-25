class_name ProjectCopy
extends RefCounted
## A saved JSONL project copied to a new path, exactly: its file's bytes and
## its audit sidecar's (a partial last line included), as they were together
## at one moment, never rewritten. Only a new path is written; a project or
## audit file already there is left alone and the copy refused.
##
## The owner is admitted (ProjectAdmission), then the audit locks of the
## source and of the destination are held together (AuditLog.with_lock with
## `also`, which orders and shares them by their native lock keys) from
## capturing both files until both copies are published. Under them the
## destination names must be positively free (ProjectFile.vacant: no entry,
## link or directory at either), so two copies to one path cannot pair one's
## project with the other's audit. The source must be saved, with no change
## pending or of unknown outcome, and is checked again, unchanged, just
## before publishing. Each copy is staged
## beside its destination and published with NewFile: the audit first, the
## project file last, so a project at the new path has its history, if the
## source had one, beside it. The two are not one atomic step: a failure
## after the audit is published leaves it there, and the receipt says so.
## Nothing already published, and no stage, is ever removed.
##
## SQLite projects are refused before anything is written.

const COPIED := "copied"
const NOT_COPIED := "not_copied"
## Something was published (the audit, or the project file whose flush or
## check failed) but the copy cannot be said complete.
const UNCERTAIN := "copy_uncertain"


## The project `owner` (open as `project`) copied to `dest`, within `parent`
## when given: a receipt {status, phase, error, dest, hash, audit, left}.
## `hash` is the SHA-256 of the project bytes captured; `audit` is {present,
## status, hash} for its sidecar (present as captured); `left` names stages
## not published, for their owner to remove; `phase` is where the copy
## stopped ("done" when COPIED). It runs synchronously, start to finish.
static func copy_jsonl(project: String, owner: DocketDB, dest: String, parent: RefCounted = null) -> Dictionary:
	if not owner is DocketDBJsonl:
		return _receipt(NOT_COPIED, "check_source", "only JSONL projects can be copied")
	if dest.to_lower().ends_with(AuditLog.SUFFIX):
		return _receipt(NOT_COPIED, "check_destination", "%s names an audit file, not a project" % dest)
	var target := ProjectFile.vacant(dest)
	if target.has("error"):
		return _receipt(NOT_COPIED, "check_destination", str(target.error))
	var work := _copy_admitted.bind(owner, str(target.path), parent)
	var admitted := ProjectAdmission.access({project: owner}, work, parent)
	if not bool(admitted.ok):
		return _receipt(NOT_COPIED, "admit", str(admitted.message))
	return admitted.value


static func _copy_admitted(_reloaded: Array, owner: DocketDBJsonl, dest: String, parent: RefCounted) -> Dictionary:
	var copied := AuditLog.with_lock(owner.get_path(), _copy_locked.bind(owner, dest), parent, dest)
	if copied.has("status"):
		return copied
	return _receipt(NOT_COPIED, "lock_audit", str(copied.get("error", "")))


static func _copy_locked(guard: RefCounted, owner: DocketDBJsonl, dest: String) -> Dictionary:
	for entry in [dest, dest + AuditLog.SUFFIX]:
		var free := ProjectFile.vacant(entry)
		if free.has("error"):
			return _receipt(NOT_COPIED, "check_destination", str(free.error))
	var source := owner.saved_snapshot()
	if source.has("error"):
		return _receipt(NOT_COPIED, "capture_source", str(source.error))
	var audit: Dictionary = guard.snapshot()
	if audit.has("error"):
		return _receipt(NOT_COPIED, "capture_audit", str(audit.error))
	var receipt := _receipt(NOT_COPIED, "stage", "", dest, str(source.hash))
	receipt.audit.present = bool(audit.present)

	var dir := dest.get_base_dir()
	var staged := NewFile.stage(dir, source.bytes)
	if staged.has("error"):
		return _left(receipt, staged, "stage", str(staged.error))
	receipt.left.append(staged.stage)
	var report := JSONLValidator.validate_file(staged.stage)
	if not bool(report.ok):
		var errors := "; ".join(PackedStringArray(report.errors))
		return _stop(receipt, "validate", "the copy is not a valid project: %s" % errors)
	var staged_audit := {}
	if bool(audit.present):
		staged_audit = NewFile.stage(dir, audit.bytes)
		if staged_audit.has("error"):
			return _left(receipt, staged_audit, "stage_audit", str(staged_audit.error))
		receipt.left.append(staged_audit.stage)
		receipt.audit.status = NewFile.NOT_PUBLISHED
		receipt.audit.hash = staged_audit.hash

	var again := owner.saved_snapshot()
	if again.has("error") or again.hash != source.hash or again.id != source.id:
		var why := str(again.get("error", "its file differs"))
		return _stop(receipt, "recheck_source", "the project changed while it was copied: %s" % why)

	if not staged_audit.is_empty():
		var audit_published := NewFile.publish(staged_audit, dest + AuditLog.SUFFIX)
		receipt.audit.status = audit_published.status
		if audit_published.status == NewFile.NOT_PUBLISHED:
			return _stop(receipt, "publish_audit", str(audit_published.error))
		receipt.left.erase(staged_audit.stage)
		if audit_published.status != NewFile.DURABLE:
			receipt.status = UNCERTAIN
			return _stop(receipt, "publish_audit", str(audit_published.error))
	var published := NewFile.publish(staged, dest)
	if published.status == NewFile.NOT_PUBLISHED:
		# The audit this copy published stays; this copy did not publish the
		# project file.
		if not staged_audit.is_empty():
			receipt.status = UNCERTAIN
		return _stop(receipt, "publish_project", str(published.error))
	receipt.left.erase(staged.stage)
	if published.status != NewFile.DURABLE:
		receipt.status = UNCERTAIN
		return _stop(receipt, "publish_project", str(published.error))
	receipt.status = COPIED
	receipt.phase = "done"
	return receipt


static func _receipt(status: String, phase: String, error: String, dest: String = "", hash: String = "") -> Dictionary:
	return {"status": status, "phase": phase, "error": error, "dest": dest, "hash": hash,
		"audit": {"present": false, "status": "", "hash": ""}, "left": []}


# `receipt` stopped at `phase`, its status as it stands.
static func _stop(receipt: Dictionary, phase: String, error: String) -> Dictionary:
	receipt.phase = phase
	receipt.error = error
	return receipt


# A stage that failed: the file it left, if any, is named.
static func _left(receipt: Dictionary, staged: Dictionary, phase: String, error: String) -> Dictionary:
	if staged.has("stage"):
		receipt.left.append(staged.stage)
	return _stop(receipt, phase, error)
