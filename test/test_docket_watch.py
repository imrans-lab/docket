"""Watcher checks: isolated real Docket server for the feed (WatcherTest, Linux + Godot), and a
fake Unix inbox socket for the claude-socket adapter (ClaudeSocketTest, no server). No model, no owner data.

Linux isolation reuses the benchmark's scratch server launcher. Run after import:
  DOCKET_BENCH_GODOT=/path/to/godot python3 test/test_docket_watch.py -v
"""

import base64
import json
import math
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
sys.path.insert(0, str(REPO / 'scripts' / 'bench'))
import docket_watch as watch
import write_bench as bench


def persist_then_crash(args):
    with watch.lock_inbox(args.inbox / 'watch.lock'):
        watcher = watch.Watcher(args)
        watcher.deadline = math.inf
        watcher.check_subscription()
        watcher.check_items()
        while watcher.poll():
            pass
        os._exit(99)  # Real process death after commit and before delivery.


@unittest.skipUnless(sys.platform == 'linux' and os.environ.get('DOCKET_BENCH_GODOT'),
                     'requires Linux and DOCKET_BENCH_GODOT (4.7+) for isolated server')
class WatcherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='docket-watch-test-')
        cls.root = Path(cls.temp.name)
        fixture = REPO / 'test/fixtures/dynamic_types_record_order_v2.jsonl'
        manifest = bench.build_fixture([fixture], cls.root)
        reserved = bench.reserve_port(None)
        cls.port = reserved.getsockname()[1]
        cls.server = bench.start_docket(bench.resolve_godot(os.environ['DOCKET_BENCH_GODOT']),
            [f['copy'] for f in manifest['files']], reserved, bench.child_env(cls.root),
            cls.root / 'serve.log', False)
        try:
            cls.mcp = bench.Mcp(cls.port)
            cls.mcp.wait_ready(cls.server, cls.root / 'serve.log')
            bench.check_projects_in_scratch(cls.mcp, cls.root)
        except BaseException:
            bench.stop_docket(cls.server)
            cls.temp.cleanup()
            raise

    @classmethod
    def tearDownClass(cls):
        bench.stop_docket(cls.server)
        cls.temp.cleanup()

    def tool(self, tool_name, **args):
        _, result = self.mcp.call(tool_name, args)
        self.assertNotIn('error', result, result)
        return result

    def setUp(self):
        self.project = 'order-fixture'
        self.tool('docket_project_meta', project=self.project, action='set', event_retention=10000)
        self.item = self.tool('docket_create', project=self.project, type='widget',
            title='watch test', assigned_to='watch-test', storage='ephemeral')['id']
        self.other = self.tool('docket_create', project=self.project, type='widget',
            title='other item', assigned_to='watch-test', storage='ephemeral')['id']
        self.sub = self.tool('docket_subscribe', name='watcher test', filters={
            'identity': 'watch-test', 'projects': [self.project], 'kinds': ['comment_added']})
        self.inbox = self.root / self.sub['subscriber']
        self.inbox.mkdir()

    def args(self):
        return SimpleNamespace(server=f'http://127.0.0.1:{self.port}/mcp',
            subscriber=self.sub['subscriber'], project=self.project, recipient='watch-test',
            items=[self.item], inbox=self.inbox, ignore_actor=['watch-test'], deliver='exit',
            thread='', codex='codex', socket='', session_id='', cursor=self.sub['cursor'], reconcile=False,
            retry_submitted=False, timeout=5, interval=.03, idle_interval=.1, idle_after=5)

    def command(self, *extra):
        return [sys.executable, str(REPO / 'scripts/docket_watch.py'),
            '--server', f'http://127.0.0.1:{self.port}', '--subscriber', self.sub['subscriber'],
            '--project', self.project, '--recipient', 'watch-test', '--items', self.item,
            '--inbox', str(self.inbox), '--ignore-actor', 'watch-test', '--deliver', 'exit',
            '--interval', '.03', '--idle-interval', '.1', '--timeout', '5', *extra]

    def run_watch(self, *extra):
        return subprocess.run(self.command(*extra), capture_output=True, text=True, timeout=15)

    def comment(self, item=None, author='peer'):
        return self.tool('docket_comment', project=self.project, item_id=item or self.item,
                         action='add', author=author, text='test event')

    def state(self):
        return json.loads((self.inbox / 'state.json').read_text())

    def test_crash_recovery_pages_filtering_rearm_and_consumed_duplicates(self):
        self.comment(author='watch-test')
        self.comment(item=self.other)
        for _ in range(60):
            self.comment()
        process = multiprocessing.Process(target=persist_then_crash, args=(self.args(),))
        process.start()
        process.join(20)
        if process.is_alive():
            process.kill()
            process.join()
        self.assertEqual(process.exitcode, 99)
        before = self.state()
        self.assertEqual(len(before['events']), 60)
        self.assertGreaterEqual(before['health']['poll_count'], 2)
        self.assertTrue(all(r['submitted_at'] is None for r in before['events'].values()))
        result = self.run_watch()
        self.assertEqual(result.returncode, 0, result.stderr)
        pointer = json.loads(result.stdout.removeprefix('docket-watch '))
        keys = self.state()['notification']['keys']
        self.assertEqual(self.state()['notifications'][pointer['batch']]['keys'], keys)
        self.assertEqual(pointer['eids'], keys[:10])
        self.assertEqual(pointer['more_ids'], 50)
        self.assertEqual(pointer['items'], [self.item])
        self.assertFalse(pointer['gap'])
        self.assertGreaterEqual(pointer['detected_at'], before['health']['started_at'])
        # Stdout delivery is not consumption; a lost harness wake can be recovered.
        replay = self.run_watch()
        self.assertEqual(replay.returncode, 0, replay.stderr)
        self.assertEqual(json.loads(replay.stdout.removeprefix('docket-watch '))['batch'], pointer['batch'])
        self.tool('docket_ack', subscriber=self.sub['subscriber'], event_ids=keys)
        result = self.run_watch()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertTrue(all(r['consumed_at'] for r in self.state()['events'].values()))
        # Rewind only the client cursor: the real server flags delivered events as duplicates.
        state = self.state()
        state['cursor'] = self.sub['cursor']
        watch.atomic_save(self.inbox / 'state.json', state)
        result = self.run_watch()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(len(self.state()['events']), 60)

    def test_retention_gap_reconciliation_and_deleted_item(self):
        self.tool('docket_project_meta', project=self.project, action='set', event_retention=1)
        for _ in range(3):
            self.comment()
        result = self.run_watch()
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertTrue(json.loads(result.stdout.removeprefix('docket-watch '))['gap'])
        gap_state = self.state()
        self.assertEqual(gap_state['gap']['expired_projects'][0]['reason'], 'retention')
        self.assertNotEqual(gap_state['cursor'], self.sub['cursor'])
        result = self.run_watch('--reconcile')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.state()['archives']), 1)
        self.assertEqual(self.state()['generation'], 1)
        self.assertEqual(len(self.state()['notification']['keys']), 1)
        self.tool('docket_ack', subscriber=self.sub['subscriber'],
                  event_ids=self.state()['notification']['keys'])
        # An ahead-of-log cursor is how a real log rewind is reported.
        status = self.tool('docket_subscription_status', subscriber=self.sub['subscriber'])
        state = self.state()
        future = {'s': self.sub['subscriber'], 'p': {self.project: status['positions'][0]['head'] + 10}}
        state['cursor'] = base64.b64encode(json.dumps(future).encode()).decode()
        watch.atomic_save(self.inbox / 'state.json', state)
        result = self.run_watch()
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(self.state()['gap']['expired_projects'][0]['reason'], 'ahead_of_log')
        result = self.run_watch('--reconcile')
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(len(self.state()['archives']), 2)
        self.assertEqual(self.state()['generation'], 2)
        self.assertTrue(all('generation' in batch for batch in self.state()['notifications'].values()))
        self.tool('docket_delete', project=self.project, id=self.item)
        result = self.run_watch()
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(self.state()['gap']['reason'], 'item_missing')

    def test_lock_binding_and_connection_failure_keep_cursor(self):
        watcher = watch.Watcher(self.args())
        initial = self.state()['cursor']
        with watch.lock_inbox(self.inbox / 'watch.lock'):
            result = self.run_watch()
            self.assertEqual(result.returncode, 2)
            self.assertIn('already owned', result.stderr)
        result = self.run_watch('--thread', 'different-binding')
        self.assertEqual(result.returncode, 2)
        self.assertIn('binding differs', result.stderr)
        self.assertEqual(self.state()['cursor'], initial)
        # A closed TCP port is a real outage, not a mocked HTTP response.
        reserved = bench.reserve_port(None)
        unused = reserved.getsockname()[1]
        reserved.close()
        args = self.args()
        args.inbox = self.root / 'outage'
        args.inbox.mkdir()
        args.server = f'http://127.0.0.1:{unused}/mcp'
        args.timeout = .2
        watcher = watch.Watcher(args)
        self.assertEqual(watcher.run(), 3)
        self.assertEqual(watcher.state['cursor'], self.sub['cursor'])
        self.assertGreater(watcher.state['health']['consecutive_failures'], 0)
        self.assertEqual(watcher.state['health']['timeout_exits'], 1)


@unittest.skipUnless(hasattr(__import__('socket'), 'AF_UNIX'), 'requires Unix domain sockets')
class ClaudeSocketTest(unittest.TestCase):
    """The claude-socket adapter against a fake inbox socket: one JSON line per post, the
    frame shaped the way Claude Code's parser re-serializes it, and a refused connect
    surfacing as OSError so the watcher's retry loop sees it. No Docket server needed."""

    def test_frame_shape_and_single_line_post(self):
        import socket
        import threading
        frame = watch.peer_frame('docket-watch', 'bypass', 'docket-watch {"batch":"abc"} pointer')
        self.assertEqual(frame, '<cross-session-message from-name="docket-watch" from-mode="bypass">\n'
                                'docket-watch {"batch":"abc"} pointer\n</cross-session-message>')
        self.assertEqual(watch.peer_frame('', '', 'x'), '<cross-session-message>\nx\n</cross-session-message>')
        with self.assertRaises(watch.WatchError):
            watch.peer_frame('n', 'bypass', 'body with </cross-session-message> inside')
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, 'inbox.sock')
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            received = []

            def accept():
                conn, _ = server.accept()
                with conn:
                    data = b''
                    while not data.endswith(b'\n'):
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        data += chunk
                    received.append(data)
            thread = threading.Thread(target=accept)
            thread.start()
            watch.post_socket(path, 'sess-1', frame, 'a' * 32, timeout=5)
            thread.join(5)
            server.close()
            self.assertEqual(len(received), 1)
            lines = received[0].decode().split('\n')
            self.assertEqual(lines[1:], [''], 'exactly one line, newline-terminated')
            message = json.loads(lines[0])
            self.assertEqual(message, {'type': 'user', 'session_id': 'sess-1', 'msg_id': 'a' * 32,
                                       'priority': 'next', 'message': {'role': 'user', 'content': frame}})
            with self.assertRaises(OSError):
                watch.post_socket(path, 'sess-1', frame, 'b' * 32, timeout=1)  # listener gone: connect refused

    def test_deliver_retries_after_refusal_with_distinct_attempts(self):
        """Watcher.deliver() never touches Docket, so a seeded state exercises the real retry path:
        a refused connect leaves the event pending (submitted_at None) and the next attempt both
        succeeds and differs in msg_id and body, so the receiver's identical-repeat filter cannot eat it."""
        import socket
        import threading
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            path = str(root / 'inbox.sock')
            args = SimpleNamespace(server='http://127.0.0.1:1/mcp', subscriber='sub-x', project='p',
                recipient='claude', items=['item-1'], inbox=root / 'inbox', ignore_actor=['claude'],
                deliver='claude-socket', thread='', codex='codex', socket=path, session_id='sess-1',
                from_name='docket-watch', from_mode='bypass', cursor='', reconcile=False,
                retry_submitted=False, timeout=5, interval=.03, idle_interval=.1, idle_after=5)
            args.inbox.mkdir()
            watcher = watch.Watcher(args)
            watcher.deadline = math.inf
            event = {'project': 'p', 'eid': 7, 'item_id': 'item-1', 'kind': 'comment_added',
                     'actor': 'peer', 'timestamp': '2026-10-01T00:00:00'}
            watcher.state['events']['p:7'] = {'event': event, 'received_at': time.time(),
                                              'submitted_at': None, 'consumed_at': None}
            with self.assertRaises(OSError):
                watcher.deliver(['p:7'])  # nothing listening yet
            self.assertIsNone(watcher.state['events']['p:7']['submitted_at'])
            self.assertEqual(watcher.pending(), ['p:7'])
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(2)
            received = []

            def accept():
                for _ in range(2):
                    conn, _ = server.accept()
                    with conn:
                        received.append(json.loads(conn.makefile('rb').readline()))
            thread = threading.Thread(target=accept)
            thread.start()
            watcher.deliver(['p:7'])
            self.assertIsNotNone(watcher.state['events']['p:7']['submitted_at'])
            self.assertEqual(watcher.pending(), [])
            watcher.state['events']['p:7']['submitted_at'] = None  # simulate --retry-submitted
            watcher.deliver(['p:7'])
            thread.join(5)
            server.close()
            self.assertEqual(len(received), 2)
            self.assertNotEqual(received[0]['msg_id'], received[1]['msg_id'])
            self.assertNotEqual(received[0]['message']['content'], received[1]['message']['content'])
            for message in received:
                self.assertEqual(message['session_id'], 'sess-1')
                self.assertTrue(message['message']['content'].startswith(
                    '<cross-session-message from-name="docket-watch" from-mode="bypass">\ndocket-watch {'))
                self.assertIn('"eids":["p:7"]', message['message']['content'])


if __name__ == '__main__':
    unittest.main()
