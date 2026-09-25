extends RefCounted
## Whether a query picks a project exactly, as the backend and a host's panel
## both need to know: the field that names open projects by selector, and the
## check of a query's filter for it. It depends on nothing, so a panel package
## can carry it without the backend's ProjectSelectors.


## The query field naming open projects exactly by selector (for this session
## only), beside `project`, which names them by stored name.
const SELECTOR_FIELD := "project_selector"


## The grid's catalog choices (a type or a type's status chosen from one
## project's catalog): each is that exact project's, a selector's scope.
const CATALOG_OPERATORS := ["catalog_in", "catalog_status"]


## Whether `query`'s filter picks a project exactly anywhere: a
## SELECTOR_FIELD condition (or its flat form), or a catalog choice, which
## compiles to one. Such a query cannot be saved, since a selector means
## nothing in another session.
static func has_selector_condition(query: Dictionary) -> bool:
	return _names_selector(query.get("filter"))


static func _names_selector(node: Variant) -> bool:
	if node is Array:
		return node.any(func(child) -> bool: return _names_selector(child))
	if not node is Dictionary:
		return false
	if str(node.get("field", "")) == SELECTOR_FIELD or node.has(SELECTOR_FIELD) or node.has(SELECTOR_FIELD + "__ne") \
			or (str(node.get("op", "")) in CATALOG_OPERATORS and _makes_choice(node.get("value"))):
		return true
	for key in ["conditions", "$and", "$or"]:
		if node.has(key) and _names_selector(node[key]):
			return true
	return false


# A type chooser with nothing chosen yet compiles to no project guard.
static func _makes_choice(value: Variant) -> bool:
	if value is Array:
		return value.any(func(v) -> bool: return not str(v).is_empty())
	return value is Dictionary or not str(value).is_empty()
