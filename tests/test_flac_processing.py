import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
FFMPEG = shutil.which('ffmpeg')
FFPROBE = shutil.which('ffprobe')


@unittest.skipUnless(FFMPEG and FFPROBE, 'FFmpeg and ffprobe are required')
class FlacProcessingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='flac_processing_')
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)

    def audio(self, path, duration=3, codec=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        args = [FFMPEG, '-nostdin', '-v', 'error', '-f', 'lavfi',
                '-i', f'sine=frequency=440:duration={duration}', '-ar', '44100']
        if path.suffix.lower() == '.mp3':
            args += ['-c:a', 'libmp3lame', '-b:a', '96k']
        elif codec:
            args += ['-c:a', codec]
        made = subprocess.run(args + [str(path)], capture_output=True, timeout=30)
        self.assertEqual(made.returncode, 0, made.stderr)
        return path

    def run_processor(self, root, run=True):
        args = ['pwsh', '-NoProfile', '-File', str(ROOT / 'file-process.ps1'), '-InputPath', str(root)]
        if run:
            args.append('-Run')
        return subprocess.run(args, capture_output=True, encoding='utf-8', errors='replace', timeout=60)

    def test_native_mp3_deletes_wav_and_flac_and_keeps_other_files(self):
        root = self.base / 'RJ99999991'
        flac = self.audio(root / '本編/FLAC/01 track.FLAC', codec='flac')
        wav = self.audio(root / '本編/WAV/01 track.wav')
        mp3 = self.audio(root / '本編/MP3/01 track.mp3')
        original_mp3 = mp3.read_bytes()
        notes = flac.parent / 'notes.txt'
        notes.write_text('keep notes')
        result = self.run_processor(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(flac.exists())
        self.assertFalse(wav.exists())
        self.assertEqual(mp3.read_bytes(), original_mp3)
        self.assertEqual(notes.read_text(), 'keep notes')
        self.assertIn('删除 FLAC：1', result.stdout)
        self.assertIn('删除 WAV：1', result.stdout)

    def test_flac_only_work_converts_to_320k_before_deletion(self):
        root = self.base / 'plain-audio-folder'
        flac = self.audio(root / 'FLAC/01 track.flac', codec='flac')
        result = self.run_processor(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(flac.exists())
        mp3 = flac.with_suffix('.mp3')
        self.assertTrue(mp3.exists())
        probe = subprocess.run([FFPROBE, '-v', 'error', '-select_streams', 'a:0',
                                '-show_entries', 'stream=codec_name,bit_rate', '-of', 'json', str(mp3)],
                               capture_output=True, text=True, timeout=30)
        stream = json.loads(probe.stdout)['streams'][0]
        self.assertEqual(stream['codec_name'], 'mp3')
        self.assertEqual(int(stream['bit_rate']), 320000)
        self.assertEqual(list(root.rglob('.flac_convert_*')), [])

    def test_preview_keeps_flac_and_mp3(self):
        root = self.base / 'RJ99999992'
        flac = self.audio(root / 'FLAC/01.flac', codec='flac')
        mp3 = self.audio(root / 'MP3/01.mp3')
        before = (flac.read_bytes(), mp3.read_bytes())
        result = self.run_processor(root, run=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((flac.read_bytes(), mp3.read_bytes()), before)
        self.assertIn('删除 FLAC', result.stdout)

    def test_bad_flac_conversion_preserves_source(self):
        root = self.base / 'RJ99999993'
        root.mkdir()
        flac = root / '01.flac'
        flac.write_bytes(b'fLaCinvalid source data')
        before = flac.read_bytes()
        result = self.run_processor(root)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(flac.read_bytes(), before)
        self.assertFalse(flac.with_suffix('.mp3').exists())
        self.assertEqual(list(root.rglob('.flac_convert_*')), [])

    def test_wrong_duration_existing_mp3_is_not_overwritten(self):
        root = self.base / 'RJ99999994'
        flac = self.audio(root / '01.flac', codec='flac')
        mp3 = self.audio(root / '01.mp3', duration=6)
        before = (flac.read_bytes(), mp3.read_bytes())
        result = self.run_processor(root)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual((flac.read_bytes(), mp3.read_bytes()), before)

    def test_effects_variant_mp3_is_not_used_for_flac(self):
        root = self.base / 'RJ99999995'
        flac = self.audio(root / 'SEなし/FLAC/01.flac', codec='flac')
        mp3 = self.audio(root / 'SEあり/MP3/01.mp3')
        before = mp3.read_bytes()
        result = self.run_processor(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('匹配到有效原生 MP3：0', result.stdout)
        self.assertTrue(flac.with_suffix('.mp3').exists())
        self.assertEqual(mp3.read_bytes(), before)

    def test_software_work_keeps_flac(self):
        root = self.base / 'RJ99999996'
        flac = self.audio(root / '01.flac', codec='flac')
        (root / 'game.exe').write_bytes(b'protected executable')
        before = flac.read_bytes()
        result = self.run_processor(root)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(flac.read_bytes(), before)
        self.assertFalse(flac.with_suffix('.mp3').exists())


if __name__ == '__main__':
    unittest.main()
