# _common.ps1 - shared helpers, dot-sourced by every step script.
# Kept PowerShell 5.1 compatible (no ??, no ternary, no clean blocks).

Set-StrictMode -Version Latest

# ---------- stack-wide constants ----------
$script:StackDefaults = @{
    PxpipePort     = 47821
    HeadroomPort   = 8787
    PxpipePackage  = 'pxpipe-proxy'
    PxpipeTask     = 'pxpipe-proxy'
    HeadroomTask   = 'Headroom Proxy'
    HeadroomDelay  = 'PT15S'
    BaseUrl        = 'http://127.0.0.1:8787'
    UpstreamUrl    = 'http://127.0.0.1:47821'
    OneDriveTarget = 'D:\OneDrive\Claude\projects'
}

function Get-StackDefaults { return $script:StackDefaults }

# ---------- output ----------
function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}
function Write-Ok     { param([string]$m) Write-Host "[ok]   $m" -ForegroundColor Green }
function Write-Info   { param([string]$m) Write-Host "[info] $m" -ForegroundColor Gray }
function Write-Warn2  { param([string]$m) Write-Host "[warn] $m" -ForegroundColor Yellow }
function Write-Fail   { param([string]$m) Write-Host "[fail] $m" -ForegroundColor Red }

function Write-Skip {
    param([string]$m)
    Write-Host "[skip] $m" -ForegroundColor DarkGray
}

# Honours -WhatIf passed down from install.ps1. Global rather than $script: so the
# value is visible no matter which scope a step script is invoked from.
function Test-DryRun {
    $v = Get-Variable -Name StackWhatIf -Scope Global -ErrorAction SilentlyContinue
    if (-not $v) { return $false }
    return [bool]$v.Value
}
function Invoke-Change {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    if (Test-DryRun) {
        Write-Host "[dry]  would $Description" -ForegroundColor Magenta
        return $null
    }
    Write-Info $Description
    return & $Action
}

# ---------- environment probes ----------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Windows11 {
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($os.Caption -notmatch 'Windows 11' -and $build -lt 22000) {
        throw "This stack supports Windows 11 only (detected: $($os.Caption), build $build)."
    }
    return "$($os.Caption) build $build"
}

# Refreshes the current session's PATH from the registry - needed right after
# npm/pip install a new shim into a directory this process never saw.
function Update-SessionPath {
    $machine  = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user     = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $registry = ($machine, $user | Where-Object { $_ }) -join ';'
    # Merge registry PATH with anything already in the session PATH so that
    # entries added before calling the installer (e.g. npm global bin in an
    # elevated session) are not silently dropped.
    $existing = $env:Path -split ';' | Where-Object { $_ -and ($registry -notlike "*$_*") }
    $env:Path = ((@($registry) + $existing) | Where-Object { $_ }) -join ';'
}

function Get-CommandPath {
    param([Parameter(Mandatory)][string]$Name)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) {
        if ($c.Source) { return $c.Source }
        return $c.Name
    }
    return $null
}

function Test-PortListening {
    param([Parameter(Mandatory)][int]$Port)
    $conn = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -eq $Port } |
            Select-Object -First 1
    if (-not $conn) { return $null }
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    $name = 'unknown'
    if ($proc) { $name = $proc.ProcessName }
    return [pscustomobject]@{
        Port        = $Port
        ProcessId   = $conn.OwningProcess
        ProcessName = $name
    }
}

function Get-NpmGlobalRoot {
    # Collect the whole stream before inspecting $LASTEXITCODE. Piping a native
    # command straight into `Select-Object -First 1` stops the pipeline early,
    # which makes PowerShell report $LASTEXITCODE = -1 even on success.
    $out = @(npm root -g 2>$null)
    $code = $LASTEXITCODE
    $root = $out | Where-Object { $_ } | Select-Object -First 1
    if ($code -ne 0 -or -not $root) {
        throw "Could not resolve the npm global root (npm exit $code). Is npm on PATH?"
    }
    return $root.Trim()
}

# ---------- template rendering ----------
function Expand-Template {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$Values
    )
    if (-not (Test-Path $TemplatePath)) {
        throw "Template not found: $TemplatePath"
    }
    $text = Get-Content $TemplatePath -Raw
    foreach ($k in $Values.Keys) {
        $text = $text.Replace("{{$k}}", [string]$Values[$k])
    }
    $left = [regex]::Matches($text, '\{\{[A-Z_]+\}\}')
    if ($left.Count -gt 0) {
        $names = ($left | ForEach-Object { $_.Value }) -join ', '
        throw "Template $TemplatePath still has unsubstituted placeholders: $names"
    }
    Invoke-Change "write $Destination" {
        Set-Content -Path $Destination -Value $text -Encoding ASCII
    } | Out-Null
    return $Destination
}

# ---------- scheduled tasks ----------
function Register-StackTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$VbsPath,
        [string]$WorkingDirectory,
        [string]$Delay,
        [switch]$RestartOnFailure
    )

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Skip "scheduled task '$TaskName' already registered"
        return $existing
    }

    if (Test-DryRun) {
        $suffix = ''
        if ($Delay) { $suffix = " (logon +$Delay)" }
        Write-Host "[dry]  would register scheduled task '$TaskName'$suffix" -ForegroundColor Magenta
        return $null
    }

    $actionArgs = @{
        Execute  = 'wscript.exe'
        Argument = "`"$VbsPath`""
    }
    if ($WorkingDirectory) { $actionArgs['WorkingDirectory'] = $WorkingDirectory }
    $action = New-ScheduledTaskAction @actionArgs

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    if ($Delay) { $trigger.Delay = $Delay }

    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Highest

    $settingsArgs = @{
        AllowStartIfOnBatteries    = $false
        DontStopIfGoingOnBatteries = $false
        ExecutionTimeLimit         = ([TimeSpan]::Zero)
        MultipleInstances          = 'IgnoreNew'
        StartWhenAvailable         = $true
    }
    if ($RestartOnFailure) {
        $settingsArgs['RestartCount']    = 3
        $settingsArgs['RestartInterval'] = (New-TimeSpan -Minutes 1)
    }
    $settings = New-ScheduledTaskSettingsSet @settingsArgs

    Write-Info "register scheduled task '$TaskName'"
    return Register-ScheduledTask `
        -TaskName  $TaskName `
        -Action    $action `
        -Trigger   $trigger `
        -Principal $principal `
        -Settings  $settings `
        -Force
}

# ---------- MCP ----------
function Get-McpServerNames {
    $cfgPath = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $cfgPath)) { return @() }
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warn2 "could not parse $cfgPath"
        return @()
    }
    if (-not $cfg.PSObject.Properties.Name.Contains('mcpServers')) { return @() }
    if (-not $cfg.mcpServers) { return @() }
    return @($cfg.mcpServers.PSObject.Properties.Name)
}

function Add-McpServer {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$CommandArgs = @()
    )
    if ((Get-McpServerNames) -contains $Name) {
        Write-Skip "MCP server '$Name' already registered at user scope"
        return
    }
    $cli = @('mcp', 'add', $Name, '--scope', 'user', '--', $Command) + $CommandArgs
    Invoke-Change "claude mcp add $Name (user scope)" {
        & claude @cli 2>&1 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { throw "claude mcp add $Name failed (exit $LASTEXITCODE)" }
    } | Out-Null
}
