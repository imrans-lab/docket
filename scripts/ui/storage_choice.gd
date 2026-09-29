extends HBoxContainer
class_name StorageChoice
## The New Item dialog's storage mode picker (scenes/ui/storage_choice.tscn).
## "Default" leaves the choice to ItemStorage.resolve (ephemeral for wr:attempt
## and steering items, durable otherwise).

const _MODES := ["", ItemStorage.DURABLE, ItemStorage.EPHEMERAL]


func requested() -> String:
	## "" (type default), "durable" or "ephemeral".
	var mode: OptionButton = %Mode
	return _MODES[mode.selected] if mode.selected >= 0 else ""


func reset(supports_ephemeral: bool) -> void:
	## Back to Default; ephemeral is offered only for a file-backed project.
	var mode: OptionButton = %Mode
	mode.select(0)
	mode.set_item_disabled(2, not supports_ephemeral)
