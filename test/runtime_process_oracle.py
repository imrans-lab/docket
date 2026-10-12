#!/usr/bin/env python3
"""Linux actual GUI/HTTP oracle; run with xvfb-run, never author gate."""
import ctypes, json, os, pathlib, signal, socket, sys, time, urllib.request

engine, project = sys.argv[1:]
assert sys.platform == 'linux' and os.environ.get('DISPLAY'), 'Linux Xvfb DISPLAY required; no skipped pass'
# Reuse the broad child oracle's framing/deadlines/cleanup rather than a second client.
source = (pathlib.Path(project) / 'test/http_child_fixture.gd').read_text()
driver = source.split('const DRIVER := """', 1)[1].split('"""', 1)[0].replace('\\\\', '\\')
exec(compile(driver, 'shared-http-client', 'exec'))
profile_environment = globals()['profile_env']
signal.alarm(180)
owner = None


def call(p, name, arguments=None):
    value = request(p, 'tools/call', name, {'name': name, 'arguments': arguments or {}})
    assert not value['result'].get('isError'), value
    return json.loads(value['result']['content'][0]['text'])


def spawn(name: str, profile: pathlib.Path, files: tuple[pathlib.Path, ...] | list[pathlib.Path] = (),
          headless: bool = False, http_port: int | None = None) -> subprocess.Popen[bytes]:
    child_env = environments[str(profile)]
    actual_profile = profile
    assert actual_profile == profile, 'profile probe mapping changed'
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        child_port = http_port if http_port is not None else reservation.getsockname()[1]
    err = open(base / (name + '.stderr'), 'wb')
    cmd = [engine, '--quiet', '--path', project]
    cmd += ['--headless'] if headless else ['--display-driver', 'x11']
    cmd += ['--', '--port', str(child_port)]
    if headless:
        cmd.append('--serve')
    for file in files:
        cmd += ['--file', str(file)]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, env=child_env, cwd=base)
    children.append((p, err))
    p.port, p.profile = child_port, profile
    deadline = time.monotonic() + 30
    while True:
        assert p.poll() is None and time.monotonic() < deadline, 'HTTP startup failed'
        try:
            if request(p, 'ping', 0)['result'] == {}:
                break
        except OSError:
            time.sleep(.05)
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
    environments = {}
    def allocated_profile(name: str) -> pathlib.Path:
        child_env, profile = profile_environment(name)
        environments[str(profile)] = child_env
        return profile
    owner_profile, private = allocated_profile('owner'), allocated_profile('second')
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
    assert listeners(p.pid), 'HTTP child lacks a TCP listener'
    assert http()['result'] == {}, 'owner HTTP collided with child'
    # Seed a real existing project with a disposable headless child.
    seed = spawn('seed', allocated_profile('seed'), [opened_file], headless=True)
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
    durable_recents = (private / 'recent_dockets.json').read_bytes()
    session = call(p, 'docket_project_add', {'mode': 'session_file', 'name': 'private-session', 'create': True})
    session_path = pathlib.Path(session['path'])
    assert session_path.parent == pathlib.Path(environments[str(private)]['XDG_DATA_HOME']) / 'docket/sessions'
    assert (private / 'recent_dockets.json').read_bytes() == durable_recents, 'session create changed recents'
    assert json.loads(pathlib.Path(str(session_path) + '.owner').read_text())['pid'] == p.pid
    assert 'opened.dct' in external_focus(p.pid)[1], 'additional open replaced primary'
    recent_before = (private / 'recent_dockets.json').read_bytes()
    call(p, 'docket_project_close', {'name': session['name']})
    assert (private / 'recent_dockets.json').read_bytes() == recent_before, 'close reordered recents'
    call(p, 'docket_project_add', {'path': str(session_path)})
    assert (private / 'recent_dockets.json').read_bytes() == durable_recents, 'session reopen changed recents'
    call(p, 'docket_project_close', {'name': added['name']})
    assert session_path.name in external_focus(p.pid)[1], 'close failed to promote fallback'
    refused = request(p, 'tools/call', 'close-last', {
        'name': 'docket_project_close', 'arguments': {'name': session['name']}})
    assert refused['result'].get('isError'), refused
    assert refused['result']['content'][0]['text'] == 'Cannot close the last project', refused
    assert session_path.name in external_focus(p.pid)[1], 'refused close changed primary title'
    call(p, 'docket_project_add', {'path': str(opened_file)})
    old_pid = p.pid
    call(p, 'docket_create', {'project': added['name'], 'type': 'chore', 'title': 'GUI HTTP write'})
    call(p, 'docket_flush')
    assert 'GUI HTTP write' in opened_file.read_text()
    finish(p)
    assert not pathlib.Path('/proc/%d' % old_pid).exists(), 'child not reaped'
    assert owner_snapshot == {f.name: f.read_bytes() for f in owner_profile.iterdir() if f.is_file()}, 'child altered separate profile'
    assert http()['result'] == {}
    # A standalone relaunch restores its saved workspace without an opt-in flag.
    p = spawn('restored', private)
    assert p.pid != old_pid
    restored = call(p, 'docket_project_list')['projects']
    assert str(opened_file) in {row['path'] for row in restored}
    finish(p)
    # Six restored files exceed MAX_RECENTS and expose startup eviction/reordering.
    startup_files = [base / ('startup-%d.dct' % i) for i in range(6)]
    seed = spawn('startup-seed', allocated_profile('startup-seed'), startup_files, headless=True)
    assert len(call(seed, 'docket_project_list')['projects']) == 6
    finish(seed)
    for restore in (False, True):
        profile = allocated_profile('startup-%s' % restore)
        (profile / 'docket_prefs.json').write_text(json.dumps({'session_paths': list(map(str, startup_files))}))
        recent = profile / 'recent_dockets.json'
        recent.write_text(json.dumps(list(map(str, reversed(startup_files[:5]))), indent=2) + '\n')
        snapshot = recent.read_bytes()
        p = spawn('startup-%s' % restore, profile, () if restore else startup_files)
        assert len(call(p, 'docket_project_list')['projects']) == 6
        assert recent.read_bytes() == snapshot, 'startup reordered/evicted saved recents'
        finish(p)
        assert recent.read_bytes() == snapshot, 'startup shutdown changed saved recents'
    print('PASS GUI/HTTP/open-mapped/focus-request/isolated-profiles/automatic-restore')
    for child, err in children:
        err.flush()
        assert b'SCRIPT ERROR' not in pathlib.Path(err.name).read_bytes(), pathlib.Path(err.name).read_text()[-8192:]
    print('HTTP RUNTIME REAL PROCESS: GUI scenario passed, 0 skipped')
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
