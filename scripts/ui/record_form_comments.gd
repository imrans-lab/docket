extends RefCounted
## The comments part of the item form (RecordForm): listing the shown item's
## comments, adding one or a reply, and accepting or rejecting one. It works
## on the form's own controls.

var _form  # RecordForm
# True while a comment is being added, so a second click cannot add it twice.
var _submitting := false


func _init(form) -> void:
	_form = form


func toggle() -> void:
	_form._comments_container.visible = not _form._comments_container.visible
	if _form._comments_container.visible:
		_form._comments_toggle.text = "v Comments"
	else:
		_form._comments_toggle.text = "> Comments"


## Add the typed text as a comment on the shown item, or as a reply to comment
## `parent_id` when it is > 0.
func submit(parent_id: int = 0) -> void:
	if _form._current_id.is_empty():
		return
	var text: String = _form._comment_input.text.strip_edges()
	if text.is_empty() or _submitting:
		return
	_submitting = true
	var generation: int = _form._load_generation
	var added: Dictionary = await _form._src.add_comment(_form._current_project, _form._current_id,
		_form._src.prefs().get_display_name(), text, parent_id)
	_submitting = false
	if added.has("error"):
		_form._show_error("Comment not added", str(added.error))  # the typed text stays
		return
	if _form._comment_input.text.strip_edges() == text:
		_form._comment_input.text = ""
	if _form._still_showing(generation):
		_refresh()


func _resolve(comment_id: int, resolution: String) -> void:
	var resolved: Dictionary = await _form._src.resolve_comment(_form._current_project, comment_id, resolution,
		_form._src.prefs().get_display_name())
	if resolved.has("error"):
		_form._show_error("Comment not resolved", str(resolved.error))
		return
	_refresh()


func _refresh() -> void:
	var generation: int = _form._load_generation
	await populate()
	var events: Array = await _form._src.item_events(_form._current_project, _form._current_id)
	if not _form._still_showing(generation):
		return
	if not events.is_empty():
		_form._populate_events({"events": events})
	_form.item_changed.emit()


func populate() -> void:
	# Cleared before and after the reply, as in RecordForm._populate_children.
	for child in _form._comments_list.get_children():
		child.queue_free()
	if _form._current_id.is_empty():
		return
	var generation: int = _form._load_generation
	var comments: Array = await _form._src.list_comments(_form._current_project, _form._current_id)
	if not _form._still_showing(generation):
		return
	for child in _form._comments_list.get_children():
		child.queue_free()

	# Update toggle label with count
	var prefix := "v" if _form._comments_container.visible else ">"
	if comments.size() > 0:
		_form._comments_toggle.text = "%s Comments (%d)" % [prefix, comments.size()]
	else:
		_form._comments_toggle.text = "%s Comments" % prefix

	for c in comments:
		var cid: int = int(c.get("id", 0))
		var parent_id: int = int(c.get("parent_id", 0))
		var status_str: String = str(c.get("status", "open"))
		var author_str: String = str(c.get("author", ""))
		var text_str: String = str(c.get("text", ""))

		var comment_vbox := VBoxContainer.new()
		comment_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		# Indent replies
		if parent_id > 0:
			var margin := MarginContainer.new()
			margin.add_theme_constant_override("margin_left", 24)
			margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			margin.add_child(comment_vbox)
			_form._comments_list.add_child(margin)
		else:
			_form._comments_list.add_child(comment_vbox)

		# Header row: indicator + initials + status badge
		var header := HBoxContainer.new()
		var indicator := Label.new()
		match status_str:
			"open":
				indicator.text = "o"
				indicator.add_theme_color_override("font_color", Color(1.0, 0.7, 0.2))
			"accepted":
				indicator.text = "+"
				indicator.add_theme_color_override("font_color", Color(0.4, 0.8, 0.4))
			"rejected":
				indicator.text = "-"
				indicator.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
		header.add_child(indicator)

		var initials_label := Label.new()
		var parts := author_str.split(" ")
		var initials := ""
		for p in parts:
			if not p.is_empty():
				initials += p[0].to_upper()
		if initials.is_empty():
			initials = "?"
		initials_label.text = "[%s]" % initials
		initials_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
		header.add_child(initials_label)

		if parent_id > 0:
			var reply_tag := Label.new()
			reply_tag.text = "reply"
			reply_tag.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			reply_tag.add_theme_font_size_override("font_size", 11)
			header.add_child(reply_tag)

		comment_vbox.add_child(header)

		# Comment text
		var text_label := Label.new()
		text_label.text = text_str
		text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		comment_vbox.add_child(text_label)

		# Action buttons (small, inline) for open comments
		if status_str == "open":
			var btn_row := HBoxContainer.new()
			btn_row.add_theme_constant_override("separation", 4)

			var accept_btn := Button.new()
			accept_btn.text = "Accept"
			accept_btn.add_theme_font_size_override("font_size", 11)
			accept_btn.pressed.connect(_resolve.bind(cid, "accepted"))
			btn_row.add_child(accept_btn)

			var reject_btn := Button.new()
			reject_btn.text = "Reject"
			reject_btn.add_theme_font_size_override("font_size", 11)
			reject_btn.pressed.connect(_resolve.bind(cid, "rejected"))
			btn_row.add_child(reject_btn)

			var reply_btn := Button.new()
			reply_btn.text = "Reply"
			reply_btn.add_theme_font_size_override("font_size", 11)
			reply_btn.pressed.connect(submit.bind(cid))
			btn_row.add_child(reply_btn)

			comment_vbox.add_child(btn_row)
