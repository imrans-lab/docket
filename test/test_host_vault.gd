extends Node
## Public managed-vault child fixture; no persisted response frames.
const HttpFixture := preload("res://test/http_child_fixture.gd")
const DRIVER := """

import base64, hashlib, hmac, secrets
passwords = [secrets.token_hex(24), secrets.token_hex(24)]
values = [secrets.token_hex(24), secrets.token_hex(24)]
keys = []
seen = bytearray()

def assert_private_files():
    persisted = [value.encode() for value in passwords + values]
    for key in keys: persisted.extend((key, key.hex().encode(), base64.b64encode(key)))
    for path in base.rglob('*'):
        if path.is_file():
            data = path.read_bytes()
            assert all(needle not in data for needle in persisted), 'vault material persisted/logged'
            if path.suffix == '.stderr': assert b'SCRIPT ERROR' not in data, 'child script error'

def call(p, name, arguments, failure=False, kdf_stage=None):
    reply = request(p, 'tools/call', 80, dict(name=name, arguments=arguments), receive_timeout=120 if kdf_stage else 30)
    assert bool(reply['result'].get('isError')) == failure, 'tool result status'
    text = reply['result']['content'][0]['text']
    return {'error': text} if failure else json.loads(text)

def private(p, method, fields, auth=None, kdf_stage=None):
    # Preserve the old scenario's result envelope while exercising public tools.
    arguments = dict(fields)
    path = arguments.pop('path', '')
    if not pathlib.Path(path).is_absolute(): return {'error':{'code':-32602}}
    projects = call(p, 'docket_project_list', {})['projects']
    matches = [item['name'] for item in projects if os.path.normcase(os.path.abspath(item['path'])) == os.path.normcase(os.path.abspath(path))]
    if len(matches) != 1: return {'error':{'code':-32602}}
    arguments.update(action='status' if method == 'vault_challenge' else method.removeprefix('vault_'), project=matches[0])
    reply = request(p, 'tools/call', 81, dict(name='docket_vault_control', arguments=arguments), receive_timeout=120 if kdf_stage else 30)['result']
    text = reply['content'][0]['text']
    return {'error':{'code':-32602, 'message':text}} if reply.get('isError') else {'result':json.loads(text)}

def locked(p, name):
    assert 'locked' in call(p, 'docket_secret_get', dict(project=name, handle='entry'), True)['error'].lower(), 'key remained accessible'

def bind(p, path):
    reply = private(p, 'vault_challenge', dict(path=str(path)))
    assert 'result' in reply, 'vault status refused'
    return reply['result']

def unlock(p, descriptor, password, kdf_stage=None):
    fields = {k:descriptor[k] for k in ('path','open_generation','fingerprint')}
    return private(p, 'vault_unlock', dict(**fields, password=password), kdf_stage=kdf_stage)

def open_host(name):
    return launch(name)
"""

func run_actual_child(scenario_driver: String) -> Variant:
	var helpers := HttpFixture.DRIVER
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
	var timing_pattern := RegEx.create_from_string("^HOST_VAULT_KDF_TIMING stage=(producer_primary_write|producer_secondary_write|vault_unlock|vault_init|consumer_secondary_write|consumer_secondary_current|consumer_secondary_archive) seconds=[0-9]+\\.[0-9]{3}$")
	for line in report.split("\n"):
		var timing_line := line.trim_suffix("\r")
		if timing_pattern.search(timing_line): print(timing_line)
		if timing_line.length() <= 16640 and paths_pattern.search(timing_line): print(timing_line)
		if timing_line.length() <= 16640 and RegEx.create_from_string("^CHILD_USERDIR path=" + json_path + " stage=before-traffic$").search(timing_line): print(timing_line)
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
