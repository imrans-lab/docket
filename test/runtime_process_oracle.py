#!/usr/bin/env python3
"""Linux actual GUI/HTTP + GUI/stdio oracle; run with xvfb-run, never author gate."""
import ctypes, json, os, pathlib, re, signal, socket, sqlite3, sys, time, urllib.request

engine, project = sys.argv[1:]
assert sys.platform == 'linux' and os.environ.get('DISPLAY'), 'Linux Xvfb DISPLAY required; no skipped pass'
# Reuse the broad child oracle's framing/deadlines/cleanup rather than a second client.
source = (pathlib.Path(project) / 'test/test_stdio_transport.gd').read_text()
driver = source.split('const DRIVER := """', 1)[1].split('"""', 1)[0].replace('\\\\', '\\')
exec(compile(driver.split('\ntry:\n', 1)[0], 'shared-stdio-client', 'exec'))
signal.alarm(180)
owner = None


def call(p, name, arguments=None):
    value = request(p, 'tools/call', name, {'name': name, 'arguments': arguments or {}})
    assert not value['result'].get('isError'), value
    return json.loads(value['result']['content'][0]['text'])


def spawn(name, profile, files=(), restore=False, headless=False, http_port=None):
    err = open(base / (name + '.stderr'), 'wb')
    cmd = [engine, '--quiet', '--path', project]
    if headless:
        cmd.append('--headless')
    else:
        cmd += ['--display-driver', 'x11', '--rendering-method', 'gl_compatibility']
    cmd += ['--', '--state-dir', str(profile), '--port', str(port)]
    if http_port is None:
        cmd.append('--stdio')
    if headless:
        cmd.append('--serve')
    if restore:
        cmd.append('--restore-session')
    for file in files:
        cmd += ['--file', str(file)]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, env=env, bufsize=0)
    os.set_blocking(p.stdin.fileno(), False)
    children.append((p, err))
    return p


def http(method='ping', params=None):
    payload = {'jsonrpc': '2.0', 'method': method, 'id': 'owner'}
    if params is not None:
        payload['params'] = params
    req = urllib.request.Request('http://127.0.0.1:%d/mcp' % port,
        data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=2) as response:
        return json.load(response)


def listeners(pid):
    inodes = set()
    for fd in pathlib.Path('/proc/%d/fd' % pid).iterdir():
        try:
            link = fd.readlink().as_posix()
        except FileNotFoundError:
            continue
        if link.startswith('socket:['):
            inodes.add(link[8:-1])
    return [line for path in ('/proc/net/tcp', '/proc/net/tcp6')
            for line in pathlib.Path(path).read_text().splitlines()[1:]
            if line.split()[3] == '0A' and line.split()[9] in inodes]


def external_focus(expected_pid):
    # Independent X11 focus/PID/title observation, not just the MCP reply.
    x = ctypes.CDLL('libX11.so.6')
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    display = x.XOpenDisplay(None)
    assert display, 'cannot inspect Xvfb focus'
    # Turn asynchronous X errors into Python failures so child diagnostics run.
    errors = []
    handler_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
    handler = handler_type(lambda display, event: errors.append('X11 observation error') or 0)
    x.XSetErrorHandler.argtypes = [handler_type]
    x.XSetErrorHandler(handler)
    x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x.XDefaultRootWindow.restype = ctypes.c_ulong
    root_window = x.XDefaultRootWindow(display)
    parent, root_id = ctypes.c_ulong(), ctypes.c_ulong()
    windows, total = ctypes.POINTER(ctypes.c_ulong)(), ctypes.c_uint()
    x.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint)]
    assert x.XQueryTree(display, root_window, ctypes.byref(root_id), ctypes.byref(parent), ctypes.byref(windows), ctypes.byref(total))
    candidates = list(windows[:total.value])
    x.XFree.argtypes = [ctypes.c_void_p]
    x.XFree(windows)
    class Attributes(ctypes.Structure):
        _fields_ = [(name, kind) for name, kind in (
            ('x', ctypes.c_int), ('y', ctypes.c_int), ('width', ctypes.c_int), ('height', ctypes.c_int),
            ('border_width', ctypes.c_int), ('depth', ctypes.c_int), ('visual', ctypes.c_void_p),
            ('root', ctypes.c_ulong), ('class_', ctypes.c_int), ('bit_gravity', ctypes.c_int),
            ('win_gravity', ctypes.c_int), ('backing_store', ctypes.c_int), ('backing_planes', ctypes.c_ulong),
            ('backing_pixel', ctypes.c_ulong), ('save_under', ctypes.c_int), ('colormap', ctypes.c_ulong),
            ('map_installed', ctypes.c_int), ('map_state', ctypes.c_int), ('all_event_masks', ctypes.c_long),
            ('your_event_mask', ctypes.c_long), ('do_not_propagate_mask', ctypes.c_long),
            ('override_redirect', ctypes.c_int), ('screen', ctypes.c_void_p))]
    x.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(Attributes)]
    window, revert = ctypes.c_ulong(), ctypes.c_int()
    x.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]
    x.XGetInputFocus(display, ctypes.byref(window), ctypes.byref(revert))
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XInternAtom.restype = ctypes.c_ulong
    atom = x.XInternAtom(display, b'_NET_WM_PID', 0)
    actual, count, remaining = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_ulong()
    fmt, data = ctypes.c_int(), ctypes.POINTER(ctypes.c_ubyte)()
    x.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
        ctypes.c_long, ctypes.c_long, ctypes.c_int, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte))]
    focused_window = window.value
    matched = None
    for candidate in candidates:
        attrs = Attributes()
        if not x.XGetWindowAttributes(display, candidate, ctypes.byref(attrs)) or attrs.map_state != 2:
            continue
        status = x.XGetWindowProperty(display, candidate, atom, 0, 1, 0, 0, ctypes.byref(actual),
            ctypes.byref(fmt), ctypes.byref(count), ctypes.byref(remaining), ctypes.byref(data))
        pid = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[0] if status == 0 and count.value == 1 and fmt.value == 32 else None
        if data:
            x.XFree(data)
        if pid == expected_pid:
            matched = candidate
            break
    x.XSync(display, 0)
    assert not errors, errors
    assert matched is not None, 'no mapped window for child PID'
    # None/PointerRoot are valid focus states on bare Xvfb, never property targets.
    assert focused_window in (0, 1, matched), ('another window owns focus', focused_window, matched)
    window.value = matched
    title = ctypes.c_char_p()
    x.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
    assert x.XFetchName(display, window, ctypes.byref(title)), 'focused window has no title'
    name = title.value.decode(errors='replace')
    x.XFree(title)
    x.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x.XSync(display, 0)
    assert not errors, errors
    x.XCloseDisplay(display)
    print('X11 mapped PID=%s title=%r focus=%s' % (expected_pid, name, focused_window))
    if focused_window in (0, 1):
        print('X11 focus transfer unobservable without WM; mapped/open verified, focus request only')
    return expected_pid, name


try:
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    assert port != 3010
    owner_profile, private = base / 'owner-profile', base / 'plugin-profile'
    default_profile = pathlib.Path(env['XDG_DATA_HOME']) / 'godot/app_userdata/Docket'
    default_profile.mkdir(parents=True)
    default_prefs = default_profile / 'docket_prefs.json'
    default_prefs.write_text(json.dumps({'first_name': 'default sentinel', 'session_paths': [str(base / 'forbidden.dct')]}))
    default_snapshot = default_prefs.read_bytes()
    env['DOCKET_SESSION_DIR'] = str(base / 'forbidden-session-dir')
    owner_profile.mkdir()
    private.mkdir()
    owner_file, opened_file = base / 'owner.dct', base / 'opened.dct'
    # Disposable sentinels, not credentials or live owner state.
    owner_prefs = owner_profile / 'docket_prefs.json'
    owner_prefs.write_text(json.dumps({'first_name': 'owner sentinel', 'session_paths': [str(owner_file)]}))
    owner = spawn('owner', owner_profile, [owner_file], http_port=port)
    deadline = time.monotonic() + 20
    while True:
        assert owner.poll() is None, 'isolated owner failed startup'
        try:
            assert http()['result'] == {}
            break
        except OSError:
            assert time.monotonic() < deadline, 'isolated owner HTTP unavailable'
            time.sleep(.1)
    # Snapshot the owner's profile after its own startup changes.
    owner_snapshot = {p.name: p.read_bytes() for p in owner_profile.iterdir() if p.is_file()}
    p = spawn('plugin', private)
    assert request(p, 'initialize', 1)['result']['serverInfo']['name'] == 'docket'
    assert call(p, 'docket_project_list')['projects'] == [], 'private child restored owner/CWD files'
    assert not listeners(p.pid), 'stdio child opened a TCP listener'
    assert http()['result'] == {}, 'owner HTTP collided with child'
    # Seed a real existing project with a disposable headless child.
    seed = spawn('seed', base / 'seed-profile', [opened_file], headless=True)
    item = call(seed, 'docket_create', {'type': 'chore', 'title': 'existing GUI item'})
    finish(seed)
    added = call(p, 'docket_project_add', {'path': str(opened_file)})
    assert added['path'] == str(opened_file)
    assert json.loads((private / 'recent_dockets.json').read_text())[0] == str(opened_file), 'MCP open absent from recents'
    assert call(p, 'docket_gui_open', {'id': item['id'], 'project': added['name'], 'focus': True})['opened'] == 'item'
    http('tools/call', {'name': 'docket_gui_open', 'arguments': {'focus': True}})
    deadline = time.monotonic() + 5
    while True:
        focused = call(p, 'docket_gui_open', {'focus': True})
        assert focused['pid'] == p.pid, focused
        if focused['focused']:
            break
        assert time.monotonic() < deadline, 'plugin window never acquired focus'
        time.sleep(.1)
    observed_pid, observed_title = external_focus(p.pid)
    assert observed_pid == p.pid and 'opened.dct' in observed_title, (observed_pid, observed_title)
    call(p, 'docket_subscribe', {'name': 'private subscriber'})
    session = call(p, 'docket_project_add', {'mode': 'session_file', 'name': 'private-session', 'create': True})
    session_path = pathlib.Path(session['path'])
    assert session_path.parent == private / 'sessions'
    assert json.loads(pathlib.Path(str(session_path) + '.owner').read_text())['pid'] == p.pid
    recent_before = (private / 'recent_dockets.json').read_bytes()
    call(p, 'docket_project_close', {'name': session['name']})
    assert (private / 'recent_dockets.json').read_bytes() == recent_before, 'close reordered recents'
    call(p, 'docket_project_add', {'path': str(session_path)})
    call(p, 'docket_project_add', {'mode': 'memory', 'name': 'private-spill'})
    assert call(p, 'docket_project_list')['memory_lease']['in_process_owner']
    call(p, 'docket_create', {'project': 'private-spill', 'type': 'chore', 'title': 'spill on EOF'})
    prefs = json.loads((private / 'docket_prefs.json').read_text())
    assert str(opened_file) in prefs['session_paths'] and 'owner sentinel' not in json.dumps(prefs)
    assert str(opened_file) in json.loads((private / 'recent_dockets.json').read_text())
    assert (private / 'docket_subscriptions.json').exists()
    old_pid = p.pid
    # Immediate EOF with a queued mutation: reply drained, canonical settled, owner released.
    send(p, {'jsonrpc': '2.0', 'method': 'tools/call', 'id': 'eof', 'params': {
        'name': 'docket_create', 'arguments': {'project': added['name'], 'type': 'chore', 'title': 'GUI EOF write'}}})
    p.stdin.close()
    assert receive(p)['id'] == 'eof'
    assert p.wait(timeout=15) == 0 and p.stdout.read() == b''
    assert 'GUI EOF write' in opened_file.read_text()
    assert not pathlib.Path(str(session_path) + '.owner').exists()
    assert not pathlib.Path('/proc/%d' % old_pid).exists(), 'child not reaped'
    spilled = private / 'sessions/private-spill.dct'
    assert spilled.exists() and 'spill on EOF' in spilled.read_text()
    assert str(spilled) in json.loads((private / 'docket_prefs.json').read_text())['session_paths']
    assert owner_snapshot == {f.name: f.read_bytes() for f in owner_profile.iterdir() if f.is_file()}, 'child altered owner profile'
    assert http()['result'] == {}
    assert default_prefs.read_bytes() == default_snapshot and not (base / 'forbidden.dct').exists()
    assert not (base / 'forbidden-session-dir').exists()
    # Re-enable empty unless restoration is explicitly requested; no automatic restart loop.
    p = spawn('reenabled', private)
    assert p.pid != old_pid and call(p, 'docket_project_list')['projects'] == []
    reenabled_pid = p.pid
    finish(p)
    p = spawn('restored', private, restore=True)
    assert p.pid not in (old_pid, reenabled_pid)
    restored = call(p, 'docket_project_list')['projects']
    assert str(opened_file) in {row['path'] for row in restored}
    assert str(spilled) in {row['path'] for row in restored}
    assert json.loads(pathlib.Path(str(session_path) + '.owner').read_text())['pid'] == p.pid
    finish(p)
    print('PASS GUI/private-state/open-mapped/focus-request/owner-health/EOF-restart')

    rejected = subprocess.run([engine, '--headless', '--quiet', '--path', project, '--',
        '--serve', '--stdio', '--state-dir', 'relative-profile'], input=b'', capture_output=True, env=env, timeout=10)
    assert rejected.returncode == 2 and rejected.stdout == b'' and b'absolute' in rejected.stderr

    # Real legacy SQLite fixture uses the authoritative schema DDL. Immutable
    # external reads intentionally ignore WAL, exposing missing checkpoints.
    legacy = base / 'legacy.dct'
    ddl = (pathlib.Path(project) / 'scripts/core/docket_db_schema.gd').read_text().split('\n\nstatic func ', 2)[1]
    with sqlite3.connect(legacy) as db:
        for multiline, single in re.findall(r'db\._exec\((?:"""(.*?)"""|"([^"\n]*)")\)', ddl, re.S):
            db.executescript(multiline or single)
    p = spawn('checkpoint', base / 'legacy-profile', [legacy], headless=True)
    call(p, 'docket_create', {'type': 'chore', 'title': 'checkpoint reply'})
    def visible(title):
        with sqlite3.connect(legacy.as_uri() + '?immutable=1', uri=True) as db:
            return db.execute('SELECT COUNT(*) FROM items WHERE title=?', (title,)).fetchone()[0] == 1
    assert visible('checkpoint reply'), 'stdio WAL not checkpointed before reply'
    send(p, {'jsonrpc': '2.0', 'method': 'tools/call', 'params': {'name': 'docket_create',
        'arguments': {'type': 'chore', 'title': 'checkpoint notification'}}})
    deadline = time.monotonic() + 5
    while not visible('checkpoint notification'):
        assert time.monotonic() < deadline, 'notification WAL not checkpointed without another request'
        time.sleep(.05)
    request(p, 'ping', 'barrier')
    finish(p)
    print('PASS legacy-SQLite/checkpoint-reply-and-notification')
    for child, err in children:
        err.flush()
        assert b'SCRIPT ERROR' not in pathlib.Path(err.name).read_bytes(), pathlib.Path(err.name).read_text()[-8192:]
    print('PRIVATE RUNTIME REAL PROCESS: 2 scenarios passed, 0 skipped')
except BaseException:
    for child, err in children:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=10)
        err.flush()
        print('CHILD %s exit=%s stderr(last 8192 bytes):\n%s' %
              (pathlib.Path(err.name).stem, child.returncode,
               pathlib.Path(err.name).read_bytes()[-8192:].decode(errors='replace')), file=sys.stderr)
    raise
finally:
    for child, err in children:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        err.close()
    root.cleanup()
