import contextlib
import importlib.util
import io
import json
import pathlib
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('rename_stage', ROOT / 'src/rename_stage.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class NamingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rj_naming_test_')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.output = self.root / 'out'
        self.output.mkdir()
        self.cache = self.root / 'cache.db'
        with contextlib.closing(sqlite3.connect(self.cache)) as c, c:
            c.execute('CREATE TABLE workmetadatacache(rjcode TEXT PRIMARY KEY, metadata TEXT)')
            for code in ('RJ99999991', 'RJ99999992'):
                c.execute('INSERT INTO workmetadatacache VALUES (?,?)', (code, json.dumps(
                    {'rjcode': code, 'work_name': 'Test: title', 'cvs': ['Voice']})))
        self.settings = self.root / 'external.json'
        stage.write_json(self.settings, {'renamer_template': 'rjcode work_name cv_list_str'})
        self.config = self.root / 'config.json'
        config = stage.read_json(ROOT / 'config.json')
        config['naming'] = {'enabled': True, 'cache_db': str(self.cache), 'external_config': str(self.settings)}
        config['extraction']['rj_password']['enabled'] = False
        config['extraction']['keep_original_archives'] = True
        config['extraction']['password_file'] = str(self.root / 'no-passwords.txt')
        stage.write_json(self.config, config)
        self.result = self.root / 'result.json'

    def work(self, code):
        d = self.output / code
        d.mkdir()
        (d / 'keep.txt').write_text('unaltered')
        return d

    def run_stage(self, paths):
        stage.write_json(self.result, {'final_directories': list(map(str, paths))})
        with contextlib.redirect_stdout(io.StringIO()):
            return stage.run(self.result, self.config)

    def test_rename_and_repeat(self):
        old = self.work('RJ99999991')
        records = self.run_stage([old])
        new = pathlib.Path(records[0]['new_path'])
        self.assertEqual(new.name, 'RJ99999991 Test_ title (CV Voice)')
        self.assertEqual((new / 'keep.txt').read_text(), 'unaltered')
        self.assertEqual(self.run_stage([new])[0]['status'], 'unchanged')

    def test_missing_cache_entry(self):
        old = self.work('RJ99999990')
        self.assertEqual(self.run_stage([old])[0]['status'], 'pending')
        self.assertTrue(old.exists())

    def test_duplicate_inputs_do_not_leave_stale_paths(self):
        first = self.work('RJ99999991')
        second = self.work('RJ99999992')
        records = self.run_stage([first, first, second])
        manifest = stage.read_json(self.result)
        self.assertEqual(manifest['final_directories'], [r['new_path'] for r in records])
        self.assertEqual(len(manifest['final_directories']), 2)
        self.assertTrue(all(pathlib.Path(p).is_dir() for p in manifest['final_directories']))

    def test_conflict_never_merges(self):
        old = self.work('RJ99999991')
        target = self.output / 'RJ99999991 Test_ title (CV Voice)'
        target.mkdir()
        self.assertEqual(self.run_stage([old])[0]['status'], 'pending')
        self.assertTrue((old / 'keep.txt').exists())
        self.assertFalse((target / 'keep.txt').exists())

    def test_missing_database_not_created(self):
        self.cache.unlink()
        self.assertEqual(self.run_stage([self.work('RJ99999991')])[0]['status'], 'pending')
        self.assertFalse(self.cache.exists())

    def test_long_and_invalid_title(self):
        with self.assertRaises(ValueError):
            stage.folder_name('RJ99999991', {'work_name': 'x' * 300}, {})
        with self.assertRaises(ValueError):
            stage.folder_name('RJ99999991', {'work_name': '\ufffd'}, {})

    def test_pipeline_and_extractor_resume(self):
        archive = self.root / 'RJ99999991.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('keep.txt', 'unaltered')
        command = ['pwsh', '-NoProfile', '-File', str(ROOT / 'processing-pipeline.ps1'),
                   '-Run', '-OutputRoot', str(self.output), '-ConfigPath', str(self.config), str(archive)]
        first = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace')
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertTrue((self.output / 'RJ99999991 Test_ title (CV Voice)' / 'keep.txt').exists(), first.stdout)
        second = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace')
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn('skipped_named_batch', ''.join(
            p.read_text(encoding='utf-8-sig') for p in (ROOT / 'logs').glob('extract*.jsonl')))
        self.assertIn('已识别名称补全后的完成结果', second.stdout)
        self.assertFalse((self.output / 'RJ99999991').exists())

    def test_multi_work_batch_resume(self):
        archive = self.root / 'RJ99999991.zip'
        with zipfile.ZipFile(archive, 'w') as outer:
            for code in ('RJ99999991', 'RJ99999992'):
                payload = io.BytesIO()
                with zipfile.ZipFile(payload, 'w') as inner:
                    inner.writestr('same.txt', code)
                outer.writestr(code + '.zip', payload.getvalue())
        command = ['pwsh', '-NoProfile', '-File', str(ROOT / 'processing-pipeline.ps1'),
                   '-Run', '-OutputRoot', str(self.output), '-ConfigPath', str(self.config), str(archive)]
        for run in range(2):
            completed = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace')
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            for code in ('RJ99999991', 'RJ99999992'):
                self.assertEqual((self.output / (code + ' Test_ title (CV Voice)') / 'same.txt').read_text(), code)
            if run:
                self.assertIn('已识别名称补全后的完成结果', completed.stdout)

    def test_nested_same_rj_game_preserves_resources(self):
        import hashlib
        program = pathlib.Path(r'C:\Program Files\7-Zip\7z.exe').read_bytes()
        archive = self.root / 'RJ99999991.zip'
        inner_data = io.BytesIO()
        payload = {'Game/Game.exe': program, 'Game/UnityPlayer.dll': program,
                   'Game/voice.wav': b'game audio', 'Game/movie.mp4': b'game video'}
        with zipfile.ZipFile(inner_data, 'w') as inner:
            for name, data in payload.items():
                inner.writestr(name, data)
        with zipfile.ZipFile(archive, 'w') as outer:
            outer.writestr('RJ99999991/RJ99999991.zip', inner_data.getvalue())
        command = ['pwsh', '-NoProfile', '-File', str(ROOT / 'processing-pipeline.ps1'),
                   '-Run', '-OutputRoot', str(self.output), '-ConfigPath', str(self.config), str(archive)]
        result = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        work = self.output / 'RJ99999991 Test_ title (CV Voice)'
        for name, data in payload.items():
            matches = list(work.rglob(pathlib.Path(name).name))
            self.assertEqual(len(matches), 1, str(matches))
            self.assertEqual(hashlib.sha256(matches[0].read_bytes()).digest(), hashlib.sha256(data).digest())
        self.assertIn('游戏/软件保护', result.stdout)
        self.assertFalse(list(work.rglob('.rsrc')))

    def test_real_sfx_still_extracts(self):
        payload = self.root / 'payload.txt'
        payload.write_text('sfx payload')
        sfx = self.root / 'RJ99999991.exe'
        build = subprocess.run([r'C:\Program Files\7-Zip\7z.exe', 'a', '-t7z',
            '-sfxC:\\Program Files\\7-Zip\\7z.sfx', str(sfx), str(payload)], capture_output=True)
        self.assertEqual(build.returncode, 0)
        archive = self.root / 'RJ99999991.zip'
        with zipfile.ZipFile(archive, 'w') as outer:
            outer.write(sfx, 'RJ99999991.exe')
        command = ['pwsh', '-NoProfile', '-File', str(ROOT / 'extract.ps1'),
                   '-Run', '-OutputRoot', str(self.output), '-ConfigPath', str(self.config), str(archive)]
        result = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.output / 'RJ99999991' / 'payload.txt').read_text(), 'sfx payload')
        self.assertFalse(list(self.output.rglob('*.exe')))

    def test_disabled(self):
        config = stage.read_json(self.config)
        config['naming']['enabled'] = False
        stage.write_json(self.config, config)
        old = self.work('RJ99999991')
        self.assertEqual(self.run_stage([old])[0]['status'], 'disabled')
        self.assertTrue(old.exists())

    def test_online_page_identity(self):
        page = '<link rel="canonical" href="https://www.dlsite.com/maniax/work/=/product_id/RJ99999990.html"><h1 id="work_name">Title &amp; More</h1><tr><th>声優</th><td><a>Voice</a></td></tr>'
        metadata = stage.parse_work_page('RJ99999990', page)
        self.assertEqual(metadata['work_name'], 'Title & More')
        self.assertEqual(metadata['cvs'], ['Voice'])
        with self.assertRaises(ValueError):
            stage.parse_work_page('RJ99999991', page)
        with self.assertRaises(ValueError):
            stage.parse_work_page('RJ99999990', '<h1>404 Not Found</h1>')

    def test_product_api_bonus_and_identity(self):
        product = {'workno': 'RJ01701292', 'work_name': 'Bonus title', 'creaters': [], 'maker_name': 'Circle'}
        self.assertEqual(stage.parse_product_api('RJ01701292', [product])['cvs'], [])
        self.assertIsNone(stage.parse_product_api('RJ01701292', []))
        with self.assertRaises(ValueError):
            stage.parse_product_api('RJ01694635', [product])
        with self.assertRaises(ValueError):
            stage.parse_product_api('RJ01701292', [product, product])

    def test_api_success_does_not_require_work_page(self):
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value = response
        response.url = 'https://www.dlsite.com/maniax/api/=/product.json'
        response.read.return_value = json.dumps([{'workno': 'RJ01701292', 'work_name': 'Bonus title'}]).encode()
        with patch.object(stage, 'urlopen', return_value=response) as request:
            self.assertEqual(stage.query_online('RJ01701292')['work_name'], 'Bonus title')
            self.assertEqual(request.call_count, 1)
            argument = request.call_args[0][0]
            self.assertIn('product.json', argument if isinstance(argument, str) else argument.full_url)

    def test_explicit_proxy_is_used_for_https(self):
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value = response
        response.url = 'https://www.dlsite.com/maniax/api/=/product.json'
        response.read.return_value = json.dumps([{'workno': 'RJ01701292', 'work_name': 'Bonus title'}]).encode()
        opener = MagicMock()
        opener.open.return_value = response
        with patch.object(stage, 'build_opener', return_value=opener) as build:
            metadata = stage.query_online('RJ01701292', proxy_url='http://127.0.0.1:7890')
        self.assertEqual(metadata['work_name'], 'Bonus title')
        handler = build.call_args[0][0]
        self.assertEqual(handler.proxies['https'], 'http://127.0.0.1:7890')
        self.assertEqual(opener.open.call_count, 1)

    def test_external_rename_recovers_mapping(self):
        old = self.work('RJ99999991')
        target = old.with_name('RJ99999991 Test_ title (CV Voice)')
        old.rename(target)
        record = self.run_stage([old])[0]
        self.assertEqual(record['status'], 'recognized_external_rename')
        self.assertEqual(record['new_path'], str(target))

    def test_online_fallback_and_cache(self):
        config = stage.read_json(self.config)
        config['naming']['online_fallback'] = True
        stage.write_json(self.config, config)
        with patch.object(stage, 'query_online', return_value={'rjcode': 'RJ99999990', 'work_name': 'Online title', 'cvs': []}) as query:
            record = self.run_stage([self.work('RJ99999990')])[0]
            self.assertEqual(record['status'], 'renamed')
            self.assertEqual(record['metadata_source'], 'dlsite_online')
            self.assertEqual(self.run_stage([record['new_path']])[0]['status'], 'unchanged')
            self.assertEqual(query.call_count, 1)

    def test_online_failure_keeps_directory(self):
        config = stage.read_json(self.config)
        config['naming']['online_fallback'] = True
        stage.write_json(self.config, config)
        original = self.work('RJ99999990')
        with patch.object(stage, 'query_online', side_effect=ValueError('404')):
            self.assertEqual(self.run_stage([original])[0]['status'], 'pending')
        self.assertTrue(original.exists())


if __name__ == '__main__':
    unittest.main()
