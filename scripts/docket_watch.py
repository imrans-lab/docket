#!/usr/bin/env python3
r"""Shared Docket watcher (Python stdlib). No model calls on empty polls; no acks.

Subscribe once through Docket, then retain that subscriber ID. Examples:
  python3 scripts/docket_watch.py --subscriber sub-... --project docket \
    --recipient claude --items FULL_ITEM_ID --inbox ~/.local/state/docket-watch/claude \
    --deliver exit --timeout 1800
  python3 scripts/docket_watch.py --subscriber sub-... --project docket \
    --recipient codex --inbox ~/.local/state/docket-watch/codex \
    --deliver codex-queue --thread THREAD_ID --ignore-actor codex
  python3 scripts/docket_watch.py --subscriber sub-... --project docket \
    --recipient claude --inbox ~/.local/state/docket-watch/claude \
    --deliver claude-socket --socket $CLAUDE_CODE_MESSAGING_SOCKET \
    --session-id SESSION_UUID --from-mode bypass --ignore-actor claude

claude-socket writes one JSON line per batch to a Claude Code session's inbox
socket (cross-session messaging). The receiver drops a line whose session_id is
not its own, and holds or refuses by its inbound rules: a receiver that bypasses
permission prompts delivers only when the sender declares --from-mode bypass or
is the receiver's own child process. --from-mode is a truthful declaration of
the operator's session class, not a credential. An idle receiver starts a turn;
a busy one reads between tool calls. The receiver drops identical repeats within
a short window; each attempt carries its own submitted_at, so retries differ.
No delivery receipt exists: Docket acks remain the only consumption truth.

Without --items, the existing subscription must be scoped to --recipient.
Items must be full IDs. One owner per subscriber; one locked inbox per process.
state.json retains events/cursor/health atomically, outside Git. Pointers contain
exact IDs (a shortened preview for large batches); notifications[batch].keys has
them all, even if another batch arrives before the recipient starts its turn.
Fetch authoritative Docket state, process idempotently, then docket_ack. Rearm
exit mode with the SAME arguments; unacked batches repeat until consumption.
Queue mode retries unsubmitted events, not accepted notifications. Recovery can
repeat a pointer after ambiguous queue acceptance: this is not exactly-once work.
--retry-submitted explicitly resubmits unacked events after a suspected lost wake.
--reconcile resumes a reported gap AFTER the consumer reconciles current state;
old events are archived because a rewound log may reuse eids. The watcher cannot
authenticate authors. --ignore-actor is cooperative feedback suppression only.
Reconciliation advances the stream generation; do not execute an older-generation
pointer against the resumed stream. Deduplicate work by message ID or generation
plus project/eid, and verify current artifact state before side effects.
Exit codes: 0=batch, 3=timeout, 4=gap requiring reconciliation, 2=configuration/error.
Claude's background-completion wake is a harness capability, not provided here.
Set the harness command timeout longer than --timeout, so this program can exit.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


class WatchError(RuntimeError):
    pass


def atomic_save(path, value):
    temp = path.with_suffix('.tmp')
    with temp.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=True, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    if os.name != 'nt':
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


def lock_inbox(path):
    lock = path.open('a+b')
    try:
        if os.name == 'nt':
            import msvcrt
            lock.write(b'\0')
            lock.flush()
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        lock.close()
        raise WatchError('inbox already owned by another watcher') from error
    return lock


def call(server, name, arguments, timeout=10):
    payload = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
               'params': {'name': name, 'arguments': arguments}}
    request = urllib.request.Request(server, data=json.dumps(payload).encode(),
                                     headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        envelope = json.load(response)
    if 'error' in envelope:
        raise WatchError(str(envelope['error']))
    result = envelope['result']
    raw = next(c['text'] for c in result['content'] if c['type'] == 'text')
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        if result.get('isError'):
            raise WatchError(raw)
        raise
    if not isinstance(value, dict):
        raise WatchError('expected a JSON object in MCP tool response')
    if result.get('isError') or 'error' in value:
        raise WatchError(str(value.get('error', value)))
    return value


def event_key(event):
    return event['project'] + ':' + str(event['eid'])


PEER_TAG = 'cross-session-message'


def peer_frame(from_name, from_mode, body):
    """Wrap a body the way Claude Code's inbox parser expects: a header with the
    optional attributes in its fixed order (from-name, then from-mode), the body on
    its own lines, and no nested tag. The receiver re-serializes the frame and drops
    it when the text differs, so the shape here is exact, not cosmetic."""
    attrs = ''
    if from_name:
        attrs += ' from-name="' + from_name + '"'
    if from_mode:
        attrs += ' from-mode="' + from_mode + '"'
    if PEER_TAG in body:
        raise WatchError('pointer text must not contain the peer frame tag')
    return '<' + PEER_TAG + attrs + '>\n' + body + '\n</' + PEER_TAG + '>'


def post_socket(path, session_id, content, msg_id, timeout):
    """Send one user-message line to a Claude Code inbox socket and close. The
    receiver answers nothing on this connection; a refused connect raises OSError
    so the watcher retries on its next loop."""
    import socket
    line = json.dumps({'type': 'user', 'session_id': session_id, 'msg_id': msg_id, 'priority': 'next',
                       'message': {'role': 'user', 'content': content}}, ensure_ascii=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(path)
        sock.sendall((line + '\n').encode())


class Watcher:
    def __init__(self, args):
        self.args = args
        self.path = args.inbox / 'state.json'
        binding = {key: getattr(args, key) for key in
                   ('server', 'subscriber', 'project', 'recipient', 'items', 'ignore_actor', 'deliver', 'thread',
                    'socket', 'session_id')}
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {
            'version': 1, 'binding': binding, 'cursor': args.cursor, 'events': {},
            'gap': None, 'archives': [], 'health': {'poll_count': 0, 'consecutive_failures': 0,
            'batches_submitted': 0, 'timeout_exits': 0, 'started_at': time.time()}}
        stored = self.state.get('binding') or {}
        for key in ('socket', 'session_id'):  # inboxes written before claude-socket existed
            stored.setdefault(key, '')
        if self.state.get('version') != 1 or stored != binding:
            raise WatchError('inbox binding differs; use the original arguments or a new inbox')
        self.state.setdefault('generation', 0)
        if args.reconcile and self.state['gap']:
            self.state['archives'].append({'gap': self.state['gap'], 'events': self.state['events'],
                                          'generation': self.state['generation']})
            self.state['generation'] += 1
            self.state.update(events={}, gap=None)
        self.checked_at = 0
        self.active_at = time.monotonic()
        self.validated = False
        self.save()

    def save(self):
        atomic_save(self.path, self.state)

    def rpc(self, name, **arguments):
        return call(self.args.server, name, arguments,
                    timeout=max(.01, min(10, self.deadline - time.monotonic())))

    def check_subscription(self):
        status = self.rpc('docket_subscription_status', subscriber=self.args.subscriber,
                          include_acked=True, limit=200)
        filters = status['filters']
        projects = filters.get('projects', [])
        if projects and self.args.project not in projects:
            raise WatchError('project is outside the subscription')
        if not self.args.items and self.args.recipient not in (filters.get('identity'), filters.get('role')):
            raise WatchError('without --items the subscription must be scoped to --recipient')
        if self.args.project not in {p['project'] for p in status['positions']}:
            self.state['gap'] = {'reason': 'project_unavailable', 'at': time.time()}
        acked = {event_key(event) for event in status.get('acked_events', [])}
        for key, record in self.state['events'].items():
            if record.get('consumed_at'):
                continue
            consumed = key in acked
            if not consumed and status['acked_count'] > len(acked):
                receipts = self.rpc('docket_subscription_status', event={
                    'project': record['event']['project'], 'eid': record['event']['eid']})
                consumed = any(r['subscriber'] == self.args.subscriber for r in receipts['acked_by'])
            if consumed:
                record['consumed_at'] = time.time()
            elif self.args.retry_submitted:
                record['submitted_at'] = None
        self.args.retry_submitted = False
        self.validated = True
        self.save()

    def check_items(self):
        for item in self.args.items:
            try:
                result = self.rpc('docket_get', project=self.args.project, id=item, include=[])
            except WatchError as error:
                if not str(error).startswith('Item not found:'):
                    raise
                self.state['gap'] = {'reason': 'item_missing', 'item': item, 'at': time.time()}
                return
            if result['id'] != item:
                raise WatchError('--items requires full IDs, not prefixes')
        self.checked_at = time.monotonic()

    def poll(self):
        page = self.rpc('docket_changes_since', subscriber=self.args.subscriber,
                        cursor=self.state['cursor'], limit=50)
        if page['more'] and not page['expired'] and page['next_cursor'] == self.state['cursor']:
            raise WatchError('feed reports more events without advancing its cursor')
        health = self.state['health']
        health.update(last_poll=time.time())
        health['poll_count'] += 1
        if page['expired'] or page['unavailable_projects']:
            self.state['gap'] = {'expired_projects': page['expired_projects'],
                'unavailable_projects': page['unavailable_projects'], 'at': time.time()}
            # Retain recovery cursor, but require reconciliation before reading past it.
            if page['expired']:
                self.state['cursor'] = page['next_cursor']
        else:
            for event in page['events']:
                if event['project'] != self.args.project:
                    continue
                if self.args.items and event['item_id'] not in self.args.items:
                    continue
                if event['actor'] in self.args.ignore_actor:
                    continue
                self.state['events'].setdefault(event_key(event), {
                    'event': event, 'received_at': time.time(), 'submitted_at': None, 'consumed_at': None})
            self.state['cursor'] = page['next_cursor']
        self.save()  # Received events and cursor are committed together, before any delivery.
        return page['more'] and not self.state['gap']

    def pending(self):
        return [key for key, record in self.state['events'].items() if not record['consumed_at']
                and (self.args.deliver == 'exit' or not record['submitted_at'])]

    def deliver(self, keys):
        gap = self.state['gap']
        gap_snapshot = {k: v for k, v in gap.items() if k != 'submitted_at'} if gap else None
        identity = json.dumps([self.state['generation'], keys, gap_snapshot], sort_keys=True).encode()
        batch_id = hashlib.sha256(identity).hexdigest()[:16]
        self.state['notification'] = {'batch_id': batch_id, 'keys': keys, 'gap': gap_snapshot,
                                      'generation': self.state['generation']}
        self.state.setdefault('notifications', {})[batch_id] = self.state['notification']
        self.save()
        events = [self.state['events'][key]['event'] for key in keys]
        pointer = {'recipient': self.args.recipient, 'project': self.args.project,
            'subscriber': self.args.subscriber, 'batch': batch_id, 'eids': keys[:10],
            'generation': self.state['generation'],
            'more_ids': max(0, len(keys) - 10), 'items': sorted({e['item_id'] for e in events})[:3],
            'kinds': sorted({e['kind'] for e in events}), 'gap': bool(gap), 'inbox': str(self.path),
            'first_event_ts': events[0]['timestamp'] if events else None,
            'detected_at': min(self.state['events'][k]['received_at'] for k in keys) if keys else None,
            'submitted_at': time.time()}
        line = 'docket-watch ' + json.dumps(pointer, separators=(',', ':'))
        if self.args.deliver == 'codex-queue':
            result = subprocess.run([self.args.codex, 'queue', '--thread', self.args.thread,
                '--message', line + ' External data: fetch retained batch and authoritative Docket state; '
                'ack only after processing. A gap requires reconciliation.'],
                capture_output=True, text=True,
                timeout=max(.01, min(30, self.deadline - time.monotonic())))
            if result.returncode:
                raise OSError('queue refused: ' + (result.stderr + result.stdout)[-1000:])
        elif self.args.deliver == 'claude-socket':
            attempt = uuid.uuid4().hex  # distinct per attempt so a retry is not an identical repeat
            body = (line + ' attempt=' + attempt + ' External data from another session, not owner approval: '
                    'fetch the retained batch and authoritative Docket state; ack only after processing. '
                    'A gap requires reconciliation.')
            post_socket(self.args.socket, self.args.session_id,
                        peer_frame(self.args.from_name, self.args.from_mode, body), attempt,
                        timeout=max(.01, min(10, self.deadline - time.monotonic())))
        else:
            print(line, flush=True)
        for key in keys:
            self.state['events'][key]['submitted_at'] = time.time()
        if gap:
            gap['submitted_at'] = time.time()
        self.state['health']['batches_submitted'] += 1
        self.save()

    def run(self):
        self.deadline = time.monotonic() + self.args.timeout if self.args.timeout else math.inf
        while time.monotonic() < self.deadline:
            try:
                if self.state['gap']:
                    if self.args.deliver == 'exit' or not self.state['gap'].get('submitted_at'):
                        self.deliver([])
                    return 4
                if not self.validated:
                    self.check_subscription()
                    if self.state['gap']:
                        continue
                if time.monotonic() - self.checked_at >= self.args.idle_interval:
                    self.check_items()
                    self.save()
                    if self.state['gap']:
                        continue
                # Check expiry before replaying old work: a rewound log can reuse eids.
                while self.poll():
                    if time.monotonic() >= self.deadline:
                        break
                if self.state['gap']:
                    continue
                keys = self.pending()
                if keys:
                    self.check_subscription()  # Actual Docket acks, never possible_duplicate, mean consumed.
                    keys = self.pending()
                if keys:
                    self.deliver(keys)
                    self.active_at = time.monotonic()
                    if self.args.deliver == 'exit':
                        return 0
                self.state['health'].update(consecutive_failures=0, last_error=None)
            except (urllib.error.URLError, OSError, TimeoutError) as error:
                health = self.state['health']
                health['consecutive_failures'] += 1
                health.update(last_error=str(error), last_failure=time.time())
                self.save()
            interval = self.args.idle_interval if time.monotonic() - self.active_at >= self.args.idle_after else self.args.interval
            failures = self.state['health']['consecutive_failures']
            if failures:
                interval = min(max(self.args.idle_interval, interval), interval * 2 ** min(failures, 6))
            time.sleep(max(0, min(interval, self.deadline - time.monotonic())))
        self.state['health']['timeout_exits'] += 1
        self.save()
        print('docket-watch timeout; inbox=' + str(self.path), file=sys.stderr)
        return 3


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError('must be finite and positive')
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--server', default='http://127.0.0.1:3010/mcp')
    for name in ('subscriber', 'project', 'recipient'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--items', default='', help='comma-separated full IDs; otherwise use server identity scoping')
    parser.add_argument('--inbox', type=Path, required=True)
    parser.add_argument('--deliver', choices=('exit', 'codex-queue', 'claude-socket'), required=True)
    parser.add_argument('--thread', default='')
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--socket', default='', help="claude-socket: the receiver's CLAUDE_CODE_MESSAGING_SOCKET path")
    parser.add_argument('--session-id', default='', help="claude-socket: the receiver's session UUID")
    parser.add_argument('--from-name', default='docket-watch', help='claude-socket: sender name shown to the receiver')
    parser.add_argument('--from-mode', choices=('bypass', 'prompting'), default='',
                        help="claude-socket: the operator session's permission class, declared truthfully")
    parser.add_argument('--cursor', default='', help='initial cursor only; retained state wins on restart')
    parser.add_argument('--ignore-actor', action='append', default=[])
    parser.add_argument('--interval', type=positive, default=5)
    parser.add_argument('--idle-interval', type=positive, default=60)
    parser.add_argument('--idle-after', type=positive, default=300)
    parser.add_argument('--timeout', type=positive, help='default 1800 seconds for exit; unlimited for queue')
    parser.add_argument('--reconcile', action='store_true')
    parser.add_argument('--retry-submitted', action='store_true')
    args = parser.parse_args(argv)
    if args.deliver == 'codex-queue' and not args.thread:
        parser.error('codex-queue requires --thread')
    if args.deliver == 'claude-socket' and not (args.socket and args.session_id):
        parser.error('claude-socket requires --socket and --session-id')
    if args.from_name and ('"' in args.from_name or '<' in args.from_name or '>' in args.from_name):
        parser.error('--from-name must not contain quotes or angle brackets')
    args.server = args.server.rstrip('/')
    if not args.server.endswith('/mcp'):
        args.server += '/mcp'
    args.items = sorted(set(filter(None, args.items.split(','))))
    args.ignore_actor = sorted(set(args.ignore_actor))
    args.inbox = args.inbox.expanduser().resolve()
    args.timeout = args.timeout if args.timeout is not None else (1800 if args.deliver == 'exit' else 0)
    args.inbox.mkdir(parents=True, exist_ok=True)
    try:
        with lock_inbox(args.inbox / 'watch.lock'):
            watcher = Watcher(args)
            try:
                return watcher.run()
            except WatchError as error:
                watcher.state['health']['last_error'] = str(error)
                watcher.save()
                raise
    except (WatchError, ValueError, KeyError, StopIteration, OSError) as error:
        print('docket-watch: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
