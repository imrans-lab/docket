extends Node
## New vaults are created only through the actual private child channel. The
## existing fixture supplies bounded pipes, safe diagnostics and leak scans.
const Fixture := preload("res://test/test_host_vault.gd")
const DRIVER := """
try:
    paths = []
    p = open_host('created')
    path = base/'created.dct'
    call(p, 'docket_project_add', dict(path=str(path), create=True))
    # The public project API deliberately refuses closing the last opening.
    call(p, 'docket_project_add', dict(path=str(base/'keeper.dct'), create=True))
    call(p, 'docket_flush', {})
    before = path.read_bytes()
    absent = bind(p, path)
    assert not absent['initialized'] and not absent['unlocked'] and absent['hint'] == '', 'absent challenge state'
    fields = {k:absent[k] for k in ('path','open_generation','fingerprint')}
    good = dict(**fields, password=passwords[0], hint='00123')
    def create(fields, auth=None, derive=False):
        return private(p, 'vault_init', fields, auth, 'vault_init' if derive else None)
    assert request(p, 'tools/call', 1, dict(name='docket/panel/vault_init', arguments=good))['error']['code'] == -32602, 'creation exposed as tool'
    assert not any(t['name'].startswith('docket/panel/') for t in request(p, 'tools/list', 2)['result']['tools']), 'private tool listed'
    for bad in (dict(good, password=''), dict(good, password=42), dict(good, password='x'*1025),
                dict(good, fingerprint='stale'), dict(good, open_generation='stale'), dict(good, path=path.name),
                dict(good, salt='caller'), dict(good, key='caller'), dict(good, iterations=10000),
                dict(good, hint=passwords[0]), dict(good, hint=42), dict(good, hint='x'*1025)):
        assert 'error' in create(bad), 'invalid creation accepted'
    assert create(good, 'f'*64)['error']['code'] == -32001, 'creation authentication bypass'
    assert path.read_bytes() == before and not pathlib.Path(str(path)+'.log').exists(), 'refusal changed storage'
    created = create(good, derive=True)['result']
    assert created['initialized'] and created['unlocked'] and created['hint'] == '00123', 'creation state'
    assert created['fingerprint'] != absent['fingerprint'] and created['open_generation'] == absent['open_generation'], 'creation binding transition'
    # Independent Python KDF checks the persisted contract, not the reply.
    call(p, 'docket_flush', {})
    meta = json.loads(path.read_text().splitlines()[0])
    assert meta['vault_kdf_iterations'] == 600000 and meta['vault_hint'] == '00123', 'new cost or string hint'
    salt = base64.b64decode(meta['vault_salt'])
    assert len(salt) == 16, 'generated salt length'
    key = hashlib.pbkdf2_hmac('sha256', passwords[0].encode(), salt, 600000)
    keys.append(key)
    assert hmac.compare_digest(hmac.new(key, b'docket-vault-verify', hashlib.sha256).digest(), base64.b64decode(meta['vault_verify'])), 'independent creation KDF'
    stored = path.read_bytes()
    repeated = dict(good, **{k:created[k] for k in ('path','open_generation','fingerprint')})
    assert 'error' in create(repeated) and path.read_bytes() == stored, 'second creation overwrote vault'
    call(p, 'docket_secret_set', dict(project='created', handle='entry', value=values[0]))
    assert call(p, 'docket_secret_get', dict(project='created', handle='entry'))['value'] == values[0], 'created secret roundtrip'
    call(p, 'docket_flush', {})
    # Close/remove cache/reopen exercises the canonical vault and plain hint.
    call(p, 'docket_project_remove', dict(name='created'))
    for cache in base.glob('created.dct.*cache*'):
        if cache.is_file(): cache.unlink()
    call(p, 'docket_project_add', dict(path=str(path)))
    locked(p, 'created')
    fresh = bind(p, path)
    assert fresh['hint'] == '00123' and fresh['open_generation'] != created['open_generation'], 'canonical rebuild descriptor'
    assert 'error' in create(good), 'closed opening creation accepted'
    assert unlock(p, fresh, passwords[0], 'vault_unlock')['result']['unlocked'], 'rebuilt vault unlock'
    assert call(p, 'docket_secret_get', dict(project='created', handle='entry'))['value'] == values[0], 'rebuilt ciphertext'
    # Partial metadata and future read-only formats must not be overwritten.
    for index, extra in enumerate(({'vault_salt':''}, {'vault_verify':''}, {'vault_verify':'broken'}, {'vault_hint':'orphan'},
                                    {'vault_kdf_iterations':600000}, {'vault_kdf_iterations':''}, {'version':'3.0.0'})):
        malformed = base/('refused-%d.dct'%index)
        malformed.write_text(json.dumps(dict(dict(_type='meta', version='2.0.0', counter=0, id_prefix='R', project='refused-%d'%index), **extra)) + chr(10))
        original = malformed.read_bytes()
        call(p, 'docket_project_add', dict(path=str(malformed)))
        assert 'error' in private(p, 'vault_challenge', dict(path=str(malformed))), 'incomplete or read-only challenge'
        assert 'error' in create(dict(good, path=str(malformed))), 'incomplete or read-only init'
        assert malformed.read_bytes() == original, 'incomplete vault changed'
        if 'version' not in extra:
            call(p, 'docket_project_meta', dict(project='refused-%d'%index, action='set', stage='experiment'))
            call(p, 'docket_flush', {})
            persisted = json.loads(malformed.read_text().splitlines()[0])
            assert all(persisted[k] == v for k,v in extra.items()), 'partial metadata lost during ordinary write'
            assert 'error' in private(p, 'vault_challenge', dict(path=str(malformed))), 'ordinary write made partial vault absent'
    if sys.platform.startswith('linux'):
        proc = pathlib.Path('/proc')/str(p.pid)
        seen.extend((proc/'cmdline').read_bytes() + (proc/'environ').read_bytes())
    finish(p)
    assert_private_files()
    old_token = token
    token = secrets.token_hex(32)
    paths = [path]
    q = open_host('created')
    assert private(q, 'vault_init', good, old_token)['error']['code'] == -32001, 'restart accepted old token'
    locked(q, 'created')
    restart = bind(q, path)
    assert restart['initialized'] and restart['hint'] == '00123' and not restart['unlocked'], 'restart vault state'
    assert unlock(q, restart, passwords[0], 'vault_unlock')['result']['unlocked'], 'created vault restart unlock'
    assert call(q, 'docket_secret_get', dict(project='created', handle='entry'))['value'] == values[0], 'restart created value'
    finish(q)
    assert_private_files()
    # Ordinary stdio cannot reach creation, even with a token in its params.
    q = launch('ordinary-created', ['--file',str(path)])
    assert private(q, 'vault_init', good)['error']['code'] == -32601, 'ordinary stdio creation bypass'
    finish(q)
    needles = [pw.encode() for pw in passwords]
    for key in keys: needles.extend((key, key.hex().encode(), base64.b64encode(key)))
    assert all(needle not in seen for needle in needles), 'creation material in output/proc'
    assert_private_files()
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

func test_real_child_creation_reopen_restart_privacy() -> Variant:
	var anchor := "\ntry:\n    # Producer and consumer"
	if Fixture.DRIVER.count(anchor) != 1: return "Vault helper slice marker missing"
	var fixture := Fixture.new()
	var result: Variant = fixture.run_actual_child(Fixture.DRIVER.get_slice(anchor, 0) + DRIVER)
	fixture.free()
	return result


func test_failed_creation_leaves_no_metadata_or_memory_key() -> Variant:
	var directory := ProjectSettings.globalize_path("user://vault-init-failure")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("failure.dct")
	var db := DocketDBJsonl.create_new_jsonl(path)
	if db == null: return "Failure fixture could not open"
	var before := FileAccess.get_file_as_bytes(path)
	var password := Crypto.new().generate_random_bytes(24).hex_encode()
	var failure := ""
	# Fail both before writing and after the metadata sidecar append landed.
	for append_first in [false, true]:
		db._atomic_write_hook = func(target: String, text: String) -> String:
			if append_first: JSONLSidecar.append(target, text)
			return "injected creation write failure"
		var descriptor := VaultKeySession.descriptor(db)
		var fields := {"panel_secret":"a".repeat(64), "path":descriptor.path,
			"open_generation":descriptor.open_generation, "fingerprint":descriptor.fingerprint, "password":password, "hint":"00123"}
		var reply := VaultKeySession.handle("vault_init", fields, db)
		db._atomic_write_hook = Callable()
		if not reply.has("error") or db.has_vault() or not VaultKeySession.key_for(db).is_empty() or not db.vault_creation_refusal().is_empty() or FileAccess.get_file_as_bytes(path) != before or JSONLSidecar.has_content(path + ".log"):
			failure = "Failed creation retained metadata, key or changed source"
			break
	db.close()
	var reopened := DocketDBJsonl.open_jsonl(path)
	if reopened == null: failure = "Failure fixture did not reopen"
	elif not reopened.vault_creation_refusal().is_empty(): failure = "Failed creation survived reopen"
	if reopened != null: reopened.close()
	var dir := DirAccess.open(directory)
	for file in dir.get_files(): dir.remove(file)
	DirAccess.remove_absolute(directory)
	return true if failure.is_empty() else failure
