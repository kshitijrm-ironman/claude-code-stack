<#
.SYNOPSIS
    Installs the full Claude Code stack on Windows 11.

.DESCRIPTION
    Single entry point. Runs scripts/01..06 in order and stops at the first
    failure. Every step is idempotent, so re-running on a configured machine is
    safe and reports what is already in place.

    Chain that gets built:
        Claude Code -> Headroom (8787) -> pxpipe (47821) -> api.anthropic.com

.PARAMETER SkipSteps
    Step numbers to skip, e.g. -SkipSteps 5 or -SkipSteps 4,5

.PARAMETER OneDrivePath
    Override the OneDrive symlink target.
    Default: D:\OneDrive\Claude\projects

.PARAMETER WhatIf
    Dry run. Prints every change without making any.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    .\install.ps1 -WhatIf

.EXAMPLE
    .\install.ps1 -SkipSteps 5 -Verbose
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int[]]$SkipSteps = @(),
    [string]$OneDrivePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'scripts\_common.ps1')

# Capture -WhatIf for our own gating, then clear the preference variable.
# Left set, $WhatIfPreference is inherited by every built-in cmdlet the step
# scripts call - including module auto-loading, which spews "What if: Set Alias"
# noise and makes unrelated cmdlets no-op unpredictably. Dry-run behaviour is
# handled explicitly by Invoke-Change/Test-DryRun instead.
$global:StackWhatIf = [bool]$WhatIfPreference
$WhatIfPreference   = $false

# Tells step scripts they are running under the installer, so step 6 reports a
# failure by throwing instead of calling exit (which would kill this process).
$global:StackInstallRun = $true

$steps = @(
    @{ N = 1; File = '01-check-prereqs.ps1';       Name = 'Check prerequisites' }
    @{ N = 2; File = '02-install-pxpipe.ps1';      Name = 'Install pxpipe + autostart' }
    @{ N = 3; File = '03-install-headroom.ps1';    Name = 'Install Headroom + autostart + BASE_URL' }
    @{ N = 4; File = '04-install-mcp-servers.ps1'; Name = 'Register MCP servers' }
    @{ N = 5; File = '05-link-onedrive-memory.ps1';Name = 'Link OneDrive memory' }
    @{ N = 6; File = '06-verify-stack.ps1';        Name = 'Verify stack' }
)

$banner = @'
  _____ _                _        _____          _        _____ _             _
 / ____| |              | |      / ____|        | |      / ____| |           | |
| |    | | __ _ _   _  _| | ___ | |     ___   __| | ___ | (___ | |_ __ _  ___| |__
| |    | |/ _` | | | |/ _` |/ _ \| |    / _ \ / _` |/ _ \ \___ \| __/ _` |/ __| |/ /
| |____| | (_| | |_| | (_| |  __/| |___| (_) | (_| |  __/ ____) | || (_| | (__|   <
 \_____|_|\__,_|\__,_|\__,_|\___| \_____\___/ \__,_|\___||_____/ \__\__,_|\___|_|\_\
'@
Write-Host $banner -ForegroundColor DarkCyan
Write-Host '  Claude Code -> Headroom :8787 -> pxpipe :47821 -> api.anthropic.com' -ForegroundColor DarkGray

if ($global:StackWhatIf) {
    Write-Host ''
    Write-Host '  *** DRY RUN - no changes will be made ***' -ForegroundColor Magenta
}

# Shared state each step can read/extend. Global so it survives across the
# separate scopes the step scripts run in.
$global:StackContext = @{
    Root         = $Root
    ConfigDir    = Join-Path $Root 'config'
    OneDrivePath = $OneDrivePath
    Defaults     = Get-StackDefaults
}

$stepResults = [ordered]@{}
$started     = Get-Date
$failed      = $null

foreach ($step in $steps) {
    $label = "[{0}/6] {1}" -f $step.N, $step.Name

    if ($SkipSteps -contains $step.N) {
        Write-Host ''
        Write-Host "--- $label -- SKIPPED (-SkipSteps) ---" -ForegroundColor DarkGray
        $stepResults[$step.Name] = 'skipped'
        continue
    }

    Write-Host ''
    Write-Host ('-' * 76) -ForegroundColor DarkGray
    Write-Host "  $label" -ForegroundColor White
    Write-Host ('-' * 76) -ForegroundColor DarkGray

    $path = Join-Path $Root "scripts\$($step.File)"
    if (-not (Test-Path $path)) {
        throw "Missing step script: $path"
    }

    try {
        # Invoked with & (child scope), NOT dot-sourced. Dot-sourcing would let a
        # step's local variables overwrite this script's state - 06-verify-stack
        # defines its own $results, which silently destroyed the summary table.
        & $path
        $stepResults[$step.Name] = 'ok'
    } catch {
        $stepResults[$step.Name] = 'FAILED'
        $failed = [pscustomobject]@{
            Step    = $label
            Script  = $step.File
            Message = $_.Exception.Message
            Line    = $_.InvocationInfo.ScriptLineNumber
        }
        break
    }
}

# ---------------- summary ----------------
$elapsed = [int]((Get-Date) - $started).TotalSeconds

Write-Host ''
Write-Host ('=' * 76) -ForegroundColor DarkGray
Write-Host '  SUMMARY' -ForegroundColor White
Write-Host ('=' * 76) -ForegroundColor DarkGray

foreach ($k in $stepResults.Keys) {
    $v = $stepResults[$k]
    $color = 'Green'
    if ($v -eq 'skipped') { $color = 'DarkGray' }
    if ($v -eq 'FAILED')  { $color = 'Red' }
    Write-Host ('  {0,-46} {1}' -f $k, $v) -ForegroundColor $color
}
Write-Host ''
Write-Host "  elapsed: ${elapsed}s" -ForegroundColor DarkGray

if ($failed) {
    Write-Host ''
    Write-Fail "$($failed.Step) failed at $($failed.Script):$($failed.Line)"
    Write-Host "       $($failed.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host '  See docs/troubleshooting.md, fix, then re-run install.ps1 -' -ForegroundColor Yellow
    Write-Host '  completed steps will report "already configured" and no-op.' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
if ($global:StackWhatIf) {
    Write-Host '  Dry run complete. Re-run without -WhatIf to apply.' -ForegroundColor Magenta
    exit 0
}

Write-Host '  Stack installed.' -ForegroundColor Green
Write-Host ''
Write-Host '  Next: log out and back in so the logon-triggered tasks fire and' -ForegroundColor White
Write-Host '  ANTHROPIC_BASE_URL reaches new processes. To skip the logout:' -ForegroundColor White
Write-Host ''
Write-Host "      Start-ScheduledTask -TaskName 'pxpipe-proxy'" -ForegroundColor Gray
Write-Host '      Start-Sleep -Seconds 15' -ForegroundColor Gray
Write-Host "      Start-ScheduledTask -TaskName 'Headroom Proxy'" -ForegroundColor Gray
Write-Host ''
exit 0
