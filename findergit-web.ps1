<#
.SYNOPSIS
    findergit web UI - local web server (http://localhost:<port>) for findergit.

.DESCRIPTION
    Serves web\index.html and a small JSON API. Scans run findergit.ps1 in a
    separate process. Only reachable from this PC. Start with "findergit -w".
#>
[CmdletBinding()]
param(
    [int]$Port = 7717,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$core = Join-Path $PSScriptRoot 'findergit.ps1'
$indexFile = Join-Path $PSScriptRoot 'web\index.html'
$cacheFile = Join-Path $env:LOCALAPPDATA 'findergit\cache.json'
$prefix = "http://localhost:$Port/"
$allowedHost = "localhost:$Port"

# Repo paths the UI may open (only paths from scan results / cache).
$known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

$scan = @{ Proc = $null; OutFile = $null; StartedAt = $null; Results = $null; Error = $null }
$script:running = $true

function ConvertTo-JsonString($obj) { ConvertTo-Json -InputObject $obj -Compress -Depth 5 }

function Add-Known([object[]]$repos) {
    foreach ($r in $repos) { if ($r -and $r.Path) { [void]$known.Add([string]$r.Path) } }
}

function Send-Response($ctx, [int]$code, [string]$body, [string]$type = 'application/json; charset=utf-8') {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $res = $ctx.Response
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['Cache-Control'] = 'no-store'
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
}

function Send-Error($ctx, [int]$code, [string]$message) {
    Send-Response $ctx $code (ConvertTo-JsonString @{ error = $message })
}

function Read-Body($req) {
    $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
    if (-not $text) { return [pscustomobject]@{} }
    return ($text | ConvertFrom-Json)
}

function Get-Drives {
    @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object {
        [pscustomobject]@{
            Letter = $_.Name.Substring(0, 1)
            Type   = [string]$_.DriveType
            Label  = $_.VolumeLabel
            SizeGB = [math]::Round($_.TotalSize / 1GB, 1)
            FreeGB = [math]::Round($_.AvailableFreeSpace / 1GB, 1)
        }
    })
}

function Update-ScanState {
    $p = $scan.Proc
    if (-not $p -or -not $p.HasExited) { return }
    try {
        if ($p.ExitCode -eq 0 -and [System.IO.File]::Exists($scan.OutFile)) {
            $raw = [System.IO.File]::ReadAllText($scan.OutFile).Trim()
            if (-not $raw) { $raw = '[]' }
            $parsed = $raw | ConvertFrom-Json
            Add-Known @($parsed)
            $scan.Results = $raw
        } elseif (-not $scan.Error) {
            $scan.Error = "Scan failed (exit code $($p.ExitCode)). See server window."
        }
    } catch {
        $scan.Error = "Could not read scan results: $($_.Exception.Message)"
    } finally {
        if ($scan.OutFile -and [System.IO.File]::Exists($scan.OutFile)) { Remove-Item -LiteralPath $scan.OutFile -Force }
        $scan.Proc = $null
    }
}

function Start-Scan($body) {
    if ($scan.Proc) { throw 'A scan is already running.' }

    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $core, '-f', 'json')

    $drives = @($body.drives | Where-Object { $_ })
    foreach ($d in $drives) { if ([string]$d -notmatch '^[A-Za-z]$') { throw "Invalid drive: $d" } }
    if ($drives.Count -gt 0) { $argsList += @('-d', ($drives -join ',')) }

    if ($body.path) {
        $p = [string]$body.path
        if ($p.Contains('"') -or -not [System.IO.Directory]::Exists($p)) { throw "Folder not found: $p" }
        $argsList += @('-p', $p)
    }
    if ($body.name) {
        $n = [string]$body.name
        if ($n.Length -gt 100 -or $n.Contains('"')) { throw 'Invalid name filter.' }
        $argsList += @('-n', $n)
    }
    $depth = 0
    if ($body.depth) { $depth = [int]$body.depth }
    if ($depth -lt 0 -or $depth -gt 100) { throw 'Depth must be 0-100.' }
    if ($depth -gt 0) { $argsList += @('-m', [string]$depth) }
    if ($body.appdata -eq $true) { $argsList += '-a' }

    $out = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "findergit-$([guid]::NewGuid().ToString('N')).json")
    $argsList += @('-o', $out)

    # Start-Process joins arguments with spaces: quote each one.
    # A trailing backslash would escape the closing quote (D:\" ), so double it.
    $quoted = $argsList | ForEach-Object { $a = [string]$_; if ($a.EndsWith('\')) { $a += '\' }; '"' + $a + '"' }
    $scan.Results = $null
    $scan.Error = $null
    $scan.OutFile = $out
    $scan.StartedAt = (Get-Date).ToString('o')
    $scan.Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $quoted -NoNewWindow -PassThru
    # Touch Handle now, otherwise ExitCode is empty after the process exits.
    $null = $scan.Proc.Handle
}

function Open-Repo($body) {
    $p = [string]$body.path
    if (-not $known.Contains($p) -or -not [System.IO.Directory]::Exists($p)) { throw 'Unknown repo path. Scan or load cache first.' }
    $q = $p
    if ($q.EndsWith('\')) { $q += '\' }
    $q = '"' + $q + '"'
    switch ([string]$body.app) {
        'explorer' { Start-Process -FilePath 'explorer.exe' -ArgumentList $q }
        'code' {
            $code = Get-Command code -ErrorAction SilentlyContinue
            if (-not $code) { throw 'VS Code "code" command not found in PATH.' }
            Start-Process -FilePath $code.Source -ArgumentList $q -WindowStyle Hidden
        }
        'terminal' {
            $wt = Get-Command wt -ErrorAction SilentlyContinue
            if ($wt) { Start-Process -FilePath $wt.Source -ArgumentList @('-d', $q) }
            else { Start-Process -FilePath 'powershell.exe' -WorkingDirectory $p }
        }
        default { throw 'Unknown app.' }
    }
}

function Invoke-Route($ctx) {
    $req = $ctx.Request
    $route = $req.Url.AbsolutePath.TrimEnd('/')
    $method = $req.HttpMethod

    if ($route -eq '' -and $method -eq 'GET') {
        Send-Response $ctx 200 ([System.IO.File]::ReadAllText($indexFile)) 'text/html; charset=utf-8'
        return
    }
    if (-not $route.StartsWith('/api/')) { Send-Error $ctx 404 'Not found'; return }

    # Only our own page may call the API: blocks other websites (CSRF / DNS rebinding).
    if ($req.Headers['Host'] -ne $allowedHost -or $req.Headers['X-Findergit'] -ne '1') {
        Send-Error $ctx 403 'Forbidden'
        return
    }

    switch ("$method $route") {
        'GET /api/drives' {
            Send-Response $ctx 200 (ConvertTo-JsonString @(Get-Drives))
        }
        'GET /api/cache' {
            if ([System.IO.File]::Exists($cacheFile)) {
                $raw = [System.IO.File]::ReadAllText($cacheFile)
                Add-Known @(($raw | ConvertFrom-Json).Repos)
                Send-Response $ctx 200 $raw
            } else {
                Send-Response $ctx 200 '{"ScannedAt":null,"Repos":[]}'
            }
        }
        'POST /api/scan' {
            try { Start-Scan (Read-Body $req) } catch { Send-Error $ctx 400 $_.Exception.Message; return }
            Send-Response $ctx 202 (ConvertTo-JsonString @{ running = $true; startedAt = $scan.StartedAt })
        }
        'GET /api/scan' {
            Update-ScanState
            $state = ConvertTo-JsonString @{ running = [bool]$scan.Proc; startedAt = $scan.StartedAt; error = $scan.Error }
            if ($scan.Results -and -not $scan.Proc) {
                $state = $state.TrimEnd('}') + ',"results":' + $scan.Results + '}'
            }
            Send-Response $ctx 200 $state
        }
        'POST /api/scan/stop' {
            if ($scan.Proc -and -not $scan.Proc.HasExited) {
                $scan.Proc.Kill()
                $scan.Error = 'Scan stopped.'
            }
            Send-Response $ctx 200 '{"ok":true}'
        }
        'POST /api/open' {
            try { Open-Repo (Read-Body $req) } catch { Send-Error $ctx 400 $_.Exception.Message; return }
            Send-Response $ctx 200 '{"ok":true}'
        }
        'POST /api/quit' {
            Send-Response $ctx 200 '{"ok":true}'
            $script:running = $false
        }
        default { Send-Error $ctx 404 'Not found' }
    }
}

# ---- main ----

if (-not [System.IO.File]::Exists($indexFile)) { throw "Missing $indexFile" }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try { $listener.Start() }
catch {
    Write-Host "Cannot start on port $Port : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Try another port: findergit -w -port 7718"
    return
}

Write-Host "findergit web UI running at $prefix" -ForegroundColor Green
Write-Host 'Press Ctrl+C (or "Stop server" in the page) to stop.' -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process $prefix }

try {
    while ($script:running -and $listener.IsListening) {
        $task = $listener.GetContextAsync()
        # Poll so Ctrl+C works and finished scans are picked up.
        while (-not $task.AsyncWaitHandle.WaitOne(250)) { Update-ScanState }
        $ctx = $task.GetAwaiter().GetResult()
        try { Invoke-Route $ctx }
        catch {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            try { Send-Error $ctx 500 $_.Exception.Message } catch { }
        }
    }
} finally {
    if ($scan.Proc -and -not $scan.Proc.HasExited) { $scan.Proc.Kill() }
    $listener.Stop()
    $listener.Close()
    Write-Host 'findergit web UI stopped.'
}
