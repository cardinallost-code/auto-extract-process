import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('resolve_rj', ROOT / 'src/resolve_rj.py')
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


class ArchiveIdentityTests(unittest.TestCase):
    def test_identity_matches_resolver_and_gui_groups(self):
        cases = [
            ('01719814.7zkkk', 'RJ01719814'),
            ('01719814.7z.001', 'RJ01719814'),
            ('01719814.part1.rar', 'RJ01719814'),
            ('01719814 (1).7zkkk', 'RJ01719814'),
            ('１７１９８１４.7zkkk', 'RJ01719814'),
            ('ＲＪ０１７１９８１４.zip', 'RJ01719814'),
            ('G:/RJ01729599/01719814.7zkkk', 'RJ01719814'),
            ('G:/01719814/inner.zip', None),
            ('作品 01719814 特典.zip', None),
            ('017198140.7z', None),
            ('RJ017198140.7z', None),
            ('01719814', 'RJ01719814'),
        ]
        for text, expected in cases:
            with self.subTest(text=text):
                codes = resolver.extract_codes(text)
                self.assertEqual(codes[0] if codes else None, expected)
        with tempfile.TemporaryDirectory(prefix='archive_identity_') as temp:
            base = pathlib.Path(temp)
            cases_path = base / 'cases.json'
            cases_path.write_text(json.dumps(cases), encoding='utf-8')
            script = r'''
param([string]$Root, [string]$Cases)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $Root 'src/archive-identity.ps1')
$results = @(Get-Content -LiteralPath $Cases -Raw | ConvertFrom-Json | ForEach-Object {
    [pscustomobject]@{ path=$_[0]; code=(Get-RjCode $_[0]) }
})
$paths=@('01719814.7zkkk', 'RJ01719814.zip', '01719814.7z.001', '01719814.7z.002', '01729599.zip', 'notes.zip')
$groups=@(Get-ArchiveProjectGroups $paths)
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'extract-gui.ps1'),[ref]$null,[ref]$null)
$f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ProjectGroupCount'},$true)
. ([scriptblock]::Create($f.Extent.Text))
$inputList=[pscustomobject]@{Items=$paths}
@{results=$results; groups=$groups; gui_count=(Get-ProjectGroupCount)}|ConvertTo-Json -Depth 5
'''
            script_path = base / 'check.ps1'
            script_path.write_text(script, encoding='utf-8')
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(script_path), str(ROOT), str(cases_path)],
                                    capture_output=True, encoding='utf-8', errors='replace', timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual([r['code'] for r in data['results']], [e for _, e in cases])
            self.assertEqual(data['gui_count'], 3)
            self.assertEqual([g['Key'] for g in data['groups']], ['RJ01719814', 'RJ01729599', 'UNIDENTIFIED_1'])
            self.assertEqual(len(data['groups'][0]['Paths']), 4)

    def test_numeric_multiwork_wrapper_preserves_attachments_outside_work_roots(self):
        with tempfile.TemporaryDirectory(prefix='numeric_multiwork_') as temp:
            base = pathlib.Path(temp)
            archive = base / '01719814.7zkkk'
            import io
            with zipfile.ZipFile(archive, 'w') as outer:
                outer.writestr('3985.txt', 'preserve package attachment')
                for code in ('RJ01719814', 'RJ01729599'):
                    inner = io.BytesIO()
                    with zipfile.ZipFile(inner, 'w') as z:
                        z.writestr('Title/track.txt', code + ' payload')
                    outer.writestr(code + '.zip', inner.getvalue())
            original = archive.read_bytes()
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
            config['extraction']['rj_password']['enabled'] = False
            config['extraction']['keep_original_archives'] = True
            config['extraction']['password_file'] = str(base / 'absent.txt')
            cfg = base / 'config.json'
            cfg.write_text(json.dumps(config), encoding='utf-8')
            output = base / 'output'
            result_file = base / 'result.json'
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'extract.ps1'),
                                     '-InputPath', str(archive), '-Run', '-OutputRoot', str(output),
                                     '-ConfigPath', str(cfg), '-ResultFile', str(result_file)],
                                    capture_output=True, encoding='utf-8', errors='replace', timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((output / '01719814').exists(), result.stdout)
            for code in ('RJ01719814', 'RJ01729599'):
                self.assertEqual((output / code / 'track.txt').read_text(), code + ' payload')
            manifest = json.loads(result_file.read_text(encoding='utf-8-sig'))
            self.assertEqual(len(manifest['final_directories']), 2)
            self.assertEqual(archive.read_bytes(), original)
            target = next(line.split(' -> ', 1)[1] for line in result.stdout.splitlines()
                          if line.startswith('包装附件已保留到隔离区：'))
            target = pathlib.Path(target)
            self.assertEqual((target / '3985.txt').read_text(), 'preserve package attachment')
            receipt = json.loads(pathlib.Path(str(target) + '.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(receipt['path'], str(output / '01719814'))
            self.assertEqual(len(receipt['files']), 2)
            # Remove only this test's receipt and quarantined attachment files.
            for file in target.iterdir():
                file.unlink()
            target.rmdir()
            pathlib.Path(str(target) + '.json').unlink()

    def test_packaging_cleanup_rejects_media_incomplete_results_and_junctions(self):
        with tempfile.TemporaryDirectory(prefix='numeric_residue_guards_') as temp:
            base = pathlib.Path(temp)
            script = r'''
param([string]$Root, [string]$Base)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $Root 'src/archive-identity.ps1')
. (Join-Path $Root 'src/archive-cleanup.ps1')
$source=Join-Path $Base '01719814.7zkkk'
[IO.File]::WriteAllText($source,'source')
$wrapper=Join-Path $Base '01719814'
$final=Join-Path $Base 'RJ01719814'
$quarantine=Join-Path $Base 'quarantine'
New-Item -ItemType Directory -Path $wrapper,$final|Out-Null
@{source_name='01719814.7zkkk'; source_size=(Get-Item $source).Length; completed='test'}|ConvertTo-Json|Out-File (Join-Path $wrapper '.extract_complete.json')
[IO.File]::WriteAllText((Join-Path $wrapper 'notes.txt'),'keep attachment')
if (@(Move-CompletedNumericPackagingResidue $wrapper $source @($final) $quarantine).Count) {throw 'Incomplete final output accepted'}
[IO.File]::WriteAllText((Join-Path $final '.extract_complete.json'),'{}')
[IO.File]::WriteAllText((Join-Path $wrapper 'track.wav'),'keep media')
if (@(Move-CompletedNumericPackagingResidue $wrapper $source @($final) $quarantine).Count) {throw 'Audio residue moved'}
Remove-Item -LiteralPath (Join-Path $wrapper 'track.wav')
$external=Join-Path $Base 'external'
New-Item -ItemType Directory -Path $external|Out-Null
[IO.File]::WriteAllText((Join-Path $external 'keep.txt'),'external data')
$junction=Join-Path $wrapper '01719814'
New-Item -ItemType Junction -Path $junction -Target $external|Out-Null
if (@(Move-CompletedNumericPackagingResidue $wrapper $source @($final) $quarantine).Count) {throw 'Junction residue moved'}
if ((Get-Content -LiteralPath (Join-Path $external 'keep.txt') -Raw) -ne 'external data') {throw 'External data changed'}
Remove-Item -LiteralPath $junction
'''
            path = base / 'check.ps1'
            path.write_text(script, encoding='utf-8')
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(path), str(ROOT), str(base)],
                                    capture_output=True, encoding='utf-8', errors='replace', timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
