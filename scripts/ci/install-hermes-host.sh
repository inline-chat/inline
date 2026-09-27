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
# Hermes' Python constraint can include update-only bridge interpreters whose
# dependency markers deliberately install no runtime. Follow its declared runtime.
bootstrap_python=${PYTHON_BIN:-python3}
"$bootstrap_python" -m venv "$host_dir/bootstrap"
"$host_dir/bootstrap/bin/python" -m pip install uv==0.12.19
uv_bin="$host_dir/bootstrap/bin/uv"
if [[ -f "$host_dir/source/.python-version" ]]; then
  host_python=$(tr -d '[:space:]' < "$host_dir/source/.python-version")
  [[ "$host_python" =~ ^3\.[0-9]+(\.[0-9]+)?$ ]] || { echo 'Invalid Hermes Python version' >&2; exit 1; }
else
  host_python=$("$bootstrap_python" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')
fi
printf 'Hermes declared Python runtime: %s\n' "$host_python"
"$uv_bin" venv --python "$host_python" "$host_dir/venv"
"$uv_bin" pip install --python "$host_dir/venv/bin/python" -e "$host_dir/source"
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
