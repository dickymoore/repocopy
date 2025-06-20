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
        [long]     $MaxFileSize
    )
    $allFiles = Get-ChildItem -Path (Join-Path $RepoRoot '*') -Recurse -File -ErrorAction Stop
    $result = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    foreach ($f in $allFiles) {
        $reason = $null

        # Folder pattern check

        $dirs = $f.DirectoryName.Split([IO.Path]::DirectorySeparatorChar) 
        foreach ($folderPattern in $IgnoreFolders) {
            $sepRegex   = [Regex]::Escape([IO.Path]::DirectorySeparatorChar)
            $segments   = $f.DirectoryName -split $sepRegex      # safe on Win & *nix
            if ($segments -like $folderPattern) {
                $reason = "matched ignore-folder '$folderPattern'"
                break
            }
        }

        # File name check

        if (-not $reason) {
            foreach ($pattern in $IgnoreFiles) {
                if (($f.Name) -like $pattern) {
                    $reason = "filename '$($f.Name)' matches ignore pattern '$pattern'"
                    break
                }
            }
        }
    
        # Size check
        if (
            -not $reason -and `
            $MaxFileSize -gt 0 -and `
            $f.Length -gt $MaxFileSize
        ) {
            $reason = "exceeds maxFileSize ($MaxFileSize bytes)"
        }

        if ($reason) {
            Write-Verbose "EXCLUDING: $($f.FullName) → $reason"
        } else {
            Write-Verbose "INCLUDING: $($f.FullName)"
            $result.Add($f)
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
    $stringBulder = [System.Text.StringBuilder]::new()
    foreach ($f in $Files) {
        $stringBulder.AppendLine("File: $($f.FullName)") | Out-Null # Appends the file name
        $stringBulder.AppendLine(('-' * 60))   | Out-Null # Appends 60 hypens as a seperator
        $text = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction Stop

        foreach ($token in $Replacements.Keys) {
            $val = $Replacements[$token]
            $text = $text -replace ([Regex]::Escape($token)), $val
        }

        $stringBulder.AppendLine($text)       | Out-Null
        $stringBulder.AppendLine()            | Out-Null
    }
    return $stringBulder.ToString()
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
    Set-Clipboard -Value $Content # Pass the entire string as a single Value, rather than via the pipeline

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
$repoPath = if ($PSBoundParameters.ContainsKey('RepoPath')) { $RepoPath } else { $config.repoPath }
$maxFileSize = if ($PSBoundParameters.ContainsKey('MaxFileSize')) { $MaxFileSize } else { [long]$config.maxFileSize }
$ignoreFolders  = if ($PSBoundParameters.ContainsKey('IgnoreFolders') -and $IgnoreFolders) { $IgnoreFolders } else { @($config.ignoreFolders) }
$ignoreFiles = if ($PSBoundParameters.ContainsKey('IgnoreFiles')   -and $IgnoreFiles)   { $IgnoreFiles }   else { @($config.ignoreFiles) }
$replacements = if ($PSBoundParameters.ContainsKey('Replacements')) { $Replacements } else {
    $tempHashtable = @{}; foreach ($p in $config.replacements.PSObject.Properties) { $tempHashtable[$p.Name] = $p.Value }; $tempHashtable
}
$shouldShowCopiedFiles = if ($PSBoundParameters.ContainsKey('ShowCopiedFiles')) {
    $ShowCopiedFiles.IsPresent
 } else {
    [bool]$config.showCopiedFiles
 }

if ($null -eq $ignoreFiles)  { $ignoreFiles  = @() }
if ($null -eq $ignoreFolders) { $ignoreFolders = @() }

# Gather, filter, and log
$filesToCopy = Get-FilesToInclude `
           -RepoRoot      $repoPath `
           -IgnoreFolders $ignoreFolders `
           -IgnoreFiles   $ignoreFiles `
           -MaxFileSize   $maxFileSize


if ($filesToCopy.Count -eq 0) {
    Write-Warning 'No files passed the filters; nothing to copy.'
    return
}

# Build content & copy
$content = Build-ClipboardContent -Files $filesToCopy -Replacements $replacements
Copy-ToClipboard -Content $content -ShowList:$shouldShowCopiedFiles -Files $filesToCopy
