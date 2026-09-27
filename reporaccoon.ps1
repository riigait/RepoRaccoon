<#
.SYNOPSIS
    RepoRaccoon - find git repositories on Windows drives.

.DESCRIPTION
    Scans local drives (auto-detected) or given drives/paths for git
    repositories (folders containing a .git directory or .git file) and lists
    them with branch and origin remote. Does not need git.exe installed.
    Run "reporaccoon -h" for usage.
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

    # With -w: run the web server in this window (visible log, no auto-stop) instead of hidden.
    [Alias('fg')]
    [switch]$Foreground,

    # Stop the background web server.
    [switch]$Stop,

    # Daily background scan (Windows Task Scheduler, current user only).
    [switch]$Install,
    [string]$At = '12:30',
    [switch]$Uninstall,
    # Hidden full scan that only refreshes the cache (what the scheduled task runs).
    [switch]$Background,

    [Alias('v')]
    [switch]$Version,

    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$AppName = 'RepoRaccoon'
$AppVersion = '1.5.0'
$CacheFile = Join-Path $env:LOCALAPPDATA 'RepoRaccoon\cache.json'
$LogFile = Join-Path $env:LOCALAPPDATA 'RepoRaccoon\background.log'
$TaskName = 'RepoRaccoon daily scan'

function Show-Help {
    @"
$AppName $AppVersion - sniffs out the git repositories on your drives

USAGE
  reporaccoon [name] [options]

EXAMPLES
  reporaccoon                find all git repos on all drives
  reporaccoon -d D           find all git repos on drive D:
  reporaccoon -d C,D         scan drives C: and D:
  reporaccoon pappime        repos whose folder name contains "pappime"
  reporaccoon api -d D       name filter + drive
  reporaccoon -p D:\vs -m 3  scan a folder, max 3 levels deep
  reporaccoon -c             show last full scan instantly (cache)
  reporaccoon -c api         search the cache by name
  reporaccoon -f json -o repos.json
  reporaccoon -w             open the web UI in your browser

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
  -w                    Open the web UI (http://localhost:7717); the server runs hidden
                        and stops by itself 10 min after the last page is closed
  -stop                 Stop the web UI server now
  -fg                   With -w: run the server in this window instead (Ctrl+C to stop)
  -port <n>             Web UI port (with -w / -stop)
  -install [-at 12:30]  Scan automatically every day (and 5 min after logon), hidden
  -uninstall            Remove the automatic daily scan
  -v                    Show version
  -h                    Show this help

NOTES
  A full scan (no -d/-p/-m/name) is saved to the cache for "reporaccoon -c".
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

# Commits made on this PC per day (last year), from the HEAD reflog.
# Returns @{ 'yyyy-MM-dd' = count }. Pulled/cloned commits are not counted.
function Get-Activity([string]$gitDir) {
    $days = @{}
    $log = Join-Path $gitDir 'logs\HEAD'
    if (-not [System.IO.File]::Exists($log)) { return $days }
    $cutoff = [DateTimeOffset]::Now.AddDays(-371).ToUnixTimeSeconds()
    try {
        foreach ($line in [System.IO.File]::ReadLines($log)) {
            if ($line.IndexOf("`tcommit") -lt 0) { continue }
            # "<old> <new> Name <email> <unix-time> <tz>`tcommit (initial|amend|merge): msg"
            if ($line -match '> (\d+) [+-]\d{4}\tcommit[^:]*:') {
                $ts = [long]$Matches[1]
                if ($ts -lt $cutoff) { continue }
                $d = [DateTimeOffset]::FromUnixTimeSeconds($ts).LocalDateTime.ToString('yyyy-MM-dd')
                if ($days.ContainsKey($d)) { $days[$d]++ } else { $days[$d] = 1 }
            }
        }
    } catch { }
    return $days
}

function Get-RepoInfo([string]$repo) {
    $branch = ''
    $remote = ''
    $activity = @{}
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

        $activity = Get-Activity $gitDir
    }
    $modified = ''
    try { $modified = [System.IO.Directory]::GetLastWriteTime($repo).ToString('yyyy-MM-dd HH:mm') } catch { }

    [pscustomobject]@{
        Name     = Split-Path $repo -Leaf
        Path     = $repo
        Branch   = $branch
        Remote   = $remote
        Modified = $modified
        Activity = $activity
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
                Write-Progress -Activity $AppName -Status "$($results.Count) repos | $scanned folders | $dir"
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
    Write-Progress -Activity $AppName -Completed
    Write-Host "Scanned $scanned folders." -ForegroundColor DarkGray
    return , $results
}

# Save a full scan as the cache. Written to a temp file first and then swapped in,
# so the web UI never reads a half-written file while a background scan saves.
function Save-Cache($results) {
    $dir = Split-Path $CacheFile -Parent
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $payload = [pscustomobject]@{
        ScannedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Repos     = @($results | Sort-Object Path)
    }
    $tmp = "$CacheFile.tmp"
    [System.IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Depth 4))
    # [NullString]::Value = real null (a plain $null reaches .NET as "" and Replace rejects it).
    if ([System.IO.File]::Exists($CacheFile)) { [System.IO.File]::Replace($tmp, $CacheFile, [NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $CacheFile) }
}

function Write-Log([string]$msg) {
    Write-Host $msg  # also to stdout (captured if the task output is redirected)
    try {
        $lines = @()
        if ([System.IO.File]::Exists($LogFile)) { $lines = @([System.IO.File]::ReadAllLines($LogFile) | Select-Object -Last 99) }
        $lines += "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  $msg"
        [System.IO.File]::WriteAllLines($LogFile, [string[]]$lines)
    } catch { Write-Host "could not write log: $($_.Exception.Message)" }
}

function Install-Schedule {
    if ($At -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw "Invalid time '$At'. Use HH:mm, e.g. -at 09:00" }
    $script = Join-Path $PSScriptRoot 'reporaccoon.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Background"
    $daily = New-ScheduledTaskTrigger -Daily -At $At
    $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $logon.Delay = 'PT5M'  # let Windows settle after login
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    # Interactive = runs as you while you're logged in (no admin rights or stored password needed).
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $daily, $logon -Settings $settings `
        -Principal $principal -Description "${AppName}: refresh the repo cache (full scan, hidden)." -Force -ErrorAction Stop | Out-Null
    $info = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
    Write-Host "Automatic scan installed: every day at $At and 5 min after you log in (hidden)." -ForegroundColor Green
    Write-Host "Next run: $($info.NextRunTime)   Log: $LogFile" -ForegroundColor DarkGray
    Write-Host "Remove with: reporaccoon -uninstall" -ForegroundColor DarkGray
}

function Uninstall-Schedule {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host 'Automatic scan removed.' -ForegroundColor Green
    } else {
        Write-Host 'Automatic scan was not installed.' -ForegroundColor DarkGray
    }
}

# ---- web UI server (hidden background process) ----
$WebIdleMinutes = 10

function Test-WebUI {
    $ProgressPreference = 'SilentlyContinue'
    try {
        $r = Invoke-WebRequest "http://localhost:$Port/api/ping" -Headers @{ 'X-RepoRaccoon' = '1' } -UseBasicParsing -TimeoutSec 2
        return $r.StatusCode -eq 200
    } catch { return $false }
}

function Start-WebUI {
    $web = Join-Path $PSScriptRoot 'reporaccoon-web.ps1'
    $url = "http://localhost:$Port/"
    if ($Foreground) { & $web -Port $Port; return }  # old behaviour: visible, Ctrl+C to stop

    if (Test-WebUI) {
        Write-Host "RepoRaccoon is already running at $url" -ForegroundColor Green
    } else {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$web`"",
            '-Port', $Port, '-NoBrowser', '-IdleMinutes', $WebIdleMinutes)
        $ok = $false
        for ($i = 0; $i -lt 40 -and -not $ok; $i++) { Start-Sleep -Milliseconds 250; $ok = Test-WebUI }
        if (-not $ok) {
            Write-Warning "Could not start the web UI on port $Port (is the port in use?). Try: reporaccoon -w -port 7718   or see errors with: reporaccoon -w -fg"
            return
        }
        Write-Host "RepoRaccoon is running in the background at $url" -ForegroundColor Green
    }
    Write-Host "It stops by itself $WebIdleMinutes min after you close the page. Stop now: reporaccoon -stop" -ForegroundColor DarkGray
    Start-Process $url
}

function Stop-WebUI {
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest "http://localhost:$Port/api/quit" -Method Post -Headers @{ 'X-RepoRaccoon' = '1' } -UseBasicParsing -TimeoutSec 3 | Out-Null
        Write-Host 'RepoRaccoon web UI stopped.' -ForegroundColor Green
    } catch {
        Write-Host "RepoRaccoon web UI is not running (port $Port)." -ForegroundColor DarkGray
    }
}

# ---- main ----

if ($Help) { Show-Help; return }
if ($Version) { "$AppName $AppVersion"; return }
if ($ListDrives) { Show-Drives; return }
if ($Web) { Start-WebUI; return }
if ($Stop) { Stop-WebUI; return }
if ($Install) { Install-Schedule; return }
if ($Uninstall) { Uninstall-Schedule; return }
if ($Background) {
    $t0 = Get-Date
    try {
        $results = Find-Repos @(Get-DefaultRoots) '*'
        Save-Cache $results
        Write-Log "background scan: $($results.Count) repos in $([int](((Get-Date) - $t0).TotalSeconds))s"
    } catch {
        Write-Log "background scan FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
        exit 1
    }
    return
}

# Plain text name = "contains" match.
$pattern = $Name
if ($pattern -notmatch '[\*\?\[]') { $pattern = "*$pattern*" }

if ($Cached) {
    if (-not [System.IO.File]::Exists($CacheFile)) {
        Write-Warning 'No cache yet. Run "reporaccoon" once (full scan) first.'
        return
    }
    $cache = [System.IO.File]::ReadAllText($CacheFile) | ConvertFrom-Json
    Write-Host "Cache from $($cache.ScannedAt)" -ForegroundColor DarkGray
    try {
        $age = (Get-Date) - [datetime]::ParseExact($cache.ScannedAt, 'yyyy-MM-dd HH:mm', $null)
        if ($age.TotalDays -ge 1) {
            Write-Host "Cache is $([int][math]::Floor($age.TotalDays)) day(s) old - may be missing new repos. Run 'reporaccoon' to refresh." -ForegroundColor Yellow
        }
    } catch { }
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
        try { Save-Cache $results } catch { Write-Warning "Could not save cache: $($_.Exception.Message)" }
    }
}

$sorted = @($results | Sort-Object Path)

$out = switch ($Format) {
    'Table' { $sorted | Format-Table Name, Branch, Remote, Path -AutoSize | Out-String -Width 4096 }
    'List'  { $sorted | Select-Object -ExcludeProperty Activity -Property * | Format-List | Out-String -Width 4096 }
    'Json'  { ConvertTo-Json -InputObject $sorted -Depth 3 }
    'Csv'   { $sorted | Select-Object -ExcludeProperty Activity -Property * | ConvertTo-Csv -NoTypeInformation }
    'Path'  { $sorted | ForEach-Object { $_.Path } }
}

if ($OutFile) {
    $out | Out-File -FilePath $OutFile -Encoding utf8
    Write-Host "Saved $($sorted.Count) repos to $OutFile" -ForegroundColor Green
} else {
    $out
    Write-Host "Found $($sorted.Count) repos." -ForegroundColor Green
}
