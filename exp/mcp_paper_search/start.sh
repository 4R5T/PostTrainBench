#!/usr/bin/env bash
# Start the paper-search MCP server using the Python environment in PATH.
# Requires: python3 with mcp and httpx packages installed.

PYTHON="$(command -v python3 || command -v python)"
SERVER_DIR="$(cd "$(dirname "$0")" && pwd)"

REQUIRED_PACKAGES=("mcp" "httpx")

for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! "$PYTHON" -c "import $pkg" 2>/dev/null; then
        "$PYTHON" -m pip install "$pkg" --quiet
    fi
done

exec "$PYTHON" "$SERVER_DIR/server.py"
