<#
.SYNOPSIS
    Step 6 - verify every layer of the stack. Read-only.

.DESCRIPTION
    Checks packages, ports, scheduled tasks, ANTHROPIC_BASE_URL, MCP servers and
    the OneDrive symlink, then prints a pass/fail table.

    Exit code 0 = healthy, 1 = at least one hard failure.
    Safe to run any time:  .\scripts\06-verify-stack.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
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

$ctx     = $global:StackContext
$d       = $ctx.Defaults
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Area,
        [string]$Name,
        [ValidateSet('ok', 'warn', 'fail')][string]$Status,
        [string]$Detail
    )
    $results.Add([pscustomobject]@{
        Area = $Area; Name = $Name; Status = $Status; Detail = $Detail
    })
}

Update-SessionPath

# ---- packages ----------------------------------------------------------
Write-Step 'Packages'

$lsOut = npm ls -g --depth=0 --json 2>$null
$pxVer = $null
if ($lsOut) {
    try {
        $tree = $lsOut | ConvertFrom-Json
        if ($tree.PSObject.Properties.Name -contains 'dependencies' -and
            $tree.dependencies.PSObject.Properties.Name -contains $d.PxpipePackage) {
            $pxVer = $tree.dependencies.($d.PxpipePackage).version
        }
    } catch { }
}
if ($pxVer) { Add-Result 'package' $d.PxpipePackage 'ok' "v$pxVer" }
else        { Add-Result 'package' $d.PxpipePackage 'fail' 'not installed globally' }

foreach ($p in 'headroom-ai', 'mempalace') {
    $show = pip show $p 2>$null
    if ($LASTEXITCODE -eq 0 -and $show) {
        $v = ($show | Select-String '^Version:\s*(.+)$').Matches.Groups[1].Value
        Add-Result 'package' $p 'ok' "v$v"
    } else {
        Add-Result 'package' $p 'fail' 'not installed'
    }
}

# ---- ports -------------------------------------------------------------
Write-Step 'Ports'

foreach ($spec in @(
    @{ Name = 'pxpipe';   Port = $d.PxpipePort;   Expect = 'node' },
    @{ Name = 'headroom'; Port = $d.HeadroomPort; Expect = 'python' }
)) {
    $l = Test-PortListening -Port $spec.Port
    if (-not $l) {
        Add-Result 'port' $spec.Name 'fail' "nothing listening on $($spec.Port)"
    } elseif ($l.ProcessName -notmatch $spec.Expect) {
        Add-Result 'port' $spec.Name 'warn' "$($spec.Port) held by $($l.ProcessName) (expected $($spec.Expect))"
    } else {
        Add-Result 'port' $spec.Name 'ok' "$($spec.Port) ($($l.ProcessName), pid $($l.ProcessId))"
    }
}

# ---- scheduled tasks ---------------------------------------------------
Write-Step 'Scheduled tasks'

foreach ($spec in @(
    @{ Task = $d.PxpipeTask;   Delay = $null },
    @{ Task = $d.HeadroomTask; Delay = $d.HeadroomDelay }
)) {
    $t = Get-ScheduledTask -TaskName $spec.Task -ErrorAction SilentlyContinue
    if (-not $t) {
        Add-Result 'task' $spec.Task 'fail' 'not registered'
        continue
    }
    $detail = "$($t.State)"
    $trigger = @($t.Triggers)[0]
    if ($trigger -and $trigger.PSObject.Properties.Name -contains 'Delay' -and $trigger.Delay) {
        $detail += " (logon +$($trigger.Delay))"
    } elseif ($trigger) {
        $detail += ' (logon)'
    }
    if ($spec.Delay -and (-not $trigger.Delay -or $trigger.Delay -ne $spec.Delay)) {
        Add-Result 'task' $spec.Task 'warn' "$detail - expected delay $($spec.Delay)"
    } else {
        Add-Result 'task' $spec.Task 'ok' $detail
    }
}

# ---- launchers ---------------------------------------------------------
Write-Step 'Silent launchers'

foreach ($v in 'pxpipe-silent.vbs', 'headroom-silent.vbs') {
    $p = Join-Path $env:USERPROFILE $v
    if (Test-Path $p) { Add-Result 'launcher' $v 'ok' $p }
    else              { Add-Result 'launcher' $v 'fail' 'missing' }
}

# ---- env ---------------------------------------------------------------
Write-Step 'Environment'

$persisted = [System.Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'User')
if ($persisted -eq $d.BaseUrl) {
    Add-Result 'env' 'ANTHROPIC_BASE_URL' 'ok' $persisted
} elseif ($persisted) {
    Add-Result 'env' 'ANTHROPIC_BASE_URL' 'warn' "= $persisted (expected $($d.BaseUrl))"
} else {
    Add-Result 'env' 'ANTHROPIC_BASE_URL' 'fail' 'not set at user scope'
}

# ---- chain reachability ------------------------------------------------
Write-Step 'Chain reachability'

foreach ($spec in @(
    @{ Name = 'headroom :8787';  Url = $d.BaseUrl },
    @{ Name = 'pxpipe   :47821'; Url = $d.UpstreamUrl }
)) {
    try {
        # Any HTTP answer - including 4xx - proves something is speaking HTTP.
        $null = Invoke-WebRequest -Uri $spec.Url -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Add-Result 'chain' $spec.Name 'ok' 'responding'
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { Add-Result 'chain' $spec.Name 'ok' 'responding (HTTP error, expected)' }
        else { Add-Result 'chain' $spec.Name 'fail' 'no response' }
    } catch {
        if ("$($_.Exception.Message)" -match 'refused|unable to connect') {
            Add-Result 'chain' $spec.Name 'fail' 'connection refused'
        } else {
            Add-Result 'chain' $spec.Name 'ok' 'responding (HTTP error, expected)'
        }
    }
}

# ---- MCP ---------------------------------------------------------------
Write-Step 'MCP servers'

$names = Get-McpServerNames
foreach ($expected in 'mempalace', 'playwright', 'headroom') {
    if ($names -contains $expected) { Add-Result 'mcp' $expected 'ok' 'registered (user scope)' }
    else                            { Add-Result 'mcp' $expected 'fail' 'not registered' }
}

# ---- symlink -----------------------------------------------------------
Write-Step 'OneDrive memory link'

$link = Join-Path $env:USERPROFILE '.claude\projects'
$item = Get-Item $link -Force -ErrorAction SilentlyContinue
if (-not $item) {
    Add-Result 'symlink' 'projects' 'fail' 'missing'
} elseif ($item.LinkType -ne 'SymbolicLink') {
    Add-Result 'symlink' 'projects' 'warn' 'real directory, not a symlink'
} else {
    $tgt = @($item.Target)[0]
    $n   = @(Get-ChildItem $link -Force -ErrorAction SilentlyContinue).Count
    if ($tgt -eq $d.OneDriveTarget) { Add-Result 'symlink' 'projects' 'ok' "-> $tgt ($n projects)" }
    else                            { Add-Result 'symlink' 'projects' 'warn' "-> $tgt (expected $($d.OneDriveTarget))" }
}

# ---- report ------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 76) -ForegroundColor DarkGray
Write-Host '  STACK VERIFICATION' -ForegroundColor White
Write-Host ('=' * 76) -ForegroundColor DarkGray

foreach ($r in $results) {
    $tag = switch ($r.Status) { 'ok' { '[ok]  ' } 'warn' { '[warn]' } 'fail' { '[fail]' } }
    $col = switch ($r.Status) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'fail' { 'Red' } }
    Write-Host ('  {0} {1,-9} {2,-16} {3}' -f $tag, $r.Area, $r.Name, $r.Detail) -ForegroundColor $col
}

$fails = @($results | Where-Object { $_.Status -eq 'fail' })
$warns = @($results | Where-Object { $_.Status -eq 'warn' })

Write-Host ''
Write-Host ("  {0} ok / {1} warn / {2} fail" -f `
    @($results | Where-Object { $_.Status -eq 'ok' }).Count, $warns.Count, $fails.Count) -ForegroundColor DarkGray

# Under install.ps1 this script runs in-process, so `exit` would tear down the
# whole installer before it could print its summary. Throw instead and let the
# step runner record the failure; only exit when invoked standalone.
$underInstaller = [bool](Get-Variable -Name StackInstallRun -Scope Global -ErrorAction SilentlyContinue)

if ($fails.Count -gt 0) {
    Write-Host ''
    Write-Fail 'stack is not fully healthy - see docs/troubleshooting.md'
    Write-Info 'if the proxies are simply not started yet, log out and back in'
    if ($underInstaller) { throw "$($fails.Count) verification check(s) failed" }
    exit 1
}

Write-Host ''
Write-Ok 'stack healthy'
if (-not $underInstaller) { exit 0 }
