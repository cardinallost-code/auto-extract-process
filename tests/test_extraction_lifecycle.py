import io
import json
import pathlib
import subprocess
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def zip_bytes(entries):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w') as archive:
        for name, content in entries.items():
            archive.writestr(name, content)
    return stream.getvalue()


class ExtractionLifecycleTests(unittest.TestCase):
    def run_extract(self, base, paths, keep=False, to_source=False, preview=False):
        config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8-sig'))
        config['extraction'].update(engine='7zip', keep_original_archives=keep,
                                    password_file=str(base / 'absent.txt'))
        config['extraction']['rj_password']['enabled'] = False
        cfg = base / 'config.json'
        cfg.write_text(json.dumps(config), encoding='utf-8')
        spec = base / 'inputs.json'
        spec.write_text(json.dumps([str(p) for p in paths]), encoding='utf-8')
        driver = base / 'run.ps1'
        driver.write_text('''param($Tool,$Spec,$Output,$Config,$Result)
$paths=@(Get-Content -LiteralPath $Spec -Raw | ConvertFrom-Json)
& $Tool -InputPath $paths RUN SWITCH -ConfigPath $Config -ResultFile $Result
exit $LASTEXITCODE
'''.replace('RUN', '' if preview else '-Run').replace('SWITCH', '-ExtractToSource' if to_source else '-OutputRoot $Output'), encoding='utf-8')
        result = subprocess.run(['pwsh', '-NoProfile', '-File', str(driver), str(ROOT / 'extract.ps1'),
                                 str(spec), str(base / 'output'), str(cfg), str(base / 'result.json')],
                                capture_output=True, encoding='utf-8', errors='replace', timeout=60)
        manifest_path = base / 'result.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig')) if manifest_path.exists() else {}
        return result, manifest

    def test_plain_non_rj_archive_deletes_original_and_registers_work(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            source = base / '普通作品.zip'
            source.write_bytes(zip_bytes({'Title/track.txt': b'payload'}))
            result, manifest = self.run_extract(base, [source])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(source.exists())
            self.assertEqual(manifest['final_directories'], [str(base / 'output' / '普通作品')])
            self.assertTrue((base / 'output' / '普通作品' / 'Title' / 'track.txt').exists())

    def test_unknown_wrapper_discovers_rj_and_cleans_marker_only_layers(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            source = base / '下载文件.zip'
            source.write_bytes(zip_bytes({'date/RJ99999991.zip': zip_bytes({'Title/a.txt': b'a'})}))
            result, manifest = self.run_extract(base, [source])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(source.exists())
            self.assertFalse((base / 'output' / '下载文件').exists())
            self.assertEqual((base / 'output' / 'RJ99999991' / 'a.txt').read_bytes(), b'a')

    def test_nested_unknown_multiwork_and_numeric_identity(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            source = base / '合集.zip'
            source.write_bytes(zip_bytes({
                'day/甲.zip': zip_bytes({'Title/a.txt': b'a'}),
                'day/乙.zip': zip_bytes({'Title/b.txt': b'b'}),
                'day/01719814.zip': zip_bytes({'Title/c.txt': b'c'}),
            }))
            result, manifest = self.run_extract(base, [source])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(source.exists())
            self.assertFalse((base / 'output' / '合集').exists())
            self.assertEqual({pathlib.Path(p).name for p in manifest['final_directories']}, {'甲', '乙', 'RJ01719814'})

    def test_rj_duplicate_wrapper_merges_identical_and_unique_files(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            payload = zip_bytes({'Album/a.txt': b'a'})
            first = base / 'RJ99999991.zip'
            first.write_bytes(payload)
            second = base / 'RJ99999991_2.zip'
            second.write_bytes(zip_bytes({'RJ99999991.zip': zip_bytes({'Album/a.txt': b'a', 'Album/bonus.txt': b'bonus'})}))
            result, manifest = self.run_extract(base, [first, second])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            work = base / 'output' / 'RJ99999991'
            self.assertEqual((work / 'Album/a.txt').read_bytes(), b'a')
            self.assertEqual((work / 'Album/bonus.txt').read_bytes(), b'bonus')
            self.assertFalse(first.exists())
            self.assertFalse(second.exists())
            self.assertFalse((base / 'output' / 'RJ99999991_2').exists())

    def test_conflict_preserves_both_sources_and_unmerged_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            first = base / 'RJ99999991.zip'
            first.write_bytes(zip_bytes({'Album/a.txt': b'original'}))
            second = base / 'RJ99999991_2.zip'
            second.write_bytes(zip_bytes({'RJ99999991.zip': zip_bytes({'Album/a.txt': b'different', 'Album/bonus.txt': b'bonus'})}))
            result, manifest = self.run_extract(base, [first, second])
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertTrue(first.exists())
            self.assertTrue(second.exists())
            self.assertEqual((base / 'output/RJ99999991/Album/a.txt').read_bytes(), b'original')
            self.assertTrue((base / 'output/RJ99999991_2/RJ99999991.zip').exists())
            self.assertFalse((base / 'output/RJ99999991/Album/bonus.txt').exists())

    def test_failed_child_keeps_outer_and_all_inner_packages(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            source = base / '合集.zip'
            source.write_bytes(zip_bytes({'good.zip': zip_bytes({'a.txt': b'a'}), 'bad.zip': b'broken'}))
            result, manifest = self.run_extract(base, [source])
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertTrue(source.exists())
            self.assertTrue((base / 'output/合集/good.zip').exists())
            self.assertTrue((base / 'output/合集/bad.zip').exists())

    def test_explicit_keep_original_still_cleans_nested_and_wrappers(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            source = base / 'transfer.zip'
            source.write_bytes(zip_bytes({'day/RJ99999991.zip': zip_bytes({'a.txt': b'a'})}))
            result, manifest = self.run_extract(base, [source], keep=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(source.exists())
            self.assertFalse((base / 'output/transfer').exists())

    def test_stale_marker_does_not_skip_changed_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            source = base / 'RJ99999991.zip'
            source.write_bytes(zip_bytes({'a.txt': b'a'}))
            result, _ = self.run_extract(base, [source], keep=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            source.write_bytes(zip_bytes({'a.txt': b'a', 'bonus.txt': b'bonus'}))
            result, _ = self.run_extract(base, [source], keep=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((base / 'output/RJ99999991/bonus.txt').read_bytes(), b'bonus')

    def test_no_extension_extract_to_source_avoids_original_path_collision(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            source = base / '普通作品'
            source.write_bytes(zip_bytes({'Title/a.txt': b'a'}))
            result, manifest = self.run_extract(base, [source], to_source=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            # Extension repair may normalize the source to .zip before choosing the output.
            self.assertFalse((base / '普通作品.zip').exists())
            self.assertTrue(pathlib.Path(manifest['final_directories'][0]).is_dir())

    def test_split_zip_deletes_all_original_volumes_after_commit(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            payload = base / 'payload.txt'
            payload.write_bytes(bytes(range(256)) * 40)
            made = subprocess.run([r'C:\Program Files\7-Zip\7z.exe', 'a', '-tzip', '-mx0', '-v1k',
                                   str(base / '分卷.zip'), str(payload)], capture_output=True, timeout=20)
            self.assertEqual(made.returncode, 0, made.stderr)
            parts = list(base.glob('分卷.zip.*'))
            self.assertGreater(len(parts), 1)
            result, manifest = self.run_extract(base, [base / '分卷.zip.001'])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(all(not part.exists() for part in parts))
            self.assertEqual((base / 'output/分卷/payload.txt').read_bytes(), payload.read_bytes())
            self.assertEqual(len(manifest['deleted_archives']), len(parts))

    def test_preview_keeps_original_and_does_not_create_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            source = base / '作品.zip'
            source.write_bytes(zip_bytes({'a.txt': b'a'}))
            result, _ = self.run_extract(base, [source], preview=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(source.exists())
            self.assertFalse((base / 'output').exists())

    def test_target_junction_keeps_source_and_external_contents(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            source = base / 'RJ99999991.zip'
            source.write_bytes(zip_bytes({'a.txt': b'a'}))
            external = base / 'external'
            external.mkdir()
            (external / 'keep.txt').write_bytes(b'keep')
            output = base / 'output'
            output.mkdir()
            link = output / 'RJ99999991'
            made = subprocess.run(['pwsh', '-NoProfile', '-Command',
                                   f"New-Item -ItemType Junction -Path '{link}' -Target '{external}' | Out-Null"],
                                  capture_output=True, timeout=20)
            self.assertEqual(made.returncode, 0)
            try:
                result, _ = self.run_extract(base, [source])
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertTrue(source.exists())
                self.assertEqual((external / 'keep.txt').read_bytes(), b'keep')
                self.assertFalse((external / 'a.txt').exists())
            finally:
                link.rmdir()

    def test_cleanup_preserves_ordinary_empty_directories_in_final_work(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            final = base / 'work'
            (final / 'wav').mkdir(parents=True)
            (final / '包装层' / 'date').mkdir(parents=True)
            (final / '包装层' / '.extract_complete.json').write_text('{}')
            (final / '.extract_complete.json').write_text('{}')
            script = f". '{ROOT / 'src/extraction-lifecycle.ps1'}'; Remove-CompletedPackagingTrees -Roots @('{final}') -FinalDirectories @('{final}') | ConvertTo-Json"
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', script], capture_output=True,
                                    encoding='utf-8', errors='replace', timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((final / 'wav').is_dir())
            self.assertTrue((final / '.extract_complete.json').exists())
            self.assertFalse((final / '包装层').exists())


if __name__ == '__main__':
    unittest.main()
