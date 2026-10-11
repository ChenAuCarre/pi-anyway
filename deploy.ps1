#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
Get-Command git -ErrorAction Stop | Out-Null
$repository = & git -C $PSScriptRoot remote get-url origin
if ($LASTEXITCODE -ne 0 -or -not $repository) {
    throw 'Run this script from a clone of pi-anyway with an origin remote.'
}

$install = Join-Path $HOME 'pi'
$id = [guid]::NewGuid().ToString('N')
$work = Join-Path $HOME ".pi-deploy-$id"
$rollback = Join-Path $HOME ".pi-rollback-$id"
$backup = $null
$partialBackup = $null
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $source = Join-Path $work 'distribution'
    & git clone --depth 1 --single-branch --branch "dist/windows-x64/$Version" -- $repository $source
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch distribution $Version. Existing installation was not changed." }

    $manifest = Get-Content -LiteralPath (Join-Path $source 'manifest.json') -Raw | ConvertFrom-Json
    $filename = 'pi-windows-x64.zip'
    if ($manifest.format_version -ne 1 -or $manifest.platform -cne 'windows-x64' -or
        $manifest.upstream_tag -cne $Version -or $manifest.version -cne $Version.Substring(1) -or
        $manifest.zip.filename -cne $filename -or
        $manifest.zip.size_bytes -isnot [ValueType] -or $manifest.zip.size_bytes -le 0 -or
        $manifest.zip.size_bytes -ne [math]::Floor($manifest.zip.size_bytes) -or
        $manifest.zip.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'Invalid distribution manifest.'
    }
    $artifacts = @($manifest.artifacts)
    if ($artifacts.Count -eq 0) { throw 'Manifest has no artifacts.' }
    for ($i = 0; $i -lt $artifacts.Count; $i++) {
        $expected = if ($artifacts.Count -eq 1) { $filename } else {
            $filename + '.' + ($i + 1).ToString('D' + [math]::Max(3, $artifacts.Count.ToString().Length))
        }
        if ($artifacts[$i] -isnot [string] -or $artifacts[$i] -cne $expected) {
            throw 'Invalid or unordered artifact path in manifest.'
        }
    }

    $zip = Join-Path $work $filename
    $output = [IO.File]::Create($zip)
    try {
        foreach ($artifact in $artifacts) {
            $input = [IO.File]::OpenRead((Join-Path $source $artifact))
            try { $input.CopyTo($output) } finally { $input.Dispose() }
        }
    } finally { $output.Dispose() }
    if ((Get-Item -LiteralPath $zip).Length -ne $manifest.zip.size_bytes -or
        (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $manifest.zip.sha256) {
        throw 'ZIP size or SHA256 mismatch. Existing installation was not changed.'
    }

    $staging = Join-Path $work 'installation'
    New-Item -ItemType Directory -Path $staging | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $segments = $name.TrimEnd('/').Split('/')
            foreach ($segment in $segments) {
                if (-not $segment -or $segment -in '.', '..' -or
                    $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
                    $segment -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
                    throw "Unsafe ZIP entry: $name"
                }
            }
            if (($entry.ExternalAttributes -shr 16 -band 0xF000) -eq 0xA000) {
                throw "ZIP symbolic links are not supported: $name"
            }
        }
    } finally { $archive.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staging)
    if (-not (Test-Path -LiteralPath (Join-Path $staging 'pi.exe') -PathType Leaf)) {
        throw 'Official ZIP must contain pi.exe at its root.'
    }

    if (Test-Path -LiteralPath $install) {
        $existing = Get-Item -LiteralPath $install -Force
        if (-not $existing.PSIsContainer) { throw "$install is not a directory." }
        # Do not follow junctions or symlinks into unrelated data during backup or cleanup.
        if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Existing installation is a junction or symbolic link; back it up manually first.'
        }
        $items = @(Get-ChildItem -LiteralPath $install -Force -Recurse)
        if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
            throw 'Existing installation contains a junction or symbolic link; back it up manually first.'
        }
        $backup = Join-Path $HOME ("pi-backup-{0}-$id.zip" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $partialBackup = "$backup.partial"
        [IO.Compression.ZipFile]::CreateFromDirectory($install, $partialBackup)
        Move-Item -LiteralPath $partialBackup -Destination $backup
        Write-Host "Backup saved: $backup"
        Move-Item -LiteralPath $install -Destination $rollback
    }
    try {
        Move-Item -LiteralPath $staging -Destination $install
    } catch {
        $failure = $_
        if (Test-Path -LiteralPath $rollback) {
            try { Move-Item -LiteralPath $rollback -Destination $install } catch {
                Write-Warning "Could not restore the old installation. It is preserved at $rollback. Backup: $backup"
            }
        }
        throw $failure
    }
    if (Test-Path -LiteralPath $rollback) {
        try { Remove-Item -LiteralPath $rollback -Recurse -Force } catch {
            Write-Warning "Installed successfully, but could not remove old directory: $rollback"
        }
    }
    Write-Host "Installed $Version at $(Join-Path $install 'pi.exe')"
    Write-Host "Add this directory to your USER environment variable Path: $install"
    Write-Host 'Open a new terminal after changing Path, then run: pi --version'
} finally {
    foreach ($temporary in @($work, $partialBackup)) {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) {
            try { Remove-Item -LiteralPath $temporary -Recurse -Force } catch {
                Write-Warning "Could not clean temporary files: $temporary"
            }
        }
    }
}
