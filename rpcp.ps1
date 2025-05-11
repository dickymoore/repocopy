<#
.SYNOPSIS
   Copy filtered parts of a repo to the clipboard according to config.json.

.DESCRIPTION
   Loads configuration from a JSON file (by default in the same folder as the script),
   enumerates all files under the target folder, excludes or includes based on:
     • ignoreFolders (wildcards OK)
     • ignoreFiles (exact names)
     • maxFileSize (bytes, 0 = no limit)
   Always applies token replacements from the config. Copies the final concatenated
   content to the clipboard. Command-line parameters can override any config value,
   and a JSON setting “showCopiedFiles” will automatically list the files copied
   unless overridden on the CLI.

.PARAMETER RepoPath
   Path of the repository to scan. Defaults to the current directory.
   Must be an existing folder.

.PARAMETER ConfigFile
   Path to the JSON configuration file. Defaults to "config.json" in the script’s folder.
   Must be an existing file.

.PARAMETER MaxFileSize
   Maximum file size in bytes to include; set to 0 to disable size filtering.
   Overrides the value in the config file if specified.

.PARAMETER IgnoreFolders
   Array of folder name patterns to ignore (supports wildcards).
   Overrides the config file’s ignoreFolders when specified.

.PARAMETER IgnoreFiles
   Array of file names to ignore (exact matches).
   Overrides the config file’s ignoreFiles when specified.

.PARAMETER Replacements
   Hashtable of token → replacement pairs.
   Overrides the config file’s replacements when specified.

.PARAMETER ShowCopiedFiles
   If specified (or if “showCopiedFiles” is true in config.json), after copying
   to clipboard the script will list every file that was included.

.PARAMETER Verbose
   Standard PowerShell -Verbose switch. When used, logs every file’s include/exclude
   decision and the reason.

.EXAMPLE
   .\rpcp.ps1
   # Uses config.json, applies its settings.

.EXAMPLE
   .\rpcp.ps1 -MaxFileSize 0 -ShowCopiedFiles:$false
   # Disables size filtering; suppresses the copied-file list.

.EXAMPLE
   .\rpcp.ps1 -RepoPath 'C:\MyProject' -ConfigFile '.\myconfig.json'
#>
[CmdletBinding()]
Param(
    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]   $RepoPath = '.',

    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]   $ConfigFile,

    [Parameter()]
    [ValidateSet('scan', 'filelist', 'scanlist', 'listfilter')]
    [string]   $SelectionMode = "scan",

    [Parameter()]
    [string]   $FileListPath = "include.md",

    [Parameter()]
    [ValidateRange(0, [long]::MaxValue)]
    [long]     $MaxFileSize,

    [Parameter()]
    [AllowNull()]
    [string[]] $IgnoreFolders,

    [Parameter()]
    [AllowNull()]
    [string[]] $IgnoreFiles,

    [Parameter()]
    [AllowNull()]

    [hashtable]$Replacements,

    [Parameter()]
    [switch]  $ShowCopiedFiles
)

function Get-Config {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string] $ConfigFilePath
    )
    try {
        $text = Get-Content -Raw -Path $ConfigFilePath -ErrorAction Stop
        return $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Error "Failed to load config from '$ConfigFilePath': $_" -ErrorAction Stop
    }
}
function Get-FileListFromPath {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    
    if (-not (Test-Path $Path -PathType Leaf)) {
        Write-Warning "File list path '$Path' not found."
        return @()
    }
    
    $content = Get-Content -Path $Path
    $files = @()
    
    foreach ($line in $content) {
        # Skip empty lines and lines starting with #, >, or -
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*[#>-]') {
            continue
        }
        
        # Extract file paths (look for things that look like paths)
        if ($line -match '[\w\d\._-]+[\\/][\w\d\._-]+') {
            $match = $Matches[0]
            # Normalize path separators
            $normalizedPath = $match.Replace('\', [IO.Path]::DirectorySeparatorChar).Replace('/', [IO.Path]::DirectorySeparatorChar)
            $files += $normalizedPath
        }
    }
    
    return $files
}

function Get-FilesToInclude {
    [CmdletBinding()]
    Param(
        [Parameter()]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]   $RepoRoot,

        [Parameter()]
        [string[]] $IgnoreFolders = @(),

        [Parameter()]
        [string[]] $IgnoreFiles   = @(),

        [Parameter()]
        [ValidateRange(0, [long]::MaxValue)]
        [long]     $MaxFileSize,
        
        [Parameter()]
        [ValidateSet('scan', 'filelist', 'scanlist', 'listfilter')]
        [string]   $SelectionMode = 'scan',
        
        [Parameter()]
        [string]   $FileListPath,
        
        [Parameter()]
        [string[]] $FileList = @()
    )
    
    # Read file list if path provided and not already loaded
    if ($FileListPath -and $FileList.Count -eq 0 -and $SelectionMode -ne 'scan') {
        $fullPath = Join-Path $RepoRoot $FileListPath
        $FileList = Get-FileListFromPath -Path $fullPath
        Write-Verbose "Found $($FileList.Count) files in list at '$FileListPath'"
    }
    
    # Handle pure filelist mode first
    if ($SelectionMode -eq 'filelist' -and $FileList.Count -gt 0) {
        $result = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        foreach ($relPath in $FileList) {
            $fullPath = Join-Path $RepoRoot $relPath
            if (Test-Path $fullPath -PathType Leaf) {
                $fileInfo = Get-Item $fullPath
                Write-Verbose "INCLUDING (from list): $($fileInfo.FullName)"
                $result.Add($fileInfo)
            } else {
                Write-Verbose "WARNING: Listed file not found: $fullPath"
            }
        }
        return $result
    }
    
    # All other modes require scanning
    $allFiles = Get-ChildItem -Path (Join-Path $RepoRoot '*') -Recurse -File -ErrorAction Stop
    $result = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    
    # For scanlist mode, first add all files from the list
    if ($SelectionMode -eq 'scanlist' -and $FileList.Count -gt 0) {
        foreach ($relPath in $FileList) {
            $fullPath = Join-Path $RepoRoot $relPath
            if (Test-Path $fullPath -PathType Leaf) {
                $fileInfo = Get-Item $fullPath
                Write-Verbose "INCLUDING (from list): $($fileInfo.FullName)"
                $result.Add($fileInfo)
            }
        }
    }
    
    # For all scan-based modes, process files according to filters
    foreach ($f in $allFiles) {
        # For listfilter mode, skip files not in the list
        if ($SelectionMode -eq 'listfilter') {
            $relativePath = $f.FullName.Substring($RepoRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
            if ($FileList -notcontains $relativePath) {
                Write-Verbose "EXCLUDING: $($f.FullName) → not in file list"
                continue
            }
        }
        
        # Skip if already included (for scanlist mode)
        if ($result.Contains($f)) {
            continue
        }
        
        $reason = $null
        # Folder pattern check
        $dirs = $f.DirectoryName.Split([IO.Path]::DirectorySeparatorChar)
        foreach ($pat in $IgnoreFolders) {
            $sepRegex = [Regex]::Escape([IO.Path]::DirectorySeparatorChar)
            $segments = $f.DirectoryName -split $sepRegex
    
            foreach ($pat in $IgnoreFolders) {
                if ($segments -like $pat) {
                    $reason = "matched ignore-folder '$pat'"
                    break
                }
            }
        }
        
        # File name check
        if (-not $reason) {
            foreach ($pattern in $IgnoreFiles) {
                if ($f.Name -like $pattern) {
                    $reason = "filename '$($f.Name)' matches ignore pattern '$pattern'"
                    break
                }
            }
        }
    
        # Size check
        if (-not $reason -and $MaxFileSize -gt 0 -and $f.Length -gt $MaxFileSize) {
            $reason = "exceeds maxFileSize ($MaxFileSize bytes)"
        }

        if ($reason) {
            Write-Verbose "EXCLUDING: $($f.FullName) → $reason"
        } else {
            # Only add if we're not in listfilter mode or the file is in the list
            if ($SelectionMode -ne 'listfilter' -or 
                ($FileList -contains $f.FullName.Substring($RepoRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar))) {
                Write-Verbose "INCLUDING: $($f.FullName)"
                $result.Add($f)
            }
        }
    }

    return $result
}

function Build-ClipboardContent {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[System.IO.FileInfo]] $Files,

        [Parameter()]
        [hashtable] $Replacements
    )
    $sb = [System.Text.StringBuilder]::new()
    foreach ($f in $Files) {
        $sb.AppendLine("File: $($f.FullName)") | Out-Null
        $sb.AppendLine(('-' * 60))   | Out-Null
        $text = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction Stop

        foreach ($token in $Replacements.Keys) {
            $val = $Replacements[$token]
            $text = $text -replace ([Regex]::Escape($token)), $val
        }

        $sb.AppendLine($text)       | Out-Null
        $sb.AppendLine()            | Out-Null
    }
    return $sb.ToString()
}

function Copy-ToClipboard {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter()]
        [switch] $ShowList,

        [Parameter()]
        [System.Collections.Generic.List[System.IO.FileInfo]] $Files
    )
    # Pass the entire string as a single Value, rather than via the pipeline
    Set-Clipboard -Value $Content

    Write-Host "✅ Copied $($Files.Count) file(s) to clipboard."
    if ($ShowList) {
        Write-Host "`nFiles included:"
        foreach ($f in $Files) {
            Write-Host " - $($f.FullName)"
        }
    }
}

#–– Begin script logic ––

if (-not $PSBoundParameters.ContainsKey('ConfigFile')) {
    # Are we running from a script file?
    if ($MyInvocation.MyCommand.Path) {
        # Use the folder the script lives in
        $scriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    else {
        # Interactive / dot-sourced: use the cwd
        $scriptFolder = (Get-Location).ProviderPath
    }

    $ConfigFile = Join-Path $scriptFolder 'config.json'
}


# Load and merge config
$config = Get-Config -ConfigFilePath $ConfigFile

# Merge CLI parameters over config values
$rp = if ($PSBoundParameters.ContainsKey('RepoPath')) { $RepoPath } else { $config.repoPath }
$mf = if ($PSBoundParameters.ContainsKey('MaxFileSize')) { $MaxFileSize } else { [long]$config.maxFileSize }
$if = if ($PSBoundParameters.ContainsKey('IgnoreFolders') -and $IgnoreFolders) { $IgnoreFolders } else { @($config.ignoreFolders) }
$ifl = if ($PSBoundParameters.ContainsKey('IgnoreFiles') -and $IgnoreFiles) { $IgnoreFiles } else { @($config.ignoreFiles) }
$rep = if ($PSBoundParameters.ContainsKey('Replacements')) { $Replacements } else {
    $h = @{}; foreach ($p in $config.replacements.PSObject.Properties) { $h[$p.Name] = $p.Value }; $h
}
$scf = if ($PSBoundParameters.ContainsKey('ShowCopiedFiles')) {
    $ShowCopiedFiles.IsPresent
} else {
    [bool]$config.showCopiedFiles
}
$sm = if ($PSBoundParameters.ContainsKey('SelectionMode')) { $SelectionMode } else { 
    if ($null -ne $config.PSObject.Properties['selectionMode']) { $config.selectionMode } else { 'scan' } 
}
$flp = if ($PSBoundParameters.ContainsKey('FileListPath')) { $FileListPath } else { 
    if ($null -ne $config.PSObject.Properties['fileListPath']) { $config.fileListPath } else { $null } 
}

if ($null -eq $if) { $if = @() }
if ($null -eq $ifl) { $ifl = @() }

# Gather, filter, and log
$filesToCopy = Get-FilesToInclude `
           -RepoRoot      $rp `
           -IgnoreFolders $if `
           -IgnoreFiles   $ifl `
           -MaxFileSize   $mf `
           -SelectionMode $sm `
           -FileListPath  $flp

if ($filesToCopy.Count -eq 0) {
    Write-Warning 'No files passed the filters; nothing to copy.'
    return
}

# Build content & copy
$content = Build-ClipboardContent -Files $filesToCopy -Replacements $rep
Copy-ToClipboard -Content $content -ShowList:$scf -Files $filesToCopy
