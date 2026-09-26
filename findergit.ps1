<#
.SYNOPSIS
    findergit - find git repositories on Windows drives.

.DESCRIPTION
    Scans local drives (auto-detected) or given drives/paths for git
    repositories (folders containing a .git directory or .git file) and lists
    them with branch and origin remote. Does not need git.exe installed.
    Run "findergit -h" for usage.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # Repo folder name to search for. Plain text = contains; wildcards allowed.
    [Parameter(Position = 0)]
    [Alias('n')]
    [string]$Name = '*',

    # Drive letters to scan: D, D:, D:\ or several (C,D).
    [Alias('d')]
    [string[]]$Drive,

    # Folder paths to scan.
    [Alias('p')]
    [string[]]$Path,

    # Max folder depth below each root. 0 = unlimited.
    [Alias('m')]
    [int]$MaxDepth = 0,

    [Alias('f')]
    [ValidateSet('Table', 'List', 'Json', 'Csv', 'Path')]
    [string]$Format = 'Table',

    # Write output to file.
    [Alias('o')]
    [string]$OutFile,

    # Show results of the last full scan instantly (no scanning).
    [Alias('c')]
    [switch]$Cached,

    # List available drives.
    [Alias('l')]
    [switch]$ListDrives,

    # Keep scanning inside a found repo (nested repos / submodules).
    [Alias('nested')]
    [switch]$IncludeNested,

    # Also scan AppData folders (skipped by default: many tool-cache repos).
    [Alias('a')]
    [switch]$IncludeAppData,

    # Extra folder names to skip.
    [Alias('x')]
    [string[]]$Exclude = @(),

    # Start the local web UI (http://localhost:<Port>).
    [Alias('w')]
    [switch]$Web,

    [int]$Port = 7717,

    [Alias('v')]
    [switch]$Version,

    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$AppVersion = '1.2.0'
$CacheFile = Join-Path $env:LOCALAPPDATA 'findergit\cache.json'

function Show-Help {
    @"
findergit $AppVersion - find git repositories on your drives

USAGE
  findergit [name] [options]

EXAMPLES
  findergit                  find all git repos on all drives
  findergit -d D             find all git repos on drive D:
  findergit -d C,D           scan drives C: and D:
  findergit pappime          repos whose folder name contains "pappime"
  findergit api -d D         name filter + drive
  findergit -p D:\vs -m 3    scan a folder, max 3 levels deep
  findergit -c               show last full scan instantly (cache)
  findergit -c api           search the cache by name
  findergit -f json -o repos.json
  findergit -w               open the web UI in your browser

OPTIONS
  [name], -n <name>     Repo folder name (contains). Wildcards * ? allowed
  -d <drive>            Drive(s) to scan: D  D:  D:\  C,D
  -p <path>             Folder path(s) to scan
  -m <depth>            Max folder depth (0 = unlimited, default)
  -f <format>           table (default) | list | json | csv | path
  -o <file>             Save output to file
  -c                    Use cache from last full scan (no scanning)
  -l                    List available drives
  -a                    Also scan AppData folders (skipped by default)
  -x <names>            Extra folder names to skip: -x build,dist
  -nested               Keep scanning inside repos (submodules)
  -w                    Start web UI at http://localhost:7717 (Ctrl+C to stop)
  -port <n>             Web UI port (with -w)
  -v                 Show version
  -h                    Show this help

NOTES
  A full scan (no -d/-p/-m/name) is saved to the cache for "findergit -c".
  Skipped: Windows, `$Recycle.Bin, System Volume Information, node_modules,
  .venv, venv, __pycache__, .cache, AppData, symlinks/junctions.
"@
}

function Get-DefaultRoots {
    [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.IsReady -and ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') } |
        ForEach-Object { $_.RootDirectory.FullName }
}

function Show-Drives {
    [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object {
        [pscustomobject]@{
            Drive  = $_.Name
            Type   = $_.DriveType
            Label  = $_.VolumeLabel
            SizeGB = [math]::Round($_.TotalSize / 1GB, 1)
            FreeGB = [math]::Round($_.AvailableFreeSpace / 1GB, 1)
        }
    } | Format-Table -AutoSize | Out-String
}

function ConvertTo-DriveRoot([string]$d) {
    $letter = $d.Trim().TrimEnd('\').TrimEnd(':')
    if ($letter -notmatch '^[A-Za-z]$') { throw "Invalid drive '$d'. Use a letter like D, D: or D:\" }
    return ($letter.ToUpper() + ':\')
}

function Get-GitDir([string]$repo) {
    $dotGit = Join-Path $repo '.git'
    if ([System.IO.Directory]::Exists($dotGit)) { return $dotGit }
    # .git file (worktree / submodule): "gitdir: <path>"
    try {
        $line = [System.IO.File]::ReadAllText($dotGit).Trim()
        if ($line -match '^gitdir:\s*(.+)$') {
            $target = $Matches[1].Trim()
            if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $repo $target }
            return [System.IO.Path]::GetFullPath($target)
        }
    } catch { }
    return $null
}

function Get-RepoInfo([string]$repo) {
    $branch = ''
    $remote = ''
    $gitDir = Get-GitDir $repo
    if ($gitDir) {
        try {
            $head = [System.IO.File]::ReadAllText((Join-Path $gitDir 'HEAD')).Trim()
            if ($head -match '^ref:\s*refs/heads/(.+)$') { $branch = $Matches[1] }
            elseif ($head.Length -ge 7) { $branch = "(detached $($head.Substring(0, 7)))" }
        } catch { }

        # Worktrees keep config in the common dir.
        $configDir = $gitDir
        try {
            $common = Join-Path $gitDir 'commondir'
            if ([System.IO.File]::Exists($common)) {
                $c = [System.IO.File]::ReadAllText($common).Trim()
                if (-not [System.IO.Path]::IsPathRooted($c)) { $c = Join-Path $gitDir $c }
                $configDir = [System.IO.Path]::GetFullPath($c)
            }
            $config = [System.IO.File]::ReadAllText((Join-Path $configDir 'config'))
            if ($config -match '(?s)\[remote "origin"\][^\[]*?url\s*=\s*(\S+)') {
                # Hide credentials embedded in URLs (https://user:token@host).
                $remote = $Matches[1] -replace '(?<=://)[^/@]+@', '***@'
            }
        } catch { }
    }
    $modified = ''
    try { $modified = [System.IO.Directory]::GetLastWriteTime($repo).ToString('yyyy-MM-dd HH:mm') } catch { }

    [pscustomobject]@{
        Name     = Split-Path $repo -Leaf
        Path     = $repo
        Branch   = $branch
        Remote   = $remote
        Modified = $modified
    }
}

function Find-Repos([string[]]$roots, [string]$pattern) {
    $skipNames = @(
        'Windows', '$Recycle.Bin', 'System Volume Information', 'Recovery',
        '$WinREAgent', 'Config.Msi', 'WindowsApps',
        'node_modules', '.venv', 'venv', '__pycache__', '.cache'
    ) + $Exclude
    if (-not $IncludeAppData) { $skipNames += 'AppData' }
    $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $skipNames) { [void]$skip.Add($s) }

    $results = New-Object System.Collections.Generic.List[object]
    $scanned = 0
    $reparse = [System.IO.FileAttributes]::ReparsePoint

    foreach ($root in $roots) {
        if (-not [System.IO.Directory]::Exists($root)) {
            Write-Warning "Not found: $root"
            continue
        }
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push(@([System.IO.Path]::GetFullPath($root), 0))

        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            $dir = $item[0]
            $depth = $item[1]
            $scanned++
            if ($scanned % 1000 -eq 0) {
                Write-Progress -Activity 'findergit' -Status "$($results.Count) repos | $scanned folders | $dir"
            }

            try { $children = ([System.IO.DirectoryInfo]$dir).GetDirectories() }
            catch { continue }  # access denied, vanished, etc.

            $isRepo = $false
            foreach ($c in $children) { if ($c.Name -eq '.git') { $isRepo = $true; break } }
            if (-not $isRepo -and [System.IO.File]::Exists((Join-Path $dir '.git'))) { $isRepo = $true }

            if ($isRepo) {
                if ((Split-Path $dir -Leaf) -like $pattern) { $results.Add((Get-RepoInfo $dir)) }
                if (-not $IncludeNested) { continue }
            }

            if ($MaxDepth -gt 0 -and $depth -ge $MaxDepth) { continue }

            foreach ($c in $children) {
                if ($c.Name -eq '.git') { continue }
                if (($c.Attributes -band $reparse) -eq $reparse) { continue }  # symlink/junction: avoid loops
                if ($skip.Contains($c.Name)) { continue }
                $stack.Push(@($c.FullName, ($depth + 1)))
            }
        }
    }
    Write-Progress -Activity 'findergit' -Completed
    Write-Host "Scanned $scanned folders." -ForegroundColor DarkGray
    return , $results
}

# ---- main ----

if ($Help) { Show-Help; return }
if ($Version) { "findergit $AppVersion"; return }
if ($ListDrives) { Show-Drives; return }
if ($Web) { & (Join-Path $PSScriptRoot 'findergit-web.ps1') -Port $Port; return }

# Plain text name = "contains" match.
$pattern = $Name
if ($pattern -notmatch '[\*\?\[]') { $pattern = "*$pattern*" }

if ($Cached) {
    if (-not [System.IO.File]::Exists($CacheFile)) {
        Write-Warning 'No cache yet. Run "findergit" once (full scan) first.'
        return
    }
    $cache = [System.IO.File]::ReadAllText($CacheFile) | ConvertFrom-Json
    Write-Host "Cache from $($cache.ScannedAt)" -ForegroundColor DarkGray
    $results = @($cache.Repos | Where-Object { $_.Name -like $pattern })
} else {
    $roots = @()
    if ($Drive) { foreach ($d in ($Drive -split ',')) { if ($d.Trim()) { $roots += ConvertTo-DriveRoot $d } } }
    if ($Path) { $roots += $Path }
    $isFullScan = ($roots.Count -eq 0 -and $pattern -eq '*' -and $MaxDepth -eq 0)
    if ($roots.Count -eq 0) { $roots = @(Get-DefaultRoots) }

    Write-Host "Scanning: $($roots -join ', ')" -ForegroundColor DarkGray
    $results = Find-Repos $roots $pattern

    if ($isFullScan) {
        try {
            $dir = Split-Path $CacheFile -Parent
            if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
            $payload = [pscustomobject]@{
                ScannedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
                Repos     = @($results | Sort-Object Path)
            }
            [System.IO.File]::WriteAllText($CacheFile, ($payload | ConvertTo-Json -Depth 4))
        } catch { Write-Warning "Could not save cache: $($_.Exception.Message)" }
    }
}

$sorted = @($results | Sort-Object Path)

$out = switch ($Format) {
    'Table' { $sorted | Format-Table Name, Branch, Remote, Path -AutoSize | Out-String -Width 4096 }
    'List'  { $sorted | Format-List | Out-String -Width 4096 }
    'Json'  { ConvertTo-Json -InputObject $sorted -Depth 3 }
    'Csv'   { $sorted | ConvertTo-Csv -NoTypeInformation }
    'Path'  { $sorted | ForEach-Object { $_.Path } }
}

if ($OutFile) {
    $out | Out-File -FilePath $OutFile -Encoding utf8
    Write-Host "Saved $($sorted.Count) repos to $OutFile" -ForegroundColor Green
} else {
    $out
    Write-Host "Found $($sorted.Count) repos." -ForegroundColor Green
}
