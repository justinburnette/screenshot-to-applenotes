# screen-reader

Select one or more screenshots in Finder, right-click, and get their text
OCR'd into a single new Apple Note -- in chronological order by capture time,
reflowed into readable paragraphs, with academic-style citations stripped out
so Notes' text-to-speech ("Speak") reads it back cleanly.

## Requirements

- A Mac signed into iCloud with Notes syncing on (Notes > Settings > Accounts).
  Notes are always created in the account literally named "iCloud".
- Xcode Command Line Tools, for the `swiftc` compiler:
  ```
  xcode-select --install
  ```
  (If `xcode-select -p` already prints a path, you have it.)
- Nothing else. OCR runs entirely on-device via Apple's Vision framework --
  no Tesseract, no Python, no network calls, no App Store app.

## Quick start

```
git clone git@github.com:justinburnette/screen-reader.git
cd screen-reader
./quickaction/install.sh
```

Then in Finder: select one or more screenshots -> right-click -> **Quick
Actions -> "OCR Screenshots to Note"**. A new Apple Note is created with the
combined text.

The first run will:
- Compile the OCR helper (`bin/ocr`) automatically -- a few seconds, one time.
- Possibly prompt macOS to approve Automation access for Notes.app -- approve it
  (System Settings > Privacy & Security > Automation if you miss the prompt).

If "OCR Screenshots to Note" doesn't show up in the Quick Actions submenu right
away, check System Settings > Keyboard > Keyboard Shortcuts > Services (or
Extensions > Finder) and make sure it's enabled there.

## Files

- `src/ocr.swift` -- OCR + text-cleanup CLI tool (`ocr <image>`), built on
  Vision. Reflows wrapped lines into paragraphs and strips citations (see
  below).
- `build.sh` -- compiles `src/ocr.swift` into `bin/ocr`. Runs automatically
  from `screenshot-to-note.sh` the first time `bin/ocr` is missing; safe to
  re-run any time (e.g. after editing `ocr.swift`).
- `screenshot-to-note.sh` -- the main script: sorts inputs by capture time,
  runs OCR on each, and creates the note. See Usage below.
- `quickaction/OCR Screenshots to Note.workflow` -- the Finder Quick Action
  bundle (Automator "Run Shell Script" wrapping `screenshot-to-note.sh`).
  Ships with a placeholder path so it works regardless of where you clone the
  repo; `install.sh` fills in the real path only in the *installed* copy.
- `quickaction/install.sh` -- copies the Quick Action into
  `~/Library/Services` (with the real path substituted in) so it shows up in
  Finder's right-click menu.

If you move the cloned repo folder after installing, re-run
`./quickaction/install.sh` so the Quick Action picks up the new location.

## Usage (command line)

The Quick Action is really just this script wired into Finder -- you can also
run it directly:

```
screenshot-to-note.sh [--recent [N]] [--folder NAME] [--title TEXT] FILE [FILE ...]
```

- `FILE...` -- one or more screenshot image paths. Order doesn't matter --
  they're sorted by capture time before OCR.
- `--recent [N]` -- use the N most recently modified screenshots from your
  configured screenshot folder instead of listing files (default N=1).
- `--folder NAME` -- file the note into this folder within the iCloud
  account (falls back to the account's default folder if NAME doesn't exist
  or is a Smart Folder).
- `--title TEXT` -- first line / title of the note (default:
  "Screenshots - <date>").

Examples:

```
screenshot-to-note.sh ~/Pictures/Screenshots/Screenshot*.png
screenshot-to-note.sh --recent 3
screenshot-to-note.sh --folder Work --title "Standup notes" a.png b.png
```

## How screenshots are ordered

macOS screenshot filenames look like `Screenshot 2026-07-02 at 2.16.50 PM.png`.
The script parses that timestamp to sort chronologically; if a file doesn't
match that naming pattern (renamed, or not a macOS screenshot), it falls back
to the file's creation time on disk.

## How text is laid out in the note

`ocr.swift` reflows wrapped lines back into normal paragraphs (undoing
mid-word hyphenation) rather than keeping one note-line per detected image
line. It tells "this line wrapped because it hit the margin" apart from
"this is a short standalone line" (heading, list item, UI label) by comparing
each line's width to the widest line on the page -- so dense document/article
screenshots read as flowing paragraphs, while UI screenshots (file lists,
menus, notifications) keep each item on its own line. Multi-column or
multi-pane layouts (e.g. an IDE with a sidebar, editor, and terminal open at
once) are left in Vision's own detection order rather than re-sorted by
position, since a naive top-to-bottom coordinate sort was found (through
testing) to interleave unrelated side-by-side regions.

It also strips academic in-text citations like `(Perosa, 1996)` or `(Shields
et al., 1994, p. 121)`, so Notes' text-to-speech ("Speak") reads cleanly
without stumbling over them -- useful if you're using the note to have
Notes read a screenshotted article back to you. Only parentheticals with a
comma directly before a `19xx`/`20xx` year are treated as citations, so plain
dates like `(Aug 14 / 15, 2026)` are left alone. This is a deterministic regex
pass, not Apple Intelligence's Writing Tools -- macOS 26 does have a
Shortcuts-automatable version of Writing Tools now, but it's LLM-based
(non-deterministic, may rewrite more than intended, requires Apple
Intelligence to be enabled) and wasn't used here on purpose.

## Uninstalling

```
rm -rf ~/Library/Services/"OCR Screenshots to Note.workflow"
killall Finder
```

## Troubleshooting

- **"failed to create the Apple Note" / Automation prompt** -- the first run
  needs you to approve Automation access for Notes (macOS will prompt; if you
  miss it, check System Settings > Privacy & Security > Automation and allow
  your terminal app / the Quick Actions service to control Notes).
- **No account named "iCloud"** -- this script always files notes into the
  account literally named "iCloud" in Notes.app. Make sure you're signed into
  iCloud with Notes syncing on (Notes > Settings > Accounts).
- **Quick Action doesn't appear in the right-click menu** -- check System
  Settings > Keyboard > Keyboard Shortcuts > Services (or Extensions >
  Finder) and enable it there. If you moved the repo folder after installing,
  re-run `./quickaction/install.sh`.
- **`swiftc: command not found`** -- install Xcode Command Line Tools:
  `xcode-select --install`.
- **Verifying note counts via AppleScript yourself** -- `count of notes of
  default account` double-counts every note on at least some configurations
  (confirmed: creating one note increased the account-level count by 2, while
  the specific folder's count correctly increased by 1). If you're
  scripting your own checks, count `notes of folder "Notes" of account
  "iCloud"`, not `notes of account "iCloud"`.
