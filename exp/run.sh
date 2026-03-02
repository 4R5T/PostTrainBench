#!/bin/bash
# Run the arithmetic-for-agents prompt with both Claude Code and Codex
#
# Usage:
#   bash run.sh                  # run both agents sequentially
#   bash run.sh claude           # run only Claude Code
#   bash run.sh codex            # run only Codex
#
# Authentication: uses subscription login (no API keys required)
#   Claude Code: claude login
#   Codex:       codex login
#
# Optional:
#   CLAUDE_MODEL  (default: claude-sonnet-4-6)
#   CODEX_MODEL   (default: gpt-5.3-codex)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/prompt.md"

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found at $PROMPT_FILE" >&2
  exit 1
fi

PROMPT="$(cat "$PROMPT_FILE")"

CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.3-codex}"

TARGET="${1:-both}"
TS="$(date +%m%d_%H%M)"

run_claude() {
  echo "========================================"
  echo "Running Claude Code (model: $CLAUDE_MODEL)"
  echo "========================================"

  unset ANTHROPIC_API_KEY
  unset OPENAI_API_KEY
  unset GEMINI_API_KEY

  export BASH_MAX_TIMEOUT_MS="36000000"

  # Create an isolated sandbox so Claude cannot see sibling experiment folders.
  # Structure: exp/claude/runs/<timestamp>/  (empty dir, symlinks only)
  local SANDBOX="$SCRIPT_DIR/claude/runs/${TS}"
  mkdir -p "$SANDBOX"

  # Symlink .claude/ (hooks + settings) and mcp_paper_search/ into the sandbox.
  # Do NOT symlink the claude/ output dir — keeps sibling experiments invisible.
  ln -sfn "$SCRIPT_DIR/.claude"            "$SANDBOX/.claude"
  ln -sfn "$SCRIPT_DIR/mcp_paper_search"   "$SANDBOX/mcp_paper_search"

  cd "$SANDBOX"

  claude --print --verbose \
    --model "$CLAUDE_MODEL" \
    --output-format stream-json \
    --dangerously-skip-permissions \
    "$PROMPT"
}

run_codex() {
  echo "========================================"
  echo "Running Codex (model: $CODEX_MODEL)"
  echo "========================================"

  # Using subscription login — no API key check needed

  unset ANTHROPIC_API_KEY
  unset OPENAI_API_KEY
  unset GEMINI_API_KEY

  mkdir -p "$SCRIPT_DIR/codex"
  cd "$SCRIPT_DIR/codex"

  codex --search exec \
    --json \
    -c model_reasoning_summary=detailed \
    --skip-git-repo-check \
    --yolo \
    --model "$CODEX_MODEL" \
    "$PROMPT"
}

case "$TARGET" in
  claude)
    run_claude
    ;;
  codex)
    run_codex
    ;;
  both)
    run_claude
    run_codex
    ;;
  *)
    echo "Usage: $0 [claude|codex|both]" >&2
    exit 1
    ;;
esac
