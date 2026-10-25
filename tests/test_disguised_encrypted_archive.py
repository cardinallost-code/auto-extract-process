import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SEVEN_ZIP = pathlib.Path('C:/Program Files/7-Zip/7z.exe')


@unittest.skipUnless(SEVEN_ZIP.exists(), '7-Zip is not installed')
class DisguisedEncryptedArchiveTests(unittest.TestCase):
    def test_pdf_extension_is_discovered_and_encrypted_payload_is_verified(self):
        with tempfile.TemporaryDirectory(prefix='disguised_7z_') as temp:
            base = pathlib.Path(temp)
            payload = base / 'payload.txt'
            payload.write_text('encrypted payload', encoding='utf-8')
            archive = base / 'RJ99999991.pdf'
            created = subprocess.run(
                [str(SEVEN_ZIP), 'a', '-t7z', '-ptest-password', str(archive), str(payload)],
                capture_output=True, timeout=30,
            )
            self.assertEqual(created.returncode, 0, created.stderr)

            script = r'''
$ErrorActionPreference = 'Stop'
$script:sevenZip = 'SEVEN_ZIP'
$ast = [Management.Automation.Language.Parser]::ParseFile('EXTRACT', [ref]$null, [ref]$null)
foreach ($name in @('Get-SignatureKind', 'Test-IsArchiveCandidate', 'Invoke-7ZipCapture', 'Find-ArchivePassword')) {
    $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
function Get-ArchiveNameCodePageArguments([string]$Archive) { return @() }
if (-not (Test-IsArchiveCandidate (Get-Item -LiteralPath 'ARCHIVE'))) { exit 1 }
$wrong = Find-ArchivePassword 'ARCHIVE' @('wrong-password')
if ($wrong.Found -or -not $wrong.EncryptedPayloadDetected) { exit 3 }
$match = Find-ArchivePassword 'ARCHIVE' @('wrong-password', 'test-password')
if (-not $match.Found -or $match.PasswordIndex -ne 1) { exit 2 }
'''.replace('SEVEN_ZIP', str(SEVEN_ZIP)).replace('EXTRACT', str(ROOT / 'extract.ps1')).replace('ARCHIVE', str(archive))
            checked = subprocess.run(
                ['pwsh', '-NoProfile', '-Command', script],
                capture_output=True, encoding='utf-8', errors='replace', timeout=30,
            )
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)


if __name__ == '__main__':
    unittest.main()
