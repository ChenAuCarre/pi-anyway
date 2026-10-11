#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Git {
    & git.exe @args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $args" }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('pi deploy tests ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $remote = Join-Path $root 'remote'
    $runner = Join-Path $root 'script clone'
    $payload = Join-Path $root 'payload'
    foreach ($directory in @($remote, $runner, $payload)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    Git init $remote
    Git -C $remote config user.name Test
    Git -C $remote config user.email test@example.invalid
    Git init $runner
    Git -C $runner remote add origin $remote
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../deploy.ps1') -Destination $runner
    [IO.File]::WriteAllText((Join-Path $payload 'pi.exe'), 'fake executable')
    [IO.File]::WriteAllText((Join-Path $payload '.hidden'), 'hidden payload')
    New-Item -ItemType Directory -Path (Join-Path $payload 'resources') | Out-Null
    [IO.File]::WriteAllText((Join-Path $payload 'resources/data.txt'), 'required resource')
    $zip = Join-Path $root 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip)
    $bytes = [IO.File]::ReadAllBytes($zip)
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash

    function Publish([string]$Tag, [string]$Kind) {
        Git -C $remote checkout --orphan "dist/windows-x64/$Tag"
        Git -C $remote rm -rf --ignore-unmatch .
        $names = @('pi-windows-x64.zip')
        $data = $bytes
        if ($Kind -eq 'unsafe-zip') {
            $unsafe = Join-Path $root 'unsafe.zip'
            $archive = [IO.Compression.ZipFile]::Open($unsafe, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $archive.CreateEntry('../escape.txt')
                $stream = $entry.Open()
                try { $stream.WriteByte(42) } finally { $stream.Dispose() }
            } finally { $archive.Dispose() }
            $data = [IO.File]::ReadAllBytes($unsafe)
        }
        if ($Kind -in 'split', 'missing', 'unordered') {
            $names = @('pi-windows-x64.zip.001', 'pi-windows-x64.zip.002')
            $middle = [int][math]::Floor($data.Length / 2)
            [IO.File]::WriteAllBytes((Join-Path $remote $names[0]), $data[0..($middle - 1)])
            if ($Kind -ne 'missing') {
                [IO.File]::WriteAllBytes((Join-Path $remote $names[1]), $data[$middle..($data.Length - 1)])
            }
            if ($Kind -eq 'unordered') { [array]::Reverse($names) }
        } else {
            [IO.File]::WriteAllBytes((Join-Path $remote $names[0]), $data)
        }
        $digest = $hash
        if ($Kind -eq 'unsafe-zip') { $digest = (Get-FileHash -LiteralPath (Join-Path $remote $names[0])).Hash }
        if ($Kind -eq 'bad-hash') { $digest = '0' * 64 }
        if ($Kind -eq 'unsafe-manifest') { $names = @('../payload.zip') }
        $manifest = @{
            format_version = 1; platform = 'windows-x64'; upstream_tag = $Tag; version = $Tag.Substring(1)
            zip = @{ filename = 'pi-windows-x64.zip'; size_bytes = $data.Length; sha256 = $digest }
            artifacts = $names
        }
        if ($Kind -eq 'bad-size') { $manifest.zip.size_bytes++ }
        if ($Kind -eq 'wrong-version') { $manifest.upstream_tag = 'v9.9.9' }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $remote 'manifest.json')
        Git -C $remote add .
        Git -C $remote commit -m $Tag
    }
    Publish 'v1.0.0' 'single'
    Publish 'v1.0.1' 'split'
    $badCases = @('missing', 'bad-hash', 'bad-size', 'unsafe-manifest', 'unsafe-zip', 'unordered', 'wrong-version')
    for ($i = 0; $i -lt $badCases.Count; $i++) { Publish "v2.0.$i" $badCases[$i] }

    Remove-Item Function:Git

    function Deploy([string]$UserHome, [string]$Tag, [string]$Fault = '') {
        # Override HOME only in this function scope; never touch the real user installation.
        Set-Variable -Name HOME -Value $UserHome -Force
        function Move-Item {
            param($LiteralPath, $Destination)
            if (($Fault -eq 'replace' -and $LiteralPath -like '*installation') -or
                ($Fault -eq 'backup' -and $LiteralPath -like '*.partial')) {
                throw 'Simulated move failure'
            }
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination
        }
        & (Join-Path $runner 'deploy.ps1') -Version $Tag
    }
    $userHome = Join-Path $root 'user home'
    New-Item -ItemType Directory -Path $userHome | Out-Null
    $oldPath = $env:Path
    Deploy $userHome 'v1.0.0'
    $install = Join-Path $userHome 'pi'
    Assert ((Get-Content -LiteralPath (Join-Path $install 'pi.exe') -Raw) -eq 'fake executable') 'Single ZIP failed'
    Assert (Test-Path -LiteralPath (Join-Path $install 'resources/data.txt')) 'Resource omitted'
    [IO.File]::WriteAllText((Join-Path $install 'old.txt'), 'old installation')
    (Get-Item -LiteralPath (Join-Path $install '.hidden') -Force).Attributes = [IO.FileAttributes]::Hidden
    Deploy $userHome 'v1.0.1'
    Assert (-not (Test-Path -LiteralPath (Join-Path $install 'old.txt'))) 'Update did not replace old installation'
    $backups = @(Get-ChildItem -LiteralPath $userHome -Filter 'pi-backup-*.zip')
    Assert ($backups.Count -eq 1) 'Expected one backup'
    $archive = [IO.Compression.ZipFile]::OpenRead($backups[0].FullName)
    try {
        Assert ($null -ne $archive.GetEntry('old.txt')) 'Old file missing from backup'
        Assert ($null -ne $archive.GetEntry('.hidden')) 'Hidden file missing from backup'
        Assert (@($archive.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq 'resources/data.txt' }).Count -eq 1) 'Nested file missing from backup'
    } finally { $archive.Dispose() }
    [IO.File]::WriteAllText((Join-Path $install 'sentinel'), 'preserve me')
    foreach ($tag in (@('v8.0.0', '../bad') + @(0..($badCases.Count - 1) | ForEach-Object { "v2.0.$_" }))) {
        $failed = $false
        try { Deploy $userHome $tag } catch { $failed = $true }
        Assert $failed "Expected failure: $tag"
        Assert (Test-Path -LiteralPath (Join-Path $install 'sentinel')) "Old installation damaged: $tag"
        Assert (@(Get-ChildItem -LiteralPath $userHome -Force -Filter '.pi-deploy-*').Count -eq 0) 'Temporary directory leaked'
    }
    foreach ($fault in @('backup', 'replace')) {
        $failed = $false
        try { Deploy $userHome 'v1.0.0' $fault } catch { $failed = $true }
        Assert $failed "Expected $fault failure"
        Assert (Test-Path -LiteralPath (Join-Path $install 'sentinel')) "$fault failure damaged old installation"
        Assert (@(Get-ChildItem -LiteralPath $userHome -Force -Filter '.pi-rollback-*').Count -eq 0) 'Rollback directory leaked'
        Assert (@(Get-ChildItem -LiteralPath $userHome -Force -Filter '*.partial').Count -eq 0) 'Partial backup leaked'
    }
    $locked = [IO.File]::Open((Join-Path $install 'sentinel'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $failed = $false
        try { Deploy $userHome 'v1.0.0' } catch { $failed = $true }
        Assert $failed 'Expected locked-file backup failure'
        Assert (Test-Path -LiteralPath (Join-Path $install 'sentinel')) 'Locked-file failure damaged installation'
        Assert (@(Get-ChildItem -LiteralPath $userHome -Force -Filter '*.partial').Count -eq 0) 'Failed compression leaked a partial ZIP'
    } finally { $locked.Dispose() }
    $junction = Join-Path $install 'linked'
    New-Item -ItemType Junction -Path $junction -Target $payload | Out-Null
    try {
        $failed = $false
        try { Deploy $userHome 'v1.0.0' } catch { $failed = $true }
        Assert $failed 'Expected junction rejection'
        Assert (Test-Path -LiteralPath (Join-Path $payload 'pi.exe')) 'Junction target damaged'
    } finally { [IO.Directory]::Delete($junction) }
    Assert ($env:Path -ceq $oldPath) 'PATH was modified'
    Write-Host 'Deploy checks passed: Git fetch, ZIP/splits, validation, hidden-file backup, failure preservation and rollback.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
