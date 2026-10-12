extends RefCounted
## Isolated HTTP child counterpart of the retired transport fixture.
const DRIVER := """
import json, os, pathlib, shutil, socket, subprocess, sys, tempfile, threading, time, urllib.request, urllib.error
engine, project = sys.argv[1:]
root = tempfile.TemporaryDirectory(prefix='docket-http-')
base = pathlib.Path(root.name).resolve()
project = str(shutil.copytree(project, base / 'project', ignore=shutil.ignore_patterns('.git')))
env = os.environ.copy()
env.pop('HOME', None)
env.pop('DOCKET_SESSION_DIR', None)
args = [engine, '--headless', '--quiet', '--path', project, '--']
children = []
completed = threading.Event()

def diagnose() -> None:
    print('HTTP_CHILD_DIAGNOSTIC TimeoutError stage=watchdog', file=sys.stderr, flush=True)

def watchdog() -> None:
    if not completed.wait(540):
        diagnose()
        for child, err in children:
            if child.poll() is None: child.kill()
        os._exit(1)
threading.Thread(target=watchdog, daemon=True).start()

def profile_env(name: str) -> tuple[dict[str, str], pathlib.Path]:
    child_env = env.copy()
    domain = base / (name + '-state')
    domain.mkdir(exist_ok=True)
    for key in ('XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'APPDATA', 'LOCALAPPDATA'):
        child_env[key] = str(domain / key)
        pathlib.Path(child_env[key]).mkdir(exist_ok=True)
    # Probe the actual engine mapping on each OS before traffic or credentials.
    probe = pathlib.Path(project) / 'test' / 'fixtures' / 'userdir_probe.gd'
    result = subprocess.run([engine, '--headless', '--quiet', '--path', project, '-s', str(probe), '--', str(base)],
                            env=child_env, cwd=base, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    assert result.returncode == 0, 'private userdir probe failed'
    profile = pathlib.Path(json.loads((base/'userdir-report.json').read_text()))
    assert base in profile.parents, 'engine profile outside scratch'
    return child_env, profile

def launch(name: str, extra: tuple[str, ...] | list[str] = ()) -> subprocess.Popen[bytes]:
    child_env, profile = profile_env(name)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    err = open(base/(name+'.stderr'), 'wb')
    p = subprocess.Popen(args + ['--port', str(port)] + list(extra), stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=err, env=child_env, cwd=base)
    children.append((p, err))
    p.port, p.profile = port, profile
    p.stop_io, p.io_threads = threading.Event(), []
    p.launch_extra = extra
    deadline = time.monotonic() + 60
    while True:
        assert p.poll() is None and time.monotonic() < deadline, 'HTTP child startup failed'
        try:
            if request(p, 'ping', 0)['result'] == {}: break
        except (OSError, urllib.error.URLError): time.sleep(.05)
    return p

def request(p: subprocess.Popen[bytes], method: str, ident: str | int, params: dict[str, object] | None = None, receive_timeout: int = 30) -> dict[str, object]:
    payload = dict(jsonrpc='2.0', id=ident, method=method)
    if params is not None: payload['params'] = params
    req = urllib.request.Request('http://127.0.0.1:%d/mcp'%p.port, json.dumps(payload).encode(), {'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=receive_timeout) as response: value = json.load(response)
    assert value.get('id') == ident, 'response id'
    return value

def finish(p: subprocess.Popen[bytes]) -> None:
    # HTTP clients do not own server lifetime. Settle before stopping our PID.
    reply = request(p, 'tools/call', 'settle', dict(name='docket_flush', arguments={}))
    assert not reply['result'].get('isError'), 'fixture flush failed'
    p.terminate()
    p.wait(timeout=30)
    p.stdin.close()
    assert p.stdout.read() == b'', 'unexpected child stdout'
    p.stdout.close()

def cleanup() -> None:
    for p, err in children:
        if p.poll() is None: p.kill(); p.wait(timeout=10)
        if not p.stdin.closed: p.stdin.close()
        if not p.stdout.closed: p.stdout.close()
        err.close()
    root.cleanup()
    completed.set()
"""
