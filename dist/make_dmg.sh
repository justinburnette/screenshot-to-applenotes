#!/usr/bin/env bash
# Builds a distributable .dmg containing a precompiled universal (arm64 +
# x86_64) ocr binary, the Quick Action workflow, and a double-clickable
# Install.command -- so someone can download, double-click, and install
# without needing git, Xcode Command Line Tools, or any Terminal commands
# typed by hand. Run on macOS (locally, or via .github/workflows/release.yml
# on a tag push).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:-dev}"
app_name="Screenshot OCR to Apple Notes"
dmg_name="ScreenshotOCRtoAppleNotes-${version}.dmg"

work_dir="$(mktemp -d)"
stage_dir="$work_dir/$app_name"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$stage_dir/bin"

echo "Building universal ocr binary (arm64 + x86_64)..."
swiftc "$repo_root/src/ocr.swift" -O -target arm64-apple-macos12 -o "$work_dir/ocr-arm64"
swiftc "$repo_root/src/ocr.swift" -O -target x86_64-apple-macos12 -o "$work_dir/ocr-x86_64"
lipo -create -output "$stage_dir/bin/ocr" "$work_dir/ocr-arm64" "$work_dir/ocr-x86_64"
chmod +x "$stage_dir/bin/ocr"

echo "Assembling DMG contents..."
cp -R "$repo_root/quickaction" "$stage_dir/"
cp "$repo_root/screenshot-to-note.sh" "$stage_dir/"
cp "$repo_root/build.sh" "$stage_dir/"
cp "$repo_root/README.md" "$stage_dir/"
cp "$repo_root/LICENSE" "$stage_dir/"
cp "$repo_root/dist/Install.command" "$stage_dir/"
chmod +x "$stage_dir/screenshot-to-note.sh" "$stage_dir/build.sh" "$stage_dir/quickaction/install.sh" "$stage_dir/Install.command"

mkdir -p "$repo_root/dist/out"
out_path="$repo_root/dist/out/$dmg_name"
rm -f "$out_path"

echo "Creating $dmg_name..."
hdiutil create -volname "$app_name" -srcfolder "$stage_dir" -ov -format UDZO "$out_path"

echo "Done: $out_path"
