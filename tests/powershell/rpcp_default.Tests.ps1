# Pester 5 tests for repocopy (PowerShell edition)
# ──────────────────────────────────────────────────────────────
Import-Module Pester                          -ErrorAction Stop
Import-Module Microsoft.PowerShell.Management -Force        # Set-Clipboard

$ErrorActionPreference = 'Stop'

Describe 'rpcp.ps1 end-to-end behaviour (fixture repo)' {

    # ──────────────────────────────────────────────────────────
    # ❶ Shared one-time setup
    # ──────────────────────────────────────────────────────────
    BeforeAll {
        $ProjectRoot = (Resolve-Path "$PSScriptRoot/../../").Path
        $Script      = Join-Path $ProjectRoot 'rpcp.ps1'
        $FixtureRoot = Join-Path $ProjectRoot 'tests/fixtures/sample-repo'

        # -- ensure fixture tree exists (idempotent) ------------------------
        if (-not (Test-Path $FixtureRoot)) {
            New-Item -ItemType Directory -Path "$FixtureRoot/src" -Force | Out-Null
        }
        
        # minimal source file & image (re-create only if missing)
        if (-not (Test-Path "$FixtureRoot/src/include.txt")) {
            'hello ClientName' | Set-Content "$FixtureRoot/src/include.txt"
        }
        if (-not (Test-Path "$FixtureRoot/manifest.json")) {
            '{ "note":"ignore" }' | Set-Content "$FixtureRoot/manifest.json"
        }
        if (-not (Test-Path "$FixtureRoot/image.png")) {
            [IO.File]::WriteAllBytes("$FixtureRoot/image.png",[byte[]](0..9))
        }
        @'
{
  "repoPath": ".",
  "maxFileSize": 204800,
  "ignoreFolders": [ "build" ],
  "ignoreFiles"  : [ "manifest.json", "*.png", "config.json" ],
  "replacements" : { "ClientName": "Bob" },
  "showCopiedFiles": false
}
'@ | Set-Content "$FixtureRoot/config.json"
        # -- create a file that should be excluded by size -----------------
        $size  = 300kb            # 300 KiB  >  maxFileSize
        $bytes = New-Object byte[] $size
        [System.Random]::new().NextBytes($bytes)
        [IO.File]::WriteAllBytes("$FixtureRoot/src/big.bin", $bytes)
        if (-not (Test-Path "$FixtureRoot/build")) {
            New-Item -ItemType Directory -Path "$FixtureRoot/build" | Out-Null
            'ignore me' | Set-Content "$FixtureRoot/build/output.txt"
        }

        # -- helper: run rpcp & capture what it puts on the clipboard -------
        # ── helper: run rpcp & capture what it puts on the clipboard ─────────────
function Invoke-Rpcp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Param
    )

    Mock Set-Clipboard {
        param($Value)
        # flatten any array → single string so tests are simpler
        Set-Variable -Name CapturedClipboard `
                     -Value ($Value -join "`n") `
                     -Scope Global
    }

    & $Script @Param | Out-Null

    # copy-out *before* we purge the global
    $result = $CapturedClipboard
    Remove-Variable -Name CapturedClipboard -Scope Global -ErrorAction SilentlyContinue
    return $result
}

    }

    # ──────────────────────────────────────────────────────────
    Context 'Default run (config.json only)' {
        It 'copies only permitted files and performs replacements' {
            $copied = Invoke-Rpcp -Param @{
                RepoPath   = $FixtureRoot
                ConfigFile = "$FixtureRoot/config.json"
            }

            $copied | Should -Match    'include\.txt'
            $copied | Should -Match    'hello Bob'

            $copied | Should -Not -Match 'manifest\.json'
            $copied | Should -Not -Match 'image\.png'
            $copied | Should -Not -Match 'config\.json'
            $copied | Should -Not -Match 'output\.txt'
            $copied | Should -Not -Match 'big\.bin'
        }
    }

    Context 'Max file-size filter' {
        It 'excludes files bigger than maxFileSize' {
            $copied = Invoke-Rpcp -Param @{
                RepoPath   = $FixtureRoot
                ConfigFile = "$FixtureRoot/config.json"   # 204 KB limit
            }

            $copied | Should -Not -Match 'big\.bin'
        }

        It 'includes big file maxFileSize Is set to 0' {
            $copied = Invoke-Rpcp -Param @{
                RepoPath    = $FixtureRoot
                ConfigFile  = "$FixtureRoot/config.json"
                MaxFileSize = 0
            }
            $copied | Should -Match 'big\.bin'
        }
    }

    Context 'Folder ignore pattern' {
        It 'skips anything inside folders named "build"' {
            $copied = Invoke-Rpcp -Param @{
                RepoPath   = $FixtureRoot
                ConfigFile = "$FixtureRoot/config.json"
            }

            $pattern = [regex]::Escape('build/output.txt')
            $copied | Should -Not -Match $pattern
        }
    }

    Context 'ShowCopiedFiles switch' {
        It 'still copies correctly when -ShowCopiedFiles is used' {
            $copied = Invoke-Rpcp -Param @{
                RepoPath        = $FixtureRoot
                ConfigFile      = "$FixtureRoot/config.json"
                ShowCopiedFiles = $true
            }

            $copied | Should -Match 'include\.txt'   # sanity check
        }
    }
}
