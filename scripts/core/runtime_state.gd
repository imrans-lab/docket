extends RefCounted
class_name DocketRuntimeState
## Shared process exit boundary.

static func quit(tree: SceneTree, exit_code: int = 0) -> void:
	tree.quit(exit_code)
