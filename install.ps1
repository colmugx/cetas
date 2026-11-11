#requires -Version 5.1
<#
.SYNOPSIS
Install Cetas Native for Windows x64 from a verified GitHub release.
.DESCRIPTION
Shows the installation plan and requests terminal approval before fetching
binary assets or modifying the destination. The DLL must remain beside EXE.
.EXAMPLE
.\install.ps1
.EXAMPLE
.\install.ps1 -Version 0.11.2 -InstallDir "$HOME\.local\bin"
.EXAMPLE
.\install.ps1 -Yes
#>
[CmdletBinding()]
param(
    [Alias("ReleaseVersion")]
    [string] $Version = "",
    [string] $InstallDir = "",
    [switch] $Yes
)

$ErrorActionPreference = "Stop"
$repo = if ($env:CETAS_REPO) { $env:CETAS_REPO } else { "colmugx/cetas" }
if (-not $InstallDir) {
    $InstallDir = if ($env:CETAS_INSTALL_DIR) {
        $env:CETAS_INSTALL_DIR
    } else {
        Join-Path $HOME ".local\bin"
    }
}
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

if (-not [Environment]::Is64BitOperatingSystem -or
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw "Cetas Native Windows release requires Windows x64."
}

# Only read GitHub release metadata before displaying the plan.
if (-not $Version) {
    $releases = Invoke-RestMethod "https://api.github.com/repos/$repo/releases?per_page=30"
    $latest = $releases | Where-Object {
        $_.tag_name -match '^cetas-v\d+\.\d+\.\d+$'
    } | Select-Object -First 1
    if (-not $latest) {
        throw "Could not locate a Cetas release. Supply -Version X.Y.Z."
    }
    $Version = $latest.tag_name.Substring("cetas-v".Length)
}

$Version = $Version -replace '^cetas-v', ''
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid version '$Version': expected X.Y.Z."
}
$tag = "cetas-v$Version"
$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/$tag"
$assetName = "cetas-windows-x64.zip"
if (-not ($release.assets | Where-Object { $_.name -eq $assetName })) {
    throw "Release $tag does not contain $assetName. No installation attempted."
}
if (-not ($release.assets | Where-Object { $_.name -eq "SHA256SUMS" })) {
    throw "Release $tag does not contain SHA256SUMS. No installation attempted."
}
$baseUrl = "https://github.com/$repo/releases/download/$tag"
$files = @("cetas.exe", "cetas-acp.exe", "cetas-run.exe", "cetas_moon.dll")

Write-Host ""
Write-Host "Cetas Native installation plan"
Write-Host "  System:       Windows x64"
Write-Host "  Version:      $Version"
Write-Host "  Repository:   $repo"
Write-Host "  Destination:  $InstallDir"
Write-Host "  Release:      $baseUrl"
Write-Host "  Archive:      $assetName"
Write-Host "  Files to install:"
foreach ($name in $files) {
    $target = Join-Path $InstallDir $name
    $suffix = if (Test-Path -LiteralPath $target) { " (will replace existing file)" } else { "" }
    Write-Host "    $name$suffix"
}
Write-Host "  DLL loading:  cetas_moon.dll must remain beside cetas.exe"
Write-Host ""

if (-not $Yes) {
    if ([Console]::IsInputRedirected) {
        throw "No interactive terminal. Installation cancelled. Use -Yes for automation."
    }
    $answer = Read-Host "Proceed with installation? [y/N]"
    if ($answer -notmatch '^(?i:y|yes)$') {
        Write-Host "Installation cancelled; no files changed."
        return
    }
}

# Binary download begins only after explicit approval.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cetas-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $zipPath = Join-Path $tmp $assetName
    $sumsPath = Join-Path $tmp "SHA256SUMS"
    Invoke-WebRequest -Uri "$baseUrl/SHA256SUMS" -OutFile $sumsPath -UseBasicParsing
    Invoke-WebRequest -Uri "$baseUrl/$assetName" -OutFile $zipPath -UseBasicParsing

    $pattern = '^([0-9a-fA-F]{64})\s+\*?cetas-windows-x64\.zip$'
    $expected = $null
    foreach ($line in [System.IO.File]::ReadAllLines($sumsPath)) {
        if ($line -match $pattern) {
            $expected = $Matches[1]
            break
        }
    }
    if (-not $expected) {
        throw "Release checksum file does not contain $assetName."
    }
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actual -ne $expected) {
        throw "SHA256 mismatch for $assetName (want $expected, got $actual)."
    }

    $unpacked = Join-Path $tmp "unpacked"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $unpacked -Force

    # Require exactly the expected named payload files at archive root.
    foreach ($name in $files) {
        $file = Join-Path $unpacked $name
        if (-not [System.IO.File]::Exists($file)) {
            throw "Missing required file in release ZIP: $name"
        }
        $attr = [System.IO.File]::GetAttributes($file)
        if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unexpected reparse point in release ZIP: $name"
        }
    }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    foreach ($name in $files) {
        Copy-Item -LiteralPath (Join-Path $unpacked $name) -Destination (Join-Path $InstallDir $name) -Force
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Installed Cetas Native $Version into $InstallDir"
& (Join-Path $InstallDir "cetas.exe") --version
if ($LASTEXITCODE -ne 0) { throw "Installed cetas.exe failed --version smoke test." }
& (Join-Path $InstallDir "cetas.exe") acp --version
if ($LASTEXITCODE -ne 0) { throw "Installed cetas ACP entry point failed." }
& (Join-Path $InstallDir "cetas.exe") run --version
if ($LASTEXITCODE -ne 0) { throw "Installed cetas Run entry point failed." }

$pathEntries = @($env:PATH -split ';' | ForEach-Object { $_.TrimEnd('\') })
if ($pathEntries -notcontains $InstallDir.TrimEnd('\')) {
    Write-Host "Note: $InstallDir is not on PATH; add it to run cetas from any directory."
}
