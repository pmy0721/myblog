#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

python3 /Users/mekeypan/.codex/skills/myblog-manager/scripts/myblog_manager.py \
  --blog-root /Users/mekeypan/Projects/myblog \
  deploy "$@"
