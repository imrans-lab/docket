extends Control
## The Docket panel a host (such as Minerva) shows for a project file (.dct):
## the Docket UI, embedded, over a RemoteDocketSource whose calls reach this
## plugin's own Docket process through the host (HostConnection). The host
## finds the hooks below by name, as its panel contract has them:
## _on_panel_loaded(ctx), _on_panel_load_request(doc), receive(channel,
## payload) and _on_panel_unload(). Everything the panel loads is preloaded
## by a path relative to it, so it runs the same from a plugin directory.

const AppShell := preload("../ui/app_shell.gd")
const Remote := preload("../ui/remote_docket_source.gd")
const HostConnection := preload("host_connection.gd")

## The host's panel contract wants this signal; this panel's calls go
## through the host's helper instead (HostConnection), whose replies may be
## large.
signal request(channel: String, payload: Dictionary, reply_id: String)

## The person using the panel, for the authorship of what they write. The
## host does not name them to the panel, so the name is the account's.
class Person:
	extends RefCounted
	func get_display_name() -> String:
		var name := OS.get_environment("USER")
		return name if not name.is_empty() else OS.get_environment("USERNAME")

var _source
var _shell: Control
var _message: Label
# Files the host asked to open while the source was starting, and those
# being opened (the host may ask for one twice: when loading the panel and
# again for the document).
var _waiting: Array[String] = []
var _opening: Dictionary = {}


func _ready() -> void:
	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_message.text = "Opening Docket…"
	add_child(_message)


## The host mounted the panel for `ctx.file_path` (if any): start the source
## and show the UI, or say why not.
func _on_panel_loaded(ctx: Dictionary) -> void:
	var source = Remote.new(HostConnection.new(self), Person.new())
	_source = source
	_open(str(ctx.get("file_path", "")))
	var error: String = await source.start()
	if _source != source:
		return  # unloaded meanwhile
	if not error.is_empty():
		_message.text = "Docket could not start: %s" % error
		return
	_message.queue_free()
	_message = null
	_shell = AppShell.new()
	_shell.init(_source, true)
	add_child(_shell)
	var waiting := _waiting
	_waiting = []
	for path in waiting:
		await _open(path)


## The host opens `doc.file_path` in this panel.
func _on_panel_load_request(doc: Dictionary) -> void:
	await _open(str(doc.get("file_path", "")))


## An event the plugin's process sent: its item changes refresh the UI.
func receive(channel: String, payload: Dictionary) -> void:
	if channel == "item_changed" and _source != null:
		_source.handle_host_event(payload)


## Nothing the source is still waiting for may reach the UI after this.
func _on_panel_unload() -> void:
	if _source != null:
		_source.stop_watching()
	_source = null


# The project at `path` joins the open ones (the process says, visibly, when
# it cannot open it), or waits for the source to start.
func _open(path: String) -> void:
	if _source == null or path.is_empty():
		return
	if _shell == null:
		if not _waiting.has(path):
			_waiting.append(path)
		return
	if _opening.has(path) or _source.project_paths().values().has(path):
		return
	_opening[path] = true
	await _source.add_project(path)
	_opening.erase(path)
