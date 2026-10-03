extends RefCounted
## Real child-process oracle. Python owns independent stdin/stdout descriptors,
## deadlines and isolated XDG paths; it never touches the owner's user data.

const DRIVER := """
import json, os, pathlib, selectors, subprocess, sys, tempfile, time
engine, project = sys.argv[1:]
root = tempfile.TemporaryDirectory(prefix='docket-stdio-')
base = pathlib.Path(root.name)
env = os.environ.copy()
for key in ('XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME'):
    env[key] = str(base / key)
    pathlib.Path(env[key]).mkdir()
args = [engine, '--headless', '--quiet', '--path', project, '--', '--serve', '--stdio']
children = []

def launch(name, extra=()):
    err = open(base / (name + '.stderr'), 'wb')
    p = subprocess.Popen(args + ['--file', str(base / (name + '.dct'))] + list(extra),
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, env=env, bufsize=0)
    children.append((p, err))
    return p

def send(p, obj):
    p.stdin.write((json.dumps(obj, ensure_ascii=False) + '\\n').encode())
    p.stdin.flush()

def receive(p):
    selector = selectors.DefaultSelector()
    selector.register(p.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 5
    raw = bytearray()
    while not raw.endswith(b'\\n'):
        assert selector.select(max(0, deadline - time.monotonic())), 'response not flushed within 5s'
        byte = os.read(p.stdout.fileno(), 1)
        assert byte, 'unexpected stdout EOF'
        raw.extend(byte)
        assert len(raw) <= 8 * 1024 * 1024, 'oversized response'
    selector.close()
    assert raw.endswith(b'\\n'), ('missing response newline', raw)
    value = json.loads(raw)
    assert isinstance(value, dict) and value.get('jsonrpc') == '2.0', raw
    return value

def request(p, method, ident, params=None):
    obj = {'jsonrpc': '2.0', 'method': method, 'id': ident}
    if params is not None:
        obj['params'] = params
    send(p, obj)
    value = receive(p)
    assert value['id'] == ident, value
    return value

def finish(p):
    p.stdin.close()
    assert p.wait(timeout=10) == 0, 'EOF exit failure'
    assert p.stdout.read() == b'', 'unexpected protocol output after EOF'

try:
    p = launch('protocol')
    # A listener on this isolated port must remain available to the test.
    import socket
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]
    q = launch('no-http', ['--port', str(port)])
    assert request(q, 'ping', 0)['result'] == {}
    finish(q)
    listener.close()
    assert request(p, 'initialize', 1)['result']['serverInfo']['name'] == 'docket'
    tools = request(p, 'tools/list', 2)['result']['tools']
    assert any(t['name'] == 'docket_create' for t in tools), 'missing current registry'
    title = 'stdio café 日本語 🦉'
    created = request(p, 'tools/call', 3, {'name': 'docket_create',
        'arguments': {'type': 'chore', 'title': title}})
    assert not created['result'].get('isError'), created
    result = json.loads(created['result']['content'][0]['text'])
    ident = result.get('id') or result.get('item', {}).get('id')
    assert ident, result
    fetched = request(p, 'tools/call', 4, {'name': 'docket_get', 'arguments': {'id': ident}})
    assert json.loads(fetched['result']['content'][0]['text'])['title'] == title, fetched
    # Notifications must execute without emitting even an unknown-method error.
    send(p, {'jsonrpc': '2.0', 'method': 'ping'})
    send(p, {'jsonrpc': '2.0', 'method': 'unknown'})
    send(p, {'jsonrpc': '2.0', 'method': 'notifications/initialized'})
    assert request(p, 'ping', '日本語')['result'] == {}
    p.stdin.write(b'{broken\\n')
    p.stdin.flush()
    assert receive(p)['error']['code'] == -32700
    for invalid in ([], None, {'jsonrpc': '2.0', 'method': 42},
                    {'jsonrpc': '2.0', 'method': 'tools/call', 'params': []},
                    {'jsonrpc': '2.0', 'method': 'tools/call', 'params': {'name': 42}},
                    {'jsonrpc': '2.0', 'method': 'ping', 'id': {}}):
        send(p, invalid)
        assert receive(p)['error']['code'] == -32600
    p.stdin.write(b'\\xff\\n')
    p.stdin.flush()
    assert receive(p)['error']['code'] == -32700
    finish(p)
    canonical = (base / 'protocol.dct').read_text()
    assert title in canonical, 'EOF did not settle the write'
    assert not pathlib.Path(str(base / 'protocol.dct') + '.lock').exists(), 'EOF retained lock'
    print('PASS protocol/unicode/notifications/malformed/EOF-settle/no-http')

    p = launch('framing')
    # Oversize discard recovers on the next newline; many queued frames exercise
    # backpressure with a producer that does not wait for responses.
    p.stdin.write(b'x' * (8 * 1024 * 1024 + 1) + b'\\n')
    p.stdin.flush()
    assert receive(p)['error']['code'] == -32700
    for ident in range(20):
        send(p, {'jsonrpc': '2.0', 'method': 'ping', 'id': ident})
    for ident in range(20):
        assert receive(p)['id'] == ident
    p.stdin.write(b'{')
    p.stdin.close()
    assert receive(p)['error']['code'] == -32700
    assert p.wait(timeout=10) == 0
    assert p.stdout.read() == b''
    print('PASS oversized/recovery/backpressure/partial-EOF')

    p = launch('empty')
    finish(p)
    print('PASS empty-EOF')
    for p, err in children:
        err.close()
    for log in base.glob('*.stderr'):
        assert b'SCRIPT ERROR' not in log.read_bytes(), log.read_text()
    print('STDIO REAL PROCESS: 3 scenarios passed, 0 skipped')
finally:
    for p, err in children:
        if p.poll() is None:
            p.kill()
            p.wait()
        err.close()
    root.cleanup()
"""


func test_real_child_stdio() -> Variant:
	if OS.get_name() != "Linux":
		return "Real stdio oracle currently requires Linux; do not record a skipped pass"
	var script_path := ProjectSettings.globalize_path("user://stdio_process_oracle.py")
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	if file == null:
		return "Cannot write isolated stdio oracle"
	file.store_string(DRIVER)
	file.close()
	var output: Array = []
	var code := OS.execute("python3", PackedStringArray([script_path, OS.get_executable_path(), ProjectSettings.globalize_path("res://")]), output, true)
	DirAccess.remove_absolute(script_path)
	var report := "\n".join(PackedStringArray(output))
	print(report)
	if code != 0 or not report.contains("3 scenarios passed, 0 skipped"):
		return "Child stdio oracle failed (exit %d): %s" % [code, report]
	return true
