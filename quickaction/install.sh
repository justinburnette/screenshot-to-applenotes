#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"
workflow_name="OCR Screenshots to Note.workflow"
source_path="$script_dir/$workflow_name"
services_dir="$HOME/Library/Services"
dest_path="$services_dir/$workflow_name"
main_script="$repo_root/screenshot-to-note.sh"

if [[ ! -d "$source_path" ]]; then
  echo "Error: $source_path not found." >&2
  exit 1
fi

if [[ ! -f "$main_script" ]]; then
  echo "Error: $main_script not found (expected next to the quickaction/ folder)." >&2
  exit 1
fi
chmod +x "$main_script" "$repo_root/build.sh" 2>/dev/null || true

mkdir -p "$services_dir"
rm -rf "$dest_path"
cp -R "$source_path" "$dest_path"

# The bundled workflow ships with a placeholder instead of a real path, since
# the repo can be cloned anywhere -- fill in this machine's actual location
# in the installed copy only, leaving the repo's own template untouched.
sed -i '' "s|__SCREENSHOT_TO_NOTE_PATH__|$main_script|g" "$dest_path/Contents/document.wflow"

# Nudge Launch Services / Finder to notice the new Service registration.
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
killall Finder >/dev/null 2>&1 || true

echo "Installed \"$workflow_name\" to $services_dir"
echo "Right-click one or more screenshots in Finder and look under Quick Actions."
echo "If it doesn't appear yet, enable it in System Settings > Keyboard > Keyboard Shortcuts > Services (or Extensions > Finder)."
