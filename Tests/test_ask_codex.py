import base64
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ask_codex', Path(__file__).parents[1] / 'scripts/ask-codex.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class ChatBridgeTests(unittest.TestCase):
    def test_truncated_transcript_keeps_complete_speaker_lines_and_marks_missing_context(self):
        transcript = '[00:01] Sprecher 1: ' + 'x' * bridge.LIMIT + '\n[28:27] Sprecher 2: Gibt es eine Notiz?'
        prompt = bridge.prompt({'mode': 'question', 'question': 'Wer fragt?', 'transcript': transcript})
        excerpt = prompt.split('Transkript:\n<<<\n', 1)[1].split('\n>>>', 1)[0]
        self.assertEqual(excerpt, '[28:27] Sprecher 2: Gibt es eine Notiz?')
        self.assertIn('Frühere Sprecherbelege können fehlen', prompt)

    def test_single_oversized_line_does_not_lose_its_speaker_label(self):
        prompt = bridge.prompt({'mode': 'question', 'question': 'Wer?',
                                'transcript': '[00:01] Sprecher 1: ' + 'x' * bridge.LIMIT})
        excerpt = prompt.split('Transkript:\n<<<\n', 1)[1].split('\n>>>', 1)[0]
        self.assertNotIn('x', excerpt)
        self.assertIn('kein vollständiges Transkriptsegment', excerpt)

    def test_analysis_starts_once_in_existing_workspace_with_stronger_model(self):
        request_id = '8b1c8e73-9a4a-4ce9-bbe7-05026319069a'
        request = {'mode': 'analysis', 'question': 'Prüfe den Plan unabhängig.', 'requestID': request_id,
                   'transcript': '[00:10] Eine Annahme.', 'history': []}
        calls = []
        def cli(*args):
            calls.append(args)
            if args[0] == 'ls':
                return []
            self.assertIn('--no-wait', args)
            self.assertIn(bridge.DEFAULTS['analysis']['workspace'], args)
            self.assertIn('codex-business/gpt-6.1-sol', args)
            self.assertIn('high', args)
            self.assertNotIn('--new-workspace', args)
            self.assertIn('[00:10] Eine Annahme.', args[-1])
            return {'agentId': 'example-analysis'}
        with patch.object(bridge, 'pandaos', cli), \
                patch('sys.stdin', io.StringIO(json.dumps(request))), patch('sys.stdout', io.StringIO()) as output:
            bridge.main()
            self.assertEqual(json.loads(output.getvalue())['sessionID'], 'example-analysis')
        self.assertEqual(len(calls), 2)
        with patch.object(bridge, 'pandaos', return_value=[{'id': 'already-started'}]) as cli, \
                patch('sys.stdin', io.StringIO(json.dumps(request))), patch('sys.stdout', io.StringIO()) as output:
            bridge.main()
            self.assertEqual(json.loads(output.getvalue())['sessionID'], 'already-started')
            self.assertEqual(cli.call_count, 1)

    def test_analysis_requires_request_id_and_normal_chat_does_not_start_sessions(self):
        request = {'mode': 'analysis', 'question': 'Prüfen'}
        with patch.object(bridge, 'pandaos') as cli, patch('sys.stdin', io.StringIO(json.dumps(request))):
            with self.assertRaisesRegex(SystemExit, 'Anfrage-ID'):
                bridge.main()
            cli.assert_not_called()
        self.assertNotIn('höchstens 8 Sätzen', bridge.QUESTION)

    def test_analysis_timeout_reports_possible_start_and_retains_clear_error(self):
        with patch.object(bridge.subprocess, 'run', side_effect=bridge.subprocess.TimeoutExpired('pandaos', 45)):
            with self.assertRaisesRegex(SystemExit, 'Analyse kann schon laufen'):
                bridge.pandaos('run', 'Test')

    def test_follow_up_contains_previous_answer_and_current_sources(self):
        request = {'mode': 'question', 'question': 'Und bis wann?', 'transcript': '[00:20] Alex: Freitag.',
                   'history': [{'question': 'Wer?', 'answer': 'Alex [00:10].'}]}
        prompt = bridge.prompt(request)
        for text in ('Und bis wann?', 'Alex [00:10].', '[00:20] Alex: Freitag.', 'PandaOS-/Paseo-'):
            self.assertIn(text, prompt)

    def test_asked_does_not_include_unrelated_chat(self):
        prompt = bridge.prompt({'mode': 'asked', 'history': [{'question': 'SECRET', 'answer': 'SECRET'}]})
        self.assertNotIn('SECRET', prompt)

    def test_bridge_uses_ephemeral_readonly_business_without_provisioning(self):
        def run(command, **kwargs):
            self.assertEqual(command[0], bridge.CODEX)
            self.assertIn('--ephemeral', command)
            self.assertIn('--ignore-user-config', command)
            self.assertNotIn('--worktree', command)
            self.assertEqual(command[command.index('-s') + 1], 'read-only')
            self.assertEqual(command[command.index('-m') + 1], 'gpt-6-luna')
            self.assertEqual(kwargs['env']['CODEX_HOME'], '/home/admin/.codex-business')
            Path(command[command.index('-o') + 1]).write_text('Freitag [00:20].')
            return SimpleNamespace(returncode=0)

        with tempfile.TemporaryDirectory() as folder:
            vault = Path(folder) / 'vault-path'
            vault.write_text(folder)
            request = {'mode': 'question', 'question': 'Bis wann?', 'history': []}
            with patch.object(bridge, 'VAULT', vault), patch.object(bridge.subprocess, 'run', run), \
                    patch('sys.stdin', io.StringIO(json.dumps(request))), patch('sys.stdout', io.StringIO()) as output:
                bridge.main()
                self.assertEqual(json.loads(output.getvalue())['answer'], 'Freitag [00:20].')

    def test_structure_uses_luna_without_vault_access(self):
        def run(command, **kwargs):
            self.assertEqual(command[command.index('-m') + 1], 'gpt-6-luna')
            self.assertEqual(command[command.index('-s') + 1], 'read-only')
            self.assertNotEqual(command[command.index('-C') + 1], 'VAULT')
            self.assertEqual(kwargs['timeout'], 600)
            self.assertIn('### Aufgaben', kwargs['input'])
            self.assertIn('[00:05] Ich: Wir liefern Freitag.', kwargs['input'])
            Path(command[command.index('-o') + 1]).write_text('### Kernpunkte\n- Lieferung Freitag')
            return SimpleNamespace(returncode=0)

        request = {'mode': 'structure', 'transcript': '[00:05] Ich: Wir liefern Freitag.'}
        with patch.object(bridge, 'VAULT', SimpleNamespace(read_text=lambda: 'VAULT')), \
                patch.object(bridge.subprocess, 'run', run), \
                patch('sys.stdin', io.StringIO(json.dumps(request))), patch('sys.stdout', io.StringIO()) as output:
            bridge.main()
            reply = json.loads(output.getvalue())
        self.assertEqual(reply['answer'], '### Kernpunkte\n- Lieferung Freitag')
        self.assertEqual(reply['model'], 'gpt-6-luna')

    def test_configured_codex_account_model_and_effort_reach_provider(self):
        def run(command, **kwargs):
            self.assertEqual(command[command.index('-m') + 1], 'gpt-6.1-sol')
            self.assertIn('model_reasoning_effort=medium', command)
            self.assertEqual(kwargs['env']['CODEX_HOME'], str(Path(folder) / '.codex-plus'))
            Path(command[command.index('-o') + 1]).write_text('Ja.')
            return SimpleNamespace(returncode=0)

        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / '.codex-plus').mkdir()
            request = {'mode': 'asked', 'ai': {'live': {'account': 'plus', 'model': 'gpt-6.1-sol',
                                                        'effort': 'medium'}}}
            with patch.dict(bridge.os.environ, {'HOME': folder}), patch.object(bridge.subprocess, 'run', run), \
                    patch('sys.stdin', io.StringIO(json.dumps(request))), patch('sys.stdout', io.StringIO()) as output:
                bridge.main()
                reply = json.loads(output.getvalue())
        self.assertEqual((reply['account'], reply['model'], reply['effort']), ('Codex plus', 'gpt-6.1-sol', 'medium'))

    def test_ollama_chat_gets_transcript_only_and_no_vault(self):
        calls = []

        def urlopen(call, timeout):
            calls.append(call)
            return io.BytesIO(json.dumps({'response': 'Freitag [00:20].'}).encode())

        request = {'mode': 'question', 'question': 'Bis wann?', 'transcript': '[00:20] Alex: Freitag.',
                   'ai': {'chat': {'provider': 'ollama', 'url': 'http://gpu.local:11434', 'model': 'qwen3.5:9b'}}}
        with patch.object(bridge, 'VAULT', SimpleNamespace(read_text=lambda: self.fail('Vault gelesen'))), \
                patch.object(bridge.urllib.request, 'urlopen', urlopen), patch.object(bridge.subprocess, 'run') as run, \
                patch('sys.stdin', io.StringIO(json.dumps(request))), patch('sys.stdout', io.StringIO()) as output:
            bridge.main()
            reply = json.loads(output.getvalue())
        run.assert_not_called()
        body = json.loads(calls[0].data)
        self.assertEqual(calls[0].full_url, 'http://gpu.local:11434/api/generate')
        self.assertEqual((body['model'], body['options']['num_ctx']), ('qwen3.5:9b', 16384))
        self.assertIn('keinen Zugriff auf Dateien', body['prompt'])
        self.assertNotIn('Second Brain im aktuellen', body['prompt'])
        self.assertEqual((reply['answer'], reply['account']), ('Freitag [00:20].', 'Ollama gpu.local'))

    def test_analysis_uses_configured_pandaos_provider_and_rejects_ollama(self):
        request = {'mode': 'analysis', 'question': 'Prüfen', 'requestID': '8b1c8e73-9a4a-4ce9-bbe7-05026319069a',
                   'ai': {'analysis': {'account': 'claude', 'model': 'opus', 'effort': 'medium'}}}
        def cli(*args):
            if args[0] == 'ls':
                return []
            self.assertEqual(args[args.index('--provider') + 1], 'claude/opus')
            self.assertEqual(args[args.index('--thinking') + 1], 'medium')
            return {'agentId': 'configured'}
        with patch.object(bridge, 'pandaos', cli), \
                patch('sys.stdin', io.StringIO(json.dumps(request))), patch('sys.stdout', io.StringIO()) as output:
            bridge.main()
            self.assertEqual(json.loads(output.getvalue())['model'], 'opus')
        for ai in ({'analysis': {'provider': 'ollama'}}, {'chat': {'model': 'x; rm -rf /'}}, {'chat': 'codex'}, 'x'):
            request = {'mode': 'question', 'question': 'Wer?', 'requestID': request['requestID'], 'ai': ai}
            if 'analysis' in ai:
                request['mode'] = 'analysis'
            with self.subTest(ai=ai), patch('sys.stdin', io.StringIO(json.dumps(request))), \
                    patch.object(bridge.subprocess, 'run') as run, patch.object(bridge, 'pandaos') as panda:
                with self.assertRaisesRegex(SystemExit, 'ai'):
                    bridge.main()
                run.assert_not_called()
                panda.assert_not_called()

    def test_structure_without_transcript_stops_before_provider(self):
        for transcript in (None, '  ', 'x' * (bridge.STRUCTURE_LIMIT + 1)):
            request = {'mode': 'structure', 'transcript': transcript}
            with self.subTest(size=len(transcript or '')), patch('sys.stdin', io.StringIO(json.dumps(request))), \
                    patch.object(bridge.subprocess, 'run') as run:
                with self.assertRaises(SystemExit):
                    bridge.main()
                run.assert_not_called()

    def test_invalid_history_stops_before_provider(self):
        request = {'mode': 'question', 'question': 'Wer?', 'history': [{'question': 'Wer?'}]}
        with patch('sys.stdin', io.StringIO(json.dumps(request))), patch.object(bridge.subprocess, 'run') as run:
            with self.assertRaisesRegex(SystemExit, 'Chatverlauf unlesbar'):
                bridge.main()
            run.assert_not_called()

    def test_images_reach_provider_as_temporary_files_and_are_removed(self):
        jpeg = b'\xff\xd8\xffsynthetic\xff\xd9'
        paths = []

        def run(command, **kwargs):
            path = Path(command[command.index('--image') + 1])
            self.assertLess(command.index('-'), command.index('--image'))
            paths.append(path)
            self.assertEqual(path.read_bytes(), jpeg)
            self.assertIn('Bildnummer', kwargs['input'])
            self.assertNotIn(base64.b64encode(jpeg).decode(), kwargs['input'])
            Path(command[command.index('-o') + 1]).write_text('Bild 1 ist sichtbar.')
            return SimpleNamespace(returncode=0)

        with tempfile.TemporaryDirectory() as folder:
            vault = Path(folder) / 'vault-path'
            vault.write_text(folder)
            request = {'mode': 'question', 'question': 'Was zeigt das Bild?',
                       'images': [{'name': '../../bild.jpg', 'data': base64.b64encode(jpeg).decode()}]}
            with patch.object(bridge, 'VAULT', vault), patch.object(bridge.subprocess, 'run', run), \
                    patch('sys.stdin', io.StringIO(json.dumps(request))), patch('sys.stdout', io.StringIO()):
                bridge.main()
        self.assertEqual(len(paths), 1)
        self.assertFalse(paths[0].exists())

    def test_invalid_images_stop_before_provider(self):
        for images in ('bad', [{}], [{'name': 'x', 'data': '%%%'}],
                       [{'name': 'x', 'data': base64.b64encode(b'not jpeg').decode()}],
                       [{'name': 'x', 'data': ''}] * 5):
            request = {'mode': 'question', 'question': 'Bild?', 'images': images}
            with self.subTest(images=images), patch('sys.stdin', io.StringIO(json.dumps(request))), \
                    patch.object(bridge.subprocess, 'run') as run:
                with self.assertRaises(SystemExit):
                    bridge.main()
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
