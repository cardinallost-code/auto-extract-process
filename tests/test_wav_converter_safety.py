"""Exercise the configured standalone WAV converter without touching real media."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
CONVERTER = Path(CONFIG['plugins']['wav_to_mp3']['script'])
FFMPEG = shutil.which('ffmpeg')
FFPROBE = shutil.which('ffprobe')


@unittest.skipUnless(CONVERTER.exists() and FFMPEG and FFPROBE, 'Configured converter and FFmpeg required')
class WavConverterSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wav_converter_safety_')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.script = self.base / 'converter' / 'wav_to_mp3.ps1'
        self.script.parent.mkdir()
        shutil.copyfile(CONVERTER, self.script)
        self.media = self.base / 'media'
        self.media.mkdir()

    def audio(self, relative):
        path = self.media / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        made = subprocess.run([FFMPEG, '-nostdin', '-v', 'error', '-f', 'lavfi',
                               '-i', 'sine=frequency=440:duration=2', str(path)],
                              capture_output=True, timeout=20)
        self.assertEqual(made.returncode, 0, made.stderr)
        return path

    def marker(self, directory, contents=None):
        (directory / '.extract_complete.json').write_text(json.dumps(
            contents if contents is not None else {'completed': '2026-10-10', 'normalized_to_rj': True}))

    def convert(self, *paths, auto=False, timeout=30, probe_timeout=None):
        env = dict(os.environ)
        env.pop('WAV_TO_MP3_AUTO', None)
        if auto:
            env['WAV_TO_MP3_AUTO'] = '1'
        args = ['pwsh', '-NoProfile', '-File', str(self.script)]
        if probe_timeout is not None:
            args += ['-ProbeTimeoutSeconds', str(probe_timeout)]
        result = subprocess.run([*args, *map(str, paths)],
                                capture_output=True, encoding='utf-8', errors='replace',
                                env=env, timeout=timeout)
        self.last_output = result.stdout + result.stderr
        return result

    def input_files(self):
        logs = sorted((self.script.parent / 'logs').glob('wav输入清单_*.txt'))
        return logs[-1].read_text(encoding='utf-8-sig').splitlines()

    def test_auto_catchup_excludes_failed_wrapper_but_keeps_valid_arbitrary_work(self):
        primary = self.audio('RJ99999991/normal.wav')
        valid = self.audio('ordinary completed folder/日本語 track.wav')
        failed = self.audio('RJ99999992.7zzzzz/RJ99999992.__extracting__/partial.wav')
        self.marker(primary.parent)
        self.marker(valid.parent)
        self.marker(failed.parents[1], {'completed': '2026-10-10', 'extracted_in_place': False})
        failed_before = failed.read_bytes()
        result = self.convert(primary.parent, auto=True)
        self.assertEqual(result.returncode, 0, self.last_output)
        self.assertEqual(set(self.input_files()), {str(primary), str(valid)})
        self.assertTrue(valid.with_suffix('.mp3').exists())
        self.assertFalse(failed.with_suffix('.mp3').exists())
        self.assertEqual(failed.read_bytes(), failed_before)
        self.assertIn('自动补漏跳过', result.stdout)

    def test_manual_input_can_convert_arbitrary_wav_even_in_temporary_named_directory(self):
        wav = self.audio('arbitrary.__extracting__/手动.wav')
        before = wav.read_bytes()
        result = self.convert(wav)
        self.assertEqual(result.returncode, 0, self.last_output)
        self.assertEqual(wav.read_bytes(), before)
        self.assertTrue(wav.with_suffix('.mp3').exists())

    def test_auto_explicit_root_excludes_nested_temporary_wav(self):
        normal = self.audio('plain folder/normal.wav')
        failed = self.audio('plain folder/nested.__extracting__/partial.wav')
        result = self.convert(normal.parent, auto=True)
        self.assertEqual(result.returncode, 0, self.last_output)
        self.assertEqual(self.input_files(), [str(normal)])
        self.assertFalse(failed.with_suffix('.mp3').exists())

    def test_invalid_source_is_preserved_and_other_files_continue(self):
        normal = self.audio('inputs/normal.wav')
        invalid = normal.parent / 'broken.wav'
        invalid.write_bytes(b'not a wave file')
        existing = invalid.with_suffix('.mp3')
        existing.write_bytes(b'preserve existing output')
        result = self.convert(normal.parent)
        self.assertEqual(result.returncode, 1, self.last_output)
        self.assertTrue(normal.with_suffix('.mp3').exists())
        self.assertEqual(invalid.read_bytes(), b'not a wave file')
        self.assertEqual(existing.read_bytes(), b'preserve existing output')
        failures = list((self.script.parent / 'logs').glob('wav转换失败_*.txt'))
        self.assertIn('ffprobe 探测失败', failures[0].read_text(encoding='utf-8-sig'))
        self.assertEqual(list(normal.parent.glob('*.tmp.mp3')), [])

    def test_malformed_zero_chunk_tail_times_out_without_conversion_or_orphan(self):
        slow = self.audio('inputs/slow.wav')
        normal = self.audio('inputs/normal.wav')
        # Reproduce the incident: RIFF/data lengths stay small, a large zero tail
        # causes ffprobe to walk millions of bogus zero-sized chunks.
        with slow.open('r+b') as stream:
            stream.truncate(512 * 1024 * 1024)
        before = (slow.stat().st_size, slow.stat().st_mtime_ns)
        start = time.monotonic()
        result = self.convert(slow.parent, timeout=15, probe_timeout=1)
        self.assertEqual(result.returncode, 1, self.last_output)
        self.assertLess(time.monotonic() - start, 10)
        self.assertIn('超过 1 秒', self.last_output)
        self.assertFalse(slow.with_suffix('.mp3').exists())
        self.assertTrue(normal.with_suffix('.mp3').exists())
        self.assertEqual((slow.stat().st_size, slow.stat().st_mtime_ns), before)
        failures = list((self.script.parent / 'logs').glob('wav转换失败_*.txt'))
        self.assertIn('124', failures[0].read_text(encoding='utf-8-sig'))
        check = subprocess.run(['pwsh', '-NoProfile', '-Command',
                                'Get-CimInstance Win32_Process -Filter "Name=\'ffprobe.exe\'" | '
                                'Select-Object -ExpandProperty CommandLine'],
                               capture_output=True, encoding='utf-8', errors='replace', timeout=10)
        self.assertNotIn(str(slow), check.stdout)

    def test_valid_existing_mp3_is_reused(self):
        wav = self.audio('inputs/normal.wav')
        result = self.convert(wav)
        self.assertEqual(result.returncode, 0, self.last_output)
        mp3 = wav.with_suffix('.mp3')
        digest = hashlib.sha256(mp3.read_bytes()).hexdigest()
        result = self.convert(wav)
        self.assertEqual(result.returncode, 0, self.last_output)
        self.assertIn('已存在跳过：1', result.stdout)
        self.assertEqual(hashlib.sha256(mp3.read_bytes()).hexdigest(), digest)

    def test_original_drag_drop_multiple_positional_files_uses_default_timeout(self):
        files = [self.audio(f'日本語 long folder/track {i}.wav') for i in range(7)]
        result = self.convert(*files)
        self.assertEqual(result.returncode, 0, self.last_output)
        self.assertEqual(set(self.input_files()), set(map(str, files)))
        self.assertTrue(all(wav.with_suffix('.mp3').exists() for wav in files))
        summary = next((self.script.parent / 'logs').glob('wav转换汇总_*.txt'))
        self.assertIn('单次音频探测超时：30 秒', summary.read_text(encoding='utf-8-sig'))

    def test_original_bat_launcher_binds_multiple_paths_without_named_arguments(self):
        launcher = Path(CONFIG['plugins']['wav_to_mp3']['launcher'])
        shutil.copyfile(launcher, self.script.with_suffix('.bat'))
        files = [self.audio(f'日本語 spaced folder/{i} audio.wav') for i in range(2)]
        env = dict(os.environ, WAV_TO_MP3_AUTO='1')
        # cmd.exe uses its own quote rules, rather than C runtime argv escaping.
        command = 'cmd.exe /d /s /c "' + ' '.join(
            f'"{path}"' for path in [self.script.with_suffix('.bat'), *files]) + '"'
        result = subprocess.run(command, env=env,
                                capture_output=True, encoding='utf-8', errors='replace', timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(set(self.input_files()), set(map(str, files)))
        self.assertTrue(all(wav.with_suffix('.mp3').exists() for wav in files))

    def test_completion_marker_rejects_explicit_failure_and_invalid_json(self):
        primary = self.audio('inputs/normal.wav')
        failed = self.audio('failed/one.wav')
        invalid = self.audio('invalid/two.wav')
        self.marker(failed.parent, {'success': False, 'failure_count': 1})
        (invalid.parent / '.extract_complete.json').write_text('{broken')
        result = self.convert(primary.parent, auto=True)
        self.assertEqual(result.returncode, 0, self.last_output)
        self.assertEqual(self.input_files(), [str(primary)])
        self.assertFalse(failed.with_suffix('.mp3').exists())
        self.assertFalse(invalid.with_suffix('.mp3').exists())


if __name__ == '__main__':
    unittest.main()
