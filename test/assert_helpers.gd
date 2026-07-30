extends RefCounted
class_name AssertHelpers
## Assertion helpers for tests. Each returns true on success or an error String on failure.


static func eq(actual: Variant, expected: Variant, label: String = "") -> Variant:
	if typeof(actual) != typeof(expected):
		var msg := "type mismatch: got %s (%s), expected %s (%s)" % [
			str(actual), type_string(typeof(actual)),
			str(expected), type_string(typeof(expected))
		]
		return _fmt(msg, label)
	if actual != expected:
		return _fmt("got %s, expected %s" % [str(actual), str(expected)], label)
	return true


static func neq(actual: Variant, expected: Variant, label: String = "") -> Variant:
	if actual == expected:
		return _fmt("expected value to differ from %s" % str(expected), label)
	return true


static func is_true(value: Variant, label: String = "") -> Variant:
	if value != true:
		return _fmt("expected true, got %s" % str(value), label)
	return true


static func is_false(value: Variant, label: String = "") -> Variant:
	if value != false:
		return _fmt("expected false, got %s" % str(value), label)
	return true


static func has_key(dict: Dictionary, key: String, label: String = "") -> Variant:
	if not dict.has(key):
		return _fmt("missing key '%s' in %s" % [key, str(dict.keys())], label)
	return true


static func not_null(value: Variant, label: String = "") -> Variant:
	if value == null:
		return _fmt("expected non-null value", label)
	return true


static func is_null(value: Variant, label: String = "") -> Variant:
	if value != null:
		return _fmt("expected null, got %s" % str(value), label)
	return true


static func contains(haystack: Variant, needle: Variant, label: String = "") -> Variant:
	if haystack is String:
		if not (haystack as String).contains(str(needle)):
			return _fmt("'%s' not found in '%s'" % [str(needle), haystack], label)
		return true
	if haystack is Array:
		if not (haystack as Array).has(needle):
			return _fmt("%s not found in array %s" % [str(needle), str(haystack)], label)
		return true
	if haystack is Dictionary:
		if not (haystack as Dictionary).has(needle):
			return _fmt("key '%s' not found in dict" % str(needle), label)
		return true
	return _fmt("contains() needs String, Array, or Dictionary", label)


static func gt(actual: Variant, threshold: Variant, label: String = "") -> Variant:
	if actual <= threshold:
		return _fmt("expected %s > %s" % [str(actual), str(threshold)], label)
	return true


static func gte(actual: Variant, threshold: Variant, label: String = "") -> Variant:
	if actual < threshold:
		return _fmt("expected %s >= %s" % [str(actual), str(threshold)], label)
	return true


static func _fmt(msg: String, label: String) -> String:
	if label.is_empty():
		return msg
	return "%s: %s" % [label, msg]
