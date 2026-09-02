#!/bin/zsh
set -euo pipefail

gallery_dir=${0:A:h}
gallery_repo=${gallery_dir:h:h}
gallery_log="$gallery_repo/.tmp/onboarding-gallery-build.log"
gallery_installed_app="$HOME/Applications/iOS Onboarding.app"
gallery_build_command=(xcodebuild -project "$gallery_dir/InlineOnboardingGallery.xcodeproj" -scheme InlineOnboardingGallery -configuration Debug -destination "platform=macOS,variant=Mac Catalyst,arch=$(/usr/bin/uname -m)" CODE_SIGNING_ALLOWED=NO build)

if [[ -e "$gallery_installed_app" ]]; then
  gallery_existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$gallery_installed_app/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$gallery_existing_id" != "chat.inline.tools.ios-onboarding-gallery" ]]; then
    print -u2 "Refusing to replace an unrelated app at $gallery_installed_app"
    exit 1
  fi
fi

# Follow the repository's one-build-at-a-time convention, even when launched directly.
if [[ -s "$gallery_repo/.running" ]]; then
  print -u2 "Another session has registered work in $gallery_repo/.running. Wait for it to finish before building."
  exit 1
fi
if /usr/bin/pgrep -x xcodebuild >/dev/null; then
  print -u2 "An Xcode build is already running. Wait for it to finish before building."
  exit 1
fi

mkdir -p "$gallery_repo/.tmp"
gallery_entry="onboarding-gallery-$$ | ${(q)gallery_build_command}"
print -r -- "$gallery_entry" >> "$gallery_repo/.running"
gallery_release_build_slot() {
  GALLERY_ENTRY="$gallery_entry" /usr/bin/python3 - "$gallery_repo/.running" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
entry = os.environ["GALLERY_ENTRY"]
path.write_text("".join(line for line in path.read_text().splitlines(keepends=True) if line.rstrip("\n") != entry))
PY
}
trap gallery_release_build_slot EXIT

if ! "${gallery_build_command[@]}" > "$gallery_log" 2>&1; then
  /usr/bin/tail -n 60 "$gallery_log"
  print -u2 "Build failed. Full log: $gallery_log"
  exit 1
fi

gallery_settings="$gallery_repo/.tmp/onboarding-gallery-build-settings.json"
xcodebuild -project "$gallery_dir/InlineOnboardingGallery.xcodeproj" \
  -scheme InlineOnboardingGallery -configuration Debug \
  -destination "platform=macOS,variant=Mac Catalyst,arch=$(/usr/bin/uname -m)" -showBuildSettings -json > "$gallery_settings"
gallery_app=$(/usr/bin/python3 -c 'import json, sys; s = next(x["buildSettings"] for x in json.load(open(sys.argv[1])) if x["target"] == "InlineOnboardingGallery"); print(s["TARGET_BUILD_DIR"] + "/" + s["FULL_PRODUCT_NAME"])' "$gallery_settings")
# Local ad-hoc signing avoids a developer-team/provisioning requirement for this offline tool.
/usr/bin/codesign --force --deep --sign - --entitlements "$gallery_dir/Resources/OnboardingGallery.entitlements" "$gallery_app"
/usr/bin/codesign --verify --deep --strict "$gallery_app"
/usr/bin/osascript <<'APPLESCRIPT'
if application id "chat.inline.tools.ios-onboarding-gallery" is running then
  tell application id "chat.inline.tools.ios-onboarding-gallery" to quit
  repeat 50 times
    if application id "chat.inline.tools.ios-onboarding-gallery" is not running then exit repeat
    delay 0.1
  end repeat
  if application id "chat.inline.tools.ios-onboarding-gallery" is running then error "The gallery is still closing. Run again after it exits."
end if
APPLESCRIPT
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$gallery_app" "$gallery_installed_app"
/usr/bin/codesign --verify --deep --strict "$gallery_installed_app"
/usr/bin/open "$gallery_installed_app"
print -r -- "Opened $gallery_installed_app"
