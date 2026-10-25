"""Use the actual BAT with a stub converter and an open stdin pipe."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))


class WavLauncherPauseTests(unittest.TestCase):
    def run_launcher(self, no_pause, converter_code=0, missing_script=False):
        with tempfile.TemporaryDirectory(prefix='wav launcher 日本語 ') as directory:
            root = Path(directory)
            launcher = root / 'wav_to_mp3.bat'
            shutil.copyfile(CONFIG['plugins']['wav_to_mp3']['launcher'], launcher)
            if not missing_script:
                (root / 'wav_to_mp3.ps1').write_text(
                    f"Write-Output 'CONVERTER_DONE'; exit {converter_code}", encoding='utf-8')
            env = dict(os.environ, WAV_TO_MP3_AUTO='0')
            env.pop('WAV_TO_MP3_NO_PAUSE', None)
            if no_pause:
                env['WAV_TO_MP3_NO_PAUSE'] = '1'
            with tempfile.TemporaryFile() as output:
                process = subprocess.Popen(
                    ['cmd', '/c', str(launcher), 'dummy'],
                    stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env)
                try:
                    if not no_pause:
                        with self.assertRaises(subprocess.TimeoutExpired):
                            process.wait(timeout=3)
                        process.stdin.write(b'\n')
                        process.stdin.flush()
                    process.wait(timeout=10)
                finally:
                    if process.poll() is None:
                        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                                       capture_output=True)
                        process.wait(timeout=10)
                    process.stdin.close()
                output.seek(0)
                return process.returncode, output.read().decode('utf-8', errors='replace')

    def test_unattended_success_returns_without_key(self):
        code, output = self.run_launcher(True)
        self.assertEqual(code, 0, output)
        self.assertIn('CONVERTER_DONE', output)

    def test_unattended_failure_preserves_exit_code(self):
        code, output = self.run_launcher(True, converter_code=2)
        self.assertEqual(code, 2, output)

    def test_missing_script_returns_without_key(self):
        code, output = self.run_launcher(True, missing_script=True)
        self.assertEqual(code, 1, output)

    def test_manual_launch_still_waits_for_key(self):
        code, output = self.run_launcher(False)
        self.assertEqual(code, 0, output)
        self.assertIn('CONVERTER_DONE', output)


if __name__ == '__main__':
    unittest.main()
