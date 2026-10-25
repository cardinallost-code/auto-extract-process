import json
import pathlib
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FFMPEG = shutil.which('ffmpeg')


@unittest.skipUnless(FFMPEG, 'FFmpeg required')
class LifecyclePipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lifecycle pipeline ')
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
        self.config['extraction'].update(engine='7zip', password_file=str(self.base / 'absent.txt'))
        self.config['extraction']['rj_password']['enabled'] = False
        self.config['naming'].update(enabled=True, cache_db=str(self.base / 'absent.db'),
                                     external_config=str(self.base / 'absent-settings.json'), online_fallback=False)
        copied = self.base / 'wav_to_mp3.ps1'
        shutil.copyfile(self.config['plugins']['wav_to_mp3']['script'], copied)
        launcher = self.base / 'convert.bat'
        shutil.copyfile(self.config['plugins']['wav_to_mp3']['launcher'], launcher)
        self.config['plugins']['wav_to_mp3'].update(script=str(copied), launcher=str(launcher))

    def audio(self, name):
        path = self.base / name
        result = subprocess.run([FFMPEG, '-nostdin', '-v', 'error', '-f', 'lavfi',
                                 '-i', 'sine=frequency=440:duration=1', str(path)], capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return path

    def pipeline(self, source, parallel=1):
        cfg = self.base / 'config.json'
        cfg.write_text(json.dumps(self.config), encoding='utf-8')
        # Keep stdin open: communicate()/DEVNULL would hide a BAT pause regression.
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen(['pwsh', '-NoProfile', '-File', str(ROOT / 'processing-pipeline.ps1'),
                                        '-InputPath', str(source), '-Run', '-OutputRoot', str(self.base / 'output'),
                                        '-MaxParallelProjects', str(parallel), '-ConfigPath', str(cfg)],
                                       stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT)
            try:
                process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True)
                process.wait(timeout=10)
                raise
            finally:
                process.stdin.close()
            output.seek(0)
            return subprocess.CompletedProcess(process.args, process.returncode,
                                               output.read().decode('utf-8', errors='replace'), '')

    def test_non_rj_full_pipeline_does_not_catch_up_failed_sibling(self):
        wav = self.audio('track.wav')
        source = self.base / '普通作品.zip'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.write(wav, 'track.wav')
        failed = self.base / 'output' / 'RJ99999991_2'
        failed.mkdir(parents=True)
        (failed / '.extract_complete.json').write_text('{"completed":"outer extraction only"}')
        sibling_wav = failed / 'leftover.wav'
        shutil.copyfile(wav, sibling_wav)
        original = sibling_wav.read_bytes()
        result = self.pipeline(source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(source.exists())
        self.assertTrue((self.base / 'output/普通作品/track.mp3').exists())
        self.assertFalse((self.base / 'output/普通作品/track.wav').exists())
        self.assertFalse((failed / 'leftover.mp3').exists())
        self.assertEqual(sibling_wav.read_bytes(), original)
        self.assertIn('not_applicable', result.stdout)
        self.assertIn('一键流水线全部完成', result.stdout)

    def test_naming_failure_does_not_print_all_complete_or_return_zero(self):
        mp3 = self.audio('track.mp3')
        source = self.base / 'RJ99999991.zip'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.write(mp3, 'track.mp3')
        result = self.pipeline(source)
        self.assertEqual(result.returncode, 10, result.stdout + result.stderr)
        self.assertNotIn('一键流水线全部完成', result.stdout)
        self.assertTrue((self.base / 'output/RJ99999991/track.mp3').exists())

    def test_wav_conversion_cleanup_and_real_rename_with_open_stdin(self):
        wav = self.audio('日本語 track.wav')
        source = self.base / 'RJ99999991.zip'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.write(wav, wav.name)
        cache = self.base / 'metadata.db'
        connection = sqlite3.connect(cache)
        try:
            connection.execute('CREATE TABLE workmetadatacache(rjcode TEXT, metadata TEXT)')
            connection.execute('INSERT INTO workmetadatacache VALUES (?, ?)', (
                'RJ99999991', json.dumps({'rjcode': 'RJ99999991', 'work_name': '回归验证', 'cvs': []})))
            connection.commit()
        finally:
            connection.close()
        settings = self.base / 'external.json'
        settings.write_text(json.dumps({'renamer_template': 'rjcode work_name'}), encoding='utf-8')
        self.config['naming'].update(cache_db=str(cache), external_config=str(settings))
        result = self.pipeline(source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        renamed = self.base / 'output/RJ99999991 回归验证'
        self.assertTrue((renamed / '日本語 track.mp3').is_file(), result.stdout)
        self.assertFalse((renamed / wav.name).exists())
        self.assertFalse((self.base / 'output/RJ99999991').exists())
        self.assertIn('renamed', result.stdout)
        self.assertIn('一键流水线全部完成', result.stdout)

    def test_parallel_unknown_wrappers_share_rj_target_without_duplicate_output(self):
        mp3 = self.audio('track.mp3')
        from test_extraction_lifecycle import zip_bytes
        source = self.base / 'inputs'
        source.mkdir()
        payload = zip_bytes({'track.mp3': mp3.read_bytes()})
        for name in ('first.zip', 'second.zip'):
            (source / name).write_bytes(zip_bytes({'RJ99999991.zip': payload}))
        self.config['naming']['enabled'] = False
        # Pass two explicit paths so the pipeline schedules independent unnamed project jobs.
        cfg = self.base / 'config.json'
        cfg.write_text(json.dumps(self.config), encoding='utf-8')
        driver = self.base / 'parallel.ps1'
        driver.write_text('''param($Tool,$Inputs,$Output,$Config)
$paths=@(Get-ChildItem -LiteralPath $Inputs -File | ForEach-Object FullName)
& $Tool -InputPath $paths -Run -OutputRoot $Output -ConfigPath $Config -MaxParallelProjects 2
exit $LASTEXITCODE
''')
        result = subprocess.run(['pwsh', '-NoProfile', '-File', str(driver), str(ROOT / 'processing-pipeline.ps1'),
                                 str(source), str(self.base / 'output'), str(cfg)],
                                capture_output=True, encoding='utf-8', errors='replace', timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        dirs = list((self.base / 'output').glob('RJ99999991*'))
        self.assertEqual(len(dirs), 1)
        self.assertEqual((dirs[0] / 'track.mp3').read_bytes(), mp3.read_bytes())
        self.assertFalse(any(source.glob('*.zip')))
        self.assertFalse((self.base / 'output/first').exists())
        self.assertFalse((self.base / 'output/second').exists())


if __name__ == '__main__':
    unittest.main()
