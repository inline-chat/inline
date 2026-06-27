#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
public_root="$(cd "${repo_root}/.." && pwd)/inline-public"
public_repo="${INLINE_PUBLIC_REPO:-https://github.com/inline-chat/inline.git}"
public_ref="${INLINE_PUBLIC_REF:-main}"

required_manifests=(
  "${repo_root}/cli/package.json"
  "${repo_root}/packages/bot-api/package.json"
  "${repo_root}/packages/mcp/package.json"
  "${repo_root}/packages/oauth-core/package.json"
  "${repo_root}/packages/openclaw/package.json"
  "${repo_root}/packages/sdk/package.json"
)

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
    git -C "${public_root}" fetch --depth=1 origin "${public_ref}"
    git -C "${public_root}" checkout --detach FETCH_HEAD
  elif [[ -e "${public_root}" ]]; then
    echo "Expected ${public_root} to be the public workspace checkout, but it is not a git repository." >&2
    exit 1
  else
    echo "Cloning public workspaces into ${public_root}."
    git clone --depth=1 --branch "${public_ref}" "${public_repo}" "${public_root}"
  fi
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
