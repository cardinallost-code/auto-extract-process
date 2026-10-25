import json
import pathlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

class EncodedInfo(zipfile.ZipInfo):
    def _encodeFilenameFlags(self):
        return self.filename.encode(self.legacy_encoding), 0

class EncodingTests(unittest.TestCase):
    def detect(self, name, encoding=None):
        with tempfile.TemporaryDirectory(prefix='encoding_test_') as temp:
            archive = pathlib.Path(temp) / 'test.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                if encoding:
                    info = EncodedInfo(name)
                    info.legacy_encoding = encoding
                    z.writestr(info, b'payload')
                else:
                    z.writestr(name, b'payload')
            script = ". '{}' ; Resolve-ZipFilenameEncoding '{}' 932 | ConvertTo-Json".format(
                ROOT / 'src/archive-encoding.ps1', archive)
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True,
                                    encoding='utf-8', errors='replace', timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(result.stdout)

    def test_japanese_default(self):
        self.assertEqual(self.detect('音声/こんにちは世界.wav', 'cp932')['CodePage'], 932)

    def test_unicode_flag_preserved(self):
        self.assertEqual(self.detect('日本語/中文/😀.wav')['Reason'], 'utf8_metadata')

    def test_unflagged_utf8(self):
        decision = self.detect('こんにちは世界/日本語の音声です.wav', 'utf-8')
        self.assertEqual(decision['CodePage'], 65001, decision)

    def test_ascii_does_not_switch(self):
        self.assertEqual(self.detect('track01.wav', 'ascii')['Reason'], 'default')

    def test_ambiguous_chinese_keeps_default(self):
        decision = self.detect('简体中文测试文件/声音.wav', 'gbk')
        self.assertEqual(decision['CodePage'], 932)
        self.assertEqual(decision['Reason'], 'ambiguous_kept_default')

if __name__ == '__main__':
    unittest.main()
