#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$script_dir/bin"
swiftc "$script_dir/src/ocr.swift" -O -o "$script_dir/bin/ocr"
echo "Built $script_dir/bin/ocr"
