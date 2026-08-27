---
name: paseo-monitor
description: Monitor a long-running job, wait for a Slurm job, watch a Globus transfer, notify when done, wake me when it finishes, avoid going stale, stop polling, and report observed state changes through a cheap bounded watcher.
---

# paseo-monitor

Use `paseo-monitor` when the target is long-running and the completion check is
mechanical. Register one watch, record the resume context, then return to the
main task. The tool observes and records state changes; delivery is best-effort
and the caller owns liveness.

Prefer this observe-half beside `paseo-queue`, which handles ordered delivery.
Prefer it over `monitor-with-subagent` when a dumb probe suffices. For cluster
work, read `cluster-access`: cadence is bounded by facility policy.

## Minimum viable watch

```sh
paseo-monitor watch --kind slurm --host cannon --job 24211558
```

`--report-to` defaults to `$PASEO_AGENT_ID`. Reports go to the caller's queue
when `--deliver paseo-queue` is selected; registration itself only records the
watch unless a delivery backend is configured.

## Kind table

The table below is also emitted by `paseo-monitor kinds` and `paseo-monitor
--help`. Copy the invocation that matches the target.

| Kind | Description | Parameters | Floor | Default interval | Copy-pasteable invocation |
| --- | --- | --- | --- | --- | --- |
| `slurm` | Slurm job state | `--host <host> --job <id>` | 120s | 600s terminal-only, 300s transitions | `paseo-monitor watch --kind slurm --host cannon --job 24211558` |
| `globus` | Globus transfer status | `--task <id>` | 60s | 300s | `paseo-monitor watch --kind globus --task TASK-ID` |
| `agent` | Paseo agent status | `--agent <id> [--report-on <tokens>] [--dwell <sweeps>]` | 60s | 60s | `paseo-monitor watch --kind agent --agent AGENT-ID --report-on BLOCKED-PERMISSION,CLOSED,ARCHIVED --dwell 2` |
| `file-exists` | File existence | `--path <path> [--host <host>]` | 60s | 60s | `paseo-monitor watch --kind file-exists --path /scratch/run/receipt --host cannon` |
| `git-ref` | Git ref SHA | `--remote <remote> --ref <ref>` | 60s | 120s | `paseo-monitor watch --kind git-ref --remote ORIGIN --ref refs/heads/main` |
| `pr-merge` | Pull request merge state | `--repo <owner/repo> --pr <number>` | 60s | 300s | `paseo-monitor watch --kind pr-merge --repo OWNER/REPO --pr 123` |
| `script` | Custom executable | `--script <file> --reason "<why no kind fits>"` | 60s | 60s | `paseo-monitor watch --script ./probe.sh --reason "custom direct-argv check" --terminal DONE` |

Examples:

```sh
paseo-monitor watch --kind slurm --host cannon --job 24211558 \
  --report-to "$PASEO_AGENT_ID" --deliver paseo-queue \
  --context 'target=24211558 changed=queued; item=0fc2d958; sha=0123456789abcdef0123456789abcdef01234567; branch=main; purpose=wait for outputs; next-owner=caller; evidence=artifact:/path/to/receipt; prohibitions=no polling, no unstated verdicts'

paseo-monitor watch --kind globus --task TASK-ID \
  --context 'target=TASK-ID changed=active; item=ITEM-ID; sha=FULL_SHA; branch=BRANCH; purpose=wait for transfer; next-owner=caller; evidence=artifact:/path/to/receipt; prohibitions=no polling'

paseo-monitor watch --kind agent --agent AGENT-ID --report-on BLOCKED-PERMISSION,CLOSED,ARCHIVED --dwell 2

paseo-monitor watch --kind file-exists --path /scratch/run/receipt --host cannon \
  --context 'target=/scratch/run/receipt changed=absent; item=ITEM-ID; sha=FULL_SHA; branch=BRANCH; purpose=wait for receipt; next-owner=caller; evidence=artifact:/path/to/plan; prohibitions=no inferred completion'

paseo-monitor watch --script ./probe.sh --reason "the target needs a custom direct-argv check" \
  --terminal DONE --context 'target=custom-id changed=running; item=ITEM-ID; sha=FULL_SHA; branch=BRANCH; purpose=wait for custom result; next-owner=caller; evidence=artifact:/path/to/log; prohibitions=no shell-string execution'
```

The `--context` resume format is required: target id and what changed; Task
Orchestrator item id; exact full SHA and branch; why or purpose; who owns the
next action; one evidence line citing an artifact; and prohibitions. `branch`
and `sha` are recommended label keys for `--label`, never CLI flags.

## Required liveness ritual

Treat this as one caller-owned backstop, not separate optional habits:

1. Register the watch with `--failsafe` when the surrounding workflow has a
   failsafe path.
2. At every turn start, run `paseo-monitor status`. Its `last-sweep-age` header
   lets the caller detect a dead or stale sweeper.
3. When the tool reports a terminal change, it clears its own schedule by
   retaining the terminal state and no longer probing it.
4. If the caller's failsafe fires first, run `paseo-monitor status <id>` before
   doing anything else, then inspect `paseo-monitor log <id>`.

Delivery is best-effort. A report in the watch log is evidence that observation
and report recording happened; it is not evidence that another process acted.
Do not over-trust the delivery path.

## Agent and custom-probe gaps

The `agent` probe cannot distinguish a stopped read from a normally idle read:
`Status=idle`, no pending permissions, and no archive field are byte-identical.
It reports `went idle`, not a completion verdict. Use an absence watch on a
receipt or checkpoint as the workaround when the artifact is authoritative.

A `--script` probe is snapshotted at registration and exec'd directly as argv.
A user script that merely invokes bare `ssh host squeue` inherits raw ssh and
remote exit-code ambiguity; its output and health code must follow the probe
contract (`TOKEN [detail]`, exit 0 for an observation). Recommend
`ControlPersist` in SSH configuration to reduce connection overhead; the tool
does not manage sockets.

## Recovery commands

```sh
paseo-monitor status [<id>]
paseo-monitor log <id> [-n N] [-f]
paseo-monitor poke <id>
paseo-monitor ls
paseo-monitor rm <id> | --all
paseo-monitor reap
```

`poke` probes out of band and resumes a parked watch. `reap` removes only
watches whose terminal or expired deadline is older than the long retention
period. Explicit `rm` is the normal cleanup path; terminal state is retained
for recovery until then.
