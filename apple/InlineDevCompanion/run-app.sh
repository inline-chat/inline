#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
user_applications_path="$HOME/Applications"
installed_app_path="$user_applications_path/Inline Dev Companion.app"

"$script_dir/build-app.sh"
mkdir -p "$user_applications_path"
/usr/bin/ditto "$script_dir/.build/app/Inline Dev Companion.app" "$installed_app_path"
/usr/bin/codesign --verify --deep --strict "$installed_app_path"
/usr/bin/open "$installed_app_path"
