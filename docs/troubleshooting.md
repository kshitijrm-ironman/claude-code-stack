# Troubleshooting

Start here every time:

```powershell
.\scripts\06-verify-stack.ps1
```

It reports each layer independently, so the first `[fail]` line usually names the
problem directly.

---

## Claude Code hangs or errors on every request

**Check the chain bottom-up — pxpipe first, then Headroom.**

```powershell
Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 47821,8787
```

Expected: `47821` held by `node`, `8787` held by `python`.

### Nothing on 47821 (pxpipe down)

```powershell
Start-ScheduledTask -TaskName 'pxpipe-proxy'
Start-Sleep 3
Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 47821
```

Still nothing? Run it in the foreground to see the actual error — the VBS shim
swallows all output by design:

```powershell
node "$env:APPDATA\npm\node_modules\pxpipe-proxy\bin\cli.js"
```

### Nothing on 8787 (Headroom down)

```powershell
Start-ScheduledTask -TaskName 'Headroom Proxy'
```

Foreground equivalent:

```powershell
headroom proxy --port 8787 --anthropic-api-url http://127.0.0.1:47821
```

### Both listening, still failing

Confirm Claude Code is actually pointed at the chain:

```powershell
$env:ANTHROPIC_BASE_URL
[System.Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL','User')
```

Both should read `http://127.0.0.1:8787`. If the persisted value is right but the
session value is empty or stale, **this shell predates the install** — open a new
one. Environment changes never reach already-running processes.

---

## Works after manual start, broken after every reboot

The logon tasks are not firing.

```powershell
Get-ScheduledTask -TaskName 'pxpipe-proxy','Headroom Proxy' |
  Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName 'pxpipe-proxy' |
  Select-Object LastRunTime, LastTaskResult, NextRunTime
```

- `State: Disabled` → `Enable-ScheduledTask -TaskName 'pxpipe-proxy'`
- `LastTaskResult: 267011` → the task has never run; log out and back in.
- `LastTaskResult: 2147942402` (file not found) → the VBS file is missing or was
  moved. Re-run `.\scripts\02-install-pxpipe.ps1`.

### Laptop on battery

Both tasks are registered with `DisallowStartIfOnBatteries`. On a laptop that
boots unplugged, **neither proxy starts**. This is the single most common cause of
"it only works at my desk". To change it:

```powershell
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Set-ScheduledTask -TaskName 'pxpipe-proxy'   -Settings $s
Set-ScheduledTask -TaskName 'Headroom Proxy' -Settings $s
```

---

## Headroom logs an upstream error at logon, then recovers

Headroom started before pxpipe finished binding 47821. The 15-second delay is
usually enough; a slow or heavily loaded boot can exceed it.

Increase the delay:

```powershell
$t = Get-ScheduledTask -TaskName 'Headroom Proxy'
$t.Triggers[0].Delay = 'PT30S'
Set-ScheduledTask -TaskName 'Headroom Proxy' -Trigger $t.Triggers[0]
```

`PT30S`, `PT1M`, `PT2M` are all valid ISO-8601 durations.

---

## Port already in use

```powershell
$p = (Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 8787).OwningProcess
Get-Process -Id $p | Select-Object Id, ProcessName, Path
```

If it is a stale copy of the proxy itself (common after killing a terminal without
stopping the task):

```powershell
Stop-ScheduledTask -TaskName 'Headroom Proxy'
Stop-Process -Id $p -Force
Start-ScheduledTask -TaskName 'Headroom Proxy'
```

If it is an unrelated application, change the stack's port — remember to update
the VBS launcher, the other component's upstream URL, and `ANTHROPIC_BASE_URL`
together (see `docs/architecture.md` → Ports).

---

## A console window flashes at logon

The task is invoking the executable directly instead of going through the VBS
shim. Verify:

```powershell
(Get-ScheduledTask -TaskName 'pxpipe-proxy').Actions |
  Select-Object Execute, Arguments
```

`Execute` must be `wscript.exe`. If it names `node.exe` or `headroom.exe`, re-run
step 2 or 3 to re-register the task correctly.

---

## MCP server shows as failed in `claude mcp list`

```powershell
claude mcp list
```

### `mempalace` failing

```powershell
pip show mempalace
Get-Command mempalace-mcp
```

If the command is missing, the pip Scripts directory is not on PATH. Either add
`%APPDATA%\Python\Python3XX\Scripts` to PATH, or re-register with an absolute
path:

```powershell
claude mcp remove mempalace -s user
claude mcp add mempalace -s user -- "$env:APPDATA\Python\Python314\Scripts\mempalace-mcp.exe"
```

### `playwright` failing

Usually a missing browser binary:

```powershell
npx --yes playwright install chromium
```

First run downloads ~150 MB. Behind a corporate proxy, set `HTTPS_PROXY` before
running it.

### `headroom` MCP failing but the proxy is fine

They are separate processes. The MCP registration needs the absolute path to
`headroom.EXE`:

```powershell
claude mcp remove headroom -s user
claude mcp add headroom -s user -- "$env:APPDATA\Python\Python314\Scripts\headroom.EXE" mcp serve
```

---

## Ponytail never activates

No `PONYTAIL MODE ACTIVE` line at session start, but `/ponytail-help` works.

The skills load from the plugin directory; the always-on ruleset comes from a
`SessionStart` hook that shells out to Node. If `node` is missing from the
**non-interactive** shell's PATH the hook produces nothing and fails quietly.

```powershell
# interactive PATH is not the one that matters
Start-Process -FilePath node -ArgumentList '--version' -NoNewWindow -Wait
```

nvm-for-Windows and per-user Node installs are the usual culprits — the shim
directory is on the interactive profile's PATH only. Fix by putting the real
`node.exe` directory on the machine or user PATH, then restart Claude Code.

---

## Graphify

### `graphify` is not a recognised command after pip install

`pip install graphifyy` without `--allow-scripts` installs the library but skips
the post-install step that places the binary and the skill:

```powershell
pip install --force-reinstall graphifyy --allow-scripts
graphify install --platform windows
```

Note the package is **`graphifyy`** (two y's); the command it provides is
`graphify`.

### `/graphify` says the skill is missing

The package and the skill install separately. `graphify install --platform windows`
writes `~\.claude\skills\graphify`; confirm and restart Claude Code:

```powershell
Test-Path "$env:USERPROFILE\.claude\skills\graphify\SKILL.md"
```

### Build fails with `WinError 123` on the interpreter path

A BOM got written into `graphify-out\.graphify_python`. Delete the cache and
re-run the build — it re-detects and rewrites the path:

```powershell
Remove-Item .\graphify-out\.graphify_python
```

### Graph is stale after a refactor

`--update` only re-extracts files whose content changed; it does not notice
deletions or moved directories. Rebuild from scratch:

```powershell
Remove-Item -Recurse -Force .\graphify-out
```

Then re-run `/graphify`.

---

## Symlink step fails

### "A required privilege is not held by the client"

Not elevated. Either run the installer from an admin PowerShell, or enable
**Settings → System → For developers → Developer Mode**, which permits
unprivileged symlink creation.

### "already a symlink but points at …"

Step 5 refuses to silently repoint an existing link. Inspect, then decide:

```powershell
Get-Item "$env:USERPROFILE\.claude\projects" -Force | Select-Object LinkType, Target
```

To repoint deliberately:

```powershell
Remove-Item "$env:USERPROFILE\.claude\projects" -Force   # removes the link only, not the target
.\scripts\05-link-onedrive-memory.ps1
```

Removing a symlink never deletes the directory it points at.

### Sessions disappeared after linking

They were not deleted. Step 5 moves the original directory aside:

```powershell
Get-ChildItem "$env:USERPROFILE\.claude" -Filter 'projects.bak-*'
```

Copy anything missing from there into `D:\OneDrive\Claude\projects`.

---

## OneDrive conflict copies appearing

Two machines wrote the same project transcript. Files look like
`sessions-MSI-KRM-271212.json`. Harmless — Claude Code ignores files it did not
create. Delete them, or leave them.

To stop it happening, avoid running the same project on two machines
simultaneously, or exclude that project folder from OneDrive sync.

---

## Starting over

Everything is reversible and nothing here deletes session history.

```powershell
# tasks
Unregister-ScheduledTask -TaskName 'pxpipe-proxy'   -Confirm:$false
Unregister-ScheduledTask -TaskName 'Headroom Proxy' -Confirm:$false

# launchers
Remove-Item "$env:USERPROFILE\pxpipe-silent.vbs","$env:USERPROFILE\headroom-silent.vbs" -Force

# env
[System.Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $null, 'User')

# mcp
claude mcp remove mempalace -s user
claude mcp remove playwright -s user
claude mcp remove headroom -s user

# packages
npm uninstall -g pxpipe-proxy
pip uninstall -y headroom-ai mempalace graphifyy

# skill (plugin is removed from inside claude: /plugin uninstall ponytail@ponytail)
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude\skills\graphify"

# symlink (target and its contents survive)
Remove-Item "$env:USERPROFILE\.claude\projects" -Force
```

Then re-run `.\install.ps1`.
