import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SEVEN_ZIP = pathlib.Path('C:/Program Files/7-Zip/7z.exe')


@unittest.skipUnless(SEVEN_ZIP.exists(), '7-Zip is not installed')
class PasswordCandidatesTests(unittest.TestCase):
    def test_padded_password_and_literal_whitespace_password_both_work(self):
        with tempfile.TemporaryDirectory(prefix='password_padding_') as temp:
            base = pathlib.Path(temp)
            payload = base / 'payload.txt'
            payload.write_text('complete encrypted payload', encoding='utf-8')
            passwords = base / 'passwords.txt'
            passwords.write_text(
                '# ignored\n\n padded-password \t\npadded-password\n literal-spaces \n',
                encoding='utf-8-sig',
            )
            for name, password in (
                ('padded.7z', 'padded-password'),
                ('literal.7z', ' literal-spaces '),
            ):
                created = subprocess.run(
                    [str(SEVEN_ZIP), 'a', '-t7z', '-mhe=on', '-p' + password,
                     str(base / name), str(payload)],
                    capture_output=True, timeout=30,
                )
                self.assertEqual(created.returncode, 0, created.stderr)

            script = r'''
param([string]$Root, [string]$Base, [string]$SevenZip)
$ErrorActionPreference = 'Stop'
$script:sevenZip = $SevenZip
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $Root 'extract.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-PasswordCandidates', 'Invoke-7ZipCapture', 'Find-ArchivePassword')) {
    $function = $ast.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name}, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
function Get-ArchiveNameCodePageArguments([string]$Archive) { return @() }
$candidates = @(Get-PasswordCandidates (Join-Path $Base 'passwords.txt'))
if ($candidates.Count -ne 5 -or $null -ne $candidates[0]) { throw 'Candidate count or no-password entry changed' }
if ($candidates[1] -cne " padded-password `t" -or $candidates[2] -cne 'padded-password') {
    throw 'Literal candidate must precede trimmed fallback'
}
if ($candidates[3] -cne ' literal-spaces ' -or $candidates[4] -cne 'literal-spaces') {
    throw 'Intentional spaces were lost'
}
foreach ($name in @('padded.7z', 'literal.7z')) {
    $archive = Join-Path $Base $name
    $wrong = Find-ArchivePassword $archive @('wrong-password')
    if ($wrong.Found) { throw 'Wrong password accepted' }
    $match = Find-ArchivePassword $archive $candidates
    if (-not $match.Found) { throw "Could not verify $name" }
    $expectedIndex = if ($name -eq 'padded.7z') { 2 } else { 3 }
    if ($match.PasswordIndex -ne $expectedIndex) { throw 'Wrong candidate selected' }
}
'''
            script_path = base / 'check.ps1'
            script_path.write_text(script, encoding='utf-8')
            checked = subprocess.run(
                ['pwsh', '-NoProfile', '-File', str(script_path), str(ROOT),
                 str(base), str(SEVEN_ZIP)],
                capture_output=True, encoding='utf-8', errors='replace', timeout=30,
            )
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)


if __name__ == '__main__':
    unittest.main()
