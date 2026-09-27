#!/usr/bin/env bash
# Install the official stable GitHub source, whose release version can lead PyPI.
set -euo pipefail
host_dir=${1:?usage: install-hermes-host.sh DEST [latest|GITHUB_TAG]}
host_ref=${2:-latest}
if [[ "$host_ref" == latest ]]; then
  host_ref=$(gh api repos/NousResearch/hermes-agent/releases/latest --jq .tag_name)
fi
[[ "$host_ref" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid Hermes release tag' >&2; exit 1; }
mkdir -p "$host_dir"
git clone --depth 1 --branch "$host_ref" https://github.com/NousResearch/hermes-agent.git "$host_dir/source"
host_sha=$(git -C "$host_dir/source" rev-parse HEAD)
"${PYTHON_BIN:-python3}" -m venv "$host_dir/venv"
"$host_dir/venv/bin/python" -m pip install -e "$host_dir/source"
"$host_dir/venv/bin/hermes" --version
printf 'Hermes source: %s (%s)\n' "$host_ref" "$host_sha"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'hermes-bin=%s/venv/bin/hermes\n' "$host_dir"
    printf 'python-bin=%s/venv/bin/python\n' "$host_dir"
    printf 'host-ref=%s\n' "$host_ref"
    printf 'host-sha=%s\n' "$host_sha"
  } >> "$GITHUB_OUTPUT"
fi
