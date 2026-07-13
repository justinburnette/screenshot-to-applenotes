#!/bin/bash
# Double-clickable installer bundled inside the release DMG. Finder runs
# .command files in a new Terminal window automatically, so this is the
# no-CLI-knowledge-required install path for the DMG download -- the
# git-clone path in the README still uses quickaction/install.sh directly.
set -euo pipefail
cd "$(dirname "$0")"

chmod +x screenshot-to-note.sh build.sh quickaction/install.sh
if [[ -f bin/ocr ]]; then
  chmod +x bin/ocr
fi

./quickaction/install.sh

echo ""
echo "Done. Press Return to close this window."
read -r
