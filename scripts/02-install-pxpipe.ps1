<#
.SYNOPSIS
    Step 2 - install pxpipe and start it silently at logon.

.DESCRIPTION
    1. npm install -g pxpipe-proxy
    2. render config/pxpipe-silent.vbs -> %USERPROFILE%\pxpipe-silent.vbs
    3. register the 'pxpipe-proxy' scheduled task (at logon, no delay)

    The npm package is 'pxpipe-proxy'; the binary it installs is 'pxpipe'.
    pxpipe listens on 47821 and is the innermost hop before api.anthropic.com.
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

# ---- 1. npm install ----------------------------------------------------
Write-Step "Installing $($d.PxpipePackage) globally"

$installed = $null
$lsOut = npm ls -g --depth=0 --json 2>$null
if ($LASTEXITCODE -eq 0 -and $lsOut) {
    try {
        $tree = ($lsOut | ConvertFrom-Json)
        if ($tree.PSObject.Properties.Name -contains 'dependencies' -and
            $tree.dependencies.PSObject.Properties.Name -contains $d.PxpipePackage) {
            $installed = $tree.dependencies.($d.PxpipePackage).version
        }
    } catch { }
}

if ($installed) {
    Write-Skip "$($d.PxpipePackage)@$installed already installed globally"
} else {
    Invoke-Change "npm install -g $($d.PxpipePackage)" {
        & npm install -g $d.PxpipePackage 2>&1 |
            ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            throw "npm install -g $($d.PxpipePackage) failed (exit $LASTEXITCODE)"
        }
    } | Out-Null
    Update-SessionPath
}

# ---- 2. resolve paths --------------------------------------------------
Write-Step 'Resolving pxpipe entry point'

$npmRoot = Get-NpmGlobalRoot
$cliJs   = Join-Path $npmRoot "$($d.PxpipePackage)\bin\cli.js"
$pkgDir  = Join-Path $npmRoot $d.PxpipePackage

if (-not (Test-Path $cliJs)) {
    if (Test-DryRun) {
        Write-Host "[dry]  would expect CLI at $cliJs" -ForegroundColor Magenta
    } else {
        throw "pxpipe CLI not found at $cliJs - the package layout may have changed."
    }
} else {
    Write-Ok "cli.js: $cliJs"
}

$nodeExe = $null
if ($ctx.PSObject -and $ctx.ContainsKey('NodeExe')) { $nodeExe = $ctx['NodeExe'] }
if (-not $nodeExe) { $nodeExe = Get-CommandPath 'node' }
if (-not $nodeExe) { throw 'node.exe not found on PATH.' }
Write-Ok "node:   $nodeExe"

# ---- 3. render the silent launcher ------------------------------------
Write-Step 'Rendering silent VBScript launcher'

$vbsDest = Join-Path $env:USERPROFILE 'pxpipe-silent.vbs'
Expand-Template `
    -TemplatePath (Join-Path $ctx.ConfigDir 'pxpipe-silent.vbs') `
    -Destination  $vbsDest `
    -Values @{
        NODE_EXE   = $nodeExe
        PXPIPE_CLI = $cliJs
    } | Out-Null
Write-Ok "launcher: $vbsDest"

# ---- 4. scheduled task -------------------------------------------------
Write-Step "Registering scheduled task '$($d.PxpipeTask)'"

Register-StackTask `
    -TaskName         $d.PxpipeTask `
    -VbsPath          $vbsDest `
    -WorkingDirectory $pkgDir `
    -RestartOnFailure | Out-Null

Write-Ok "pxpipe will start at logon and listen on $($d.PxpipePort)"
Write-Info "start it now with: Start-ScheduledTask -TaskName '$($d.PxpipeTask)'"
