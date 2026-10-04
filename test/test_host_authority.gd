extends Node
## Fresh real children with synthetic authentication only. Reuse the stdio
## fixture's bounded pipe I/O, watchdog and private process directories.
const HostAuthority := preload("res://scripts/mcp/host_authority.gd")
const StdioFixture := preload("res://test/test_stdio_transport.gd")
const DRIVER := """
a, b = 'a' * 64, 'b' * 64
sentinels = (a, b, 'short', 'g' * 64, 'A' * 64, 'a' * 63, 'a' * 65)
env.pop('DOCKET_PANEL_SECRET', None)

def private(p, token, ident=1, method='docket/panel/status', extra=None):
    params = {} if token is None else {'panel_secret': token}
    params.update(extra or {})
    reply = request(p, method, ident, params)
    assert a not in json.dumps(reply) and b not in json.dumps(reply), 'authentication reflected'
    return reply

def refused(reply, code):
    assert reply.get('error', {}).get('code') == code, 'wrong refusal'

try:
    if scenario == 'startup':
        for i, token in enumerate((None, '', 'short', 'g' * 64, 'A' * 64, 'a' * 63, 'a' * 65)):
            if token is None:
                env.pop('DOCKET_PANEL_SECRET', None)
            else:
                env['DOCKET_PANEL_SECRET'] = token
            p = launch('invalid-%d' % i, ['--host-authority'])
            assert p.wait(timeout=10) == 2, 'invalid hosted startup did not refuse'
            assert remaining_stdout(p) == b'', 'refused startup emitted stdout'
        env['DOCKET_PANEL_SECRET'] = a
        args.remove('--stdio')
        p = launch('http-optin', ['--host-authority'])
        assert p.wait(timeout=10) == 2, 'HTTP hosted opt-in did not refuse'
        assert remaining_stdout(p) == b'', 'HTTP refusal emitted stdout'
    elif scenario == 'auth-restart':
        env['DOCKET_PANEL_SECRET'] = a
        p = launch('hosted', ['--host-authority'])
        assert request(p, 'initialize', 0)['result']['serverInfo']['name'] == 'docket'
        tools = request(p, 'tools/list', 1)['result']['tools']
        assert tools and all(not t['name'].startswith('docket/panel/') for t in tools), 'private tool listed'
        refused(request(p, 'tools/call', 2, {'name': 'docket/panel/status',
            'arguments': {'panel_secret': a}}), -32602)
        first = private(p, a, 3)['result']
        assert first == {'protocol': 'docket_panel_v1', 'pid': p.pid}, 'private status routing failed'
        for i, token in enumerate((None, '', b, 'short', 42, {'nested': a})):
            refused(private(p, token, 10 + i), -32001)
        for field in ('panel_grant', 'panel_session', 'panel', 'person', 'actions', 'arguments'):
            refused(private(p, a, 20, extra={field: {}}), -32602)
        refused(private(p, a, 21, method='docket/panel/unknown'), -32601)
        refused(request(p, 'docket/panel/status', 22, {'panel_secret': a, 'extra': True}), -32602)
        # The framer rejects malformed containers before the private dispatcher.
        send(p, {'jsonrpc': '2.0', 'id': 23, 'method': 'docket/panel/status', 'params': []})
        refused(receive(p), -32600)
        assert request(p, 'ping', 24)['result'] == {}, 'ordinary hosted MCP failed'
        finish(p)
        env['DOCKET_PANEL_SECRET'] = b
        q = launch('hosted', ['--host-authority'])  # same state, fresh generation
        refused(private(q, a), -32001)
        current = private(q, b, 2)['result']
        assert current == {'protocol': 'docket_panel_v1', 'pid': q.pid}, 'fresh secret refused'
        assert current['pid'] != first['pid'], 'restart reused process'
        finish(q)
    elif scenario == 'transports':
        env['DOCKET_PANEL_SECRET'] = a  # presence alone must never enable authority
        p = launch('ordinary')
        assert request(p, 'ping', 0)['result'] == {}
        refused(private(p, a), -32601)
        assert request(p, 'tools/list', 2)['result']['tools'], 'ordinary stdio registry missing'
        finish(p)
        import socket, urllib.request, urllib.error
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        args.remove('--stdio')
        q = launch('ordinary-http', ['--port', str(port)])
        def http(method, params=None):
            payload = {'jsonrpc': '2.0', 'id': 1, 'method': method}
            if params is not None:
                payload['params'] = params
            req = urllib.request.Request('http://127.0.0.1:%d/mcp' % port,
                data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
            deadline = time.monotonic() + 10
            while True:
                try:
                    with urllib.request.urlopen(req, timeout=2) as response:
                        return json.load(response)
                except urllib.error.URLError:
                    assert q.poll() is None and time.monotonic() < deadline, 'HTTP startup failed'
                    time.sleep(.1)
        assert http('ping')['result'] == {}, 'ordinary HTTP ping failed'
        assert http('tools/list')['result']['tools'], 'ordinary HTTP registry missing'
        refused(http('docket/panel/status', {'panel_secret': a}), -32601)
        refused(http('tools/call', {'name': 'docket/panel/status', 'arguments': {}}), -32602)
        q.terminate()
        q.wait(timeout=10)
    else:
        raise AssertionError('unknown scenario')
    for log in base.glob('*.stderr'):
        data = log.read_bytes()
        assert b'SCRIPT ERROR' not in data, 'child script error'
        assert all(token.encode() not in data for token in sentinels), 'authentication logged'
    # Domain state must never retain a per-process authentication token.
    for path in base.rglob('*'):
        if path.is_file() and path.suffix != '.stderr':
            data = path.read_bytes()
            assert a.encode() not in data and b.encode() not in data, 'authentication persisted'
    print('HOST AUTH %s PASS' % scenario)
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


func _run_scenario(scenario: String) -> Variant:
	# A Windows checkout may give CRLF sources; the slice marker is LF-only.
	var driver := StdioFixture.DRIVER.replace("\r\n", "\n")
	var helpers := driver.get_slice("\ntry:\n    p = launch('scratch')", 0)
	if helpers == driver:
		return "stdio driver slice marker not found"
	helpers = helpers.replace("['--state-dir', str(base / (name + '-state')), '--file', str(base / (name + '.dct'))]", "['--state-dir', str(base / (name + '-state'))] + ([] if '--host-authority' in extra else ['--file', str(base / (name + '.dct'))])")
	var source := "import sys\nscenario = sys.argv.pop()\n" + helpers + DRIVER
	var python := "python" if OS.get_name() == "Windows" else "python3"
	var output: Array = []
	var code := OS.execute(python, PackedStringArray(["-c", source, OS.get_executable_path(),
		ProjectSettings.globalize_path("res://"), scenario]), output, true)
	var report := "\n".join(PackedStringArray(output))
	# Even a failing child's traceback must not publish synthetic tokens.
	for token in ["a".repeat(65), "a".repeat(64), "a".repeat(63), "b".repeat(64),
		"g".repeat(64), "A".repeat(64), "short"]:
		report = report.replace(token, "[redacted]")
	print(report)
	if code != 0 or not report.contains("HOST AUTH %s PASS" % scenario):
		return "Host authentication %s failed (exit %d)" % [scenario, code]
	return true


func test_hosted_startup_refusals() -> Variant:
	return _run_scenario("startup")


func test_private_authentication_and_restart() -> Variant:
	return _run_scenario("auth-restart")


func test_ordinary_stdio_and_http() -> Variant:
	return _run_scenario("transports")


func test_environment_secret_consumed() -> Variant:
	var was_present := OS.has_environment("DOCKET_PANEL_SECRET")
	var previous := OS.get_environment("DOCKET_PANEL_SECRET")
	for enabled in [false, true]:
		OS.set_environment("DOCKET_PANEL_SECRET", "a".repeat(64))
		var authority := HostAuthority.new()
		var error := authority.configure_from_environment(enabled, true)
		var cleared := OS.get_environment("DOCKET_PANEL_SECRET").is_empty()
		if was_present:
			OS.set_environment("DOCKET_PANEL_SECRET", previous)
		else:
			OS.unset_environment("DOCKET_PANEL_SECRET")
		if not cleared:
			return "Host authority retained environment secret (enabled=%s)" % enabled
		if not error.is_empty():
			return "Host authority configuration failed (enabled=%s)" % enabled
	return true
