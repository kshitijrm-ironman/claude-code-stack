# Updating

Components upgrade independently. Nothing here requires re-running `install.ps1`
from scratch — though doing so is always safe, since every step is idempotent.

Verify after any upgrade:

```powershell
.\scripts\06-verify-stack.ps1
```

---

## The golden rule

**Stop the scheduled task before upgrading a proxy.** Both `npm install -g` and
`pip install --upgrade` replace files a running process has open. On Windows that
either fails with a sharing violation or, worse, half-succeeds and leaves a
process running deleted code.

```powershell
Stop-ScheduledTask -TaskName 'pxpipe-proxy'      # or 'Headroom Proxy'
# ... upgrade ...
Start-ScheduledTask -TaskName 'pxpipe-proxy'
```

`Stop-ScheduledTask` does not always kill a process launched via `wscript.exe`,
because the shim exits immediately and the daemon is orphaned from the task. If
the port stays bound, kill it directly:

```powershell
$p = (Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 47821).OwningProcess
Stop-Process -Id $p -Force
```

---

## pxpipe

```powershell
Stop-ScheduledTask -TaskName 'pxpipe-proxy'
$p = (Get-NetTCPConnection -State Listen -EA 0 | Where-Object LocalPort -eq 47821).OwningProcess
if ($p) { Stop-Process -Id $p -Force }

npm install -g pxpipe-proxy@latest
npm ls -g --depth=0 pxpipe-proxy

Start-ScheduledTask -TaskName 'pxpipe-proxy'
```

**Re-render the launcher if the package layout changed.** The VBS file hardcodes
the absolute path to `bin\cli.js`. If a major version relocates that entry point,
the task silently starts nothing.

```powershell
.\scripts\02-install-pxpipe.ps1
```

That re-resolves the path, rewrites the VBS, and leaves the existing task alone.

---

## Headroom

```powershell
Stop-ScheduledTask -TaskName 'Headroom Proxy'
$p = (Get-NetTCPConnection -State Listen -EA 0 | Where-Object LocalPort -eq 8787).OwningProcess
if ($p) { Stop-Process -Id $p -Force }

pip install --upgrade "headroom-ai[all]"
pip show headroom-ai

Start-ScheduledTask -TaskName 'Headroom Proxy'
```

Keep the `[all]` extra. Upgrading with plain `pip install --upgrade headroom-ai`
drops the optional dependencies and the MCP server loses features without any
obvious error.

**A Python minor-version bump moves everything.** Scripts install to a
version-pinned path:

```
%APPDATA%\Python\Python314\Scripts\headroom.exe
                      ^^^
```

Going 3.14 → 3.15 leaves the VBS launcher and the MCP registration pointing at a
directory that no longer exists. After any Python upgrade:

```powershell
.\scripts\03-install-headroom.ps1     # re-renders the VBS
.\scripts\04-install-mcp-servers.ps1  # re-checks MCP registration
```

If the MCP entry still holds the old absolute path, re-register it:

```powershell
claude mcp remove headroom -s user
claude mcp add headroom -s user -- "$env:APPDATA\Python\Python315\Scripts\headroom.EXE" mcp serve
```

---

## MemPalace

No daemon, no scheduled task — Claude Code spawns it per session. Safe to upgrade
any time, though a running Claude Code session keeps the old process until it
restarts.

```powershell
pip install --upgrade mempalace
pip show mempalace
```

Memory data lives outside the package and survives upgrades. Check a major version
bump's release notes for store migrations before jumping.

---

## Playwright MCP

The MCP registration uses `@latest`, so **the server itself updates on every
spawn** — there is nothing to upgrade.

The browser binary is separate and does not auto-update:

```powershell
npx --yes playwright install chromium
```

Do this when Playwright starts reporting a browser/driver version mismatch.

Old Chromium revisions accumulate in `%USERPROFILE%\AppData\Local\ms-playwright`
and are never cleaned up automatically:

```powershell
# inspect first
Get-ChildItem "$env:LOCALAPPDATA\ms-playwright" | Select-Object Name, LastWriteTime
npx --yes playwright uninstall --all
npx --yes playwright install chromium
```

Pinning is possible if `@latest` ever breaks:

```powershell
claude mcp remove playwright -s user
claude mcp add playwright -s user -- npx @playwright/mcp@0.0.41
```

---

## Ponytail

The plugin tracks the marketplace it came from. Inside a `claude` session:

```
/plugin marketplace update ponytail
```

Restart Claude Code afterwards — the `SessionStart` hook is read once, at session
start, so an upgraded plugin does nothing until the next session.

To remove it:

```
/plugin uninstall ponytail@ponytail
```

---

## Graphify

```powershell
pip install --upgrade graphifyy --allow-scripts
graphify install --platform windows
```

Re-run `graphify install` after every upgrade: it refreshes
`~\.claude\skills\graphify`, which the package ships separately from the CLI. Skip
it and you get a new binary driven by the old skill.

Existing `graphify-out/` directories survive upgrades but are **not** migrated.
If a version bump changes the graph schema, rebuild rather than `--update`:

```
/graphify <path>
```

---

## Claude Code

```powershell
npm install -g @anthropic-ai/claude-code@latest
```

Upgrades do not disturb the proxies, `ANTHROPIC_BASE_URL`, or MCP registrations —
those live in the environment and in `~\.claude.json`, not in the package.

After a major version, re-check that MCP servers still connect:

```powershell
claude mcp list
```

---

## Node or Python major upgrades

The riskiest change in this stack, because every hardcoded path in the VBS
launchers is version- or location-specific.

After upgrading either runtime:

```powershell
.\install.ps1
```

A full re-run re-resolves `node.exe`, `cli.js`, and `headroom.exe`, rewrites both
launchers, and skips everything already correct. It will not duplicate tasks,
re-register MCP servers, or touch the symlink.

---

## Updating this repo

```powershell
cd 'D:\OneDrive\Applications by Kshitij\claude-code-stack'
git pull
.\install.ps1 -WhatIf     # preview what changed
.\install.ps1
```

Always dry-run first after pulling. `-WhatIf` prints every intended change without
making one.
