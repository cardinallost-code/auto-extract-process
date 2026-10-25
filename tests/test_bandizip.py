import pathlib
import json
import io
import subprocess
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BZ = pathlib.Path('C:/Program Files/Bandizip/bz.exe')

@unittest.skipUnless(BZ.exists(), 'Bandizip is not installed')
class BandizipTests(unittest.TestCase):
    def test_recursive_extractor(self):
        with tempfile.TemporaryDirectory(prefix='bandizip_recursive_') as temp:
            base = pathlib.Path(temp)
            inner = io.BytesIO()
            with zipfile.ZipFile(inner, 'w') as z:
                z.writestr('日本語/音声.txt', 'nested payload')
            archive = base / 'RJ99999991.ra'
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr('inner.zi', inner.getvalue())
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
            config['extraction']['rj_password']['enabled'] = False
            config['extraction']['password_file'] = str(base / 'absent-passwords.txt')
            cfg = base / 'config.json'
            cfg.write_text(json.dumps(config), encoding='utf-8')
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'extract.ps1'),
                                     '-InputPath', str(archive), '-Run', '-OutputRoot', str(base / 'output'),
                                     '-ConfigPath', str(cfg), '-ResultFile', str(base / 'result.json')],
                                    capture_output=True, encoding='utf-8', errors='replace', timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Bandizip', result.stdout)
            files = list((base / 'output').rglob('音声.txt'))
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].read_text(), 'nested payload')
            self.assertFalse((base / 'RJ99999991.zip').exists())
            manifest = json.loads((base / 'result.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(manifest['failed_archives'], [])

    def test_real_audio_ra_is_not_an_archive(self):
        with tempfile.TemporaryDirectory(prefix='real_audio_ra_') as temp:
            media = pathlib.Path(temp) / 'sample.ra'
            media.write_bytes(b'.ra\xfd\x00not an archive')
            script = """
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile('EXTRACT',[ref]$null,[ref]$null)
foreach($name in @('Get-SignatureKind','Test-IsRealSfx','Test-IsArchiveCandidate')){
  $f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
  . ([scriptblock]::Create($f.Extent.Text))
}
if(Test-IsArchiveCandidate (Get-Item -LiteralPath 'MEDIA')){exit 1}
""".replace('EXTRACT', str(ROOT / 'extract.ps1')).replace('MEDIA', str(media))
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True,
                                    encoding='utf-8', errors='replace', timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failure_manifest_contains_archive_and_reason(self):
        with tempfile.TemporaryDirectory(prefix='bandizip_failure_list_') as temp:
            base = pathlib.Path(temp)
            archive = base / 'RJ99999991.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr('track.txt', 'payload')
            output = base / 'output'
            (output / 'RJ99999991').mkdir(parents=True)
            (output / 'RJ99999991' / 'track.txt').write_text('conflicting existing payload')
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
            config['extraction']['rj_password']['enabled'] = False
            config['extraction']['password_file'] = str(base / 'absent-passwords.txt')
            cfg = base / 'config.json'
            cfg.write_text(json.dumps(config), encoding='utf-8')
            result_file = base / 'result.json'
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'extract.ps1'),
                                     '-InputPath', str(archive), '-Run', '-OutputRoot', str(output),
                                     '-ConfigPath', str(cfg), '-ResultFile', str(result_file)],
                                    capture_output=True, encoding='utf-8', errors='replace', timeout=60)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            manifest = json.loads(result_file.read_text(encoding='utf-8-sig'))
            self.assertEqual(manifest['failed_archives'][0]['archive'], str(archive))
            self.assertIn('内容冲突', manifest['failed_archives'][0]['reason'])
            self.assertIn('失败压缩包', result.stdout)

    def test_failed_nested_final_commit_keeps_archive_on_retry(self):
        with tempfile.TemporaryDirectory(prefix='bandizip_commit_retry_') as temp:
            base = pathlib.Path(temp)
            inner = io.BytesIO()
            with zipfile.ZipFile(inner, 'w') as z:
                z.writestr('Title/track.txt', 'nested payload')
            outer = base / 'RJ99999991_3.zip'
            with zipfile.ZipFile(outer, 'w') as z:
                z.writestr('RJ99999991.zip', inner.getvalue())
            output = base / 'output'
            existing = output / 'RJ99999991'
            existing.mkdir(parents=True)
            (existing / 'original.txt').write_text('keep')
            (existing / 'track.txt').write_text('conflicting payload')
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
            config['extraction']['rj_password']['enabled'] = False
            config['extraction']['password_file'] = str(base / 'absent-passwords.txt')
            cfg = base / 'config.json'
            cfg.write_text(json.dumps(config), encoding='utf-8')
            nested = output / 'RJ99999991_3' / 'RJ99999991.zip'
            for attempt in range(2):
                result_file = base / f'result-{attempt}.json'
                result = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'extract.ps1'),
                                         '-InputPath', str(outer), '-Run', '-OutputRoot', str(output),
                                         '-ConfigPath', str(cfg), '-ResultFile', str(result_file)],
                                        capture_output=True, encoding='utf-8', errors='replace', timeout=60)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertTrue(nested.exists(), result.stdout + result.stderr)
                self.assertEqual((existing / 'original.txt').read_text(), 'keep')
                manifest = json.loads(result_file.read_text(encoding='utf-8-sig'))
                self.assertTrue(any(item['status'] == 'final_commit_failed'
                                    for item in manifest['failed_archives']))

    def test_disguised_nested_zip_can_extract_beside_its_own_filename(self):
        with tempfile.TemporaryDirectory(prefix='bandizip_disguised_nested_') as temp:
            base = pathlib.Path(temp)
            inner = io.BytesIO()
            with zipfile.ZipFile(inner, 'w') as z:
                z.writestr('Title/track.txt', 'nested payload')
            outer = base / 'RJ99999992.jpg'
            with zipfile.ZipFile(outer, 'w') as z:
                z.writestr('RJ99999992.pdf', inner.getvalue())
            output = base / 'output'
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
            config['extraction']['rj_password']['enabled'] = False
            config['extraction']['password_file'] = str(base / 'absent-passwords.txt')
            cfg = base / 'config.json'
            cfg.write_text(json.dumps(config), encoding='utf-8')
            result_file = base / 'result.json'
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'extract.ps1'),
                                     '-InputPath', str(outer), '-Run', '-OutputRoot', str(output),
                                     '-ConfigPath', str(cfg), '-ResultFile', str(result_file)],
                                    capture_output=True, encoding='utf-8', errors='replace', timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((output / 'RJ99999992' / 'track.txt').read_text(), 'nested payload')
            manifest = json.loads(result_file.read_text(encoding='utf-8-sig'))
            self.assertEqual(manifest['failed_archives'], [])

    def test_failed_name_map_receipt_does_not_skip_archive(self):
        with tempfile.TemporaryDirectory(prefix='bandizip_failed_receipt_') as temp:
            base = pathlib.Path(temp)
            archive = base / 'RJ99999993.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr('track.txt', 'payload')
            output = base / 'output'
            output.mkdir()
            prior = base / 'prior-result.json'
            prior.write_text(json.dumps({'success': False, 'failure_count': 1,
                                         'failed_archives': [{'archive': str(archive)}]}))
            stat = archive.stat()
            ticks = str(int((stat.st_mtime_ns // 100) + 621355968000000000))
            receipt = [{'sources': [{'path': str(archive), 'size': str(stat.st_size),
                                    'modified': ticks}], 'directories': [str(output)],
                        'result_file': str(prior)}]
            (output / '.rj-name-map.json').write_text(json.dumps(receipt))
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
            config['extraction']['rj_password']['enabled'] = False
            config['extraction']['password_file'] = str(base / 'absent-passwords.txt')
            cfg = base / 'config.json'
            cfg.write_text(json.dumps(config), encoding='utf-8')
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'extract.ps1'),
                                     '-InputPath', str(archive), '-Run', '-OutputRoot', str(output),
                                     '-ConfigPath', str(cfg)], capture_output=True,
                                    encoding='utf-8', errors='replace', timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((output / 'RJ99999993' / 'track.txt').read_text(), 'payload')

    def test_extract_and_password_failures(self):
        with tempfile.TemporaryDirectory(prefix='bandizip_test_') as temp:
            base = pathlib.Path(temp)
            archive = base / 'sample.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr('日本語/音声.txt', 'test audio')
            def extract(source, dest, password='$null'):
                script = ". '{}' ; $r=Invoke-BandizipExtraction '{}' '{}' '{}' {} 932; exit $r.ExitCode".format(
                    ROOT / 'src/bandizip.ps1', BZ, source, dest, password)
                return subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True, timeout=30)
            self.assertEqual(extract(archive, base / 'out').returncode, 0)
            self.assertEqual((base / 'out/日本語/音声.txt').read_text(), 'test audio')
            encrypted = base / 'encrypted.zip'
            create = subprocess.run([str(BZ), 'c', '-p:secret', str(encrypted), str(base / 'out/日本語/音声.txt')], capture_output=True, timeout=30)
            self.assertEqual(create.returncode, 0)
            self.assertNotEqual(extract(encrypted, base / 'wrong', "'wrong'").returncode, 0)
            self.assertNotEqual(extract(encrypted, base / 'empty').returncode, 0)
            self.assertEqual(extract(encrypted, base / 'correct', "'secret'").returncode, 0)

    def test_corrupt_unencrypted_zip_fails_once_and_retains_partial_output(self):
        with tempfile.TemporaryDirectory(prefix='bandizip_corrupt_once_') as temp:
            base = pathlib.Path(temp)
            archive = base / 'RJ99999994.zip'
            payload = b'original audio payload' * 1000
            with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as z:
                z.writestr('track.wav', payload)
                item = z.getinfo('track.wav')
                offset = item.header_offset + 30 + len(item.filename.encode()) + len(item.extra)
            data = bytearray(archive.read_bytes())
            data[offset + 100] ^= 1
            archive.write_bytes(data)
            original = archive.read_bytes()
            passwords = base / 'passwords.txt'
            passwords.write_text('candidate-one\ncandidate-two\ncandidate-three\n')
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
            config['extraction']['rj_password']['enabled'] = False
            config['extraction']['password_file'] = str(passwords)
            cfg = base / 'config.json'
            cfg.write_text(json.dumps(config), encoding='utf-8')
            result_file = base / 'result.json'
            output = base / 'output'
            result = subprocess.run(
                ['pwsh', '-NoProfile', '-File', str(ROOT / 'extract.ps1'),
                 '-InputPath', str(archive), '-Run', '-OutputRoot', str(output),
                 '-ConfigPath', str(cfg), '-ResultFile', str(result_file)],
                capture_output=True, encoding='utf-8', errors='replace', timeout=30,
            )
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertEqual(result.stdout.count('开始解压：'), 1, result.stdout)
            manifest = json.loads(result_file.read_text(encoding='utf-8-sig'))
            self.assertEqual(manifest['failure_count'], 1)
            failure = manifest['failed_archives'][0]
            self.assertEqual(failure['status'], 'failed_extract')
            self.assertIn('不再更换密码重试', failure['reason'])
            partial = output / 'RJ99999994.__extracting__' / 'track.wav'
            self.assertTrue(partial.exists(), result.stdout + result.stderr)
            self.assertGreater(partial.stat().st_size, 0)
            self.assertFalse((output / 'RJ99999994' / '.extract_complete.json').exists())
            self.assertEqual(archive.read_bytes(), original)
            for password in passwords.read_text().splitlines():
                self.assertNotIn(password, result.stdout + result.stderr)

    def test_verified_encrypted_archive_extracts_with_selected_password(self):
        with tempfile.TemporaryDirectory(prefix='bandizip_verified_password_') as temp:
            base = pathlib.Path(temp)
            payload = base / 'track.txt'
            payload.write_text('verified audio payload')
            archive = base / 'RJ99999995.zip'
            created = subprocess.run(
                [str(BZ), 'c', '-p:correct-test-password', str(archive), str(payload)],
                capture_output=True, timeout=30,
            )
            self.assertEqual(created.returncode, 0, created.stderr)
            passwords = base / 'passwords.txt'
            passwords.write_text('wrong-one\ncorrect-test-password\nwrong-two\n')
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
            config['extraction']['rj_password']['enabled'] = False
            config['extraction']['password_file'] = str(passwords)
            cfg = base / 'config.json'
            cfg.write_text(json.dumps(config), encoding='utf-8')
            result_file = base / 'result.json'
            output = base / 'output'
            result = subprocess.run(
                ['pwsh', '-NoProfile', '-File', str(ROOT / 'extract.ps1'),
                 '-InputPath', str(archive), '-Run', '-OutputRoot', str(output),
                 '-ConfigPath', str(cfg), '-ResultFile', str(result_file)],
                capture_output=True, encoding='utf-8', errors='replace', timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.count('开始解压：'), 1, result.stdout)
            self.assertEqual((output / 'RJ99999995' / 'track.txt').read_text(), payload.read_text())
            manifest = json.loads(result_file.read_text(encoding='utf-8-sig'))
            self.assertEqual(manifest['failed_archives'], [])

if __name__ == '__main__':
    unittest.main()
