#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
for directory in cli packages/sdk packages/mcp packages/bot-client packages/oauth-core plugins/openclaw plugins/hermes-agent plugins/chat-sdk-plugin; do
  if [[ ! -f "${repo_root}/${directory}/package.json" || -L "${repo_root}/${directory}" ]]; then
    echo "Missing in-repository workspace: ${directory}" >&2
    exit 1
  fi
done
echo "All integration workspaces are available in this repository."
