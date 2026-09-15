# Architecture

## The request path

Claude Code never talks to `api.anthropic.com` directly on this machine. Every
request passes through two local proxies first.

```
  Claude Code
      │  ANTHROPIC_BASE_URL = http://127.0.0.1:8787
      ▼
  Headroom proxy  ──────────────── 127.0.0.1:8787
      │  --anthropic-api-url http://127.0.0.1:47821
      ▼
  pxpipe          ──────────────── 127.0.0.1:47821
      │
      ▼
  api.anthropic.com
```

Responses return along the same path in reverse. Both hops are plain HTTP on the
loopback interface; TLS is terminated once, by pxpipe, on the way out.

## Why two proxies

They do different jobs and are independently replaceable.

**pxpipe** (`pxpipe-proxy`, Node) is the egress layer. It owns the real upstream
connection and is the only component that knows how to reach Anthropic. Anything
that needs to sit "closest to the wire" belongs here.

**Headroom** (`headroom-ai`, Python) is the context layer. It inspects and
compresses conversation payloads before they leave the machine. It deliberately
does not manage the upstream connection — it just forwards to whatever
`--anthropic-api-url` names, which happens to be pxpipe.

Because Headroom treats its upstream as opaque, you can pull pxpipe out of the
chain by pointing Headroom at `https://api.anthropic.com` instead, and everything
still works. The reverse is also true: unset `ANTHROPIC_BASE_URL` to `:47821` and
Claude Code talks to pxpipe alone, skipping compression.

## Ports

| Port | Owner | Bound by | Notes |
|---|---|---|---|
| `8787` | Headroom proxy | `python.exe` | What Claude Code points at |
| `47821` | pxpipe | `node.exe` | Headroom's upstream |

Both are loopback-only. Nothing in this stack opens a listener on an external
interface, and no firewall rule is required.

Changing a port means changing it in three places at once — the VBS template, the
other component's upstream URL, and `ANTHROPIC_BASE_URL`. There is no shared
config file; the values are wired through `scripts/_common.ps1` (`$StackDefaults`).

## Startup and ordering

Both proxies start from **Task Scheduler at logon**, each through a small
VBScript shim.

The shim exists for one reason: `wscript.exe` can launch a process with
`WshShell.Run(cmd, 0, False)` where `0` means *hidden window*. Registering the
executable directly with Task Scheduler leaves a console window flashing on every
logon, and on some configurations a persistent black window. VBScript is the
lightest way to get a truly silent launch without a helper binary.

```
 t=0s    logon
 t=0s    task "pxpipe-proxy"   → wscript pxpipe-silent.vbs   → node cli.js       → binds 47821
 t=15s   task "Headroom Proxy" → wscript headroom-silent.vbs → headroom proxy    → binds 8787
```

### Why 15 seconds

Task Scheduler has no "start after another task" relationship. Ordering is
enforced purely by the delay on the Headroom trigger.

Headroom performs an upstream health check shortly after binding. If pxpipe has
not yet claimed 47821, that check fails and Headroom logs an upstream error —
recoverable, but it produces a confusing first-request failure. Fifteen seconds is
comfortably more than pxpipe's cold start (typically ~1–2s) while staying short
enough to be invisible at logon.

The delay is set on the trigger, not in the script:

```xml
<LogonTrigger>
  <Delay>PT15S</Delay>
</LogonTrigger>
```

### Task settings that matter

- `RunLevel: HighestAvailable` — both tasks run elevated.
- `ExecutionTimeLimit: PT0S` — never time out. These are long-lived daemons; the
  default 72-hour limit would silently kill them.
- `MultipleInstances: IgnoreNew` — a manual `Start-ScheduledTask` while the proxy
  is already up does nothing rather than double-binding the port.
- pxpipe adds `RestartOnFailure` (3 attempts, 1 minute apart). Headroom does not:
  if pxpipe is down, restarting Headroom repeatedly does not help, and the retry
  noise obscures the real cause.

## MCP servers

The MCP servers are **not** part of the proxy chain. Claude Code spawns each one
as a child process and speaks MCP over stdio. They never touch ports 8787 or
47821.

| Server | Command | Provides |
|---|---|---|
| `headroom` | `headroom.EXE mcp serve` | On-demand context compression / retrieval |
| `mempalace` | `mempalace-mcp` | Persistent long-term memory across sessions |
| `playwright` | `npx @playwright/mcp@latest` | Browser automation against a local Chromium |

All three are registered at **user scope** (`claude mcp add … --scope user`),
landing in `~\.claude.json` under `mcpServers`. User scope makes them available in
every project directory; project scope would confine them to one repo.

Note that `headroom-ai` supplies both a proxy and an MCP server from one package.
They are separate processes with separate lifecycles — the proxy is a daemon
under Task Scheduler, the MCP server is spawned per Claude Code session.

## Memory sync

```
C:\Users\<username>\.claude\projects   ──symlink──►   D:\OneDrive\Claude\projects
```

Claude Code writes per-project session transcripts under `~\.claude\projects`.
Redirecting that directory onto OneDrive means session history follows the user
to any machine running this stack.

A **directory symlink** is used rather than a junction or a moved folder:

- Claude Code resolves the path normally and needs no configuration change.
- Unlike a junction, a symlink is explicit about its target in `Get-Item`, which
  makes verification straightforward.
- Creating one requires elevation *or* Windows Developer Mode.

OneDrive syncs the target like any other folder. Transcripts are small JSON files,
so sync pressure is negligible — but two machines writing the same project
concurrently can produce OneDrive conflict copies (`… -MSI-KRM-271212.json`).
These are harmless; Claude Code ignores files it did not write.

## What is not stored here

No API key, token, or credential is written by any script in this repo.
Authentication stays entirely inside Claude Code's own credential store, and the
proxies forward whatever `Authorization` header the client sends.
