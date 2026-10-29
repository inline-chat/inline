#!/usr/bin/env sh
# Manual bootstrap. Enrolled updates use the CLI's built-in verifier thereafter.
set -eu
umask 077
BASE_URL="${INLINE_RELEASE_BASE_URL:-https://public-assets.inline.chat/cli}"
CHANNEL="${INLINE_CLI_CHANNEL:-stable}"
case "$CHANNEL" in stable|alpha) ;; *) printf '%s\n' 'INLINE_CLI_CHANNEL must be stable or alpha' >&2; exit 1;; esac
MANIFEST_URL="${INLINE_RELEASE_MANIFEST_URL:-${BASE_URL%/}/channels/$CHANNEL.json}"
KEY_ID='inline-cli-2026-10'
# Ed25519 SubjectPublicKeyInfo, derived from cli/release-keys.json.
PUBLIC_KEY='MCowBQYDK2VwAyEAXRnthgyciTxQh/hF6QgvPjCy0CorCD4IlW4Nwlknoyo='
log() { printf '%s\n' "$1" >&2; }
error() { log "$1"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
cleanup() { [ -z "${work:-}" ] || rm -rf "$work"; [ -z "${replacement:-}" ] || rm -f "$replacement"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for tool in uname mktemp tar install openssl wc chmod mv dirname sed tr head cat sleep; do
  command_exists "$tool" || error "Install '$tool' and rerun the Inline installer."
done
if command_exists shasum; then SHA256_CMD='shasum -a 256';
elif command_exists sha256sum; then SHA256_CMD='sha256sum';
else error 'Install shasum or sha256sum and rerun the Inline installer.'; fi
command_exists curl || error 'Install curl and rerun the Inline installer.'
work=$(mktemp -d)
os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Darwin)
    [ "$arch" = arm64 ] || error 'Inline CLI requires Apple silicon on macOS.'
    target=aarch64-apple-darwin ;;
  Linux)
    libc=gnu
    if command_exists ldd && ldd --version 2>&1 | grep -qi musl; then libc=musl; fi
    case "$arch" in aarch64|arm64) arch=aarch64;; x86_64|amd64) arch=x86_64;; *) error "Unsupported architecture: $arch";; esac
    target="$arch-unknown-linux-$libc" ;;
  *) error "Unsupported OS: $os" ;;
esac
log "Detected target: $target"

download() {
  # An explicit manifest override is a manual developer/test bootstrap only.
  # Production downloads and redirects stay on HTTPS and are bounded.
  case "$1" in
    https://*) protocols='=https';;
    file://*) [ -n "${INLINE_RELEASE_MANIFEST_URL:-}" ] || error 'Expected an HTTPS release'; protocols='=file';;
    *) error 'Expected an HTTPS release';;
  esac
  curl --fail --silent --show-error --location --proto "$protocols" --proto-redir "$protocols" \
    --connect-timeout 10 --max-time 120 --max-filesize "$3" "$1" -o "$2"
  [ "$(wc -c < "$2" | tr -d ' ')" -le "$3" ] || error 'Release download exceeded the safety limit.'
}

log "Fetching the $CHANNEL release..."
download "$MANIFEST_URL" "$work/envelope.json" 262144
if [ -n "${INLINE_RELEASE_MANIFEST_URL:-}" ]; then
  # Explicit overrides retain the old manual fixture/mirror contract. They do
  # not enable the enrolled automatic updater or change its pinned keys.
  cat "$work/envelope.json" > "$work/manifest.json"
else
  compact=$(tr -d '\n\r\t ' < "$work/envelope.json")
  if command_exists jq; then
    payload=$(jq -r '.payload // empty' "$work/envelope.json")
    signature=$(jq -r --arg id "$KEY_ID" '.signatures[] | select(.keyId == $id) | .signature' "$work/envelope.json" | head -n1)
  else
    payload=$(printf '%s' "$compact" | sed -n 's/.*"payload":"\([A-Za-z0-9+/=]*\)".*/\1/p')
    key_id=$(printf '%s' "$compact" | sed -n 's/.*"keyId":"\([^"]*\)".*/\1/p')
    [ "$key_id" = "$KEY_ID" ] || error 'Unknown CLI release signing key. Refresh the installer from inline.chat.'
    signature=$(printf '%s' "$compact" | sed -n 's/.*"signature":"\([A-Za-z0-9+/=]*\)".*/\1/p')
  fi
  [ -n "$payload" ] && [ -n "$signature" ] || error 'The CLI release signature is missing. Retry later.'
  printf '%s' "$payload" | openssl base64 -d -A > "$work/manifest.json"
  printf '%s' "$signature" | openssl base64 -d -A > "$work/signature"
  printf '%s' "$PUBLIC_KEY" | openssl base64 -d -A > "$work/public.der"
  printf 'inline-cli-channel-v1\000' > "$work/signed"
  cat "$work/manifest.json" >> "$work/signed"
  if openssl pkey -pubin -inform DER -in "$work/public.der" -noout >/dev/null 2>&1; then
    openssl pkeyutl -verify -pubin -keyform DER -inkey "$work/public.der" -rawin \
      -in "$work/signed" -sigfile "$work/signature" >/dev/null 2>&1 \
      || error 'CLI release verification failed. The existing installation was kept; retry later.'
  elif [ "$os" = Darwin ]; then
    # System LibreSSL may lack Ed25519. Manual Mac bootstrap still requires
    # Inline's strict Developer ID identity before executing anything.
    log 'Using macOS Developer ID verification for this manual install (system crypto lacks Ed25519).'
  else
    error 'This installer needs OpenSSL with Ed25519 support (OpenSSL 1.1.1 or newer). Install it and retry.'
  fi
fi

if command_exists jq; then
  version=$(jq -r '.version // empty' "$work/manifest.json")
  release_channel=$(jq -r '.channel // empty' "$work/manifest.json")
  url=$(jq -r --arg t "$target" '.targets[$t].url // empty' "$work/manifest.json")
  sha256=$(jq -r --arg t "$target" '.targets[$t].sha256 // empty' "$work/manifest.json")
  size=$(jq -r --arg t "$target" '.targets[$t].size // empty' "$work/manifest.json")
else
  # The signed publisher emits canonical compact JSON. Split version fields to
  # select the top-level version before optional intermediate baselines.
  compact=$(tr -d '\n\r\t ' < "$work/manifest.json")
  version=$(printf '%s' "$compact" | sed 's/"version"/\
"version"/g' | sed -n 's/^"version":"\([^"]*\)".*/\1/p' | head -n1)
  release_channel=$(printf '%s' "$compact" | sed -n 's/.*"channel":"\([^"]*\)".*/\1/p')
  # Top-level targets follow any required baseline and therefore win last.
  block=$(printf '%s' "$compact" | sed -n "s/.*\"$target\":{\\([^}]*\\)}.*/\\1/p")
  url=$(printf '%s' "$block" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
  sha256=$(printf '%s' "$block" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')
  size=$(printf '%s' "$block" | sed -n 's/.*"size":\([0-9]*\).*/\1/p')
fi
[ -n "$version" ] && [ -n "$url" ] || error "No release found for $target."
[ -n "${INLINE_RELEASE_MANIFEST_URL:-}" ] || [ "$release_channel" = "$CHANNEL" ] || error 'CLI release channel mismatch.'
case "$sha256" in *[!a-fA-F0-9]*|'') error 'Invalid release checksum.';; esac
[ "${#sha256}" = 64 ] || error 'Invalid release checksum.'
case "$size" in *[!0-9]*|'') error 'Invalid release size.';; esac
[ "${#size}" -le 9 ] && [ "$size" -gt 0 ] && [ "$size" -le 104857600 ] || error 'Invalid release size.'
log "Downloading inline v$version..."
download "$url" "$work/inline.tar.gz" "$size"
[ "$(wc -c < "$work/inline.tar.gz" | tr -d ' ')" = "$size" ] || error 'Release size mismatch.'
printf '%s  %s\n' "$sha256" "$work/inline.tar.gz" | $SHA256_CMD -c - >/dev/null
entry=$(tar -tzf "$work/inline.tar.gz")
case "$entry" in inline|./inline) ;; *) error 'Release archive must contain exactly one inline executable.';; esac
kind=$(tar -tvzf "$work/inline.tar.gz" | head -c1)
[ "$kind" = '-' ] || error 'Release executable must be a regular file.'
# Extract only that entry to stdout; archive names never become filesystem paths.
(ulimit -f 409600; tar -xOzf "$work/inline.tar.gz" "$entry" > "$work/inline")
[ "$(wc -c < "$work/inline" | tr -d ' ')" -le 209715200 ] || error 'Expanded release exceeded the safety limit.'
chmod 755 "$work/inline"
if [ "$os" = Darwin ]; then
  /usr/bin/codesign --verify --strict --all-architectures \
    '-R=anchor apple generic and identifier "chat.inline.cli" and certificate leaf[subject.OU] = "2487AN8AL4"' "$work/inline" \
    || error 'The CLI does not have Inline’s Developer ID signature.'
fi
"$work/inline" --version > "$work/version" &
probe=$!
(sleep 10; kill -TERM "$probe" 2>/dev/null || true; sleep 1; kill -KILL "$probe" 2>/dev/null || true) &
watchdog=$!
probe_status=0
wait "$probe" || probe_status=$?
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
[ "$probe_status" = 0 ] && [ "$(cat "$work/version")" = "inline $version" ] || error 'The release executable failed its version check.'

existing=$(command -v inline 2>/dev/null || true)
if [ -z "${INLINE_INSTALL_DIR:-}" ] && [ -n "$existing" ]; then
  case "$existing" in */Cellar/*|*/Caskroom/*|/opt/homebrew/*) error 'Homebrew manages this CLI. Use: brew upgrade --cask inline';; esac
  error "An existing CLI is at $existing. Use 'inline update', or explicitly set INLINE_INSTALL_DIR to replace its regular executable. No second installation was created."
fi
[ -n "${HOME:-}" ] || [ -n "${INLINE_INSTALL_DIR:-}" ] || error 'Set HOME or INLINE_INSTALL_DIR.'
install_dir="${INLINE_INSTALL_DIR:-$HOME/.local/bin}"
case "$install_dir" in /*/Cellar/*|/*/Caskroom/*|/opt/homebrew/*) error 'Homebrew owns this installation directory.';; /*) ;; *) error 'INLINE_INSTALL_DIR must be an absolute path.';; esac
mkdir -p "$install_dir" || error "Cannot create $install_dir. Choose a user-writable directory."
destination="$install_dir/inline"
[ ! -L "$destination" ] || error 'An installation symlink already exists. Use its package manager or choose another explicit location.'
if [ -e "$destination" ] && [ ! -f "$destination" ]; then error 'The installation destination is not a regular file.'; fi
replacement=$(mktemp "$install_dir/.inline.install.XXXXXX")
install -m 0755 "$work/inline" "$replacement"
mv -f "$replacement" "$destination"
replacement=''
# Auth files are not rewritten; an explicit opt-out in updater state survives.
"$destination" update config --channel "$CHANNEL" --register --json >/dev/null \
  || log "Installed. To enroll updates, run: $destination update config --register"
log "Installed inline v$version to $destination"
case ":$PATH:" in *":$install_dir:"*) ;; *) log "Add $install_dir to PATH to run inline from your shell.";; esac
