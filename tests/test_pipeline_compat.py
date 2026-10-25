import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class PipelineCompatibilityTests(unittest.TestCase):
    def merge_jobs(self, entries, expected=None):
        with tempfile.TemporaryDirectory(prefix='pipeline_merge_') as temp:
            base = pathlib.Path(temp)
            jobs = []
            for index, (code, manifest) in enumerate(entries):
                path = base / f'{index}.json'
                if manifest is not None:
                    path.write_text(manifest if isinstance(manifest, str) else json.dumps(manifest), encoding='utf-8')
                jobs.append({'exit_code': code, 'result_file': str(path), 'paths': [f'input{index}.zip']})
            job_path = base / 'jobs.json'
            job_path.write_text(json.dumps(jobs), encoding='utf-8')
            quote = lambda p: "'" + str(p).replace("'", "''") + "'"
            script = f'''
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$ast=[Management.Automation.Language.Parser]::ParseFile({quote(ROOT / 'processing-pipeline.ps1')},[ref]$null,[ref]$null)
foreach ($name in @('Get-OptionalPropertyItems', 'Merge-ExtractionJobResults')) {{
    $f=$ast.Find({{param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}},$true)
    . ([scriptblock]::Create($f.Extent.Text))
}}
$jobs = @(Get-Content -LiteralPath {quote(job_path)} -Raw | ConvertFrom-Json)
Merge-ExtractionJobResults -Jobs $jobs -ExpectedCount {len(entries) if expected is None else expected} | ConvertTo-Json -Depth 8
'''
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True,
                                    encoding='utf-8', errors='replace', timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(result.stdout)

    def test_all_jobs_fail_without_manifests(self):
        merged = self.merge_jobs([(1, None), (1, None)])
        self.assertEqual(merged['exit_code'], 1)
        self.assertEqual(merged['final_directories'], [])
        self.assertEqual(len(merged['failed_archives']), 2)

    def test_missing_corrupt_or_invalid_manifest_is_fatal(self):
        for manifest in (None, '{broken', {}, {'failure_count': 0, 'final_directories': 'x'}):
            with self.subTest(manifest=manifest):
                merged = self.merge_jobs([(0, manifest)])
                self.assertEqual(merged['exit_code'], 1)
                self.assertFalse(merged['success'])
                self.assertEqual(merged['failed_archives'][0]['archive'], 'input0.zip')

    def test_partial_failure_preserves_valid_directories(self):
        merged = self.merge_jobs([
            (0, {'final_directories': ['a'], 'failure_count': 0}),
            (2, {'final_directories': ['b', 'a'], 'failure_count': 1}),
        ])
        self.assertEqual(merged['exit_code'], 2)
        self.assertEqual(merged['final_directories'], ['a', 'b'])
        self.assertEqual(merged['source_archives'], [])

    def test_warning_exit_cannot_be_reported_as_success(self):
        merged = self.merge_jobs([(2, {'final_directories': ['a'], 'failure_count': 0})])
        self.assertEqual(merged['exit_code'], 2)
        self.assertFalse(merged['success'])

    def test_missing_worker_is_fatal(self):
        merged = self.merge_jobs([], expected=1)
        self.assertEqual(merged['exit_code'], 1)
        self.assertEqual(merged['failed_archives'][0]['status'], 'missing_job')

    def test_success_preserves_sources(self):
        source = {'path': 'input.zip', 'size': 123}
        merged = self.merge_jobs([(0, {'final_directories': ['a'], 'failure_count': 0,
                                      'source_archives': [source]})])
        self.assertEqual(merged['exit_code'], 0)
        self.assertTrue(merged['success'])
        self.assertEqual(merged['source_archives'], [source])

    def test_missing_failed_archives_is_empty(self):
        script = r'''
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$ast=[Management.Automation.Language.Parser]::ParseFile('PIPELINE',[ref]$null,[ref]$null)
$f=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-OptionalPropertyItems'},$true)
. ([scriptblock]::Create($f.Extent.Text))
$old=[pscustomobject]@{failure_count=0; final_directories=@('x')}
@{count=@(Get-OptionalPropertyItems $old 'failed_archives').Count} | ConvertTo-Json
'''.replace('PIPELINE', str(ROOT / 'processing-pipeline.ps1'))
        result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True,
                                encoding='utf-8', errors='replace', timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['count'], 0)


if __name__ == '__main__':
    unittest.main()
