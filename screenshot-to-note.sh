#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ocr_bin="$script_dir/bin/ocr"

default_screenshot_dir="$(defaults read com.apple.screencapture location 2>/dev/null || true)"
default_screenshot_dir="${default_screenshot_dir:-$HOME/Desktop}"
default_screenshot_dir="${default_screenshot_dir/#\~/$HOME}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--recent [N]] [--folder NAME] [--title TEXT] FILE [FILE ...]

  FILE...          One or more screenshot image paths. Order doesn't matter --
                   they are sorted by capture time before OCR.
  --recent [N]     Use the N most recently modified screenshots from
                   $default_screenshot_dir instead of listing files (default N=1).
  --folder NAME    Folder within the iCloud Notes account to file the note into
                   (falls back to the account's default folder if NAME doesn't
                   exist). Notes are always created in the iCloud account.
  --title TEXT     First line / title of the note (default: "Screenshots - <date>").

Examples:
  $(basename "$0") "$default_screenshot_dir"/Screenshot*.png
  $(basename "$0") --recent 3
  $(basename "$0") --folder Work --title "Standup notes" a.png b.png
EOF
}

if [[ ! -x "$ocr_bin" ]]; then
  echo "OCR binary not found, building it..." >&2
  "$script_dir/build.sh"
fi

recent_count=0
folder=""
title=""
files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recent)
      recent_count=1
      shift
      if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
        recent_count="$1"
        shift
      fi
      ;;
    --folder)
      [[ $# -ge 2 ]] || { echo "Error: --folder requires a value" >&2; exit 1; }
      folder="$2"
      shift 2
      ;;
    --title)
      [[ $# -ge 2 ]] || { echo "Error: --title requires a value" >&2; exit 1; }
      title="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done

if [[ "$recent_count" -gt 0 ]]; then
  if [[ ! -d "$default_screenshot_dir" ]]; then
    echo "Error: screenshot folder not found: $default_screenshot_dir" >&2
    exit 1
  fi
  scan_files=()
  while IFS= read -r -d '' f; do
    scan_files+=("$f")
  done < <(find "$default_screenshot_dir" -maxdepth 1 -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.tiff' \) -print0)

  pairs=()
  for f in "${scan_files[@]}"; do
    pairs+=("$(stat -f '%m' "$f")|$f")
  done
  while IFS='|' read -r _ f; do
    files+=("$f")
  done < <(printf '%s\n' "${pairs[@]}" | sort -t'|' -k1,1 -rn | head -n "$recent_count")
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "Error: no screenshot files given (pass file paths or use --recent)." >&2
  usage >&2
  exit 1
fi

screenshot_epoch() {
  local file="$1" base name re datepart clocktime meridiem epoch
  base="$(basename "$file")"
  name="${base%.*}"
  name="${name%% (*}"
  # macOS separates seconds from AM/PM with a narrow no-break space (U+202F) on
  # most system locales, not a plain space -- match it as a wildcard and rebuild
  # a clean "H.MM.SS AM/PM" string ourselves rather than depending on that byte.
  re='^Screenshot ([0-9]{4}-[0-9]{2}-[0-9]{2}) at ([0-9]{1,2}\.[0-9]{2}\.[0-9]{2}).*(AM|PM)$'
  if [[ "$name" =~ $re ]]; then
    datepart="${BASH_REMATCH[1]}"
    clocktime="${BASH_REMATCH[2]}"
    meridiem="${BASH_REMATCH[3]}"
    epoch="$(date -j -f "%Y-%m-%d %I.%M.%S %p" "${datepart} ${clocktime} ${meridiem}" "+%s" 2>/dev/null || true)"
    if [[ -n "$epoch" ]]; then
      printf '%s' "$epoch"
      return
    fi
  fi
  stat -f '%B' "$file" 2>/dev/null || stat -f '%m' "$file"
}

extract_text() {
  local file="$1" text status
  set +e
  text="$("$ocr_bin" "$file" 2>&1)"
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    echo "Warning: OCR failed for $(basename "$file"): $text" >&2
    printf '[OCR failed for %s]' "$(basename "$file")"
    return
  fi
  if [[ -z "$text" ]]; then
    printf '[No text detected in %s]' "$(basename "$file")"
    return
  fi
  printf '%s' "$text"
}

as_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

pairs=()
for f in "${files[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "Warning: skipping missing file: $f" >&2
    continue
  fi
  pairs+=("$(screenshot_epoch "$f")|$f")
done

if [[ ${#pairs[@]} -eq 0 ]]; then
  echo "Error: none of the given files exist." >&2
  exit 1
fi

sorted_files=()
while IFS='|' read -r _ f; do
  sorted_files+=("$f")
done < <(printf '%s\n' "${pairs[@]}" | sort -t'|' -k1,1 -n)

note_title="${title:-Screenshots - $(date +'%b %d, %Y %I:%M %p')}"
full_text="$note_title"$'\n\n'
first=true
echo "Processing ${#sorted_files[@]} screenshot(s) in chronological order:" >&2
for f in "${sorted_files[@]}"; do
  section="$(extract_text "$f")"
  echo "  - $(basename "$f")  (${#section} chars extracted)" >&2
  if $first; then
    full_text+="$section"
    first=false
  else
    full_text+=$'\n\n'"$section"
  fi
done

html_body=""
while IFS= read -r line || [[ -n "$line" ]]; do
  esc="${line//&/&amp;}"
  esc="${esc//</&lt;}"
  esc="${esc//>/&gt;}"
  if [[ -z "$esc" ]]; then
    html_body+="<div><br></div>"
  else
    html_body+="<div>${esc}</div>"
  fi
done <<< "$full_text"

tmp_html="$(mktemp -t screenshot-note-html)"
trap 'rm -f "$tmp_html"' EXIT
printf '%s' "$html_body" > "$tmp_html"

folder_escaped="$(as_escape "$folder")"

if ! result="$(osascript <<APPLESCRIPT
on run
	set htmlBody to read (POSIX file "$tmp_html") as «class utf8»
	set folderName to "$folder_escaped"
	tell application "Notes"
		try
			set targetAccount to account "iCloud"
		on error
			return "NOACCOUNT:iCloud"
		end try
		tell targetAccount
			if folderName is "" then
				make new note with properties {body:htmlBody}
				return "OK:default"
			end if
			try
				tell folder folderName
					make new note with properties {body:htmlBody}
				end tell
				return "OK:" & folderName
			on error
				make new note with properties {body:htmlBody}
				return "FALLBACK:" & folderName
			end try
		end tell
	end tell
end run
APPLESCRIPT
)"; then
  echo "Error: failed to create the Apple Note. If macOS is prompting for Automation permission, grant your terminal app access to Notes (System Settings > Privacy & Security > Automation) and re-run." >&2
  exit 1
fi

case "$result" in
  OK:default)
    echo "Created note \"$note_title\" in the iCloud account's default Notes folder." ;;
  OK:*)
    echo "Created note \"$note_title\" in iCloud folder \"${result#OK:}\"." ;;
  FALLBACK:*)
    echo "Warning: couldn't file the note into iCloud folder \"${result#FALLBACK:}\" (it may not exist, or may be a Smart Folder that can't hold new notes); created note \"$note_title\" in the iCloud account's default folder instead." >&2 ;;
  NOACCOUNT:*)
    echo "Error: no \"${result#NOACCOUNT:}\" account found in Notes.app. This script always files notes into iCloud, so Notes needs an iCloud account signed in (Notes > Settings > Accounts)." >&2
    exit 1 ;;
  *)
    echo "Note creation returned an unexpected result: $result" >&2 ;;
esac
