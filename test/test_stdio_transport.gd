extends Node
## Real child-process oracle. Python owns independent stdin/stdout descriptors,
## deadlines and isolated XDG paths; it never touches the owner's user data.

const DRIVER := """
import json, os, pathlib, selectors, signal, subprocess, sys, tempfile, time
signal.alarm(180)
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
    os.set_blocking(p.stdin.fileno(), False)
    children.append((p, err))
    return p

def write(p, data):
    data = memoryview(data)
    selector = selectors.DefaultSelector()
    selector.register(p.stdin, selectors.EVENT_WRITE)
    deadline = time.monotonic() + 30
    try:
        while data:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and selector.select(remaining), 'stdin write exceeded 30s'
            try:
                count = os.write(p.stdin.fileno(), data)
            except BlockingIOError:
                continue
            assert count > 0, 'stdin write made no progress'
            data = data[count:]
    finally:
        selector.close()

def send(p, obj):
    write(p, (json.dumps(obj, ensure_ascii=False) + '\\n').encode())

# Every stdout line, including startup and EOF, must be JSON-RPC; trailing
# bytes are refused by finish/EOF assertions rather than ignored.
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
    p = launch('scratch')
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
    write(p, b'{broken\\n')
    assert receive(p)['error']['code'] == -32700
    for invalid in ([], None, {'jsonrpc': '2.0', 'method': 42},
                    {'jsonrpc': '2.0', 'method': 'tools/call', 'params': []},
                    {'jsonrpc': '2.0', 'method': 'tools/call', 'params': {'name': 42}},
                    {'jsonrpc': '2.0', 'method': 'ping', 'id': {}}):
        send(p, invalid)
        assert receive(p)['error']['code'] == -32600
    write(p, b'\\xff\\n')
    assert receive(p)['error']['code'] == -32700
    # Close immediately after a mutation, before receiving or any idle settle.
    eof_title = 'immediate EOF mutation'
    send(p, {'jsonrpc': '2.0', 'method': 'tools/call', 'id': 'eof',
             'params': {'name': 'docket_create', 'arguments': {'type': 'chore', 'title': eof_title}}})
    p.stdin.close()
    reply = receive(p)
    assert reply['id'] == 'eof' and not reply['result'].get('isError'), reply
    assert p.wait(timeout=10) == 0, 'EOF exit failure'
    assert p.stdout.read() == b'', 'unexpected protocol output after EOF'
    canonical = (base / 'scratch.dct').read_text()
    assert title in canonical and eof_title in canonical, 'EOF did not settle the immediate write'
    assert not pathlib.Path(str(base / 'scratch.dct') + '.lock').exists(), 'EOF retained lock'
    print('PASS protocol/unicode/notifications/malformed/EOF-settle/no-http')

    p = launch('framing')
    # Oversize discard recovers on the next newline; many queued frames exercise
    # backpressure with a producer that does not wait for responses.
    write(p, b'x' * (8 * 1024 * 1024 + 1) + b'\\n')
    assert receive(p)['error']['code'] == -32700
    for ident in range(20):
        send(p, {'jsonrpc': '2.0', 'method': 'ping', 'id': ident})
    for ident in range(20):
        assert receive(p)['id'] == ident
    write(p, b'{')
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
except BaseException:
    # Preserve the original traceback and report each child's actual failure.
    # Kill still-running children first so their final stderr is available.
    for child, err in children:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=10)
        if not err.closed:
            err.flush()
        with open(err.name, 'rb') as log:
            log.seek(0, os.SEEK_END)
            size = log.tell()
            log.seek(max(0, size - 8192))
            tail = log.read().decode('utf-8', errors='replace')
        print('CHILD %s exit=%s stderr(last 8192 bytes):\\n%s' %
              (pathlib.Path(err.name).stem, child.returncode, tail), file=sys.stderr)
    raise
finally:
    for p, err in children:
        if p.poll() is None:
            p.kill()
            p.wait()
        err.close()
    root.cleanup()
"""


func test_real_child_stdio() -> Variant:
	if OS.get_name() not in ["Linux", "macOS"]:
		return {"skip": "Real stdio oracle requires POSIX pipes (Linux/macOS); platform not executed"}
	var temp_dir := "/tmp/docket-stdio-oracle-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if DirAccess.make_dir_absolute(temp_dir) != OK:
		return "Cannot create absolute isolated oracle directory"
	var script_path := temp_dir.path_join("driver.py")
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	if file == null:
		return "Cannot write isolated stdio oracle"
	file.store_string(DRIVER)
	file.close()
	var output: Array = []
	var code := OS.execute("python3", PackedStringArray([script_path, OS.get_executable_path(), ProjectSettings.globalize_path("res://")]), output, true)
	DirAccess.remove_absolute(script_path)
	DirAccess.remove_absolute(temp_dir)
	var report := "\n".join(PackedStringArray(output))
	print(report)
	if code != 0 or not report.contains("3 scenarios passed, 0 skipped"):
		return "Child stdio oracle failed (exit %d): %s" % [code, report]
	return true
