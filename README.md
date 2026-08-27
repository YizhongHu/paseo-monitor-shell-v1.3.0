# paseo-monitor

`paseo-monitor` is a cheap, stateless watcher for long-running external work.
A launchd-fired sweeper observes a due watch and reports only state changes;
the caller owns the liveness backstop. The complete design is in `PLAN.md`.

This repository targets macOS and POSIX `sh` (`/bin/sh` is bash 3.2.57 in
`sh` mode). The deliberate trigger choice is launchd: its GUI agent preserves
`SSH_AUTH_SOCK` and login-Keychain access for cluster probes. The core avoids
platform-specific shell features and does not use `jq`, `flock`, `setsid`,
`timeout(1)`, or nanosecond `date` formatting.

## CLI

The CLI observes and records without requiring a delivery backend. Reports are
terminal transitions by default; `--report-transitions` opts into intermediate
changes. Optional delivery uses one direct-argv backend: `--deliver
paseo-queue` pipes the report to `paseo-queue add <report-to>`, while
`--deliver <command>` pipes it to an arbitrary executable. Delivery failures
remain recorded in the watch for retry on the next sweep.

```sh
paseo-monitor watch --kind <kind> [kind args] [options]
paseo-monitor watch --script <file> --reason "<why no kind fits>" [options]
paseo-monitor kinds
paseo-monitor ls
paseo-monitor status [<id>]
paseo-monitor log <id> [-n N] [-f]
paseo-monitor poke <id>
paseo-monitor rm <id> | --all
paseo-monitor reap
paseo-monitor _sweep
```

Registration output states that delivery is best-effort and makes no wake-up
promise. The caller owns its liveness backstop.

### Agent stall watch

The `agent` kind watches stalls and observable lifecycle changes, not a
guaranteed completion event:

```sh
paseo-monitor watch --kind agent --agent <id> \
  --report-on BLOCKED-PERMISSION,CLOSED,ARCHIVED --dwell 2
```

`paseo inspect <id> --json` exposes `Status`, `Archived`/`ArchivedAt`,
`PendingPermissions`, and `UpdatedAt`. Permission holds report as
`BLOCKED-PERMISSION`; permission queue depth and verbatim `updated_at=` are
included in the detail. For an idle observation the detail says `went idle`
and includes `idle_since=` with that same unmodified `UpdatedAt` value. Use
`--dwell N` to require N consecutive observations for an agent transition;
this narrow flap control applies only to agents.

**Measured gap:** a stopped agent is byte-identical to a normally finished
agent (`Status=idle`, `Archived=False`, `PendingPermissions=[]`), and the CLI
has no `stopped` status or attention field. No polling cadence can recover
that absent state. The probe therefore says **went idle**, never **finished**.
For certainty, pair this with an **absence watch** on a receipt or checkpoint
file; that workaround observes the artifact rather than inventing a verdict.

## State and knobs

Default state is `~/.paseo-monitor`. The state root contains `sweep.lock/`,
`sweep.log`, `sweep.beacon`, and `watches/<watch-id>/` directories. A watch
directory contains `spec`, `context`, `probe`, `last`, `detail`, `nextDue`,
`health`, `state`, `undelivered`, `fires`, and `log` as applicable. The global
lock is mkdir-based and all mutable files use atomic temporary-file plus `mv`
writes.

External knobs are read once at process startup into internal `PM_*` variables;
runtime code must use only the internal names:

| External knob | Default | Purpose |
| --- | --- | --- |
| `PASEO_MONITOR_HOME` | `$HOME/.paseo-monitor` | State root |
| `PASEO_MONITOR_LOG_MAX_BYTES` | `5242880` | Single-generation log rotation threshold |
| `PASEO_MONITOR_LOCK_GRACE_SECONDS` | `5` | Lock-without-pid liveness grace window |
| `PASEO_MONITOR_BACKOFF_SCALE` | `1` | Test-only backoff multiplier |
| `PASEO_MONITOR_FAST_SWEEP` | `0` | Test-only fast-sweep mode |

The inherited environment is intentionally not sanitized. In particular,
credential variables needed by SSH and Kerberos probes remain available.

## Installation

From a checkout:

```sh
./install.sh
export PATH="$HOME/.local/bin:$PATH"
paseo-monitor --help
```

Installation creates the idempotent symlink
`~/.local/bin/paseo-monitor -> bin/paseo-monitor` and bootstraps the managed
launchd user agent `com.paseo-monitor.sweep` with `StartInterval=60` and
`RunAtLoad=true`. The agent is deliberate: a GUI launchd process carries
`SSH_AUTH_SOCK` and login-Keychain access required by cluster probes, unlike a
bare cron process. Re-running the installer safely reloads the marked plist;
`./install.sh uninstall` removes the agent and CLI symlink without deleting
watch state.

## Development

Run the tests with:

```sh
tests/run-tests.sh
```

Each test creates a fresh temporary sandbox and places mock `paseo`,
`paseo-queue`, and `ssh` commands first on `PATH`. Tests never use a real
cluster, daemon, or user monitor state.
