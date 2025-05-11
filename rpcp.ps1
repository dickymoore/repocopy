#!/usr/bin/env pwsh
# ───────────────────────────────────────────────────────────────────────
# RePoCoPy - Repository Copy Tool (PowerShell Edition)
# Copies files from a repo to clipboard while respecting ignore patterns
# and performing text replacements for sensitive data.
# ───────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RepoPath = ".",
    
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "",
    
    [Parameter(Mandatory = $false)]
    [int]$MaxFileSize = 0, # 0 means disable max file size filtering
    
    [Parameter(Mandatory = $false)]
    [switch]$ShowCopiedFiles = $false,
    
    [Parameter(Mandatory = $false)]
    [string]$FileListPath = "",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("scan", "filelist", "scanlist", "listfilter")]
    [string]$SelectionMode = ""
)

# Ensure we stop on all errors
$ErrorActionPreference = 'Stop'

# ───────────────────────────────────────────────────────────────────────
# Support Functions
# ───────────────────────────────────────────────────────────────────────
function Get-DefaultConfig {
    return @{
        repoPath = "."
        maxFileSize = 1MB  # Default 1MB file size limit
        ignoreFolders = @(
            "node_modules",
            ".git",
            ".idea",
            ".vscode"
        )
        ignoreFiles = @(
            "*.log",
            "*.tmp",
            "package-lock.json",
            "yarn.lock"
        )
        replacements = @{}
        showCopiedFiles = $false
        selectionMode = "scan"
        fileListPath = ""
    }
}

function Get-ConfigFile {
    param (
        [Parameter(Mandatory=$true)][string]$RepoPath,
        [Parameter(Mandatory=$false)][string]$ConfigFile = ""
    )
    
    # If config file is specified, use it
    if ($ConfigFile -ne "" -and (Test-Path $ConfigFile)) {
        return $ConfigFile
    }
    
    # Try to find config file in repo path
    $defaultConfigs = @(
        "repocopy.json",
        ".repocopy.json",
        "repocopy.config.json",
        "config.json"
    )
    
    foreach ($config in $defaultConfigs) {
        $configPath = Join-Path $RepoPath $config
        if (Test-Path $configPath) {
            return $configPath
        }
    }
    
    # No config file found
    return $null
}

function Read-ConfigFile {
    param (
        [Parameter(Mandatory=$true)][string]$ConfigFilePath
    )
    
    try {
        $configContent = Get-Content -Raw -Path $ConfigFilePath | ConvertFrom-Json
        
        # Convert to hashtable for easier manipulation
        $config = @{}
        $configContent.PSObject.Properties | ForEach-Object {
            if ($_.Name -eq "replacements") {
                # Handle replacements object specially
                $replacements = @{}
                if ($null -ne $_.Value) {
                    $_.Value.PSObject.Properties | ForEach-Object {
                        $replacements[$_.Name] = $_.Value
                    }
                }
                $config[$_.Name] = $replacements
            } else {
                $config[$_.Name] = $_.Value
            }
        }
        
        return $config
    } catch {
        Write-Error "Failed to read config file: $_"
        exit 1
    }
}

function Get-FilesToInclude {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]   $RepoPath,
        [Parameter(Mandatory=$true)] [int]      $MaxFileSize,
        [Parameter(Mandatory=$true)] [string[]] $IgnoreFolders,
        [Parameter(Mandatory=$true)] [string[]] $IgnoreFiles,
        [Parameter(Mandatory=$false)][string]   $FileListPath,
        [Parameter(Mandatory=$false)][string]   $SelectionMode = "scan"
    )
    
    $files = @()
    $fileList = @()
    
    # Check if we need to process a file list
    if ($SelectionMode -in @("filelist", "scanlist", "listfilter") -and (![string]::IsNullOrEmpty($FileListPath))) {
        if (Test-Path $FileListPath) {
            # Extract file paths from the file list
            $content = Get-Content -Path $FileListPath -Raw
            
            # Extract file paths - one per line
            $fileList = $content -split "\r?\n" | 
                        Where-Object { $_ -match '\S' -and -not $_.StartsWith('#') } |  # Non-empty, non-comment lines
                        ForEach-Object { $_.Trim() }
            
            # Add the file list path itself to the ignoreFiles list to prevent it from being included
            $IgnoreFiles += $(Split-Path -Leaf $FileListPath)
        } else {
            Write-Warning "FileListPath '$FileListPath' not found. Defaulting to scan mode."
            $SelectionMode = "scan"
        }
    }
    
    # For filelist mode, we only process files in the list
    if ($SelectionMode -eq "filelist") {
        foreach ($relativePath in $fileList) {
            $fullPath = Join-Path $RepoPath $relativePath
            
            if (Test-Path $fullPath -PathType Leaf) {
                $fileInfo = [System.IO.FileInfo]::new($fullPath)
                
                # Apply size filter for consistency (skip size filter if MaxFileSize is 0)
                if ($MaxFileSize -eq 0) {
                } else {
                    if ($MaxFileSize -le 0 -or $fileInfo.Length -le $MaxFileSize) {
                        $files += @{
                            Path = $fullPath
                            RelativePath = $relativePath
                        }
                    } else {
                        Write-Verbose "Skipping file exceeding size limit: $relativePath"
                    }

                }                
            } else {
                Write-Verbose "File from list not found: $relativePath"
            }
        }
        
        return $files
    }
    
    # For other modes, we need to scan the repository
    $allFiles = Get-ChildItem -Path $RepoPath -Recurse -File | 
                Where-Object { 
                    # Filter out files in ignored folders
                    $folderMatch = $false
                    foreach ($folder in $IgnoreFolders) {
                        # Ensure $_.FullName is never null
                        if ($null -ne $_ -and $null -ne $_.FullName) {
                            # Normalize path separators to forward slashes for consistent matching
                            $normalizedPath = $_.FullName.Replace('\', '/')
                            
                            # Look for the folder pattern surrounded by slashes or at start/end
                            if ($normalizedPath -match "(^|/)$([regex]::Escape($folder))(/|$)") {
                                $folderMatch = $true
                                break
                            }
                        }
                    }
                    
                    if ($folderMatch) {
                        return $false
                    }
                    
                    # Continue with file filtering
                    $fileMatch = $false
                    foreach ($pattern in $IgnoreFiles) {
                        if ($_.Name -like $pattern) {
                            $fileMatch = $true
                            break
                        }
                    }
                    
                    # Keep files that don't match ignore patterns
                    return -not $fileMatch
                }
    
    # Process scanned files
    $scanFiles = @()
    foreach ($file in $allFiles) {
        # Ensure we have a valid path before doing string operations
        if ($null -eq $file -or [string]::IsNullOrEmpty($file.FullName)) {
            Write-Warning "Skipping invalid file entry"
            continue
        }
        
        # Get the relative path - handle potential path issues safely
        try {
            # Ensure both paths are fully qualified and normalized
            $fullRepoPath = [System.IO.Path]::GetFullPath($RepoPath)
            $fullFilePath = [System.IO.Path]::GetFullPath($file.FullName)
            
            # Ensure fullRepoPath ends with a directory separator
            if (-not $fullRepoPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
                $fullRepoPath = $fullRepoPath + [System.IO.Path]::DirectorySeparatorChar
            }
            
            # Check that the file path starts with the repo path
            if ($fullFilePath.StartsWith($fullRepoPath, [StringComparison]::OrdinalIgnoreCase)) {
                # Get the relative path by removing the repo path prefix
                $relativePath = $fullFilePath.Substring($fullRepoPath.Length)
                
                # Convert backslashes to forward slashes for consistency
                $relativePath = $relativePath.Replace('\', '/')
                
                # Apply size filter
                if ($MaxFileSize -le 0 -or $file.Length -le $MaxFileSize) {
                    $scanFiles += @{
                        Path = $file.FullName
                        RelativePath = $relativePath
                    }
                } else {
                    Write-Verbose "Skipping file exceeding size limit: $relativePath"
                }
            } else {
                Write-Warning "File path is not within repository path: $($file.FullName)"
            }
        } catch {
            Write-Warning "Error processing file path '$($file.FullName)': $_"
            continue
        }
    }
    
    # Now process files based on selection mode
    switch ($SelectionMode) {
        "scan" {
            # For scan mode, use all filtered files
            $files = $scanFiles
        }
        "scanlist" {
            # For scanlist mode, add files from scan
            $files = $scanFiles
            
            # Also add files from the list even if they didn't pass the scan
            foreach ($listPath in $fileList) {
                # Skip if this file is already included from scan
                if (($scanFiles | Where-Object { $_.RelativePath -eq $listPath }).Count -gt 0) {
                    continue
                }
                
                $listFullPath = Join-Path $RepoPath $listPath
                if (Test-Path $listFullPath -PathType Leaf) {
                    $listFileInfo = [System.IO.FileInfo]::new($listFullPath)
                    if ($MaxFileSize -le 0 -or $listFileInfo.Length -le $MaxFileSize) {
                        $files += @{
                            Path = $listFullPath
                            RelativePath = $listPath
                        }
                    }
                }
            }
        }
        "listfilter" {
            # For listfilter mode, only add files that are both in the list and pass filters
            $files = @()
            foreach ($scanFile in $scanFiles) {
                if ($fileList -contains $scanFile.RelativePath) {
                    $files += $scanFile
                }
            }
        }
    }
    
    # Return unique files by RelativePath (might have duplicates from scanlist)
    if ($SelectionMode -eq "scanlist") {
        $uniqueFiles = @{}
        foreach ($file in $files) {
            if (-not $uniqueFiles.ContainsKey($file.RelativePath)) {
                $uniqueFiles[$file.RelativePath] = $file
            }
        }
        return $uniqueFiles.Values
    }
    
    return $files
}

function Apply-Replacements {
    param (
        [Parameter(Mandatory=$true)][string]$Content,
        [Parameter(Mandatory=$true)][hashtable]$Replacements
    )
    
    $result = $Content
    foreach ($key in $Replacements.Keys) {
        $result = $result.Replace($key, $Replacements[$key])
    }
    
    return $result
}

function Get-FileContent {
    param (
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][hashtable]$Replacements
    )
    
        # if this isn’t one of our known-text extensions, show the placeholder
        $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
        if ($ext -notin '.txt','.md','.json','.ps1','.sh') {
            return '[Binary file content not shown]'
        }
    
        # now it’s “text” so read + replace safely
        $content = Get-Content -Raw -Path $FilePath
        if ($Replacements.Count -gt 0) {
            $content = Apply-Replacements -Content $content -Replacements $Replacements
        }
        return $content
    
}

# ───────────────────────────────────────────────────────────────────────
# Main Function
# ───────────────────────────────────────────────────────────────────────
function Copy-RepoToClipboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$RepoPath = ".",
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigFile = "",
        
        [Parameter(Mandatory = $false)]
        [int]$MaxFileSize = 0,  # 0 means use the value from config
        
        [Parameter(Mandatory = $false)]
        [switch]$ShowCopiedFiles = $false,
        
        [Parameter(Mandatory = $false)]
        [string]$FileListPath = "",
        
        [Parameter(Mandatory = $false)]
        [string]$SelectionMode = ""
    )
    
    # Step 1: Load configuration
    $configPath = Get-ConfigFile -RepoPath $RepoPath -ConfigFile $ConfigFile
    $defaultConfig = Get-DefaultConfig
    
    if ($configPath) {
        # Load actual config from file
        $config = Read-ConfigFile -ConfigFilePath $configPath
        
        # Merge with defaults for any missing values
        foreach ($key in $defaultConfig.Keys) {
            if (-not $config.ContainsKey($key)) {
                $config[$key] = $defaultConfig[$key]
            }
        }
    } else {
        # Use default config
        $config = $defaultConfig
        
        # Adjust for the provided repo path
        $config.repoPath = $RepoPath
    }
    
    # Override config with command line parameters
    if ($RepoPath -ne ".") {
        $config.repoPath = $RepoPath
    }
    
    # If the user passed –MaxFileSize at all, override even if it’s zero (zero → no limit).
    if ($PSBoundParameters.ContainsKey('MaxFileSize')) {
        $config.maxFileSize = $MaxFileSize
    }
    
    if ($ShowCopiedFiles) {
        $config.showCopiedFiles = $true
    }
    
    if ($FileListPath -ne "") {
        $config.fileListPath = $FileListPath
    }
    
    if ($SelectionMode -ne "") {
        $config.selectionMode = $SelectionMode
    }
    
    # Step 2: Get files to include
    $filesToInclude = Get-FilesToInclude `
        -RepoPath $config.repoPath `
        -MaxFileSize $config.maxFileSize `
        -IgnoreFolders $config.ignoreFolders `
        -IgnoreFiles $config.ignoreFiles `
        -FileListPath $config.fileListPath `
        -SelectionMode $config.selectionMode
        if ( $filesToInclude.Count -eq 0 ) {
            Write-Host "–– DEBUG ––"
            Write-Host " RepoPath:      $($config.repoPath)"
            Write-Host " maxFileSize:   $($config.maxFileSize)"
            Write-Host " ignoreFolders: $($config.ignoreFolders -join ', ')"
            Write-Host " ignoreFiles:   $($config.ignoreFiles   -join ', ')"
            Write-Host " selectionMode: $($config.selectionMode)"
            Write-Host " fileListPath:  $($config.fileListPath)"
            Write-Host "––––––––––––––––"
        }
    
    # Step 3: Process and format files
    $resultContent = @()
    
    foreach ($file in $filesToInclude) {
        # Format file header with path
        $header = "File: $($file.Path)`r`n" + "-" * 60
        $resultContent += $header
        
        # Get and process file content
        $content = Get-FileContent -FilePath $file.Path -Replacements $config.replacements
        $resultContent += $content
        $resultContent += ""  # Add blank line between files
    }
    
    # Step 4: Copy to clipboard
    if ($resultContent.Count -gt 0) {
        $concatenated = $resultContent -join "`r`n"
        
        # Set clipboard
        Set-Clipboard -Value $concatenated
        
        # Optionally show files copied
        if ($config.showCopiedFiles) {
            $fileCount = $filesToInclude.Count
            Write-Host "✅ Copied $fileCount file(s) to clipboard." -ForegroundColor Green
            
            foreach ($file in $filesToInclude) {
                Write-Host "  - $($file.RelativePath)" -ForegroundColor DarkGray
            }
        } else {
            $fileCount = $filesToInclude.Count
            Write-Host "✅ Copied $fileCount file(s) to clipboard." -ForegroundColor Green
        }
        
        return $true
    } else {
        Write-Host "⚠️ No files found to copy." -ForegroundColor Yellow
        return $false
    }
}

# ───────────────────────────────────────────────────────────────────────
# Execute main function if script is run directly
# ───────────────────────────────────────────────────────────────────────
if ($MyInvocation.InvocationName -ne ".") {
    # Script was executed directly (not dot-sourced)
    $result = Copy-RepoToClipboard `
        -RepoPath $RepoPath `
        -ConfigFile $ConfigFile `
        -MaxFileSize $MaxFileSize `
        -ShowCopiedFiles:$ShowCopiedFiles `
        -FileListPath $FileListPath `
        -SelectionMode $SelectionMode
}