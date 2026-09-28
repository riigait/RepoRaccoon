# MCP stdio adapter. Launch from an MCP client; stdout is reserved for JSON-RPC.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Send-Reply($id, $result, $errorInfo) {
    $reply = @{ jsonrpc = '2.0'; id = $id }
    if ($null -ne $errorInfo) { $reply.error = $errorInfo } else { $reply.result = $result }
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $reply -Depth 12 -Compress))
    [Console]::Out.Flush()
}

$searchTool = @{
    name = 'find_repositories'
    description = 'Find local Git repositories under an explicit folder. Returns names, branches and paths; no remote URLs or file contents. Does not modify repositories. When includeNested is true, each result also reports NestedCount: how many other returned repos live inside it (submodules or repos-in-repos) - rerun with path set to that repo to drill into them.'
    inputSchema = @{
        type = 'object'; required = @('path'); additionalProperties = $false
        properties = @{
            path = @{ type = 'string'; description = 'Absolute folder path to scan.' }
            name = @{ type = 'string'; description = 'Optional repository name filter; wildcards supported.' }
            maxDepth = @{ type = 'integer'; minimum = 1; maximum = 10; default = 3 }
            includeNested = @{ type = 'boolean'; default = $false; description = 'Keep scanning inside repositories to find nested repositories and submodules.' }
        }
    }
    annotations = @{ readOnlyHint = $true; destructiveHint = $false; openWorldHint = $false }
}

while ($null -ne ($line = [Console]::ReadLine())) {
    try { $request = ConvertFrom-Json -InputObject $line -ErrorAction Stop }
    catch { Send-Reply $null $null @{ code = -32700; message = 'Parse error' }; continue }
    if ($null -eq $request -or $request -is [array] -or $request.jsonrpc -ne '2.0' -or
        $request.method -isnot [string]) {
        Send-Reply $null $null @{ code = -32600; message = 'Invalid request' }
        continue
    }
    # Notifications, including initialized and cancelled, receive no response.
    if ($null -eq $request.PSObject.Properties['id']) { continue }
    switch ($request.method) {
        'initialize' {
            Send-Reply $request.id @{
                protocolVersion = '2025-06-18'
                capabilities = @{ tools = @{} }
                serverInfo = @{ name = 'reporaccoon'; version = '1.1.0' }
            } $null
        }
        'ping' { Send-Reply $request.id @{} $null }
        'tools/list' { Send-Reply $request.id @{ tools = @($searchTool) } $null }
        'tools/call' {
            if ($request.params.name -ne 'find_repositories') {
                Send-Reply $request.id $null @{ code = -32602; message = 'Unknown tool' }
                continue
            }
            $argsObject = $request.params.arguments
            $invalid = $null -eq $argsObject -or $argsObject.path -isnot [string]
            if (-not $invalid) {
                $invalid = $argsObject.path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)'
                foreach ($property in $argsObject.PSObject.Properties.Name) {
                    if ($property -notin @('path', 'name', 'maxDepth', 'includeNested')) { $invalid = $true }
                }
                if ($null -ne $argsObject.PSObject.Properties['name'] -and $argsObject.name -isnot [string]) { $invalid = $true }
                if ($null -ne $argsObject.PSObject.Properties['includeNested'] -and $argsObject.includeNested -isnot [bool]) { $invalid = $true }
            }
            $depth = 3
            if ($null -ne $argsObject -and $null -ne $argsObject.PSObject.Properties['maxDepth']) {
                if (($argsObject.maxDepth -isnot [int] -and $argsObject.maxDepth -isnot [long]) -or
                    $argsObject.maxDepth -lt 1 -or $argsObject.maxDepth -gt 10) { $invalid = $true }
                else { $depth = [int]$argsObject.maxDepth }
            }
            if ($invalid) {
                Send-Reply $request.id $null @{ code = -32602; message = 'Expected absolute path, optional string name, integer maxDepth (1-10), and boolean includeNested.' }
                continue
            }
            try {
                if (-not [System.IO.Directory]::Exists($argsObject.path)) { throw 'Folder unavailable' }
                $filter = '*'
                if ($argsObject.name) { $filter = $argsObject.name }
                $json = & (Join-Path $PSScriptRoot 'reporaccoon.ps1') -Path $argsObject.path -Name $filter -MaxDepth $depth -IncludeNested:($argsObject.includeNested -eq $true) -Format Json -Exclude @('dist','build','.next','.nuxt','coverage','logs','uploads','temp','cache','vendor','generated','media','assets') 3>$null 6>$null
                $repos = @($json | ConvertFrom-Json | ForEach-Object { $_ } | Select-Object Name, Branch, Path)
                foreach ($r in $repos) {
                    $prefix = $r.Path.TrimEnd('\', '/') + '\'
                    $nestedCount = @($repos | Where-Object { $_.Path -ne $r.Path -and $_.Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) }).Count
                    $r | Add-Member -NotePropertyName NestedCount -NotePropertyValue $nestedCount -Force
                }
                $body = ConvertTo-Json -InputObject $repos -Depth 4 -Compress
                Send-Reply $request.id @{ content = @(@{ type = 'text'; text = $body }); isError = $false } $null
            } catch {
                Send-Reply $request.id @{ content = @(@{ type = 'text'; text = 'Could not scan folder. Check that it exists and is readable.' }); isError = $true } $null
            }
        }
        default { Send-Reply $request.id $null @{ code = -32601; message = 'Method not found' } }
    }
}
