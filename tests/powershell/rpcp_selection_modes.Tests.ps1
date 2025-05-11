# Pester 5 tests for repocopy's selection modes feature (PowerShell edition)
# ──────────────────────────────────────────────────────────────
Import-Module Pester                          -ErrorAction Stop
Import-Module Microsoft.PowerShell.Management -Force        # Set-Clipboard

$ErrorActionPreference = 'Stop'

Describe 'rpcp.ps1 selectionMode behavior (fixture repo)' {

    # ──────────────────────────────────────────────────────────
    # ❶ Shared one-time setup
    # ──────────────────────────────────────────────────────────
    BeforeAll {
        $ProjectRoot = (Resolve-Path "$PSScriptRoot/../../").Path
        $Script      = Join-Path $ProjectRoot 'rpcp.ps1'
        $TestRepo    = Join-Path ([IO.Path]::GetTempPath()) "rpcp_test_$(Get-Random)"
        
        # Create test repo structure
        New-Item -ItemType Directory -Path "$TestRepo/src/include-dir" -Force | Out-Null
        New-Item -ItemType Directory -Path "$TestRepo/build" -Force | Out-Null
        
        # Create test files
        'hello ClientName' | Set-Content "$TestRepo/src/main.txt"
        'include me' | Set-Content "$TestRepo/src/include-dir/file1.txt"
        'include me too' | Set-Content "$TestRepo/src/include-dir/file2.txt" 
        '{ "note":"ignore" }' | Set-Content "$TestRepo/manifest.json"
        [IO.File]::WriteAllBytes("$TestRepo/image.png", [byte[]](0..9))
        
        # Create a file that should be excluded by size
        $bigSize = 300KB  # > maxFileSize
        $bytes = New-Object byte[] $bigSize
        [System.Random]::new().NextBytes($bytes)
        [IO.File]::WriteAllBytes("$TestRepo/src/big.bin", $bytes)
        
        # Create a file in the ignored build directory
        'build artifact' | Set-Content "$TestRepo/build/output.txt"
        
        # Create the fileListPath document
        @'
### Files to include

src/include-dir/file1.txt
manifest.json
build/output.txt
'@ | Set-Content "$TestRepo/affected.md"
        
        # Create base config.json
        @'
{
  "repoPath": ".",
  "maxFileSize": 204800,
  "ignoreFolders": [ "build" ],
  "ignoreFiles": [ "manifest.json", "*.png", "config.json" ],
  "replacements": { "ClientName": "Redacted_name" },
  "showCopiedFiles": false,
  "selectionMode": "scan",
  "fileListPath": "affected.md"
}
'@ | Set-Content "$TestRepo/config.json"

        # -- helper: run rpcp & capture what it puts on the clipboard -------
        function Invoke-Rpcp {
            [CmdletBinding()]
            param(
                [Parameter()]
                [string]$SelectionMode,
                
                [Parameter()]
                [hashtable]$ExtraParams = @{}
            )
            
            # Update config if selection mode provided
            if ($SelectionMode) {
                $config = Get-Content -Raw "$TestRepo/config.json" | ConvertFrom-Json
                $config.selectionMode = $SelectionMode
                $config | ConvertTo-Json | Set-Content "$TestRepo/config.json"
            }

            $params = @{
                RepoPath   = $TestRepo
                ConfigFile = "$TestRepo/config.json"
            }
            
            # Merge with any extra parameters
            foreach ($key in $ExtraParams.Keys) {
                $params[$key] = $ExtraParams[$key]
            }

            Mock Set-Clipboard {
                param($Value)
                # Flatten any array → single string so tests are simpler
                Set-Variable -Name CapturedClipboard `
                            -Value ($Value -join "`n") `
                            -Scope Global
            }

            & $Script @params | Out-Null

            # Copy-out *before* we purge the global
            $result = $CapturedClipboard
            Remove-Variable -Name CapturedClipboard -Scope Global -ErrorAction SilentlyContinue
            return $result
        }
    }

    AfterAll {
        # Clean up test repo
        if (Test-Path $TestRepo) {
            Remove-Item -Recurse -Force $TestRepo -ErrorAction SilentlyContinue
        }
    }

    # ──────────────────────────────────────────────────────────
    Context 'filelist mode' {
        It 'copies only files listed in fileListPath' {
            $copied = Invoke-Rpcp -SelectionMode 'filelist'

            # Should include files from the list
            $copied | Should -Match 'include-dir/file1\.txt'
            $copied | Should -Match 'manifest\.json'
            $copied | Should -Match 'build/output\.txt'
            
            # Replacements should be applied
            $copied | Should -Match 'Redacted_name'
            
            # Should NOT include files not in the list, even if they'd pass filters
            $copied | Should -Not -Match 'main\.txt'
            $copied | Should -Not -Match 'file2\.txt'
            
            # Large files should be excluded if not in the list
            $copied | Should -Not -Match 'big\.bin'
        }
    }

    Context 'scanlist mode' {
        It 'includes both listed files and files passing normal scan filters' {
            $copied = Invoke-Rpcp -SelectionMode 'scanlist'
            
            # Should include files from the list
            $copied | Should -Match 'include-dir/file1\.txt'
            $copied | Should -Match 'manifest\.json'
            $copied | Should -Match 'build/output\.txt'
            
            # Should also include files that pass normal scan filters
            $copied | Should -Match 'main\.txt'
            $copied | Should -Match 'file2\.txt'
            
            # Files excluded by normal scan and not in the list should still be excluded
            $copied | Should -Not -Match 'image\.png'
            $copied | Should -Not -Match 'big\.bin'
        }
    }

    Context 'listfilter mode' {
        It 'applies normal scan filters to files in fileListPath' {
            $copied = Invoke-Rpcp -SelectionMode 'listfilter'
            
            # Files in the list that pass filters should be included
            $copied | Should -Match 'include-dir/file1\.txt'
            
            # Files in the list but excluded by filters should NOT be included
            $copied | Should -Not -Match 'manifest\.json'
            $copied | Should -Not -Match 'build/output\.txt'
            
            # Files not in the list should not be included regardless of filters
            $copied | Should -Not -Match 'main\.txt'
            $copied | Should -Not -Match 'file2\.txt'
            $copied | Should -Not -Match 'image\.png'
            $copied | Should -Not -Match 'big\.bin'
        }
    }

    Context 'scan mode (default)' {
        It 'uses original scan-only behavior when mode is set to scan' {
            $copied = Invoke-Rpcp -SelectionMode 'scan'
            
            # Original behavior - include files that pass filters
            $copied | Should -Match 'main\.txt'
            $copied | Should -Match 'include-dir/file1\.txt'
            $copied | Should -Match 'include-dir/file2\.txt'
            
            # Files excluded by filters should not be included
            $copied | Should -Not -Match 'manifest\.json'
            $copied | Should -Not -Match 'build/output\.txt'
            $copied | Should -Not -Match 'image\.png'
            $copied | Should -Not -Match 'big\.bin'
        }
        
        It 'defaults to scan mode when selectionMode is missing from config' {
            # Remove selectionMode from config
            $config = Get-Content -Raw "$TestRepo/config.json" | ConvertFrom-Json
            $config.PSObject.Properties.Remove('selectionMode')
            $config | ConvertTo-Json | Set-Content "$TestRepo/config.json"
            
            $copied = Invoke-Rpcp
            
            # Should behave like scan mode
            $copied | Should -Match 'main\.txt'
            $copied | Should -Not -Match 'manifest\.json'
            $copied | Should -Not -Match 'build/output\.txt'
        }
    }
    
    Context 'CLI override parameters' {
        It 'allows override of selectionMode via CLI parameter' {
            # This would need to be implemented in rpcp.ps1
            # For now, just documenting what the test would look like
            
            $params = @{
                SelectionMode = 'scan'  # Base config
                ExtraParams = @{
                    # Assume we added a SelectionMode parameter to rpcp.ps1
                    # SelectionMode = 'filelist'
                }
            }
            
            # Skip this test since the implementation doesn't exist yet
            Set-ItResult -Skipped -Because "CLI parameter for selectionMode not implemented yet"
        }
    }
}