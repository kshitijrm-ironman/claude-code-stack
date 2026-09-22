<#
.SYNOPSIS
    Exercises every branch of 05-link-onedrive-memory.ps1 in a throwaway sandbox.

.DESCRIPTION
    Step 5 is the only destructive step in this repo: when ~\.claude\projects is
    a real directory it copies the contents into OneDrive, moves the original
    aside, and replaces it with a symlink. That path must never be debugged
    against live session history, so this harness drives it with -LinkPath and
    -OneDrivePath pointed at a temp tree instead.

    Covers:
      1. missing link                  -> symlink created
      2. already correct symlink       -> no-op, nothing disturbed
      3. symlink pointing elsewhere    -> refuses, throws, changes nothing
      4. real directory with contents  -> merged into target, original backed up
      5. newer file at destination     -> NOT overwritten (robocopy /XO)

    Requires Administrator (or Developer Mode) for symlink creation.
    Exit 0 = all passed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\test-05-link.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stepScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\05-link-onedrive-memory.ps1'
if (-not (Test-Path $stepScript)) { throw "Cannot find $stepScript" }

$sandbox = Join-Path $env:TEMP "ccstack-test-05-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$passed = 0
$failed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $case = Join-Path $sandbox ($Name -replace '[^a-zA-Z0-9]+', '-')
    New-Item -ItemType Directory -Path $case -Force | Out-Null
    Write-Host ''
    Write-Host "--- $Name" -ForegroundColor Cyan
    try {
        & $Body $case
        Write-Host "  PASS" -ForegroundColor Green
        $script:passed++
    } catch {
        Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

# Each case runs the step in a child powershell so a thrown error or a leftover
# $global:StackContext cannot leak between cases.
function Invoke-Step {
    param([string]$Link, [string]$Target)
    # EAP must drop to Continue here: with 'Stop', stderr from the native command
    # arrives as terminating error records and kills the harness before a single
    # assertion runs - which is exactly how the refusal case first "failed".
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $stepScript `
                  -LinkPath $Link -OneDrivePath $Target 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    # Console wrapping splits long messages across records; join with a space so
    # -match still sees contiguous phrases.
    return [pscustomobject]@{
        Output   = (($out | ForEach-Object { $_.ToString() }) -join ' ')
        ExitCode = $code
    }
}

Write-Host "sandbox: $sandbox" -ForegroundColor DarkGray

# ---- 1. missing link ---------------------------------------------------
Test-Case 'missing link creates symlink' {
    param($case)
    $target = Join-Path $case 'OneDrive\Claude\projects'
    $link   = Join-Path $case 'home\.claude\projects'
    New-Item -ItemType Directory -Path $target -Force | Out-Null

    $r = Invoke-Step -Link $link -Target $target
    Assert-True ($r.ExitCode -eq 0) "expected exit 0, got $($r.ExitCode): $($r.Output)"

    $item = Get-Item $link -Force
    Assert-True ($item.LinkType -eq 'SymbolicLink') 'link was not created as a symlink'
    Assert-True (@($item.Target)[0] -eq $target)    "symlink points at $(@($item.Target)[0])"
}

# ---- 2. already correct ------------------------------------------------
Test-Case 'existing correct symlink is a no-op' {
    param($case)
    $target = Join-Path $case 'OneDrive\Claude\projects'
    $link   = Join-Path $case 'home\.claude\projects'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $link) -Force | Out-Null
    New-Item -ItemType SymbolicLink -Path $link -Target $target -Force | Out-Null
    Set-Content (Join-Path $target 'keep.json') 'original'

    $r = Invoke-Step -Link $link -Target $target
    Assert-True ($r.ExitCode -eq 0) "expected exit 0, got $($r.ExitCode): $($r.Output)"
    Assert-True ($r.Output -match 'already symlinked') 'did not report already-symlinked'
    Assert-True ((Get-Content (Join-Path $target 'keep.json')) -eq 'original') 'contents disturbed'
    # no stray backup directories
    Assert-True (@(Get-ChildItem (Split-Path -Parent $link) -Filter 'projects.bak-*').Count -eq 0) `
                'a backup was created on a no-op run'
}

# ---- 2b. regression: StrictMode .Count on 0 and 1 results --------------
# A bare (Get-ChildItem ...).Count throws under StrictMode for 0 and 1 items
# and only works from 2 up. Case 2 covers 1 item; this covers the empty tree,
# i.e. a brand-new machine with no project history yet.
Test-Case 'empty project tree does not trip StrictMode' {
    param($case)
    $target = Join-Path $case 'OneDrive\Claude\projects'
    $link   = Join-Path $case 'home\.claude\projects'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $link) -Force | Out-Null
    New-Item -ItemType SymbolicLink -Path $link -Target $target -Force | Out-Null

    $r = Invoke-Step -Link $link -Target $target
    Assert-True ($r.ExitCode -eq 0) "expected exit 0, got $($r.ExitCode): $($r.Output)"
    Assert-True ($r.Output -notmatch "property 'Count'") 'StrictMode Count regression is back'
    Assert-True ($r.Output -match '0 project folder\(s\) syncing') 'did not report 0 folders'
}

# ---- 3. symlink pointing elsewhere ------------------------------------
Test-Case 'symlink to wrong target is refused' {
    param($case)
    $target = Join-Path $case 'OneDrive\Claude\projects'
    $other  = Join-Path $case 'somewhere\else'
    $link   = Join-Path $case 'home\.claude\projects'
    New-Item -ItemType Directory -Path $target, $other -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $link) -Force | Out-Null
    New-Item -ItemType SymbolicLink -Path $link -Target $other -Force | Out-Null

    $r = Invoke-Step -Link $link -Target $target
    Assert-True ($r.ExitCode -ne 0) 'expected a non-zero exit for a mispointed symlink'
    Assert-True ($r.Output -match 'already a symlink but points at') 'wrong error message'
    # must not have been repointed
    Assert-True (@((Get-Item $link -Force).Target)[0] -eq $other) 'symlink was repointed despite refusing'
}

# ---- 4 + 5. real directory with contents ------------------------------
Test-Case 'real directory is merged and backed up, newer files survive' {
    param($case)
    $target = Join-Path $case 'OneDrive\Claude\projects'
    $link   = Join-Path $case 'home\.claude\projects'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $link 'proj-a') -Force | Out-Null

    # only in the local dir -> must be copied across
    Set-Content (Join-Path $link 'proj-a\only-local.json') 'local'
    # present in both; destination copy is NEWER -> must NOT be overwritten
    New-Item -ItemType Directory -Path (Join-Path $target 'proj-a') -Force | Out-Null
    Set-Content (Join-Path $link   'proj-a\shared.json') 'OLD-from-local'
    Start-Sleep -Milliseconds 1200
    Set-Content (Join-Path $target 'proj-a\shared.json') 'NEW-at-destination'

    $r = Invoke-Step -Link $link -Target $target
    Assert-True ($r.ExitCode -eq 0) "expected exit 0, got $($r.ExitCode): $($r.Output)"

    # link is now a symlink to target
    $item = Get-Item $link -Force
    Assert-True ($item.LinkType -eq 'SymbolicLink') 'link is not a symlink after migration'

    # missing file was carried over
    Assert-True (Test-Path (Join-Path $target 'proj-a\only-local.json')) 'only-local.json was not copied'

    # newer destination file won
    $shared = Get-Content (Join-Path $target 'proj-a\shared.json')
    Assert-True ($shared -eq 'NEW-at-destination') "newer destination file was overwritten (got '$shared')"

    # original preserved, nothing deleted
    $bak = @(Get-ChildItem (Split-Path -Parent $link) -Filter 'projects.bak-*' -Force)
    Assert-True ($bak.Count -eq 1) "expected exactly 1 backup dir, found $($bak.Count)"
    Assert-True (Test-Path (Join-Path $bak[0].FullName 'proj-a\only-local.json')) 'backup is missing original files'
}

# ---- report ------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host "  step 5 branches: $passed passed, $failed failed" -ForegroundColor White
Write-Host ('=' * 60) -ForegroundColor DarkGray

if ($failed -eq 0) {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  sandbox cleaned up' -ForegroundColor DarkGray
    exit 0
}
Write-Host "  sandbox kept for inspection: $sandbox" -ForegroundColor Yellow
exit 1
