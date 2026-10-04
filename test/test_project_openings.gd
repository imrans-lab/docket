extends Node
## Literal descriptor contract and lifecycle through actual hosted children.
const StdioFixture := preload("res://test/test_stdio_transport.gd")
const DRIVER := """
env['DOCKET_PANEL_SECRET'] = 'a' * 64
schema = {'types': {'chore': {'label': 'Chore', 'states': ['open', 'done'], 'initial_state': 'open', 'terminal_states': ['done'], 'transitions': {'open': ['done'], 'done': []}, 'required_fields': ['title'], 'optional_fields': []}}}

def call(p, name, arguments, failure=False):
    reply = request(p, 'tools/call', 92, dict(name=name, arguments=arguments))
    assert bool(reply['result'].get('isError')) == failure, reply
    text = reply['result']['content'][0]['text']
    return text if failure else json.loads(text)

def listed(p):
    return call(p, 'docket_project_list', {})['projects']

def hosted(name):
    p = launch(name, ['--host-authority'])
    assert listed(p) == []
    reply = request(p, 'docket/panel/declare_schema', 91, dict(panel_secret='a' * 64, schema=schema, version='opening-fixture'))
    assert 'result' in reply, reply
    return p

def descriptor(value, path, primary=True):
    # These literal keys are consumed by DocketHost; no producer helper oracle.
    assert value['name'] == 'shared' and value['display_name'] == 'shared'
    assert value['path'] == str(path) and value['primary'] is primary
    assert value['prefix'] and value['open_generation']
    assert value['storage_mode'] == 'durable' and value['read_only_reason'] == ''

try:
    first, other = base / 'first.dct', base / 'other.dct'
    for path in (first, other):
        path.write_text(json.dumps(dict(_type='meta', version='1.0.0', counter=0, id_prefix='SHR', project='shared', name='spoof', path='spoof', open_generation='spoof', primary=False)) + '\\n')
    for gui in (False, True):
        if gui: args.remove('--serve')
        p = hosted('hosted-%s' % gui)
        opened = call(p, 'docket_project_add', dict(path=str(first)))
        descriptor(opened, first)
        assert listed(p) == [opened]
        token = opened['open_generation']
        before_other = other.read_bytes()
        for path in (first, first.parent / '.' / first.name, other):
            error = call(p, 'docket_project_add', dict(path=str(path)), True)
            assert 'already loaded' in error.lower()
            assert listed(p) == [opened]
        assert other.read_bytes() == before_other
        reply = call(p, 'docket_reload', dict(project='shared'))
        assert reply['reloaded'] == ['shared'] and reply['count'] == 1 and not reply.get('failed')
        assert listed(p)[0]['open_generation'] == token
        # An external content edit changes rows, never the served opening.
        meta = json.loads(first.read_text().splitlines()[0]); meta['description'] = 'external edit'
        first.write_text(json.dumps(meta) + '\\n')
        reply = call(p, 'docket_reload', dict(project='shared'))
        assert reply['reloaded'] == ['shared'] and listed(p)[0]['open_generation'] == token
        keeper = call(p, 'docket_project_add', dict(path=str(base / ('keeper-%s.dct' % gui)), create=True))
        call(p, 'docket_project_remove', dict(name='shared'))
        assert len(listed(p)) == 1 and listed(p)[0]['name'] == keeper['name']
        reopened = call(p, 'docket_project_add', dict(path=str(first)))
        descriptor(reopened, first, False)
        assert reopened['open_generation'] != token
        assert [entry for entry in listed(p) if entry['name'] == 'shared'] == [reopened]
        finish(p)
        # Host connection/process generation invalidates restart, not global IDs.
        p = hosted('restart-%s' % gui)
        restarted = call(p, 'docket_project_add', dict(path=str(first)))
        descriptor(restarted, first)
        assert listed(p) == [restarted]
        finish(p)
    args.append('--serve')
    # Ordinary startup's repeated --file admissions use the same collision rule.
    p = launch('startup', ['--file', str(first), '--file', str(other)])
    entries = listed(p)
    shared = [entry for entry in entries if entry['name'] == 'shared']
    assert len(shared) == 1 and shared[0]['path'] == str(first)
    finish(p)
    for log in base.glob('*.stderr'):
        assert b'SCRIPT ERROR' not in log.read_bytes(), 'child script error'
    print('PROJECT OPENINGS PASS')
finally:
    for p, err in children:
        if p.poll() is None:
            p.kill(); p.wait(timeout=10)
        p.stop_io.set()
        for worker in p.io_threads: worker.join(timeout=1)
        p.stdin.close(); p.stdout.close(); err.close()
    root.cleanup()
    completed.set()
"""

func test_real_hosted_children_and_startup() -> Variant:
	var driver := StdioFixture.DRIVER.replace("\r\n", "\n")
	var helpers := driver.get_slice("\ntry:\n    p = launch('scratch')", 0)
	if helpers == driver: return "stdio driver slice marker not found"
	helpers = helpers.replace(", '--file', str(base / (name + '.dct'))", "")
	var source := "import sys\nscenario = sys.argv.pop()\n" + helpers + DRIVER
	var output: Array = []
	var python := "python" if OS.get_name() == "Windows" else "python3"
	var code := OS.execute(python, PackedStringArray(["-c", source, OS.get_executable_path(), ProjectSettings.globalize_path("res://"), "openings"]), output, true)
	var report := "\n".join(PackedStringArray(output)).replace("a".repeat(64), "[redacted]")
	print(report)
	return true if code == 0 and report.contains("PROJECT OPENINGS PASS") else "Project openings child failed (exit %d)" % code

const DIR := "user://test_project_openings"
var _state: AppState
var _reloads := 0
var _failures := 0

func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_state = AppState.new()
	_state.load_schema()
	_reloads = 0
	_failures = 0
	_state.load_failed.connect(func(_path: String, _reason: String) -> void: _failures += 1)

func after_each() -> void:
	for name in _state.get_project_dbs().keys(): _state.remove_project(str(name))
	_remove_tree(DIR)

func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null: return
	for name in directory.get_directories(): _remove_tree(path + "/" + name)
	for name in directory.get_files(): directory.remove(name)
	DirAccess.remove_absolute(path)

func _seed(path: String, name: String = "shared") -> void:
	var created := DocketDBJsonl.create_new_jsonl(path)
	created.set_project_name(name)
	for key in ["name", "display_name", "path", "prefix", "primary", "open_generation", "read_only_reason", "owner", "usage"]:
		created.set_meta_value(key, "spoof")
	created.close()

func _listed() -> Array:
	return DocketProjectList.new().execute({}, _state.schema, _state.db, _state.get_project_dbs()).projects

func test_descriptor_reload_failure_and_reopening() -> Variant:
	var path := DIR + "/first.dct"
	_seed(path)
	var added := _state.add_project_result(path)
	if added.has("error"): return added.error
	var live := _state.db as DocketDBJsonl
	live.content_reloaded.connect(func() -> void: _reloads += 1)
	if _listed() != [added] or added.name != "shared" or added.display_name != "shared" or added.path != live.get_path() or added.prefix != live.get_id_prefix() or added.primary != true or added.open_generation == "spoof" or added.read_only_reason != "" or added.has("owner") or added.has("usage"):
		return "Add/list literal descriptor or reserved metadata protection failed"
	var token: String = added.open_generation
	if not live.reload() or _reloads != 1 or _listed()[0].open_generation != token: return "Content reload changed opening or missed signal"
	var good := FileAccess.get_file_as_string(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("broken canonical\n"); file.close()
	if live.reload() or _reloads != 1 or _listed()[0].open_generation != token: return "Failed reload reported success or replaced opening"
	file = FileAccess.open(path, FileAccess.WRITE); file.store_string(good); file.close()
	if not live.reload() or _reloads != 2: return "Restored canonical did not reload"
	_state.remove_project("shared")
	var reopened := _state.add_project_result(path)
	return true if not reopened.has("error") and reopened.open_generation != token else "Close/reopen retained opening"

func test_additive_collisions_preserve_primary_registry_and_creation_destination() -> Variant:
	var first := DIR + "/first.dct"
	var other := DIR + "/other.dct"
	_seed(first); _seed(other)
	_state.load_projects([first, other])
	var primary := _state.db
	var registry := _state.get_type_registry("shared")
	var descriptor: Dictionary = _listed()[0]
	var original := FileAccess.get_file_as_string(first)
	var rejected := FileAccess.get_file_as_string(other)
	if _failures != 1 or _state.get_project_dbs().size() != 1: return "Session loading accepted duplicate selector"
	if _state.add_project(first).is_empty() or _state.add_project(DIR + "/./first.dct").is_empty() or _state.add_project(other).is_empty(): return "Direct additive duplicate admitted"
	_state.create_and_add_project(first)
	DirAccess.make_dir_recursive_absolute(DIR + "/nested")
	_state.create_and_add_project(DIR + "/nested/shared.dct")
	if FileAccess.file_exists(DIR + "/nested/shared.dct"): return "Creation touched colliding name"
	if not (_state.db == primary and _state.get_type_registry("shared") == registry and _listed() == [descriptor] and FileAccess.get_file_as_string(first) == original and FileAccess.get_file_as_string(other) == rejected): return "Collision changed original DB, registry, token or files"
	_state.remove_project("shared")
	MemoryProject.renew("opening fixture")
	_state.add_project("memory://shared")
	var memory := _state.db
	var refused := _state.add_project(other)
	MemoryProject._lease_until_msec = 0
	return true if refused == "Project name already loaded: shared" and _state.db == memory and _state.get_project_dbs()["shared"] == memory else "Ordinary file replaced served memory outside persist"

func test_promotion_and_explicit_upgrade_are_new_openings() -> Variant:
	var path := DIR + "/legacy.dct"
	var legacy := DocketDB.create_new(path)
	legacy.close()
	_state.add_project(path)
	var token: String = _listed()[0].open_generation
	var promoted := _state.promote_project_to_jsonl("legacy", true)
	if not promoted.get("success", false) or _listed()[0].open_generation == token: return "Promotion did not create new opening"
	token = _listed()[0].open_generation
	var upgraded := _state.upgrade_project_to_jsonl_v2("legacy", JSONLTypeUpgrade.preview(path), true)
	return true if upgraded.get("ok", false) and _listed()[0].open_generation != token else "Type upgrade did not create new opening"

func test_session_ownership_and_memory_descriptors_survive_refusals() -> Variant:
	DirAccess.make_dir_recursive_absolute(DIR + "/sessions")
	var first := DIR + "/sessions/first.dct"
	var other := DIR + "/sessions/other.dct"
	for path in [first, other]:
		var created := DocketDBJsonl.create_new_jsonl(path)
		created.set_project_name("owned")
		created.set_meta_value(SessionProject.META_KEY, SessionProject.MODE_SESSION_FILE)
		created.close()
	var added := _state.add_project_result(first)
	if added.has("error"): return added.error
	var owner := FileAccess.get_file_as_string(first + ".owner")
	var primary := _state.db
	var registry := _state.get_type_registry("owned")
	if added.storage_mode != "session_file" or added.owner.pid != OS.get_process_id(): return "Session descriptor lost ownership"
	if _state.add_project(other).is_empty() or _state.add_project(first).is_empty(): return "Session collision admitted"
	if _state.db != primary or _state.get_type_registry("owned") != registry or _listed() != [added] or FileAccess.get_file_as_string(first + ".owner") != owner or FileAccess.file_exists(other + ".owner"):
		return "Refusal changed existing ownership or claimed rejected file"
	var memory := _state.add_project_result("memory://scratch")
	if memory.has("error"): return memory.error
	var entry: Dictionary = _listed()[1]
	if memory != entry or entry.storage_mode != "memory" or not entry.has("usage") or entry.has("owner") or entry.primary:
		return "Memory descriptor lost usage or storage semantics"
	return true
