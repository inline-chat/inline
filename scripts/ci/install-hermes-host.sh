#!/usr/bin/env bash
# Official stock compatibility or an exact reviewed GitHub core commit.
set -euo pipefail
[[ $# -le 3 ]] || { echo 'usage: install-hermes-host.sh DEST [latest|TAG|main|SHA] [OWNER/REPO]' >&2; exit 1; }
host_dir=${1:?usage: install-hermes-host.sh DEST [latest|TAG|main|SHA] [OWNER/REPO]}
host_ref=${2-latest}
host_repository=${3-NousResearch/hermes-agent}
[[ "$host_repository" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid Hermes GitHub repository' >&2; exit 1; }
[[ "$host_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid Hermes ref' >&2; exit 1; }
if [[ "$host_repository" != NousResearch/hermes-agent && ! "$host_ref" =~ ^[a-f0-9]{40}$ ]]; then
  echo 'A reviewed fork requires an exact lowercase 40-hex commit' >&2
  exit 1
fi
if [[ "$host_ref" == latest ]]; then
  host_ref=$(gh api "repos/$host_repository/releases/latest" --jq .tag_name)
fi
[[ "$host_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid Hermes release tag' >&2; exit 1; }
[[ ! -e "$host_dir/source" ]] || { echo 'Hermes source destination already exists; use a fresh destination' >&2; exit 1; }
mkdir -p "$host_dir"
host_url="https://github.com/$host_repository.git"
if [[ "$host_ref" =~ ^[a-f0-9]{40}$ ]]; then
  git init -q "$host_dir/source"
  git -C "$host_dir/source" remote add origin "$host_url"
  git -C "$host_dir/source" fetch --depth 1 --filter=blob:none origin "$host_ref"
  git -C "$host_dir/source" -c advice.detachedHead=false checkout --detach FETCH_HEAD
else
  git clone --depth 1 --filter=blob:none --branch "$host_ref" -- "$host_url" "$host_dir/source"
fi
host_sha=$(git -C "$host_dir/source" rev-parse HEAD)
if [[ "$host_ref" =~ ^[a-f0-9]{40}$ && "$host_sha" != "$host_ref" ]]; then
  echo 'Hermes checkout does not match the requested commit' >&2
  exit 1
fi
bootstrap_python=${PYTHON_BIN:-python3}
if [[ -e "$host_dir/source/pm" ]]; then
  [[ -f "$host_dir/source/pm/build_env.py" ]] || { echo 'Hermes PM source is missing its fresh environment builder' >&2; exit 1; }
  # Canonical source version comes from reachable release tags and ancestry,
  # never a fabricated install stamp or the unstamped __version__ placeholder.
  history_options=(--tags --filter=blob:none)
  if [[ "$(git -C "$host_dir/source" rev-parse --is-shallow-repository)" == true ]]; then
    history_options+=(--unshallow)
  fi
  git -C "$host_dir/source" fetch "${history_options[@]}" origin "$host_sha"
  if [[ "$host_repository" != NousResearch/hermes-agent ]]; then
    git -C "$host_dir/source" fetch --no-tags --filter=blob:none https://github.com/NousResearch/hermes-agent.git 'refs/tags/v*:refs/tags/v*'
  fi
  [[ "$(git -C "$host_dir/source" rev-parse HEAD)" == "$host_sha" ]] || { echo 'Hermes checkout changed while fetching version ancestry' >&2; exit 1; }
  # VersionInfo reads the nearest CalVer release's project through a three-second
  # Git timeout. Hydrate that one deferred blob before its normal reader runs.
  if release_description=$(git -C "$host_dir/source" describe --tags --long --match 'v2[0-9][0-9][0-9].*' HEAD); then
    release_tag=${release_description%-*-*}
    git -C "$host_dir/source" show "$release_tag:pyproject.toml" > /dev/null
  fi
  # PM owns its pinned tools and frozen dependency build. This caller-owned
  # output never selects or repairs an installed application's generation.
  pm_host_dir=$(cd "$host_dir" && pwd -P)
  bootstrap_python=$(command -v "$bootstrap_python")
  [[ "$bootstrap_python" == /* ]] || bootstrap_python="$PWD/$bootstrap_python"
  (
    cd "$pm_host_dir/source"
    export HERMES_HOME="$pm_host_dir/build-home"
    export HERMES_RUNTIME_DIR="$pm_host_dir/runtime"
    "$bootstrap_python" -m pm.build_env --source . --out "$pm_host_dir/venv"
    "$pm_host_dir/venv/bin/hermes" --version
  )
else
  # Legacy stock sources predate PM. Follow their declared runtime, rather
  # than a Python constraint that may also admit update-only interpreters.
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
fi
printf 'Hermes source: %s @ %s (%s)\n' "$host_repository" "$host_ref" "$host_sha"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'hermes-bin=%s/venv/bin/hermes\n' "$host_dir"
    printf 'python-bin=%s/venv/bin/python\n' "$host_dir"
    printf 'host-ref=%s\n' "$host_ref"
    printf 'host-sha=%s\n' "$host_sha"
    printf 'host-repository=%s\n' "$host_repository"
  } >> "$GITHUB_OUTPUT"
fi
