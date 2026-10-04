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
    elif scenario == 'bootstrap':
        import base64
        stage = 'bootstrap_setup'
        schema = {'types': {'chore': {'label': 'Chore', 'states': ['open', 'done'], 'initial_state': 'open', 'terminal_states': ['done'], 'transitions': {'open': ['done'], 'done': []}, 'required_fields': ['title'], 'optional_fields': []}}}
        shipment = chr(10).join((json.dumps(dict(_type='meta', version='1.0.0', counter=1, id_prefix='BTS', project='bootstrap'), separators=(',', ':')), json.dumps(dict(_type='item', id='BTS-0001', type='chore', status='open', title='shipped', created_at='t', updated_at='t'), separators=(',', ':')), ''))
        def call(p, name, arguments):
            reply = request(p, 'tools/call', 92, dict(name=name, arguments=arguments))
            assert not reply['result'].get('isError'), 'ordinary tool refused'
            return json.loads(reply['result']['content'][0]['text'])
        def bootstrap(p, canonical_path, text=shipment, **extra):
            fields = dict(path=str(canonical_path), content=base64.b64encode(text.encode()).decode())
            fields.update(extra)
            return private(p, a, 93, 'docket/panel/bootstrap_project', fields)
        try:
            assert shipment.count(chr(10)) == 2
            for row in shipment.splitlines(): json.loads(row)
        except BaseException as error:
            print('BOOTSTRAP_FIXTURE_DIAGNOSTIC %s lf=%d lines=%d' % (type(error).__name__, shipment.count(chr(10)), len(shipment.splitlines())), file=sys.stderr, flush=True)
            raise
        for gui in (False, True):
            stage = 'bootstrap_gui' if gui else 'bootstrap_headless'
            if gui: args.remove('--serve')
            env['DOCKET_PANEL_SECRET'] = a
            p = launch('bootstrap-%s' % gui, ['--host-authority'])
            path = base / ('bootstrap-%s.dct' % gui)
            refused(bootstrap(p, path), -32602)
            assert not path.exists(), 'undeclared schema mutated disk'
            assert 'result' in private(p, a, 94, 'docket/panel/declare_schema', dict(schema=schema, version='bootstrap-fixture'))
            for fields in ({'content': '!!!!'}, {'content': 'YQ=='}, {'content': '/w=='}, {'content': 'YQ='}, {'path': 'relative.dct'}, {'extra': True}):
                refused(bootstrap(p, path, **fields), -32602)
                assert not path.exists(), 'invalid request mutated disk'
            refused(private(p, b, 95, 'docket/panel/bootstrap_project', dict(path=str(path), content=base64.b64encode(shipment.encode()).decode())), -32001)
            first_reply = bootstrap(p, path)
            # Only this synthetic non-vault install's refusal message is retained.
            diagnostic_dir = pathlib.Path(project) / 'runtime-logs'
            if 'error' in first_reply and diagnostic_dir.is_dir():
                (diagnostic_dir / 'bootstrap-install-refusal.txt').write_text(first_reply['error']['message'])
            result = first_reply['result']
            opened = result['project']
            seeded = bootstrap(p, path, shipment.replace('"counter":1', '"counter":1,"master_bootstrap_state":"forged"'))
            refused(seeded, -32602)
            assert 'Shipment may not seed reserved bootstrap state' in seeded['error']['message'], 'disk refusal reason omitted'
            malformed = bootstrap(p, path, 'bad JSONL')
            refused(malformed, -32602)
            assert 'malformed JSONL at line 1' in malformed['error']['message'], 'shipment refusal reason omitted'
            assert result['status'] == 'installed' and result['inserted'] == ['BTS-0001']
            assert opened['name'] == 'bootstrap' and opened['path'] == str(path)
            assert opened['primary'] and opened['open_generation'] and opened['read_only_reason'] == ''
            assert call(p, 'docket_project_list', {})['projects'] == [opened]
            assert call(p, 'docket_get', dict(id='BTS-0001'))['title'] == 'shipped'
            installed = path.read_bytes()
            repeated = bootstrap(p, path)['result']
            assert repeated['project'] == opened and path.read_bytes() == installed
            collision = base / ('collision-%s.dct' % gui)
            refused(bootstrap(p, collision), -32602)
            assert not collision.exists() and call(p, 'docket_project_list', {})['projects'] == [opened]
            current = bootstrap(p, path, shipment.replace('shipped', 'upgraded'))['result']
            assert current['updated'] == ['BTS-0001'] and current['project']['open_generation'] == opened['open_generation']
            assert call(p, 'docket_get', dict(id='BTS-0001'))['title'] == 'upgraded'
            state = json.loads(path.read_text().splitlines()[0])['master_bootstrap_state']
            assert isinstance(state, str) and json.loads(state)['ever_shipped'] == ['BTS-0001']
            changed = call(p, 'docket_project_meta', dict(action='set', stage='experiment', hypothesis='ordinary', master_bootstrap_state='forged'))
            call(p, 'docket_flush', {})
            assert json.loads(path.read_text().splitlines()[0])['master_bootstrap_state'] == state
            for reply in (result, repeated, current, changed, call(p, 'docket_project_meta', dict(action='get')), call(p, 'docket_project_list', {})):
                assert 'master_bootstrap_state' not in json.dumps(reply) and 'baseline_b64' not in json.dumps(reply), 'internal state exposed'
            refused(request(p, 'tools/call', 96, dict(name='docket/panel/bootstrap_project', arguments={})), -32602)
            assert not any(t['name'] == 'docket/panel/bootstrap_project' for t in request(p, 'tools/list', 97)['result']['tools'])
            finish(p)
        args.append('--serve')
    elif scenario == 'transports':
        env['DOCKET_PANEL_SECRET'] = a  # presence alone must never enable authority
        p = launch('ordinary')
        assert request(p, 'ping', 0)['result'] == {}
        refused(private(p, a), -32601)
        refused(private(p, a, 3, 'docket/panel/bootstrap_project', dict(path=str(base / 'private.dct'), content='YQ==')), -32601)
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
        refused(http('docket/panel/bootstrap_project', {'panel_secret': a, 'path': str(base / 'private.dct'), 'content': 'YQ=='}), -32601)
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
except BaseException as error:
    trace = error.__traceback__
    while trace.tb_next is not None: trace = trace.tb_next
    print('HOST_AUTH_DIAGNOSTIC %s line=%d stage=%s' % (type(error).__name__, trace.tb_lineno, scenario), file=sys.stderr, flush=True)
    sys.exit(1)
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
	var unsafe_reporter := helpers.get_slice("def diagnose():", 1).get_slice("def watchdog():", 0)
	helpers = helpers.replace("def diagnose():" + unsafe_reporter, "def diagnose():\n    print('HOST_AUTH_DIAGNOSTIC TimeoutError line=0 stage=watchdog', file=sys.stderr, flush=True)\n\n")
	helpers = helpers.replace("completed.wait(180)", "completed.wait(540)")
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
		for params in [null, []]:
			var refusal := authority.handle("docket/panel/status", params)
			if refusal.get("error", {}).get("code") != -32001:
				return "Unauthenticated private parameter shape did not refuse authentication"
	return true


func test_private_bootstrap_gui_and_headless() -> Variant:
	return _run_scenario("bootstrap")
