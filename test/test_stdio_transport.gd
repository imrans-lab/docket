extends Node
## Real child-process oracle. Python owns independent stdin/stdout descriptors,
## deadlines and isolated XDG paths; it never touches the owner's user data.

const DRIVER := """
import json, os, pathlib, queue, subprocess, sys, tempfile, threading, time
engine, project = sys.argv[1:]
root = tempfile.TemporaryDirectory(prefix='docket-stdio-')
base = pathlib.Path(root.name).resolve()
env = os.environ.copy()
for key in ('XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'APPDATA', 'LOCALAPPDATA'):
    env[key] = str(base / key)
    pathlib.Path(env[key]).mkdir()
args = [engine, '--headless', '--quiet', '--path', project, '--', '--serve', '--stdio']
children = []
completed = threading.Event()

def diagnose():
    # Kill all owned children before waiting, then retain actual exit/stderr.
    for child, err in children:
        if child.poll() is None:
            child.kill()
    for child, err in children:
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            print('CHILD reap exceeded 10s', file=sys.stderr, flush=True)
        if not err.closed:
            err.flush()
        with open(err.name, 'rb') as log:
            log.seek(0, os.SEEK_END)
            size = log.tell()
            log.seek(max(0, size - 8192))
            tail = log.read().decode('utf-8', errors='replace')
        print('CHILD %s exit=%s stderr(last 8192 bytes):\\n%s' %
              (pathlib.Path(err.name).stem, child.returncode, tail), file=sys.stderr, flush=True)

def watchdog():
    if not completed.wait(180):
        print('whole child oracle exceeded 180s', file=sys.stderr, flush=True)
        try:
            diagnose()
        finally:
            # A blocked main thread must not keep OS.execute waiting forever.
            os._exit(1)
threading.Thread(target=watchdog, daemon=True).start()

def launch(name, extra=()):
    err = open(base / (name + '.stderr'), 'wb')
    try:
        p = subprocess.Popen(args + ['--state-dir', str(base / (name + '-state')), '--file', str(base / (name + '.dct'))] + list(extra),
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, env=env, bufsize=0)
    except BaseException:
        err.close()
        raise
    children.append((p, err))
    # Bounded chunks prevent unsolicited stdout from growing memory forever.
    p.output_queue = queue.Queue(maxsize=64)
    p.write_queue = queue.Queue(maxsize=1)
    p.pending = bytearray()
    p.output_eof = False
    p.stop_io = threading.Event()
    def reader():
        try:
            while True:
                chunk = p.stdout.read(4096)
                while not p.stop_io.is_set():
                    try:
                        p.output_queue.put(chunk, timeout=.1)
                        break
                    except queue.Full:
                        pass
                if not chunk or p.stop_io.is_set():
                    return
        except BaseException as error:
            while not p.stop_io.is_set():
                try:
                    p.output_queue.put(error, timeout=.1)
                    return
                except queue.Full:
                    pass
    def writer():
        while not p.stop_io.is_set():
            try:
                data, done, errors = p.write_queue.get(timeout=.1)
            except queue.Empty:
                continue
            try:
                data = memoryview(data)
                while data:
                    count = p.stdin.write(data)
                    assert count and count > 0, 'stdin write made no progress'
                    data = data[count:]
            except BaseException as error:
                errors.append(error)
            finally:
                done.set()
    p.io_threads = [threading.Thread(target=reader, daemon=True), threading.Thread(target=writer, daemon=True)]
    for worker in p.io_threads:
        worker.start()
    return p

def write(p, data):
    deadline = time.monotonic() + 30
    done, errors = threading.Event(), []
    p.write_queue.put((data, done, errors), timeout=max(0, deadline - time.monotonic()))
    assert done.wait(max(0, deadline - time.monotonic())), 'stdin write exceeded 30s'
    if errors:
        raise errors[0]

def read_chunk(p, deadline):
    remaining = deadline - time.monotonic()
    assert remaining > 0, 'stdout deadline exceeded'
    try:
        chunk = p.output_queue.get(timeout=remaining)
    except queue.Empty:
        raise TimeoutError('response not flushed within stdout deadline')
    if isinstance(chunk, BaseException):
        raise chunk
    if not chunk:
        p.output_eof = True
    return chunk

def remaining_stdout(p):
    deadline = time.monotonic() + 5
    tail = bytearray(p.pending)
    p.pending.clear()
    while not p.output_eof:
        tail.extend(read_chunk(p, deadline))
        assert len(tail) <= 8 * 1024 * 1024, 'oversized trailing stdout'
    return bytes(tail)

def send(p, obj):
    write(p, (json.dumps(obj, ensure_ascii=False) + '\\n').encode())

# Active stdout lines must be JSON-RPC. Immediate mutation/partial EOF checks
# reject every trailing byte; finish retains the engine teardown allowance.
def receive(p, receive_timeout=5):
    deadline = time.monotonic() + receive_timeout
    while b'\\n' not in p.pending:
        chunk = read_chunk(p, deadline)
        assert chunk, 'unexpected stdout EOF'
        p.pending.extend(chunk)
        assert len(p.pending) <= 8 * 1024 * 1024 + 4096, 'oversized response'
    newline = p.pending.index(b'\\n') + 1
    assert newline <= 8 * 1024 * 1024, 'oversized response'
    raw = bytes(p.pending[:newline])
    del p.pending[:newline]
    assert raw.endswith(b'\\n'), ('missing response newline', raw)
    value = json.loads(raw)
    assert isinstance(value, dict) and value.get('jsonrpc') == '2.0', raw
    return value

def request(p, method, ident, params=None, receive_timeout=5):
    obj = {'jsonrpc': '2.0', 'method': method, 'id': ident}
    if params is not None:
        obj['params'] = params
    send(p, obj)
    value = receive(p, receive_timeout)
    assert value['id'] == ident, value
    return value

def finish(p):
    p.stdin.close()
    assert p.wait(timeout=10) == 0, 'EOF exit failure'
    # GUI children may print engine teardown text after EOF; only a protocol frame is a defect.
    assert b'"jsonrpc"' not in remaining_stdout(p), 'unexpected protocol output after EOF'

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
    def tool(name, arguments):
        value = request(p, 'tools/call', name, {'name': name, 'arguments': arguments})
        assert not value['result'].get('isError'), value
        return json.loads(value['result']['content'][0]['text'])
    lease = tool('docket_project_heartbeat', {'client': 'tool', 'client_class': 'tool'})
    assert not lease['renewed'] and not lease['lease']['owner_present'], lease
    refused = request(p, 'tools/call', 'refused', {'name': 'docket_project_add',
        'arguments': {'mode': 'memory', 'name': 'undeclared'}})
    assert refused['result'].get('isError'), refused
    assert tool('docket_project_heartbeat', {'client': 'parent', 'client_class': 'owner',
        'lease_seconds': 1})['renewed']
    time.sleep(1.2)
    assert not tool('docket_project_heartbeat', {'client': 'tool', 'client_class': 'tool'})['lease']['owner_present']
    grant_started = time.monotonic()
    assert tool('docket_project_heartbeat', {'client': 'parent', 'client_class': 'owner',
        'lease_seconds': 2})['lease']['owner_present']
    # Response time bounds the original expiry above, even for a slow grant.
    original_deadline = time.monotonic() + 2
    tool('docket_project_add', {'mode': 'memory', 'name': 'leased'})
    tool('docket_create', {'project': 'leased', 'type': 'chore', 'title': 'leased spill'})
    time.sleep(.5)
    renewal_started = time.monotonic()
    assert renewal_started < grant_started + 2, 'renewal may have missed original expiry'
    assert tool('docket_project_heartbeat', {'client': 'parent', 'client_class': 'owner',
        'lease_seconds': 4})['renewed']
    time.sleep(max(0, original_deadline - time.monotonic()) + .3)
    assert time.monotonic() < renewal_started + 4, 'observation missed renewed lease window'
    renewed = tool('docket_project_list', {})
    assert original_deadline < time.monotonic() < renewal_started + 4, 'observation outside renewal window'
    assert renewed['memory_lease']['owner_present'] and renewed['memory_lease']['holder'] == 'parent', renewed
    assert any(row['name'] == 'leased' and row['storage_mode'] == 'memory' for row in renewed['projects']), renewed
    assert tool('docket_project_heartbeat', {'client': 'parent', 'client_class': 'owner',
        'lease_seconds': 30})['renewed']
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
    assert remaining_stdout(p) == b'', 'unexpected protocol output after EOF'
    canonical = (base / 'scratch.dct').read_text(encoding='utf-8')
    assert title in canonical and eof_title in canonical, 'EOF did not settle the immediate write'
    assert not pathlib.Path(str(base / 'scratch.dct') + '.lock').exists(), 'EOF retained lock'
    spill = base / 'scratch-state' / 'sessions' / 'leased.dct'
    assert spill.exists() and 'leased spill' in spill.read_text(encoding='utf-8'), 'headless EOF did not spill privately'
    print('PASS explicit-owner-heartbeat/renewal/expiry/private-spill')
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
    assert remaining_stdout(p) == b''
    print('PASS oversized/recovery/backpressure/partial-EOF')

    p = launch('empty')
    finish(p)
    print('PASS empty-EOF')
    for p, err in children:
        err.close()
    for log in base.glob('*.stderr'):
        assert b'SCRIPT ERROR' not in log.read_bytes(), log.read_text(encoding='utf-8', errors='replace')
    print('STDIO REAL PROCESS: 3 scenarios passed, 0 skipped')
except BaseException:
    diagnose()
    raise
finally:
    for p, err in children:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=10)
        p.stop_io.set()
        for worker in p.io_threads:
            worker.join(timeout=1)
        p.stdin.close()
        p.stdout.close()
        err.close()
    root.cleanup()
    completed.set()
"""


func test_real_child_stdio() -> Variant:
	# setup-python installs `python` on Windows (release.yml uses the same name).
	# -c avoids a launcher file in Godot user:// or a platform-specific /tmp.
	var python := "python" if OS.get_name() == "Windows" else "python3"
	var output: Array = []
	var code := OS.execute(python, PackedStringArray(["-c", DRIVER, OS.get_executable_path(), ProjectSettings.globalize_path("res://")]), output, true)
	var report := "\n".join(PackedStringArray(output))
	print(report)
	if code != 0 or not report.contains("3 scenarios passed, 0 skipped"):
		return "Child stdio oracle failed (exit %d): %s" % [code, report]
	return true
