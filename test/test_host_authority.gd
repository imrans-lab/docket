extends Node
## Existing bootstrap integration oracle, now exercising public HTTP tools.
const Fixture := preload("res://test/test_host_vault.gd")
const DRIVER := """
def refused(reply, code):
    assert reply.get('error', {}).get('code') == code, 'expected public refusal'
try:
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
        reply = request(p, 'tools/call', 93, dict(name='docket_project_bootstrap', arguments=fields))['result']
        return {'error':json.loads(reply['content'][0]['text'])} if reply.get('isError') else {'result':json.loads(reply['content'][0]['text'])}
    try:
        assert shipment.count(chr(10)) == 2
        for row in shipment.splitlines(): json.loads(row)
    except BaseException as error:
        print('BOOTSTRAP_FIXTURE_DIAGNOSTIC %s lf=%d lines=%d' % (type(error).__name__, shipment.count(chr(10)), len(shipment.splitlines())), file=sys.stderr, flush=True)
        raise
    for gui in (False, True):
        stage = 'bootstrap_gui' if gui else 'bootstrap_headless'
        p = launch('bootstrap-%s' % gui)
        path = base / ('bootstrap-%s.dct' % gui)
        call(p, 'docket_schema_declare', dict(schema=schema, version='bootstrap-fixture'))
        for fields in ({'content': '!!!!'}, {'content': 'YQ=='}, {'content': '/w=='}, {'content': 'YQ='}, {'path': 'relative.dct'}, {'extra': True}):
            refused(bootstrap(p, path, **fields), -32602)
            assert not path.exists(), 'invalid request mutated disk'
        first_reply = bootstrap(p, path)
        # Only this synthetic non-vault install's refusal message is retained.
        diagnostic_dir = pathlib.Path(project) / 'runtime-logs'
        if 'error' in first_reply and diagnostic_dir.is_dir():
            (diagnostic_dir / 'bootstrap-install-refusal.txt').write_text(first_reply['error']['message'])
        result = first_reply['result']
        opened = result['project']
        seeded_meta = json.loads(shipment.splitlines()[0])
        seeded_meta['master_bootstrap_state'] = 'forged'
        seeded_text = json.dumps(seeded_meta, separators=(',', ':')) + chr(10) + shipment.splitlines()[1] + chr(10)
        assert seeded_text != shipment and json.loads(seeded_text.splitlines()[0])['master_bootstrap_state'] == 'forged'
        seeded = bootstrap(p, path, seeded_text)
        refused(seeded, -32602)
        assert 'Shipment may not seed reserved bootstrap state' in seeded['error']['message'], 'disk refusal reason omitted'
        malformed = bootstrap(p, path, 'bad JSONL')
        refused(malformed, -32602)
        assert 'malformed JSONL at line 1' in malformed['error']['message'], 'shipment refusal reason omitted'
        assert result['status'] == 'installed' and result['inserted'] == ['BTS-0001']
        # Descriptor paths use forward slashes on every platform.
        assert opened['name'] == 'bootstrap' and opened['path'] == path.as_posix()
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
        call(p, 'docket_update', dict(id='BTS-0001', title='mine'))
        preserved = bootstrap(p, path, shipment.replace('shipped', 'upstream'))['result']
        assert call(p, 'docket_get', dict(id='BTS-0001'))['title'] == 'mine', 'customised item replaced'
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
    for log in base.glob('*.stderr'):
        assert b'SCRIPT ERROR' not in log.read_bytes(), 'child script error'
    print('HOST VAULT receiver-consumer-lifetime-privacy PASS')
finally:
    cleanup()
"""

func test_public_bootstrap_real_child() -> Variant:
	var fixture := Fixture.new()
	var result: Variant = fixture.run_actual_child(DRIVER)
	fixture.free()
	return result
