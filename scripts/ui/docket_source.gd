extends RefCounted
## Everything the Docket UI reads from and writes to its projects goes through
## a DocketSource, so the same UI runs over the projects in this process
## (LocalDocketSource, the standalone app) or over MCP to a Docket process
## that owns them (a host such as Minerva embedding the UI). UI scripts never
## touch DocketDB, TypeRegistry or AppState themselves.
##
## Await every method that returns something: a remote source answers
## asynchronously (one returning nothing may be sent without waiting).
## Failures come back as {"error": String} (or a non-empty error String where
## a method returns one). The methods here are the contract; a source that
## cannot do something returns UNSUPPORTED.

## A project was opened, closed, reloaded or changed on disk.
signal file_changed
## Items changed (the grid and form refresh).
signal data_changed
signal load_failed(path: String, reason: String)
signal open_item_requested(id: String, project: String)
signal open_query_requested(filter: String, label: String)

const UNSUPPORTED := "not supported by this data source"


func _unsupported() -> Dictionary:
	return {"error": UNSUPPORTED}


# -- Projects -------------------------------------------------------------------

## Names of the open projects, sorted case-insensitively (answered at once).
func project_names() -> Array[String]:
	return []


## The primary (first opened) project's name and file path, "" when none
## (answered at once).
func primary_project() -> String:
	return ""


func primary_path() -> String:
	return ""


## Open project name → its file path (answered at once).
func project_paths() -> Dictionary:
	return {}


## The person's preferences (a UserPrefs: display name for authorship).
func prefs():
	return null


## Replace the open projects with the one at `path`.
func open_project(_path: String) -> void:
	pass


## Open the project at `path` beside the others.
func add_project(_path: String) -> void:
	pass


## Create a project file at `path` and open it (beside the others, if any).
func create_project(_path: String) -> void:
	pass


func remove_project(_project: String) -> void:
	pass


## Save every open project.
func save_all() -> void:
	pass


## Save the primary project under `path` and make that its path.
func save_primary_as(_path: String) -> void:
	pass


## A token that changes whenever any open project changes on disk.
func change_token() -> String:
	return ""


## Reload projects whose files changed on disk: the names reloaded.
func reload_stale() -> Array:
	return []


## Reload every project from its file: the names reloaded.
func reload_all() -> Array:
	return []


## A display setting stored for the person (ui_scale, ui_font_size).
func ui_setting(_key: String, default_value: String) -> String:
	return default_value


func set_ui_setting(_key: String, _value: String) -> void:
	pass


## How many MCP tools Docket serves.
func tool_count() -> int:
	return 0


# -- Items --------------------------------------------------------------------------

## Item `id`'s current revision token, "" when it is gone.
func item_token(_project: String, _id: String) -> String:
	return ""


## Item `id`'s title as {title}, or {} when it is gone.
func item_title(_project: String, _id: String) -> Dictionary:
	return {}


## The item form's view of item `id`: {item, resolved (its type
## resolution), token (revision token), short_id}, or {error, kind}: kind
## closed (project not open), registry (no type registry), refresh (its
## definitions could not be refreshed; only with `refresh`), missing (the
## item is gone). `refresh` first reloads the project's type definitions.
func item_view(_project: String, _id: String, _refresh: bool = false) -> Dictionary:
	return _unsupported()


## Item `id`'s events, newest last, or [] when it is gone.
func item_events(_project: String, _id: String) -> Array:
	return []


## Attach a file to item `id`: the attachment record, or {error}.
func attach_file(_project: String, _id: String, _filename: String, _data: PackedByteArray, _mime: String,
		_description: String) -> Dictionary:
	return _unsupported()


## Items in any open project whose parent is `qualified_id` ("project:id").
func children_of(_qualified_id: String) -> Array:
	return []


## Move item `id` from `project` to `target_project`: {new_id} or {error}.
func move_item(_project: String, _id: String, _target_project: String) -> Dictionary:
	return _unsupported()


## Update item `id` (the form's changes, guarded by the revision and token it
## was loaded at); `secret` carries a protected item's vault input (see
## vault_problem). "" or the error.
func save_item(_project: String, _id: String, _changes: Dictionary, _revision: String, _token: String,
		_secret: Dictionary = {}) -> String:
	return UNSUPPORTED


## Create an item of `fields.type` in `project`: {id}, or {error} — with
## payload_failed when the item was refused for its vault content.
func create_item(_project: String, _fields: Dictionary, _secret: Dictionary = {}) -> Dictionary:
	return _unsupported()


## Move item `id` to status `target` (with `note` when off the normal flow)
## and apply `changes`: "" or the error.
func transition_item(_project: String, _id: String, _target: String, _note: String, _changes: Dictionary,
		_revision: String, _token: String, _secret: Dictionary = {}) -> String:
	return UNSUPPORTED


# -- Comments -------------------------------------------------------------------------

func list_comments(_project: String, _id: String) -> Array:
	return []


## Add a comment (a reply when `parent_id` > 0) by `author`.
func add_comment(_project: String, _id: String, _author: String, _text: String, _parent_id: int = 0) -> Dictionary:
	return _unsupported()


## Resolve comment `comment_id` as "accepted" or "rejected".
func resolve_comment(_project: String, _comment_id: int, _resolution: String, _by: String) -> Dictionary:
	return _unsupported()


# -- Type snapshot (answered at once) ---------------------------------------------------
# The item form rebuilds its type and status pickers inside synchronous
# updates; a remote source keeps these from a cache it refreshes.

## `project`'s active types with definitions ("" = the primary project);
## [] when its registry is unavailable.
func cached_types(_project: String) -> Array:
	return []


## Type `slug` of `project` with its definition, or {error}.
func cached_type(_project: String, _slug: String) -> Dictionary:
	return _unsupported()


## The type resolution of `item` in `project` (state_category, revision,
## definition...), or {error}.
func cached_resolve(_project: String, _item: Dictionary) -> Dictionary:
	return _unsupported()


# -- Vault ----------------------------------------------------------------------------

## Per project, the vault entries that belong to no item: {project: [{handle,
## requires_2fa, updated_at}]}. Values are never included.
func standalone_secrets() -> Dictionary:
	return {}


## Why `project`'s vault cannot take a protected item's content now, or "":
## "Vault password not set. Go to Preferences first." or "Vault password does
## not match." A vault not created yet is created when content is saved.
##
## Protected content moves as `secret` input: {type: "secret" or
## "encrypted_note", value (the new secret; absent when unchanged),
## requires_2fa, secondary_password (with a new 2FA value), notes (new notes
## or body; absent when unchanged)}.
func vault_problem(_project: String) -> String:
	return UNSUPPORTED


## Whether vault entry `handle` of `project` can be read: {vault: ok |
## no_password | unavailable (password set but no vault or it does not
## match), exists, requires_2fa}.
func secret_info(_project: String, _handle: String) -> Dictionary:
	return {"vault": "unavailable", "exists": false, "requires_2fa": false}


## Decrypt vault entry `handle` (a 2FA one needs `secondary_password`):
## {value} or {error}. `audit` records the read in the project's audit log.
func read_secret(_project: String, _handle: String, _secondary_password: String = "",
		_audit: bool = false) -> Dictionary:
	return _unsupported()


## Earlier versions of `handle`: [{version, created_at, rotated_by}].
func secret_versions(_project: String, _handle: String) -> Array:
	return []


func read_secret_version(_project: String, _handle: String, _version: int) -> Dictionary:
	return _unsupported()


## The vault password setting: {password, hint}.
func vault_settings() -> Dictionary:
	return {"password": "", "hint": ""}


## Store the vault password `password` (empty clears it) and `hint`; a
## changed password re-encrypts every open project's vault first.
func set_vault_settings(_password: String, _hint: String) -> void:
	pass


## The item schema (data/schema.json; answered at once).
func schema() -> Dictionary:
	return {}


# -- Queries ----------------------------------------------------------------------

## Run a query (filter, sort) over every open project: {rows, details} —
## details[i] for rows[i] being {short_id, resolved}, resolved the row's type
## resolution (state_category, state_outcome, is_terminal, revision,
## definition) or {error} — or {error}.
func run_query(_query: Dictionary) -> Dictionary:
	return _unsupported()


## The type catalog of every open project, for the query builder: {records,
## diagnostic} (diagnostic "" when every project's registry is usable).
func type_catalog() -> Dictionary:
	return {"records": [], "diagnostic": UNSUPPORTED}


## A type descriptor (with its definition) by id or slug in `project`, or
## {error}.
func resolve_type_ref(_project: String, _type_ref: String) -> Dictionary:
	return _unsupported()


# -- Type registry --------------------------------------------------------------

## The active and draft types of `project`, with their definitions:
## {types} or {error}.
func list_types(_project: String) -> Dictionary:
	return _unsupported()


## Type `slug` of `project` (descriptor with definition), or {error}.
func get_type(_project: String, _slug: String) -> Dictionary:
	return _unsupported()


## The types of `project` for the Project Types panel:
## {types: [descriptor], counts: {slug: item count}, legacy: bool} — legacy
## when the project still needs promoting or upgrading — or {error, kind},
## kind being no_project, unavailable (registry diagnostic), closed, or
## list_failed.
func types_overview(_project: String, _include_deprecated: bool) -> Dictionary:
	return _unsupported()


## Whether `project`'s type registry is usable: "" or why not.
func types_problem(_project: String) -> String:
	return UNSUPPORTED


## One type's descriptor plus `revisions` (its immutable history, ordered by
## revision ID, not by date), or {error}.
func type_with_history(_project: String, _slug: String) -> Dictionary:
	return _unsupported()


func type_revision(_project: String, _revision_id: String) -> Dictionary:
	return _unsupported()


## "" when `definition` is a valid type definition, else why not.
func validate_type_definition(_project: String, _definition: Dictionary) -> String:
	return UNSUPPORTED


## What evolving type `slug` to `definition` would do (the preview to apply),
## or {error}.
func preview_type_evolution(_project: String, _slug: String, _definition: Dictionary,
		_expected_revision: String, _item_ids: Array) -> Dictionary:
	return _unsupported()


## Create type `slug` as a draft: the new descriptor, or {error}.
func define_type(_project: String, _slug: String, _definition: Dictionary, _author: String,
		_reason: String) -> Dictionary:
	return _unsupported()


## Apply a preview_type_evolution result: "" or the error.
func apply_type_evolution(_project: String, _preview: Dictionary, _author: String,
		_reason: String) -> String:
	return UNSUPPORTED


## Make type `slug` "active" or "deprecated": "" or the error.
func set_type_lifecycle(_project: String, _slug: String, _lifecycle: String,
		_expected_revision: String, _author: String, _reason: String) -> String:
	return UNSUPPORTED


# -- Project format migrations ----------------------------------------------------

## Promote a SQLite project to JSONL at the same path (the caller has
## confirmed no other writer is running): the migration report.
func promote_project(_project: String) -> Dictionary:
	return _unsupported()


## Preview upgrading a JSONL project to 2.0 without changing it: the
## preview to pass to apply_project_upgrade ({ok, ...}), or {ok: false, error}.
func preview_project_upgrade(_project: String) -> Dictionary:
	return {"ok": false, "error": UNSUPPORTED}


## Apply a preview_project_upgrade result, refusing if the project or its file
## changed since: the upgrade report ({ok, ...}).
func apply_project_upgrade(_project: String, _preview: Dictionary) -> Dictionary:
	return {"ok": false, "error": UNSUPPORTED}
