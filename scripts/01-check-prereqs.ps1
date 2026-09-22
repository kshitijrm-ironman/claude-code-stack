<#
.SYNOPSIS
    Step 1 - verify everything the stack needs before any change is made.

.DESCRIPTION
    Read-only. Fails fast with an actionable message rather than letting a later
    step die halfway through. Runnable standalone.
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
        Root         = (Split-Path -Parent $PSScriptRoot)
        ConfigDir    = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config')
        OneDrivePath = $null
        Defaults     = Get-StackDefaults
    }
}

$ctx  = $global:StackContext
$errs = New-Object System.Collections.Generic.List[string]
$warn = New-Object System.Collections.Generic.List[string]

Update-SessionPath

# Ensure the npm global bin is in PATH so claude is findable in elevated sessions
# where the User PATH from the registry may belong to a different account.
$npmGlobalBin = & npm root -g 2>$null | Select-Object -First 1
if ($npmGlobalBin) {
    $npmBin = Split-Path -Parent $npmGlobalBin.Trim()
    if ($env:Path -notlike "*$npmBin*") { $env:Path += ";$npmBin" }
}

# ---- OS ----------------------------------------------------------------
Write-Step 'Operating system'
try {
    $os = Assert-Windows11
    Write-Ok "OS: $os"
} catch {
    $errs.Add($_.Exception.Message)
    Write-Fail $_.Exception.Message
}

# ---- elevation ---------------------------------------------------------
Write-Step 'Elevation'
if (Test-IsAdmin) {
    Write-Ok 'running as Administrator'
} else {
    $msg = 'Not running as Administrator. Scheduled-task registration (steps 2-3) will fail.'
    $errs.Add($msg)
    Write-Fail $msg
    Write-Info 'Re-launch: Start-Process powershell -Verb RunAs'
}

# ---- Node / npm --------------------------------------------------------
Write-Step 'Node.js and npm'
$nodeExe = Get-CommandPath 'node'
if (-not $nodeExe) {
    $errs.Add('node.exe not found on PATH. Install Node.js 18+ from https://nodejs.org')
    Write-Fail 'node not found'
} else {
    $nodeVer = (& node --version).TrimStart('v')
    $major   = [int]($nodeVer.Split('.')[0])
    if ($major -lt 18) {
        $errs.Add("Node $nodeVer is too old; need 18 or newer.")
        Write-Fail "node $nodeVer (need >= 18)"
    } else {
        Write-Ok "node $nodeVer at $nodeExe"
    }
    $ctx['NodeExe'] = $nodeExe
}

if (-not (Get-CommandPath 'npm')) {
    $errs.Add('npm not found on PATH.')
    Write-Fail 'npm not found'
} else {
    Write-Ok "npm $(& npm --version)"
}

# ---- Python / pip ------------------------------------------------------
Write-Step 'Python and pip'
$pyExe = Get-CommandPath 'python'
if (-not $pyExe) {
    $errs.Add('python.exe not found on PATH. Install Python 3.10+ and tick "Add to PATH".')
    Write-Fail 'python not found'
} else {
    $pyRaw = (& python --version 2>&1) -replace '^Python\s+', ''
    $parts = $pyRaw.Split('.')
    $pyOk  = ([int]$parts[0] -gt 3) -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 10)
    if (-not $pyOk) {
        $errs.Add("Python $pyRaw is too old; need 3.10 or newer.")
        Write-Fail "python $pyRaw (need >= 3.10)"
    } else {
        Write-Ok "python $pyRaw at $pyExe"
    }
    $ctx['PythonExe'] = $pyExe
}

if (-not (Get-CommandPath 'pip')) {
    $errs.Add('pip not found on PATH. Try: python -m ensurepip --upgrade')
    Write-Fail 'pip not found'
} else {
    Write-Ok ((& pip --version) -split ' from ')[0]
}

# ---- Claude Code -------------------------------------------------------
Write-Step 'Claude Code'
$claudeExe = Get-CommandPath 'claude'
if (-not $claudeExe) {
    $errs.Add('claude not found on PATH. Install: npm install -g @anthropic-ai/claude-code')
    Write-Fail 'claude not found'
} else {
    $cv = (& claude --version 2>&1 | Select-Object -First 1)
    Write-Ok "claude $cv"
    $ctx['ClaudeExe'] = $claudeExe
}

# ---- OneDrive ----------------------------------------------------------
Write-Step 'OneDrive'
$target = $null
if ($ctx.ContainsKey('OneDrivePath')) { $target = $ctx['OneDrivePath'] }
if (-not $target) { $target = $ctx.Defaults.OneDriveTarget }
$oneDriveRoot = Split-Path -Parent (Split-Path -Parent $target)   # D:\OneDrive
if (Test-Path $oneDriveRoot) {
    Write-Ok "OneDrive root present: $oneDriveRoot"
} else {
    $msg = "OneDrive root not found: $oneDriveRoot (step 5 will fail; use -OneDrivePath or -SkipSteps 5)"
    $warn.Add($msg)
    Write-Warn2 $msg
}

# ---- port availability -------------------------------------------------
Write-Step 'Ports'
foreach ($spec in @(
    @{ Port = $ctx.Defaults.PxpipePort;   Who = 'pxpipe' },
    @{ Port = $ctx.Defaults.HeadroomPort; Who = 'headroom' }
)) {
    $l = Test-PortListening -Port $spec.Port
    if (-not $l) {
        Write-Ok "port $($spec.Port) free (for $($spec.Who))"
    } else {
        Write-Info "port $($spec.Port) already bound by $($l.ProcessName) pid $($l.ProcessId) - likely $($spec.Who) already running"
    }
}

# ---- templates ---------------------------------------------------------
Write-Step 'Repo templates'
foreach ($t in 'pxpipe-silent.vbs', 'headroom-silent.vbs') {
    $p = Join-Path $ctx.ConfigDir $t
    if (Test-Path $p) {
        Write-Ok "template present: config\$t"
    } else {
        $errs.Add("Missing template: $p")
        Write-Fail "template missing: config\$t"
    }
}

# ---- verdict -----------------------------------------------------------
Write-Host ''
if ($warn.Count -gt 0) {
    Write-Warn2 "$($warn.Count) warning(s) - install can continue"
}
if ($errs.Count -gt 0) {
    Write-Host ''
    Write-Fail "$($errs.Count) blocking problem(s):"
    foreach ($e in $errs) { Write-Host "       - $e" -ForegroundColor Red }
    throw "Prerequisite check failed with $($errs.Count) blocking problem(s)."
}
Write-Ok 'all prerequisites satisfied'
