#!/bin/sh
# install.sh: idempotent installer for paseo-monitor.
#
# The launchd trigger is intentionally left to a later implementation lane.
# This lane installs the CLI symlink and any skill file that exists.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=${REPO_DIR:-"$script_dir"}

chmod +x "$REPO_DIR/bin/paseo-monitor"
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO_DIR/bin/paseo-monitor" "$HOME/.local/bin/paseo-monitor"

# skills/paseo-monitor/SKILL.md is added by a later lane. Keep installation
# idempotent and usable before that file exists.
if [ -f "$REPO_DIR/skills/paseo-monitor/SKILL.md" ]; then
    for skills_root in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
        mkdir -p "$skills_root/paseo-monitor"
        cp -f "$REPO_DIR/skills/paseo-monitor/SKILL.md" "$skills_root/paseo-monitor/SKILL.md"
    done
fi

if ! command -v paseo-monitor >/dev/null 2>&1; then
    echo "install.sh: FAILED - paseo-monitor is not on PATH." >&2
    echo 'Remedy: add $HOME/.local/bin to PATH.' >&2
    exit 1
fi
if ! paseo-monitor --help >/dev/null 2>&1; then
    echo "install.sh: FAILED - paseo-monitor --help did not exit 0." >&2
    exit 1
fi

echo "install.sh: SUCCESS - installed $HOME/.local/bin/paseo-monitor -> $REPO_DIR/bin/paseo-monitor"
