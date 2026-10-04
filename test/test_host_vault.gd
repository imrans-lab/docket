extends Node
## Synthetic standalone producers; hosted consumers use private memory only.
const StdioFixture := preload("res://test/test_stdio_transport.gd")
const DRIVER := """
import base64, hashlib, hmac, secrets, socket, urllib.request, urllib.error
passwords = [secrets.token_hex(24), secrets.token_hex(24)]
values = [secrets.token_hex(24), secrets.token_hex(24)]
token = secrets.token_hex(32)
keys = []
seen = bytearray()
original_receive = receive
def receive(p, receive_timeout=5):
    value = original_receive(p, receive_timeout)
    seen.extend(json.dumps(value).encode())
    return value

# Only explicit derivation call sites get the longer receive deadline. All
# ordinary calls, parameter/descriptor refusals and global bounds stay strict.
KDF_STAGES = ('producer_primary_write', 'producer_secondary_write', 'vault_unlock',
              'consumer_secondary_write', 'consumer_secondary_current', 'consumer_secondary_archive')
def kdf_request(p, method, ident, params, stage):
    assert stage in KDF_STAGES, 'KDF timing stage'
    started = time.monotonic()
    reply = request(p, method, ident, params, receive_timeout=120)
    print('HOST_VAULT_KDF_TIMING stage=%s seconds=%.3f' % (stage, time.monotonic() - started), flush=True)
    return reply

def call(p, name, arguments, failure=False, kdf_stage=None):
    params = dict(name=name, arguments=arguments)
    reply = request(p, 'tools/call', 80, params) if kdf_stage is None else kdf_request(p, 'tools/call', 80, params, kdf_stage)
    assert bool(reply['result'].get('isError')) == failure, 'tool result status'
    text = reply['result']['content'][0]['text']
    return {'error': text} if failure else json.loads(text)

def private(p, method, fields, auth=None, kdf_stage=None):
    auth = token if auth is None else auth
    params = dict(panel_secret=auth, **fields)
    return request(p, 'docket/panel/' + method, 81, params) if kdf_stage is None else kdf_request(p, 'docket/panel/' + method, 81, params, kdf_stage)

def locked(p, name):
    assert 'locked' in call(p, 'docket_secret_get', dict(project=name, handle='entry'), True)['error'].lower(), 'key remained accessible'

def fixture_path(value, expected):
    # Only this freshly allocated root's known fixture files may be printed.
    # samefile preserves returned case/8.3/separator spellings in diagnostics.
    if not isinstance(value, str) or len(value) > 2048 or any(ord(c) < 32 for c in value):
        return None
    candidate = pathlib.Path(value)
    try:
        if candidate.is_absolute() and os.path.samefile(candidate.parent, base) and os.path.samefile(candidate, expected):
            return value
    except (OSError, ValueError):
        pass
    return None

def diagnose_paths(p, path):
    fixtures = {name: base/(name+'.dct') for name in ('legacy', 'current', 'empty')}
    supplied = next((value for expected in fixtures.values() if (value := fixture_path(str(path), expected)) is not None), None)
    assert supplied is not None, 'diagnostic fixture path provenance'
    served = []
    for entry in call(p, 'docket_project_list', {})['projects']:
        expected = fixtures.get(entry.get('name'))
        value = fixture_path(entry.get('path'), expected) if expected is not None else None
        if value is not None and value not in served: served.append(value)
    assert len(served) <= 3, 'diagnostic fixture path count'
    print('HOST_VAULT_PATHS supplied=%s served=%s' % (json.dumps(supplied), json.dumps(served)), flush=True)

def bind(p, path):
    reply = private(p, 'vault_challenge', dict(path=str(path)))
    if 'result' not in reply: diagnose_paths(p, path)
    assert 'result' in reply, 'vault challenge refused'
    return reply['result']

def unlock(p, descriptor, password, kdf_stage=None):
    fields = {k: descriptor[k] for k in ('path', 'open_generation', 'fingerprint')}
    return private(p, 'vault_unlock', dict(**fields, password=password), kdf_stage=kdf_stage)

def open_host(name, auth=token):
    env['DOCKET_PANEL_SECRET'] = auth
    p = launch(name, ['--host-authority'])
    assert 'result' in private(p, 'declare_schema', dict(schema=json.loads((pathlib.Path(project)/'data/schema.json').read_text()), version='synthetic'), auth), 'host schema declaration'
    for path in paths:
        call(p, 'docket_project_add', dict(path=str(path)))
    return p

try:
    # Producer and consumer have distinct state and XDG directories. Only the
    # ordinary synthetic producer may persist its fixture password.
    paths = [base/'legacy.dct', base/'current.dct']
    for i, path in enumerate(paths):
        name = 'producer-%d' % i
        state = base/(name+'-state')
        state.mkdir()
        (state/'docket_prefs.json').write_text(json.dumps(dict(vault_password=passwords[i])))
        if i == 0:
            salt = secrets.token_bytes(16)
            key = hashlib.pbkdf2_hmac('sha256', passwords[i].encode(), salt, 10000)
            verify = hmac.new(key, b'docket-vault-verify', hashlib.sha256).digest()
            # Same retained legacy fixture route as test_vault_kdf_migration:
            # absent iteration metadata explicitly means 10,000.
            path.write_text(json.dumps(dict(_type='meta', version='1.0.0', counter=0, id_prefix='L', project='legacy', vault_salt=base64.b64encode(salt).decode(), vault_verify=base64.b64encode(verify).decode())) + '\\n')
        p = launch(name, ['--file', str(path)])
        call(p, 'docket_secret_set', dict(handle='entry', value=values[0]), kdf_stage='producer_primary_write')
        call(p, 'docket_secret_set', dict(handle='entry', value=values[1]), kdf_stage='producer_primary_write')
        call(p, 'docket_secret_set', dict(handle='dual', value=values[0], requires_2fa=True, secondary_password=secrets.token_hex(16)), kdf_stage='producer_secondary_write')
        finish(p)
        (state/'docket_prefs.json').unlink()
        meta = json.loads(path.read_text().splitlines()[0])
        keys.append(hashlib.pbkdf2_hmac('sha256', passwords[i].encode(), base64.b64decode(meta['vault_salt']), 10000 if i == 0 else 600000))
    # A conflicting preexisting hosted preference never supplies a fallback.
    state = base/'hosted-state'
    state.mkdir()
    prefs = state/'docket_prefs.json'
    pref_bytes = json.dumps(dict(vault_password='synthetic-conflicting-persisted')).encode()
    prefs.write_bytes(pref_bytes)
    for key in ('XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'APPDATA', 'LOCALAPPDATA'):
        env[key] = str(base/('host-'+key))
        pathlib.Path(env[key]).mkdir()
    before = [path.read_bytes() for path in paths]
    p = open_host('hosted')
    # Isolated vault-less opening: refusal cannot initialize metadata or files.
    empty_path = base/'empty.dct'
    call(p, 'docket_project_add', dict(path=str(empty_path), create=True))
    empty_before = empty_path.read_bytes()
    listing = call(p, 'docket_project_list', {})
    empty_descriptor = next(d for d in listing['projects'] if d['path'] == str(empty_path))
    refusal = private(p, 'vault_unlock', dict(path=str(empty_path), open_generation=empty_descriptor['open_generation'], fingerprint='absent', password=passwords[0]))
    assert refusal['error'] == dict(code=-32602, message='Vault request refused') and empty_path.read_bytes() == empty_before and not any(k.startswith('vault_') for k in json.loads(empty_path.read_text().splitlines()[0])), 'vault-less unlock initialized state'
    assert private(p, 'vault_migrate', {})['error']['code'] == -32601, 'unknown private vault verb accepted'
    tools = request(p, 'tools/list', 1)['result']['tools']
    assert all(not t['name'].startswith('docket/panel/') for t in tools), 'private vault tool listed'
    assert request(p, 'tools/call', 1, dict(name='docket/panel/vault_unlock', arguments={}))['error']['code'] == -32602, 'private method tool refusal'
    if sys.platform.startswith('linux'):
        proc = pathlib.Path('/proc')/str(p.pid)
        seen.extend((proc/'cmdline').read_bytes() + (proc/'environ').read_bytes())
    descriptors = []
    for i, path in enumerate(paths):
        name = path.stem
        locked(p, name)
        d = bind(p, path)
        # Equivalent absolute paths retain the same opening identity. Native
        # Windows backslashes exercise real client input; slash form also binds.
        equivalent = str(path.parent) + '/./' + path.name
        assert bind(p, equivalent) == d, 'equivalent absolute vault path'
        if sys.platform == 'win32':
            assert bind(p, path.as_posix()) == d, 'Windows vault path separators'
        assert 'error' in private(p, 'vault_challenge', dict(path=path.name)), 'relative vault path accepted'
        descriptors.append(d)
        for auth in (None, 'f'*64):
            fields = dict(path=str(path))
            reply = request(p, 'docket/panel/vault_challenge', 2, fields) if auth is None else private(p, 'vault_challenge', fields, auth)
            assert reply['error']['code'] == -32001, 'auth bypass'
        for password in (None, 42, '', 'x'*1025):
            assert 'error' in unlock(p, d, password), 'invalid password accepted'
            locked(p, name)
        assert 'error' in unlock(p, d, passwords[1-i], kdf_stage='vault_unlock'), 'wrong password accepted'
        locked(p, name)
        audit = [json.loads(line) for line in pathlib.Path(str(path)+'.audit.jsonl').read_text().splitlines()]
        failures = [entry for entry in audit if entry['event'] == 'vault_unlock_failed' and entry.get('source') == 'host']
        assert len(failures) == 1 and failures[0]['ok'] is False and 'handle' not in failures[0], 'host verification failure audit'
        assert all(pw not in json.dumps(failures) for pw in passwords), 'password sentinel in failed unlock audit'
        assert unlock(p, d, passwords[i], kdf_stage='vault_unlock')['result']['unlocked'], 'valid unlock failed'
        item = call(p, 'docket_create', dict(project=name, type='bug', title='unrelated'))
        assert bind(p, path) == dict(d, unlocked=True), 'unrelated edit changed vault identity'
        call(p, 'docket_flush', dict(project=name))
        before[i] = path.read_bytes()
        assert call(p, 'docket_secret_get', dict(project=name, handle='entry'))['value'] == values[1], 'current plaintext'
        assert call(p, 'docket_secret_get', dict(project=name, handle='entry', version=1))['value'] == values[0], 'archived plaintext'
        assert 'secondary password' in call(p, 'docket_secret_get', dict(project=name, handle='dual'), True)['error'], '2FA refusal'
        # Never print or retain response plaintexts. They are expected consumer
        # outputs, unlike the password/key sentinels checked below.
        for field in ('unknown', 'key', 'project', 'migrate', 'initialize'):
            params = {k:d[k] for k in ('path','open_generation','fingerprint')}
            assert 'error' in private(p, 'vault_unlock', dict(**params, password=passwords[i], **{field:True})), 'unknown parameter'
            locked(p, name)
        params = {k:d[k] for k in ('path','open_generation','fingerprint')}
        for _ in range(2):
            assert unlock(p, d, passwords[i], kdf_stage='vault_unlock')['result']['unlocked'], 'valid unlock failed'
            assert not private(p, 'vault_lock', params)['result']['unlocked'], 'lock failed'
            locked(p, name)
        assert unlock(p, d, passwords[i], kdf_stage='vault_unlock')['result']['unlocked'], 'valid unlock failed'
        assert 'error' in unlock(p, dict(d, fingerprint='stale'), passwords[i]), 'stale fingerprint accepted'
        locked(p, name)
        assert path.read_bytes() == before[i], 'unlock mutated vault'
    assert 'error' in private(p, 'vault_challenge', dict(path=str(base/'absent.dct'))), 'absent project accepted'
    d = descriptors[0]
    assert unlock(p, d, passwords[0], kdf_stage='vault_unlock')['result']['unlocked'], 'valid unlock failed'
    call(p, 'docket_project_remove', dict(name='legacy'))
    assert 'error' in unlock(p, d, passwords[0]), 'closed opening accepted'
    call(p, 'docket_project_add', dict(path=str(paths[0])))
    locked(p, 'legacy')
    assert 'error' in unlock(p, d, passwords[0]), 'reopened descriptor accepted'
    fresh = bind(p, paths[0])
    assert fresh['open_generation'] != d['open_generation'], 'reopened generation unchanged'
    assert unlock(p, fresh, passwords[0], kdf_stage='vault_unlock')['result']['unlocked'], 'valid unlock failed'
    finish(p)
    token2 = secrets.token_hex(32)
    q = open_host('hosted', token2)
    assert 'error' in private(q, 'vault_challenge', dict(path=str(paths[0]))), 'previous connection token accepted'
    token = token2
    locked(q, 'legacy')
    restart_descriptor = bind(q, paths[0])
    assert unlock(q, restart_descriptor, passwords[0], kdf_stage='vault_unlock')['result']['unlocked'], 'new connection unlock failed'
    assert not private(q, 'vault_lock', {k:restart_descriptor[k] for k in ('path','open_generation','fingerprint')})['result']['unlocked'], 'new connection lock failed'
    # H3 generations are process-local: the new connection's token is the
    # restart boundary, tested above; generation values may repeat in a child.
    for field in ('vault_salt','vault_kdf_iterations','vault_verify'):
        d = bind(q, paths[1])
        assert unlock(q, d, passwords[1], kdf_stage='vault_unlock')['result']['unlocked'], 'valid unlock failed'
        lines = paths[1].read_text().splitlines()
        meta = json.loads(lines[0])
        meta[field] = 10000 if field == 'vault_kdf_iterations' else base64.b64encode(secrets.token_bytes(16 if field == 'vault_salt' else 32)).decode()
        lines[0] = json.dumps(meta)
        paths[1].write_text('\\n'.join(lines)+'\\n')
        locked(q, 'current')
        assert 'error' in unlock(q, d, passwords[1]), 'replaced metadata accepted'
        paths[1].write_bytes(before[1])
    finish(q)
    assert json.loads(prefs.read_bytes())['vault_password'] == json.loads(pref_bytes)['vault_password'], 'hosted credential changed'
    # Ordinary HTTP refuses every private vault method (token presence does
    # not opt in). Reserve a disposable port and use the actual HTTP server.
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1',0))
        port = reservation.getsockname()[1]
    args.remove('--stdio')
    q = launch('http', ['--port',str(port)])
    for method in ('vault_challenge','vault_unlock','vault_lock'):
        body = json.dumps(dict(jsonrpc='2.0', id=1, method='docket/panel/'+method, params=dict(panel_secret=token))).encode()
        req = urllib.request.Request('http://127.0.0.1:%d/mcp'%port, data=body, headers={'Content-Type':'application/json'})
        deadline = time.monotonic()+10
        while True:
            try:
                with urllib.request.urlopen(req,timeout=2) as response: reply=json.load(response)
                break
            except urllib.error.URLError:
                assert q.poll() is None and time.monotonic()<deadline, 'HTTP startup'
                time.sleep(.1)
        assert reply['error']['code'] == -32601, 'HTTP private bypass'
    q.terminate()
    q.wait(timeout=10)
    needles = [pw.encode() for pw in passwords]
    for key in keys: needles.extend((key, key.hex().encode(), base64.b64encode(key)))
    assert all(needle not in seen for needle in needles), 'vault material in output/proc'
    for path in base.rglob('*'):
        if path.is_file():
            data = path.read_bytes()
            assert all(needle not in data for needle in needles), 'vault material persisted/logged'
            if path.suffix == '.stderr': assert b'SCRIPT ERROR' not in data, 'child script error'
    print('HOST VAULT receiver-consumer-lifetime-privacy PASS')
except BaseException as error:
    safe_diagnostic(type(error), error, error.__traceback__)
    sys.exit(1)
finally:
    for p, err in children:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=10)
        p.stop_io.set()
        for worker in p.io_threads: worker.join(timeout=1)
        if not p.stdin.closed: p.stdin.close()
        p.stdout.close()
        err.close()
    root.cleanup()
    completed.set()
"""

func test_actual_child_vault_contract() -> Variant:
	for path in ["C:/fixture/legacy.dct", "C:\\fixture\\legacy.dct"]:
		if not path.is_absolute_path(): return "Windows absolute vault path rejected"
	return run_actual_child(DRIVER)

func run_actual_child(scenario_driver: String) -> Variant:
	var driver := StdioFixture.DRIVER.replace("\r\n", "\n")
	var helpers := driver.get_slice("\ntry:\n    p = launch('scratch')", 0)
	if helpers == driver: return "stdio driver slice marker not found"
	helpers = helpers.replace("['--state-dir', str(base / (name + '-state')), '--file', str(base / (name + '.dct'))]", "['--state-dir', str(base / (name + '-state'))]")
	# These two vault drivers make repeated real KDF calls; leave room below
	# the isolated runner's 600s class limit without widening other drivers.
	for marker in ["completed.wait(180)", "whole child oracle exceeded 180s"]:
		if not helpers.contains(marker): return "stdio watchdog replacement marker not found"
	helpers = helpers.replace("completed.wait(180)", "completed.wait(540)")
	helpers = helpers.replace("whole child oracle exceeded 180s", "whole child oracle exceeded 540s")
	# Diagnostics must never publish response bodies or secret-bearing frames.
	helpers = helpers.replace("assert value['id'] == ident, value", "assert value['id'] == ident, 'response id'")
	helpers = helpers.replace("assert b'\"jsonrpc\"' not in remaining_stdout(p)", "assert remaining_stdout(p) == b''")
	# No inherited watchdog stderr tails or default traceback can expose frames.
	helpers = helpers.replace("assert raw.endswith(b'\\n'), ('missing response newline', raw)", "assert raw.endswith(b'\\n'), 'missing response newline'")
	helpers = helpers.replace("assert isinstance(value, dict) and value.get('jsonrpc') == '2.0', raw", "assert isinstance(value, dict) and value.get('jsonrpc') == '2.0', 'response envelope'")
	helpers = helpers.replace("assert remaining_stdout(p) == b'', 'unexpected protocol output after EOF'", "assert remaining_stdout(p) == b'', 'trailing stdout'")
	var diagnostic := """
import ast
# Allow only literal assertion labels present in the composed source.
_SAFE_LABELS = {node.msg.value for node in ast.walk(ast.parse(SOURCE)) if isinstance(node, ast.Assert) and isinstance(node.msg, ast.Constant) and isinstance(node.msg.value, str)}
def safe_diagnostic(kind, error, trace):
    line = 0
    call_site = 0
    while trace is not None:
        if trace.tb_frame.f_code.co_filename == __file__:
            if call_site == 0: call_site = trace.tb_lineno
            line = trace.tb_lineno
        trace = trace.tb_next
    label = error.args[0] if kind is AssertionError and len(error.args) == 1 and isinstance(error.args[0], str) and error.args[0] in _SAFE_LABELS else 'non-assert failure'
    print('HOST_VAULT_DIAGNOSTIC %s line=%d call_site=%d label=%s' % (kind.__name__, line, call_site, label), file=sys.stderr, flush=True)
sys.excepthook = safe_diagnostic
def diagnose():
    print('HOST_VAULT_DIAGNOSTIC TimeoutError line=%d label=watchdog deadline' % sys._getframe().f_lineno, file=sys.stderr, flush=True)
"""
	# Remove the inherited stderr-tail reporter before starting its watchdog.
	var unsafe_reporter := helpers.get_slice("def diagnose():", 1).get_slice("def watchdog():", 0)
	helpers = helpers.replace("def diagnose():" + unsafe_reporter, "")
	# Install before fixture startup; diagnostics identify actual composed lines.
	var source := helpers + scenario_driver
	var prefix := "import sys\nSOURCE = " + JSON.stringify(source) + "\n" + diagnostic
	var output: Array = []
	var python := "python" if OS.get_name() == "Windows" else "python3"
	# Windows CreateProcess caps command lines at 32,767 characters. Keep the
	# composed source in isolated test scratch; secrets are generated at runtime.
	var driver_path := ProjectSettings.globalize_path("user://host-vault-driver-%d.py" % Time.get_ticks_usec())
	var driver_file := FileAccess.open(driver_path, FileAccess.WRITE)
	if driver_file == null: return "Host vault driver scratch creation failed"
	driver_file.store_string(prefix + helpers + scenario_driver)
	driver_file.close()
	var code := OS.execute(python, PackedStringArray([driver_path, OS.get_executable_path(), ProjectSettings.globalize_path("res://")]), output, true)
	DirAccess.remove_absolute(driver_path)
	var report := "\n".join(PackedStringArray(output))
	# The explicit path exception is provenance-checked in the Python driver.
	# Match only bounded JSON strings/lists, never arbitrary captured output.
	var json_path := "\"(?:[^\"\\\\\\x00-\\x1f]|\\\\(?:[\"\\\\]|u[0-9a-fA-F]{4}))*\""
	var paths_pattern := RegEx.create_from_string("^HOST_VAULT_PATHS supplied=" + json_path + " served=\\[(?:" + json_path + "(?:, " + json_path + "){0,2})?\\]$")
	# Forward only fixed stages, numeric durations and verified fixture paths.
	var timing_pattern := RegEx.create_from_string("^HOST_VAULT_KDF_TIMING stage=(producer_primary_write|producer_secondary_write|vault_unlock|consumer_secondary_write|consumer_secondary_current|consumer_secondary_archive) seconds=[0-9]+\\.[0-9]{3}$")
	for line in report.split("\n"):
		var timing_line := line.trim_suffix("\r")
		if timing_pattern.search(timing_line): print(timing_line)
		if timing_line.length() <= 16640 and paths_pattern.search(timing_line): print(timing_line)
	# Emit labels only, even when the composed driver's watchdog diagnoses.
	if code != 0 or not report.contains("HOST VAULT receiver-consumer-lifetime-privacy PASS"):
		var lines := report.trim_suffix("\n").split("\n") if not report.is_empty() else PackedStringArray()
		var exception_class := "unavailable"
		var exception_pattern := RegEx.create_from_string("^[A-Za-z_]+(Error|Exception|Exit)\\b")
		for line in lines:
			var matched := exception_pattern.search(line)
			if matched: exception_class = matched.get_string()
		var safe_report := "diagnostic unavailable exit=%d lines=%d class=%s" % [code, lines.size(), exception_class]
		for line in report.split("\n"):
			if line.begins_with("HOST_VAULT_DIAGNOSTIC "): safe_report = line
		return "Host vault actual-child contract failed (exit %d): %s" % [code, safe_report]
	print("HOST VAULT receiver-consumer-lifetime-privacy PASS")
	return true

func test_visible_app_shell_preferences_subset_save() -> Variant:
	# Actual AppShell and dialogs, in a disposable domain directory. No mock
	# acceptance; exercises the same signal handler as clicking Preferences Save.
	var directory := DocketRuntimeState.directory
	var hosted := DocketRuntimeState.hosted
	var path := ProjectSettings.globalize_path("user://host-vault-ui")
	DirAccess.make_dir_recursive_absolute(path)
	DocketRuntimeState.directory = path
	DocketRuntimeState.hosted = false
	UserPrefs.save_vault_password("synthetic-existing-ui")
	var credential_before := str(UserPrefs._load_data().get("vault_password", ""))
	var db_path := path.path_join("ui.dct")
	var db := DocketDBJsonl.create_new_jsonl(db_path)
	var salt := VaultCrypto.generate_salt()
	var key := VaultCrypto.derive_key(credential_before, salt)
	db.init_vault(key, salt)
	var encrypted := VaultCrypto.encrypt("synthetic-ui-secret", key)
	db.set_secret("entry", encrypted.ciphertext, encrypted.iv, encrypted.mac)
	db.flush()
	var vault_before := FileAccess.get_file_as_bytes(db_path)
	var state := AppState.new()
	state.schema = TypeRegistryBootstrap.load_shipped_schema()
	state.prefs = UserPrefs.new()
	state.db = db
	state._project_dbs = {"ui":db}
	var shell := AppShell.new()
	shell.init(state)
	add_child(shell)
	DocketRuntimeState.hosted = true
	shell._show_preferences()
	var safe := shell._prefs_vault_pw.text.is_empty() and shell._prefs_dialog.visible
	shell._prefs_first.text = " Ordinary "
	shell._prefs_last.text = " Hosted "
	shell._prefs_vault_hint.text = " ordinary hint "
	shell._prefs_dialog.hide()
	shell._prefs_dialog.confirmed.emit()
	db.flush()
	var ordinary := UserPrefs._load_data()
	safe = safe and not shell._info_dialog.visible and ordinary.get("first_name") == "Ordinary" and ordinary.get("last_name") == "Hosted" and ordinary.get("vault_password_hint") == "ordinary hint" and str(ordinary.get("vault_password", "")) == credential_before and FileAccess.get_file_as_bytes(db_path) == vault_before
	shell._show_preferences()
	safe = safe and shell._prefs_vault_pw.text.is_empty()
	shell._prefs_first.text = " Attempted "
	shell._prefs_last.text = " Change "
	shell._prefs_vault_hint.text = " attempted hint "
	shell._prefs_vault_pw.text = "synthetic-new-ui"
	shell._prefs_dialog.hide()
	shell._prefs_dialog.confirmed.emit()
	db.flush()
	var attempted := UserPrefs._load_data()
	safe = safe and shell._info_dialog.visible and shell._info_dialog.dialog_text.contains("unavailable") and attempted.get("first_name") == "Attempted" and attempted.get("last_name") == "Change" and attempted.get("vault_password_hint") == "attempted hint" and str(attempted.get("vault_password", "")) == credential_before and UserPrefs.load_vault_password().is_empty() and FileAccess.get_file_as_bytes(db_path) == vault_before
	UserPrefs.save_vault_password("synthetic-api-write")
	UserPrefs.clear_vault_password()
	state.prefs.first_name = "Hosted"
	state.prefs.save()
	UserPrefs.save_session(PackedStringArray(["synthetic-session"]))
	UserPrefs.save_last_query("synthetic-filter", "synthetic-label")
	UserPrefs.save_vault_password_hint("synthetic-hint")
	UserPrefs.save_type_shortcuts("ui", ["bug"], ["chore"])
	var saved := UserPrefs._load_data()
	safe = safe and UserPrefs.load_vault_password().is_empty() and str(saved.get("vault_password", "")) == credential_before and saved.get("first_name") == "Hosted" and UserPrefs.load_session() == PackedStringArray(["synthetic-session"]) and UserPrefs.load_last_query().get("filter") == "synthetic-filter" and UserPrefs.load_vault_password_hint() == "synthetic-hint" and UserPrefs.load_type_shortcuts("ui").pinned == ["bug"] and db.has_vault() and FileAccess.get_file_as_bytes(db_path) == vault_before
	db.close()
	shell.free()
	await get_tree().process_frame
	DocketRuntimeState.hosted = hosted
	DocketRuntimeState.directory = directory
	for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
	return true if safe else "Hosted visible Preferences subset-save/password guard failed"
