<#
.SYNOPSIS
    Step 5 - point ~\.claude\projects at OneDrive so session memory syncs.

.DESCRIPTION
    Creates a directory symlink:
        C:\Users\<username>\.claude\projects  ->  D:\OneDrive\Claude\projects

    This step touches real session history, so it is deliberately conservative:

      * already the correct symlink      -> no-op
      * a symlink pointing somewhere else -> refuse, tell the user
      * a real directory with contents    -> copy contents into OneDrive
                                             (never overwriting newer files),
                                             move the original aside to
                                             projects.bak-<timestamp>,
                                             then create the link
      * missing                           -> create the link

    Nothing is ever deleted. The .bak directory is left for you to remove once
    you have confirmed the sync looks right.
#>
[CmdletBinding()]
param(
    [string]$OneDrivePath
)

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

$target = $OneDrivePath
if (-not $target -and $ctx.ContainsKey('OneDrivePath')) { $target = $ctx['OneDrivePath'] }
if (-not $target) { $target = $ctx.Defaults.OneDriveTarget }

$link = Join-Path $env:USERPROFILE '.claude\projects'

Write-Step 'Linking Claude projects memory to OneDrive'
Write-Info "link:   $link"
Write-Info "target: $target"

# ---- target must exist -------------------------------------------------
$oneDriveRoot = Split-Path -Parent (Split-Path -Parent $target)
if (-not (Test-Path $oneDriveRoot)) {
    throw "OneDrive root not found: $oneDriveRoot. Pass -OneDrivePath or skip with -SkipSteps 5."
}
if (-not (Test-Path $target)) {
    Invoke-Change "create target directory $target" {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    } | Out-Null
} else {
    Write-Ok 'OneDrive target directory exists'
}

# ---- inspect the link path --------------------------------------------
$existing = Get-Item $link -Force -ErrorAction SilentlyContinue

if ($existing -and $existing.LinkType -eq 'SymbolicLink') {
    $currentTarget = @($existing.Target)[0]
    if ($currentTarget -eq $target) {
        Write-Skip "already symlinked to $target"
        Write-Ok  "$((Get-ChildItem $link -Force -ErrorAction SilentlyContinue).Count) project folder(s) syncing"
        return
    }
    throw "$link is already a symlink but points at '$currentTarget', not '$target'. " +
          'Remove it manually if you intend to repoint it.'
}

# ---- a real directory is in the way ------------------------------------
if ($existing -and -not $existing.LinkType) {
    $children = @(Get-ChildItem $link -Force -ErrorAction SilentlyContinue)
    Write-Warn2 "$link is a real directory with $($children.Count) item(s)"

    if ($children.Count -gt 0) {
        Write-Info 'copying existing history into OneDrive (newer files win, nothing overwritten blindly)'
        Invoke-Change "robocopy $link -> $target" {
            # /E all subdirs, /XN /XO skip newer+older at destination (copy only
            # what is genuinely missing), /NFL /NDL quiet file listings.
            & robocopy $link $target /E /XN /XO /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
            # robocopy exit codes < 8 are success//informational.
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE)" }
            $global:LASTEXITCODE = 0
        } | Out-Null
    }

    $backup = "$link.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Invoke-Change "move original aside to $backup" {
        Move-Item -Path $link -Destination $backup -Force
    } | Out-Null
    Write-Ok "original preserved at $backup"
}

# ---- create the link ---------------------------------------------------
$parent = Split-Path -Parent $link
if (-not (Test-Path $parent)) {
    Invoke-Change "create $parent" {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    } | Out-Null
}

if (-not (Test-IsAdmin)) {
    Write-Warn2 'not elevated - symlink creation needs admin or Windows Developer Mode'
}

Invoke-Change "create symlink $link -> $target" {
    New-Item -ItemType SymbolicLink -Path $link -Target $target -Force | Out-Null
} | Out-Null

if (-not (Test-DryRun)) {
    $check = Get-Item $link -Force
    if ($check.LinkType -ne 'SymbolicLink') {
        throw "Symlink creation did not take effect at $link"
    }
    Write-Ok "symlinked: $link -> $(@($check.Target)[0])"
}
