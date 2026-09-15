<#
.SYNOPSIS
    Step 4 - install and register the MCP servers at user scope.

.DESCRIPTION
    MemPalace   pip install mempalace      -> claude mcp add mempalace  -s user
    Playwright  npx @playwright/mcp@latest -> claude mcp add playwright -s user
                (plus a one-off chromium download)
    Headroom    already installed in step 3 -> claude mcp add headroom -s user

    User scope means the servers are available in every project, not just the
    directory you happened to run this from.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command Write-Step -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '_common.ps1')
}
if (-not (Get-Variable -Name StackContext -Scope Global -ErrorAction SilentlyContinue)) {
    $global:StackContext = @{
        Root      = (Split-Path -Parent $PSScriptRoot)
        ConfigDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config')
        Defaults  = Get-StackDefaults
    }
}

$ctx = $global:StackContext

if (-not (Get-CommandPath 'claude')) {
    throw 'claude not found on PATH - cannot register MCP servers.'
}

# ---- MemPalace ---------------------------------------------------------
Write-Step 'MemPalace'

$mpInstalled = $false
$show = pip show mempalace 2>$null
if ($LASTEXITCODE -eq 0 -and $show) {
    $ver = ($show | Select-String '^Version:\s*(.+)$').Matches.Groups[1].Value
    Write-Skip "mempalace $ver already installed"
    $mpInstalled = $true
}
if (-not $mpInstalled) {
    Invoke-Change 'pip install mempalace' {
        & pip install mempalace 2>&1 |
            ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { throw "pip install mempalace failed (exit $LASTEXITCODE)" }
    } | Out-Null
    Update-SessionPath
}

Add-McpServer -Name 'mempalace' -Command 'mempalace-mcp'

# ---- Playwright --------------------------------------------------------
Write-Step 'Playwright MCP'

# Warm the npx cache and download the browser binary now, so the first
# Claude Code session that touches Playwright is not blocked on a download.
Invoke-Change 'npx playwright install chromium' {
    & npx --yes playwright install chromium 2>&1 |
        Select-Object -Last 8 |
        ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "chromium download returned exit $LASTEXITCODE - Playwright will retry on first use"
    }
} | Out-Null

Add-McpServer -Name 'playwright' -Command 'npx' -CommandArgs @('@playwright/mcp@latest')

# ---- Headroom MCP ------------------------------------------------------
Write-Step 'Headroom MCP'

$headroomExe = $null
if ($ctx.ContainsKey('HeadroomExe')) { $headroomExe = $ctx['HeadroomExe'] }
if (-not $headroomExe) { $headroomExe = Get-CommandPath 'headroom' }

if (-not $headroomExe) {
    Write-Warn2 'headroom.exe not found - skipping its MCP registration (proxy is unaffected)'
} else {
    Add-McpServer -Name 'headroom' -Command $headroomExe -CommandArgs @('mcp', 'serve')
}

# ---- report ------------------------------------------------------------
Write-Step 'Registered MCP servers (user scope)'
$names = Get-McpServerNames
if ($names.Count -eq 0) {
    Write-Warn2 'no MCP servers found in ~\.claude.json'
} else {
    foreach ($n in $names) { Write-Ok $n }
}
Write-Info 'health check: claude mcp list'
