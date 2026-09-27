<#
.SYNOPSIS
    Installs (or removes) RepoRaccoon for the current user. No admin rights needed.

.DESCRIPTION
    - Run from an extracted release folder: copies that folder's files.
    - Run as a one-liner (irm ... | iex): downloads the latest release from GitHub.
    Files go to %LOCALAPPDATA%\Programs\RepoRaccoon and that folder is added to the user PATH.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
    irm https://raw.githubusercontent.com/riigait/RepoRaccoon/main/install.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'Programs\RepoRaccoon'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Repo = 'riigait/RepoRaccoon'
$Files = @('reporaccoon.cmd', 'reporaccoon.ps1', 'reporaccoon-web.ps1', 'install.ps1','LICENSE', 'README.md', 'web', 'assets')

function Get-UserPath { [Environment]::GetEnvironmentVariable('Path', 'User') }
function Set-UserPath([string]$value) { [Environment]::SetEnvironmentVariable('Path', $value, 'User') }
function Split-PathList([string]$value) { @(($value -split ';') | Where-Object { $_ }) }

if ($Uninstall) {
    $cmd = Join-Path $Dir 'reporaccoon.ps1'
    if (Test-Path $cmd) {
        # Stop the background web server and remove the daily scan task, if present.
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File $cmd -stop *> $null } catch {}
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File $cmd -uninstall *> $null } catch {}
    }
    $kept = Split-PathList (Get-UserPath) | Where-Object { $_.TrimEnd('\') -ne $Dir.TrimEnd('\') }
    Set-UserPath ($kept -join ';')
    if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
    Write-Host "RepoRaccoon removed from $Dir and your PATH." -ForegroundColor Green
    Write-Host "Scan cache kept in $env:LOCALAPPDATA\RepoRaccoon (delete it by hand if you like)."
    return
}

# Source: the folder this script sits in (extracted release / git clone), else download the latest release.
$src = $null
$tmp = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'reporaccoon.ps1'))) {
    $src = $PSScriptRoot
} else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("reporaccoon-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'RepoRaccoon.zip'
    $url = "https://github.com/$Repo/releases/latest/download/RepoRaccoon.zip"
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $found = Get-ChildItem $tmp -Recurse -Filter 'reporaccoon.ps1' | Select-Object -First 1
    if (-not $found) { throw 'Download did not contain reporaccoon.ps1' }
    $src = $found.DirectoryName
}

try {
    if ((Resolve-Path $src).Path.TrimEnd('\') -ne $Dir.TrimEnd('\')) {
        # Stop a running server from an older install so its files can be replaced.
        $old = Join-Path $Dir 'reporaccoon.ps1'
        if (Test-Path $old) { try { & powershell -NoProfile -ExecutionPolicy Bypass -File $old -stop *> $null } catch {} }
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        foreach ($f in $Files) {
            $p = Join-Path $src $f
            if (Test-Path $p) { Copy-Item $p -Destination $Dir -Recurse -Force }
        }
    }
    # Files downloaded from the internet are blocked under RemoteSigned; unblock ours.
    Get-ChildItem $Dir -Recurse -File | Unblock-File

    $parts = Split-PathList (Get-UserPath)
    if (-not ($parts | Where-Object { $_.TrimEnd('\') -eq $Dir.TrimEnd('\') })) {
        Set-UserPath ((@($parts) + $Dir) -join ';')
        Write-Host "Added $Dir to your user PATH."
    }
    if (-not (($env:Path -split ';') -contains $Dir)) { $env:Path = "$env:Path;$Dir" }
} finally {
    if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

$version = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'reporaccoon.ps1') -v
Write-Host "$version installed to $Dir" -ForegroundColor Green

$policy = Get-ExecutionPolicy
if ($policy -in 'Restricted', 'AllSigned', 'Undefined') {
    Write-Host ""
    Write-Host "Note: PowerShell's execution policy is '$policy', so typing 'reporaccoon' inside PowerShell may be blocked." -ForegroundColor Yellow
    Write-Host "CMD works as-is. For PowerShell, either run 'reporaccoon.cmd', or allow local scripts with:"
    Write-Host "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}
Write-Host ""
Write-Host "Open a NEW terminal, then try:"
Write-Host "  reporaccoon -h          help"
Write-Host "  reporaccoon -w          web UI"
Write-Host "  reporaccoon -install    daily background scan (optional)"
