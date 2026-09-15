<#
.SYNOPSIS
    Step 3 - install Headroom, chain it to pxpipe, autostart it, set BASE_URL.

.DESCRIPTION
    1. pip install "headroom-ai[all]"
    2. render config/headroom-silent.vbs -> %USERPROFILE%\headroom-silent.vbs
       with --port 8787 --anthropic-api-url http://127.0.0.1:47821
    3. register the 'Headroom Proxy' scheduled task (at logon + 15s delay)
    4. set ANTHROPIC_BASE_URL=http://127.0.0.1:8787 permanently (user scope)

    The 15s delay exists so pxpipe is already bound to 47821 when Headroom
    performs its first upstream health check.
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
$d   = $ctx.Defaults

# ---- 1. pip install ----------------------------------------------------
Write-Step 'Installing headroom-ai[all]'

$already = $false
$show = pip show headroom-ai 2>$null
if ($LASTEXITCODE -eq 0 -and $show) {
    $ver = ($show | Select-String '^Version:\s*(.+)$').Matches.Groups[1].Value
    Write-Skip "headroom-ai $ver already installed"
    $already = $true
}

if (-not $already) {
    Invoke-Change 'pip install "headroom-ai[all]"' {
        & pip install 'headroom-ai[all]' 2>&1 |
            ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            throw "pip install headroom-ai[all] failed (exit $LASTEXITCODE)"
        }
    } | Out-Null
    Update-SessionPath
}

# ---- 2. resolve headroom.exe ------------------------------------------
Write-Step 'Resolving headroom executable'

$headroomExe = Get-CommandPath 'headroom'
if (-not $headroomExe) {
    # pip user-scope installs land in %APPDATA%\Python\PythonXY\Scripts, which is
    # often missing from PATH until a new session.
    $candidates = Get-ChildItem -Path (Join-Path $env:APPDATA 'Python') `
                                -Filter 'headroom.exe' -Recurse -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty FullName
    if ($candidates) { $headroomExe = @($candidates)[0] }
}
if (-not $headroomExe) {
    if (Test-DryRun) {
        $headroomExe = '<headroom.exe - resolved at run time>'
        Write-Host "[dry]  would resolve headroom.exe" -ForegroundColor Magenta
    } else {
        throw 'headroom.exe not found. Ensure the pip Scripts directory is on PATH.'
    }
} else {
    Write-Ok "headroom: $headroomExe"
    $ctx['HeadroomExe'] = $headroomExe
}

# ---- 3. render the silent launcher ------------------------------------
Write-Step 'Rendering silent VBScript launcher'

$vbsDest = Join-Path $env:USERPROFILE 'headroom-silent.vbs'
Expand-Template `
    -TemplatePath (Join-Path $ctx.ConfigDir 'headroom-silent.vbs') `
    -Destination  $vbsDest `
    -Values @{
        HEADROOM_EXE  = $headroomExe
        HEADROOM_PORT = $d.HeadroomPort
        UPSTREAM_URL  = $d.UpstreamUrl
    } | Out-Null
Write-Ok "launcher: $vbsDest"
Write-Info "command: headroom proxy --port $($d.HeadroomPort) --anthropic-api-url $($d.UpstreamUrl)"

# ---- 4. scheduled task (15s delay) ------------------------------------
Write-Step "Registering scheduled task '$($d.HeadroomTask)' (logon + 15s)"

Register-StackTask `
    -TaskName $d.HeadroomTask `
    -VbsPath  $vbsDest `
    -Delay    $d.HeadroomDelay | Out-Null

# ---- 5. ANTHROPIC_BASE_URL --------------------------------------------
Write-Step 'Setting ANTHROPIC_BASE_URL (user scope, permanent)'

$current = [System.Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'User')
if ($current -eq $d.BaseUrl) {
    Write-Skip "ANTHROPIC_BASE_URL already = $($d.BaseUrl)"
} else {
    if ($current) { Write-Warn2 "overwriting existing value: $current" }
    Invoke-Change "set ANTHROPIC_BASE_URL=$($d.BaseUrl)" {
        [System.Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $d.BaseUrl, 'User')
    } | Out-Null
    Write-Ok "ANTHROPIC_BASE_URL = $($d.BaseUrl)"
}

# Make it usable in the current session too.
if (-not (Test-DryRun)) { $env:ANTHROPIC_BASE_URL = $d.BaseUrl }

Write-Info 'Existing shells keep the old value until restarted.'
