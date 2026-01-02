#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${INLINE_RELEASE_BASE_URL:-https://public-assets.inline.chat/cli}"
MANIFEST_URL="${INLINE_RELEASE_MANIFEST_URL:-${BASE_URL%/}/manifest.json}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [ -n "${TMPDIR_CLEANUP:-}" ] && [ -d "$TMPDIR_CLEANUP" ]; then
    rm -rf "$TMPDIR_CLEANUP"
  fi
}

trap cleanup EXIT INT TERM

need_cmd() {
  if ! command_exists "$1"; then
    error "need '$1' (command not found)"
  fi
}

check_prereqs() {
  need_cmd uname
  need_cmd mktemp
  need_cmd tar
  need_cmd install
  if command_exists shasum; then
    SHA256_CMD="shasum -a 256"
  elif command_exists sha256sum; then
    SHA256_CMD="sha256sum"
  else
    error "need 'shasum' or 'sha256sum' (command not found)"
  fi
  if ! command_exists curl && ! command_exists wget; then
    error "need 'curl' or 'wget' (command not found)"
  fi
}

downloader() {
  local url="$1"
  local output_file="$2"

  if command_exists curl; then
    curl -fsSL "$url" -o "$output_file"
  elif command_exists wget; then
    wget -q -O "$output_file" "$url"
  else
    error "Neither curl nor wget found"
  fi
}

download_file() {
  local url="$1"
  local output_file="$2"
  local temp_file
  temp_file=$(mktemp "$(dirname "$output_file")/tmp.XXXXXX")
  downloader "$url" "$temp_file"
  mv "$temp_file" "$output_file"
}

detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  if [ "$os" != "Darwin" ]; then
    error "Unsupported OS: $os (macOS only)"
  fi

  case "$arch" in
    arm64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) error "Unsupported architecture: $arch" ;;
  esac
}

check_prereqs

TMPDIR_CLEANUP="$(mktemp -d)"

log "Fetching manifest..."
manifest_file="$TMPDIR_CLEANUP/manifest.json"
download_file "$MANIFEST_URL" "$manifest_file"
manifest="$(cat "$manifest_file")"

target="$(detect_target)"
log "Detected target: $target"

if command_exists jq; then
  version="$(printf '%s' "$manifest" | jq -r '.version // empty')"
  url="$(printf '%s' "$manifest" | jq -r --arg t "$target" '.targets[$t].url // empty')"
  sha256="$(printf '%s' "$manifest" | jq -r --arg t "$target" '.targets[$t].sha256 // empty')"
else
  compact="$(printf '%s' "$manifest" | tr -d '\n\r\t')"
  version="$(printf '%s' "$compact" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  target_block="$(printf '%s' "$compact" | sed -n "s/.*\"$target\"[[:space:]]*:[[:space:]]*{\\([^}]*\\)}.*/\\1/p" | head -n1)"
  url="$(printf '%s' "$target_block" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  sha256="$(printf '%s' "$target_block" | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
fi

if [ -z "$version" ] || [ -z "$url" ] || [ -z "$sha256" ]; then
  error "No release found for $target"
fi

archive="$TMPDIR_CLEANUP/inline.tar.gz"

log "Downloading inline v$version..."
download_file "$url" "$archive"

log "Verifying checksum..."
echo "$sha256  $archive" | $SHA256_CMD -c -

tar -xzf "$archive" -C "$TMPDIR_CLEANUP"

if [ ! -f "$TMPDIR_CLEANUP/inline" ]; then
  error "Archive did not contain inline binary"
fi

install_dir="/usr/local/bin"
install_path="$install_dir/inline"

if [ -w "$install_dir" ]; then
  install -m 0755 "$TMPDIR_CLEANUP/inline" "$install_path"
else
  if ! command_exists sudo; then
    error "sudo is required to install into $install_dir"
  fi
  sudo install -m 0755 "$TMPDIR_CLEANUP/inline" "$install_path"
fi

success "Installed inline v$version to $install_path"
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$install_dir"; then
  warn "$install_dir is not on your PATH. Add it to run 'inline'."
fi
