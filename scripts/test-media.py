#!/usr/bin/env python3
"""Exercise the actual broker ledger with a compile-time fake state/command provider."""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / '.build/media-test/broker'
TRACK = dict(title='SYNTHETIC PRIVATE TITLE', artist='Synthetic artist', album='Synthetic album', duration=180)


def build():
    BINARY.parent.mkdir(parents=True, exist_ok=True)
    main = BINARY.parent / 'main.m'
    main.write_text('void adapter_broker(void); int main(void) { adapter_broker(); return 0; }\n')
    subprocess.run(['xcrun', 'clang', '-isysroot', subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip(), '-arch', 'arm64', '-fobjc-arc', '-DWHISPR_BROKER_TEST',
                    '-I', str(ROOT / 'Vendor/mediaremote-adapter/src'),
                    '-I', str(ROOT / 'Vendor/mediaremote-adapter/include'),
                    str(ROOT / 'Vendor/mediaremote-adapter/patches/broker.m'), str(main),
                    '-framework', 'Foundation', '-framework', 'AppKit', '-o', str(BINARY)], check=True)


class Broker:
    def __init__(self, **env):
        self.process = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env={**os.environ, 'WHISPR_DEBUG_DIAGNOSTICS': '1', **env})
        self.events = queue.Queue()
        self.commands = []
        self.generation = None
        def read():
            for line in self.process.stdout:
                event = json.loads(line)
                if event['type'] == 'testCommand':
                    self.commands.append(event['command'])
                self.events.put(event)
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()
        self.wait('ready')

    def wait(self, event_type, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            event = self.events.get(timeout=max(.001, deadline - time.monotonic()))
            if event['type'] == 'ready':
                self.generation = event['generation']
            if event['type'] == event_type:
                return event
        raise AssertionError(f'Missing {event_type}')

    def send(self, operation, session='s1', **extra):
        body = dict(version=1, operation=operation, session=session, request=f'{time.monotonic_ns()}',
                    generation=self.generation, deadlineMS=500)
        body.update(extra)
        self.process.stdin.write(json.dumps(body).encode() + b'\n')
        self.process.stdin.flush()
        return body['request']

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.wait(timeout=2)
        self.thread.join(timeout=1)
        self.process.stdout.close()


class LeaseTests(unittest.TestCase):
    def broker(self, **env):
        broker = Broker(**env)
        self.addCleanup(broker.close)
        return broker

    def test_end_before_query_cancels_unsent_pause(self):
        b = self.broker(WHISPR_TEST_QUERY_DELAY_MS='80')
        b.send('begin'); b.send('end'); b.wait('skipped')
        b.send('snapshot'); b.wait('snapshot')
        self.assertEqual(b.commands, [])

    def test_end_after_issue_settles_and_duplicate_end_does_not_replay(self):
        b = self.broker()
        b.send('begin'); b.wait('issued'); b.send('end'); b.wait('released')
        b.send('end'); b.wait('skipped')
        self.assertEqual(b.commands, [1, 0])
        b.send('begin', 's2'); b.wait('issued'); b.send('end', 's2'); b.wait('released')
        self.assertEqual(b.commands, [1, 0, 1, 0])

    def test_paused_absent_unknown_or_untrusted_never_commands(self):
        for state in [dict(playing=False), dict(known=False), dict(trustworthy=False)]:
            with self.subTest(state=state):
                b = self.broker()
                b.send('testState', state=state)
                b.send('begin'); b.wait('skipped'); b.send('end'); b.wait('skipped')
                self.assertEqual(b.commands, [])

    def test_native_numeric_booleans_are_normalized_on_the_wire(self):
        b = self.broker()
        # Real Objective-C @(pid == expectedPID) boxes a C int as JSON 1.
        b.send('testState', state=dict(known=1, playing=1, trustworthy=1))
        b.send('snapshot')
        event = b.wait('snapshot')
        for key in ('known', 'playing', 'trustworthy', 'subscriptionHealthy'):
            self.assertIs(type(event['state'][key]), bool)
            self.assertTrue(event['state'][key])
        b.send('begin'); b.wait('paused'); b.send('end'); b.wait('released')
        self.assertEqual(b.commands, [1, 0])

    def test_track_tab_player_and_lifetime_changes_invalidate(self):
        for key, value, reason in [('item', 'new.tab', 'itemChanged'), ('pid', 99, 'playerChanged'),
                                   ('lifetime', 2, 'playerRestarted'), ('bundle', 'new.player', 'playerChanged')]:
            with self.subTest(key=key):
                b = self.broker()
                if key != 'item': b.send('testState', state=dict(metadata=TRACK))
                b.send('begin'); b.wait('paused')
                b.send('testState', state={key: value})
                event = b.wait('skipped')
                self.assertEqual(event['reason'], reason)
                self.assertEqual(event['session'], 's1')
                b.send('end'); self.assertEqual(b.wait('skipped')['reason'], 'noLease')
                self.assertEqual(b.commands, [1])

    def test_external_play_invalidates_resume(self):
        b = self.broker()
        b.send('begin'); b.wait('paused')
        b.send('testState', state=dict(playing=True))
        self.assertEqual(b.wait('skipped')['reason'], 'externalPlayback')
        b.send('end'); self.assertEqual(b.wait('skipped')['reason'], 'noLease')
        self.assertEqual(b.commands, [1])

    def test_opaque_identifier_refresh_with_same_content_resumes_once(self):
        for debug in ('0', '1'):
            with self.subTest(debug=debug):
                b = self.broker(WHISPR_DEBUG_DIAGNOSTICS=debug)
                b.send('testState', state=dict(metadata=TRACK))
                b.send('begin'); event = b.wait('paused')
                self.assertNotIn('trackIdentity', event['state'])
                self.assertNotIn('metadata', event['state'])
                self.assertNotIn(TRACK['title'], json.dumps(event))
                b.send('testState', state=dict(item='refreshed.identifier'))
                if debug == '1':
                    self.assertEqual(b.wait('snapshot')['reason'], 'itemIdentifierRefreshed')
                b.send('end'); b.wait('released'); b.wait('resumed')
                b.send('end'); b.wait('skipped')
                self.assertEqual(b.commands, [1, 0])

    def test_changed_metadata_invalidates_even_with_same_opaque_identifier(self):
        for key, value in [('title', 'Changed title'), ('artist', 'Changed artist'),
                           ('album', 'Changed album'), ('duration', 240)]:
            with self.subTest(key=key):
                b = self.broker()
                b.send('testState', state=dict(metadata=TRACK))
                b.send('begin'); b.wait('paused')
                b.send('testState', state=dict(metadata={**TRACK, key: value}))
                self.assertEqual(b.wait('skipped')['reason'], 'itemChanged')
                b.send('end'); self.assertEqual(b.wait('skipped')['reason'], 'noLease')
                self.assertEqual(b.commands, [1])

    def test_unknown_or_invalid_content_keeps_strict_identifier_check(self):
        for metadata in [None, {**TRACK, 'title': ''}, {**TRACK, 'title': 'x' * 1025},
                         {**TRACK, 'duration': 0}, {**TRACK, 'duration': 'invalid'},
                         {**TRACK, 'artist': '', 'album': ''}]:
            with self.subTest(metadata=metadata):
                b = self.broker()
                b.send('testState', state=dict(metadata=metadata))
                b.send('begin'); b.wait('paused')
                b.send('testState', state=dict(item='different.identifier'))
                self.assertEqual(b.wait('skipped')['reason'], 'itemChanged')
                b.send('end'); b.wait('skipped')
                self.assertEqual(b.commands, [1])

    def test_identifier_minted_by_our_pause_without_metadata_still_resumes(self):
        # Chrome: the pause update carries a new opaque ID and no comparable track metadata.
        for metadata in [None, {**TRACK, 'artist': '', 'album': ''}, {**TRACK, 'duration': 180.4}]:
            with self.subTest(metadata=metadata):
                b = self.broker(WHISPR_TEST_PAUSE_ITEM='minted.by.pause')
                b.send('testState', state=dict(metadata=metadata))
                b.send('begin'); b.wait('paused')
                b.send('end'); b.wait('released'); b.wait('resumed')
                self.assertEqual(b.commands, [1, 0])

    def test_contradicting_track_at_pause_still_invalidates(self):
        b = self.broker(WHISPR_TEST_PAUSE_ITEM='other.item', WHISPR_TEST_PAUSE_TITLE='Different synthetic title')
        b.send('testState', state=dict(metadata=TRACK))
        b.send('begin'); self.assertEqual(b.wait('skipped')['reason'], 'itemChanged')
        b.send('end'); self.assertEqual(b.wait('skipped')['reason'], 'noLease')
        self.assertEqual(b.commands, [1])

    def test_debug_off_omits_diagnostic_reason_and_invalidation_event(self):
        b = self.broker(WHISPR_DEBUG_DIAGNOSTICS='0')
        b.send('begin'); b.wait('paused')
        b.send('testState', state=dict(item='new.track'))
        request = b.send('end')
        event = b.wait('skipped')
        self.assertEqual(event['request'], request)
        self.assertNotIn('reason', event)
        self.assertEqual(b.commands, [1])

    def test_unconfirmed_pause_never_plays(self):
        b = self.broker(WHISPR_TEST_UNCONFIRMED='1')
        b.send('begin'); self.assertEqual(b.wait('unconfirmed')['reason'], 'pauseUnconfirmed')
        b.send('end'); self.assertEqual(b.wait('skipped')['reason'], 'pauseUnconfirmed')
        self.assertEqual(b.commands, [1])

    def test_wrong_generation_is_ignored(self):
        b = self.broker()
        b.send('begin', generation='old-generation'); b.send('snapshot'); b.wait('snapshot')
        self.assertEqual(b.commands, [])

    def test_parent_eof_attempts_confirmed_release(self):
        b = self.broker()
        b.send('begin'); b.wait('paused'); b.close()
        self.assertEqual(b.commands, [1, 0])

    def test_fragmentation_and_oversize(self):
        b = self.broker()
        payload = json.dumps(dict(version=1, operation='snapshot', session='', request='fragment',
                                  generation=b.generation, deadlineMS=500)).encode() + b'\n'
        for byte in payload:
            b.process.stdin.write(bytes([byte])); b.process.stdin.flush()
        b.wait('snapshot')
        b.process.stdin.write(b'x' * 8193); b.process.stdin.flush()
        b.process.wait(timeout=2)
        self.assertEqual(b.commands, [])

if __name__ == '__main__':
    build()
    unittest.main()
