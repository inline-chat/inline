#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
public_root="$(cd "${repo_root}/.." && pwd -P)/inline-public"
public_repo="${INLINE_PUBLIC_REPO:-https://github.com/inline-chat/inline.git}"
public_ref_file="${INLINE_PUBLIC_REF_FILE:-${repo_root}/scripts/ci/public-workspaces-ref}"

if [[ -n "${INLINE_PUBLIC_REF:-}" ]]; then
  public_ref="${INLINE_PUBLIC_REF}"
elif [[ -f "${public_ref_file}" ]]; then
  public_ref="$(tr -d '[:space:]' < "${public_ref_file}")"
else
  public_ref="main"
fi

if [[ -z "${public_ref}" ]]; then
  echo "Public workspace ref is empty." >&2
  exit 1
fi

default_required_manifest_paths=(
  "cli/package.json"
  "packages/bot-api/package.json"
  "packages/mcp/package.json"
  "packages/oauth-core/package.json"
  "packages/openclaw/package.json"
  "packages/sdk/package.json"
)

if [[ -n "${INLINE_PUBLIC_REQUIRED_MANIFESTS:-}" ]]; then
  read -r -a required_manifest_paths <<< "${INLINE_PUBLIC_REQUIRED_MANIFESTS}"
else
  required_manifest_paths=("${default_required_manifest_paths[@]}")
fi

required_manifests=()
for manifest_path in "${required_manifest_paths[@]}"; do
  required_manifests+=("${repo_root}/${manifest_path}")
done

missing=0
for manifest in "${required_manifests[@]}"; do
  if [[ ! -f "${manifest}" ]]; then
    missing=1
    break
  fi
done

if [[ "${missing}" -eq 0 ]]; then
  echo "Public workspaces already available."
else
  if [[ -d "${public_root}/.git" ]]; then
    echo "Updating public workspaces at ${public_root}."
  elif [[ -e "${public_root}" ]]; then
    echo "Expected ${public_root} to be the public workspace checkout, but it is not a git repository." >&2
    exit 1
  else
    echo "Cloning public workspaces into ${public_root}."
    mkdir -p "${public_root}"
    git -C "${public_root}" init
    git -C "${public_root}" remote add origin "${public_repo}"
  fi

  git -C "${public_root}" fetch --depth=1 origin "${public_ref}"
  git -C "${public_root}" checkout --detach FETCH_HEAD
fi

if [[ ! -e "${public_root}/node_modules" && ! -L "${public_root}/node_modules" ]]; then
  echo "Linking public workspace dependencies to ${repo_root}/node_modules."
  ln -s "${repo_root}/node_modules" "${public_root}/node_modules"
fi

for manifest in "${required_manifests[@]}"; do
  if [[ ! -f "${manifest}" ]]; then
    echo "Public workspace manifest still missing: ${manifest}" >&2
    exit 1
  fi
done

echo "Public workspaces are ready."
