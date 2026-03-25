#!/usr/bin/env bash

set -euo pipefail

# Sync private agent definitions from a private repository clone into
# this workspace's .github/agents directory for local usage.
#
# Defaults can be overridden via environment variables:
#   PRIVATE_AGENT_REPO
#   PRIVATE_AGENT_SOURCE_SUBDIR
#   PRIVATE_AGENT_TARGET_DIR
#
# Example:
#   PRIVATE_AGENT_REPO=/tmp/copilot-customizations \
#   bash scripts/agents/sync-private-agents.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRIVATE_AGENT_REPO="${PRIVATE_AGENT_REPO:-$HOME/copilot-customizations}"
PRIVATE_AGENT_SOURCE_SUBDIR="${PRIVATE_AGENT_SOURCE_SUBDIR:-personal/agents}"
PRIVATE_AGENT_TARGET_DIR="${PRIVATE_AGENT_TARGET_DIR:-$ROOT_DIR/.github/agents}"

SOURCE_DIR="$PRIVATE_AGENT_REPO/$PRIVATE_AGENT_SOURCE_SUBDIR"

if [[ ! -d "$PRIVATE_AGENT_REPO/.git" ]]; then
  echo "Private repo not found at: $PRIVATE_AGENT_REPO" >&2
  echo "Clone it first, or set PRIVATE_AGENT_REPO to your local clone path." >&2
  exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Source directory not found: $SOURCE_DIR" >&2
  echo "Set PRIVATE_AGENT_SOURCE_SUBDIR if your layout differs." >&2
  exit 1
fi

mkdir -p "$PRIVATE_AGENT_TARGET_DIR"

synced=0
shopt -s nullglob
for src in "$SOURCE_DIR"/*.agent.md; do
  cp "$src" "$PRIVATE_AGENT_TARGET_DIR/"
  echo "Synced: $(basename "$src")"
  synced=$((synced + 1))
done
shopt -u nullglob

if [[ "$synced" -eq 0 ]]; then
  echo "No *.agent.md files found in $SOURCE_DIR"
  exit 1
fi

echo "Done. Synced $synced agent file(s) to $PRIVATE_AGENT_TARGET_DIR"
