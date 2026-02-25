#!/bin/bash
# Install Claude Code and Codex via npm

set -e

echo "Installing @anthropic-ai/claude-code..."
npm install -g @anthropic-ai/claude-code

echo "Installing @openai/codex..."
npm install -g @openai/codex

echo "Done. Installed:"
echo "  claude: $(claude --version 2>/dev/null || echo 'not found')"
echo "  codex:  $(codex --version 2>/dev/null || echo 'not found')"
