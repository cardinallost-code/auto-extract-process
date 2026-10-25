import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CleanupTests(unittest.TestCase):
    def run_collapse(self, roots, warning_length=240):
        quoted = ','.join("'{}'".format(str(path).replace("'", "''")) for path in roots)
        script = ". '{}' ; Collapse-PackagingDirectories -Roots @({}) -PathWarningLength {} | ConvertTo-Json".format(
            ROOT / 'src/archive-cleanup.ps1', quoted, warning_length)
        return subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True,
                              encoding='utf-8', errors='replace')

    def test_collapses_repeated_rj_and_long_single_wrapper(self):
        with tempfile.TemporaryDirectory(prefix='rj_collapse_test_') as temp:
            base = pathlib.Path(temp)
            repeated = base / 'RJ99999991 Formal title'
            inner = repeated / 'RJ99999991 Original title' / 'RJ99999991 Original title'
            inner.mkdir(parents=True)
            (inner / 'audio.wav').write_bytes(b'audio')

            long_root = base / ('RJ99999992 ' + 'A' * 40)
            wrapper = long_root / ('Different package title ' + 'B' * 50)
            wrapper.mkdir(parents=True)
            (long_root / '.extract_complete.json').write_text('{}')
            (wrapper / 'track.wav').write_bytes(b'audio')

            result = self.run_collapse([repeated, long_root], warning_length=150)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((repeated / 'audio.wav').exists())
            self.assertTrue((long_root / 'track.wav').exists())
            self.assertFalse((repeated / 'RJ99999991 Original title').exists())
            self.assertFalse(wrapper.exists())

    def test_preserves_semantic_directory_and_conflict(self):
        with tempfile.TemporaryDirectory(prefix='rj_collapse_safe_test_') as temp:
            base = pathlib.Path(temp)
            semantic = base / 'RJ99999993 Title'
            wav = semantic / '01_wav'
            wav.mkdir(parents=True)
            (wav / 'track.wav').write_bytes(b'audio')

            conflict = base / 'RJ99999994 Title'
            wrapper = conflict / 'RJ99999994 Package'
            wrapper.mkdir(parents=True)
            (conflict / 'track.wav').write_bytes(b'parent')
            (wrapper / 'track.wav').write_bytes(b'child')

            result = self.run_collapse([semantic, conflict])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(wav.exists())
            self.assertEqual((conflict / 'track.wav').read_bytes(), b'parent')
            self.assertEqual((wrapper / 'track.wav').read_bytes(), b'child')

    def test_repeated_wrapper_junction_preserves_external_files(self):
        with tempfile.TemporaryDirectory(prefix='rj_junction_test_') as temp:
            base = pathlib.Path(temp)
            root = base / 'RJ99999991'
            wrapper = root / 'RJ99999991'
            wrapper.mkdir(parents=True)
            outside = base / 'outside'
            outside.mkdir()
            payload = outside / 'keep.txt'
            payload.write_text('must stay outside')
            link = wrapper / wrapper.name
            quote = lambda p: "'" + str(p).replace("'", "''") + "'"
            setup = subprocess.run(
                ['pwsh', '-NoProfile', '-Command',
                 f"$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path {quote(link)} -Target {quote(outside)} | Out-Null"],
                capture_output=True, encoding='utf-8', errors='replace', timeout=30)
            self.assertEqual(setup.returncode, 0, setup.stdout + setup.stderr)
            try:
                result = self.run_collapse([root])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(payload.exists(), result.stdout + result.stderr)
                self.assertEqual(payload.read_text(), 'must stay outside')
                self.assertTrue(link.is_junction())
                self.assertFalse((root / 'keep.txt').exists())
            finally:
                if link.is_junction():
                    link.rmdir()

    def test_cover_wrapper_and_conflict(self):
        for conflict in (False, True):
            with self.subTest(conflict=conflict), tempfile.TemporaryDirectory(prefix='rj_cover_test_') as temp:
                root = pathlib.Path(temp) / 'RJ99999991 Title'
                wrapper = root / 'RJ99999991 [Maker] Title.part1'
                inner = wrapper / 'RJ99999991 [Maker] Title'
                inner.mkdir(parents=True)
                (root / '.extract_complete.json').write_text(json.dumps({'normalized_to_rj': True}))
                (wrapper / '.extract_complete.json').write_text(json.dumps({'source_name': 'RJ99999991 [Maker] Title.part1.exe', 'completed': '2026-08-27'}))
                cover = inner / 'cover.jpg'
                cover.write_bytes(b'original cover')
                if conflict:
                    (root / 'cover.jpg').write_bytes(b'other cover')
                script = r'''
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. 'HELPER'
$ast=[System.Management.Automation.Language.Parser]::ParseFile('EXTRACT',[ref]$null,[ref]$null)
$function=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ArchiveBaseName'},$true)
. ([scriptblock]::Create($function.Extent.Text))
if ((Get-ArchiveBaseName 'Title.part1.exe') -ne 'Title') { throw 'Bad first volume basename' }
Repair-SplitCoverWrappers -Root 'WORK' | ConvertTo-Json
'''.replace('HELPER', str(ROOT / 'src/archive-cleanup.ps1')).replace('EXTRACT', str(ROOT / 'extract.ps1')).replace('WORK', str(root))
                result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True, encoding='utf-8', errors='replace')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((root / '.extract_complete.json').exists())
                if conflict:
                    self.assertEqual(cover.read_bytes(), b'original cover')
                    self.assertEqual((root / 'cover.jpg').read_bytes(), b'other cover')
                else:
                    self.assertFalse(wrapper.exists())
                    self.assertEqual((root / 'cover.jpg').read_bytes(), b'original cover')

    def test_marker_proof_and_empty_wrapper_boundaries(self):
        with tempfile.TemporaryDirectory(prefix='rj_cleanup_test_') as temp:
            base = pathlib.Path(temp)
            work = base / 'RJ99999991 Title'
            work.mkdir()
            expanded = work / 'Package.part1'
            expanded.mkdir()
            (expanded / '.extract_complete.json').write_text(json.dumps({
                'source_name': 'Package.part1.exe', 'source_size': 123, 'completed': '2026-08-27T00:00:00'}), encoding='utf-8')
            remainder = work / 'Package.part2.rar'
            remainder.write_bytes(b'test')
            unknown = work / 'Unknown.part2.rar'
            unknown.write_bytes(b'preserve')
            empty = work / 'RJ99999991'
            empty.mkdir()
            ordinary = work / 'wav'
            ordinary.mkdir()
            protected = expanded / 'RJ99999991'
            protected.mkdir()
            (protected / '.hidden').write_text('preserve')
            original = base / 'Package.part2.rar'
            original.write_bytes(b'outer')
            script = r'''
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. 'HELPER'
$ast=[System.Management.Automation.Language.Parser]::ParseFile('EXTRACT',[ref]$null,[ref]$null)
$function=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ArchiveBaseName'},$true)
. ([scriptblock]::Create($function.Extent.Text))
Repair-CompletedArchiveCleanup -Roots @('WORK') -DeleteParts $true | ConvertTo-Json
'''.replace('HELPER', str(ROOT / 'src/archive-cleanup.ps1')).replace('EXTRACT', str(ROOT / 'extract.ps1')).replace('WORK', str(work))
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True, encoding='utf-8', errors='replace')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(remainder.exists())
            self.assertFalse(empty.exists())
            for path in (unknown, ordinary, protected, original, work):
                self.assertTrue(path.exists(), str(path))
            again = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True, encoding='utf-8', errors='replace')
            self.assertEqual(again.returncode, 0, again.stdout + again.stderr)

    def test_split_groups(self):
        with tempfile.TemporaryDirectory(prefix='rj_parts_test_') as temp:
            root = pathlib.Path(temp)
            for name in ('A.part1.exe', 'A.part2.rar', 'A.part3.r', 'AB.part2.rar', 'B.7z.001', 'B.7z.002', 'Other.txt'):
                (root / name).write_bytes(b'test')
            script = ". '{}' ; @(Get-ArchivePartFiles '{}').Name | ConvertTo-Json".format(
                ROOT / 'src/archive-cleanup.ps1', root / 'A.part1.exe')
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True, encoding='utf-8')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(set(json.loads(result.stdout)), {'A.part1.exe', 'A.part2.rar', 'A.part3.r'})
            script = script.replace('A.part1.exe', 'B.7z.001')
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True, encoding='utf-8')
            self.assertEqual(set(json.loads(result.stdout)), {'B.7z.001', 'B.7z.002'})


if __name__ == '__main__':
    unittest.main()
