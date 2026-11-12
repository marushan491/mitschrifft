import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/live_mcp.py'
spec = importlib.util.spec_from_file_location('live_mcp', SCRIPT)
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
RID = '2026-01-01T12:00:00'


class LiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'partial').mkdir()
        self.file = self.root / 'partial' / (RID + '.jsonl')
        self.config = self.root / 'config.json'
        self.config.write_text('{}')
        self.reader = live.Reader(self.root, self.config)
        self.append({'kind': 'header', 'id': RID, 'startedAt': '2026-01-01T12:00:00Z'})

    def append(self, value):
        with self.file.open('ab') as file:
            file.write((json.dumps(value, ensure_ascii=False) + '\n').encode())

    def read(self, cursor=None, rid=RID):
        return self.reader.call('read_transcript', {'recording_id': rid, **({'cursor': cursor} if cursor else {})})

    def test_independent_clients_replay_and_partial_utf8(self):
        first = self.read()
        raw = json.dumps({'kind': 'segment', 'track': 'mic', 'start': 0, 'end': 1,
                          'text': 'Grüße'}, ensure_ascii=False).encode() + b'\n'
        cut = raw.index('ü'.encode()) + 1
        with self.file.open('ab') as file:
            file.write(raw[:cut])
        self.assertEqual(self.read(first['cursor'])['events'], [])
        with self.file.open('ab') as file:
            file.write(raw[cut:])
        second = self.read(first['cursor'])
        self.assertEqual(second, self.read(first['cursor']))
        self.assertEqual(second['events'][0]['text'], 'Grüße')
        self.assertEqual(self.read(second['cursor'])['events'], [])
        self.append({'kind': 'speaker', 'speaker': 9, 'start': 0, 'end': 1})
        self.assertEqual(self.read(second['cursor'])['events'][0]['diarizer_speaker'], 9)

    def test_bounds_gaps_and_private_fields(self):
        self.append({'kind': 'screen', 'text': 'private', 'imageFile': '/private/image'})
        with self.file.open('ab') as file:
            file.write(b'broken\n')
        self.append({'kind': 'segment', 'track': 'system', 'text': 'source', 'start': 0, 'end': 1,
                     'secret': 'private'})
        page = self.read()
        self.assertEqual(page['status'], 'gaps')
        self.assertEqual(len(page['events']), 1)
        self.assertNotIn('private', json.dumps(page))
        with self.file.open('ab') as file:
            file.write(b'x' * (live.RECORD + 1))
        with self.assertRaisesRegex(live.ReadError, 'record_too_large'):
            self.read(page['cursor'])

    def test_invalid_cursors_replacement_truncation_and_missing(self):
        self.append({'kind': 'speaker', 'speaker': 1, 'start': 0, 'end': 1})
        page = self.read()
        with self.assertRaisesRegex(live.ReadError, 'cursor_reset'):
            self.read('not-base64')
        contents = self.file.read_bytes()
        self.file.write_bytes(contents[:-10])
        with self.assertRaisesRegex(live.ReadError, 'cursor_reset'):
            self.read(page['cursor'])
        self.file.rename(self.file.with_suffix('.old'))
        self.file.write_bytes(contents)
        with self.assertRaisesRegex(live.ReadError, 'cursor_reset'):
            self.read(page['cursor'])
        self.file.unlink()
        self.assertTrue(self.read(page['cursor'])['possible_unread_loss'])

    def test_no_arbitrary_paths_symlinks_or_fifo(self):
        for rid in ('../config', '/etc/passwd', '-x', 'other'):
            with self.assertRaises(live.ReadError):
                self.read(rid=rid)
        self.file.unlink()
        self.file.symlink_to(self.config)
        with self.assertRaises(OSError):
            self.read()
        self.assertEqual(self.reader.call('list_recordings', {})['recordings'], [])
        self.file.unlink()
        import os
        os.mkfifo(self.file)
        with self.assertRaisesRegex(live.ReadError, 'not_regular'):
            self.read()

    def test_bounded_paging_and_identity(self):
        for i in range(130):
            self.append({'kind': 'speaker', 'speaker': i, 'start': 0, 'end': 1})
        page = self.read()
        self.assertEqual(len(page['events']), 100)
        self.assertTrue(page['has_more'])
        self.assertEqual(len(self.read(page['cursor'])['events']), 30)
        self.file.write_text('{"kind":"header","id":"wrong"}\n')
        with self.assertRaisesRegex(live.ReadError, 'identity'):
            self.read()

    def test_chat_opt_in_consent_recheck_and_exact_recording(self):
        folder = self.root / 'shared-chat'
        folder.mkdir()
        (folder / 'snapshot.json').write_text(json.dumps({'recording_id': RID, 'generation': 'g',
            'revision': 'r', 'turns': [{'question': 'q', 'answer': 'a', 'images': ['private']}]}))
        self.assertEqual(self.reader.call('read_chat', {'recording_id': RID})['status'], 'disabled')
        self.config.write_text('{"shareChat":true}')
        result = self.reader.call('read_chat', {'recording_id': RID})
        self.assertEqual(result['turns'], [{'question': 'q', 'answer': 'a'}])
        self.assertEqual(self.reader.call('read_chat', {'recording_id': RID + '.1'})['status'], 'unavailable')
        self.config.write_text('{}')
        self.assertEqual(self.reader.call('read_chat', {'recording_id': RID})['status'], 'disabled')
        self.config.write_text('{"shareChat":true}')
        (folder / 'snapshot.json').write_text(json.dumps({'recording_id': RID, 'turns': [1]}))
        with self.assertRaisesRegex(live.ReadError, 'invalid_chat'):
            self.reader.call('read_chat', {'recording_id': RID})

    def test_stdio_protocol_and_one_shot(self):
        calls = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
                  'params': {'protocolVersion': '2025-03-26'}},
                 {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                 {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
                 {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call',
                  'params': {'name': 'read_transcript', 'arguments': {'recording_id': RID}}},
                 {'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call',
                  'params': {'name': 'read_transcript', 'arguments': {'recording_id': '../x'}}},
                 {'jsonrpc': '2.0', 'id': 5, 'method': 'initialize', 'params': []},
                 {'jsonrpc': '2.0', 'id': 6, 'method': 'tools/call', 'params': []},
                 {'jsonrpc': '2.0', 'id': 7, 'method': 'ping'}]
        result = subprocess.run([sys.executable, '-I', str(SCRIPT), '--state', str(self.root),
                                 '--config', str(self.config)],
                                input='\n'.join(map(json.dumps, calls)) + '\n',
                                text=True, capture_output=True, timeout=5, check=True)
        replies = list(map(json.loads, result.stdout.splitlines()))
        self.assertEqual(len(replies), 7)
        self.assertEqual(len(replies[1]['result']['tools']), 3)
        self.assertFalse(replies[2]['result']['isError'])
        self.assertTrue(replies[3]['result']['isError'])
        self.assertIn('error', replies[4])
        self.assertIn('error', replies[5])
        self.assertEqual(replies[6]['result'], {})
        one = subprocess.run([sys.executable, '-I', str(SCRIPT), '--call', '--state', str(self.root)],
                             input='{"name":"list_recordings"}', text=True, capture_output=True,
                             timeout=5, check=True)
        self.assertEqual(json.loads(one.stdout)['recordings'][0]['recording_id'], RID)


if __name__ == '__main__':
    unittest.main()
