#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
configuration=release
app_path="$script_dir/.build/app/Inline Dev Companion.app"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"

swift build --package-path "$script_dir" --configuration "$configuration"
binary_path=$(swift build --package-path "$script_dir" --configuration "$configuration" --show-bin-path)

mkdir -p "$macos_path"
cp "$binary_path/InlineDevCompanion" "$macos_path/InlineDevCompanion"
cp "$script_dir/Resources/Info.plist" "$contents_path/Info.plist"

signing_identity=$(
  /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/awk -F '"' '
      /Developer ID Application:/ { print $2; found = 1; exit }
      /Apple Development:/ && development == "" { development = $2 }
      END { if (!found && development != "") print development }
    '
)
if [[ -n "$signing_identity" ]]; then
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign "$signing_identity" \
    "$app_path"
else
  /usr/bin/codesign --force --sign - "$app_path"
fi

echo "$app_path"
