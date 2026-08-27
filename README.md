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
changes, and `--report-on` narrows intermediate reports to selected tokens.
Optional delivery uses one direct-argv backend: `--deliver
paseo-queue` pipes the report to `paseo-queue add <report-to>`, while
`--deliver <command>` pipes it to an arbitrary executable. Delivery failures
remain recorded in the watch for retry on the next sweep.

```sh
paseo-monitor watch --kind <kind> [kind args] --deadline <when> [options]
paseo-monitor watch --script <file> --reason "<why no kind fits>" --deadline <when> [options]
paseo-monitor kinds
paseo-monitor ls
paseo-monitor status [<id>]
paseo-monitor log <id> [-n N] [-f]
paseo-monitor poke <id>
paseo-monitor rm <id> | --all
paseo-monitor reap
paseo-monitor _sweep
```

`--deadline <when>` is required for every watch; malformed deadline values are rejected separately.

Common watch options include `--report-transitions`, `--report-on TOK,TOK`,
`--label k=v`, `--prohibit TEXT`, `--failsafe`, `--max-runs N`, and
`--expires-in DURATION`. `--with-reason` is the Slurm reason-detail switch;
reason tokens in `--report-on` derive it automatically. Slurm and PBS have
120-second floors; their defaults are 600 seconds terminal-only and 300
seconds when transitions are enabled. Other kind floors and defaults are
listed by `paseo-monitor kinds` and in the skill table.

Kind floors and defaults:

| Kind | Floor | Default interval |
| --- | --- | --- |
| `slurm` | 120s | 600s terminal-only, 300s transitions |
| `pbs` | 120s | 600s terminal-only, 300s transitions |
| `globus` | 60s | 300s |
| `agent` | 60s | 60s; default dwell 2 |
| `file-exists` (absence / receipt pattern) | 60s local, 120s remote | 60s local, 120s remote |
| `git-ref` | 60s | 120s |
| `pr-merge` | 60s | 300s |
| `script` | 60s | 60s |

For an absence / receipt watch, key `file-exists` to a pre-agreed receipt path:

```sh
paseo-monitor watch --kind file-exists --path /scratch/run/receipt --deadline +3600
```

Job-id-keyed watches cannot observe a target that never entered the queue.

`--failsafe` creates a bounded one-shot Paseo schedule in the daemon. Its
pointer-only prompt contains the watch id, the `status`/`log` procedure, and
the opaque prohibition text, never routing or state. A clean terminal report
removes the schedule. Use `--max-runs` and `--expires-in` for explicit bounds;
without them, one run expires at the watch deadline.

At registration the tool attempts to harvest the caller's `role`, `job`,
`item`, and `lane` labels from `paseo inspect "$PASEO_AGENT_ID" --json` when
the CLI exposes them. Some installed CLI versions omit labels; explicit
`--label k=v` is the reliable fallback. `branch` and `sha` are recommended
label keys, never dedicated flags. `--prohibit` is a courier, not an
enforcer: use it only for unconditional target-scoped constraints. Put
conditional or situational constraints in Task Orchestrator notes and point
to them.

Registration output states that delivery is best-effort. The caller owns its
liveness backstop.

Agent watches default to `--dwell 2`; the setting remains specific to this kind.

### Agent stall watch

The `agent` kind watches stalls and observable lifecycle changes, not a
completion event:

```sh
paseo-monitor watch --kind agent --agent <id> \
  --report-to "$PASEO_AGENT_ID" --deadline +3600
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
directory contains `spec`, `context`, `probe`, `last`, `detail`, `dwell`,
`nextDue`, `health`, `state`, `undelivered`, `fires`, and `log` as applicable.
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
