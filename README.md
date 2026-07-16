# screenshot-to-applenotes (Screenshot OCR to Apple Notes - Use Siri voice to read)

Take screenshots of anything you want to process or read! The mac shortcut for screenshots is **Command+Shift+4** then it autosaves to your mac desktop (or change location with **Command+Shift+5** ).

Select one or more screenshots in Finder, right-click, and get their text
OCR'd into a single new Apple Note -- in chronological order by capture time,
reflowed into readable paragraphs, with academic-style citations stripped out
so Notes' text-to-speech ("Speak") reads it back cleanly.

<img width="775" height="555" alt="image" src="https://github.com/user-attachments/assets/c920e26a-6213-4821-807a-059ddfcf2016" />

## Requirements

- A Mac. Notes are always created in the account literally named "iCloud".
- Nothing else if you use the DMG download below. If installing from
  source instead, you'll also need Xcode Command Line Tools for the
  `swiftc` compiler:
  ```
  xcode-select --install
  ```
  (If `xcode-select -p` already prints a path, you have it.)
- OCR runs entirely on-device via Apple's Vision framework -- no
  Tesseract, no Python, no network calls, no App Store app.

## Download (no git or Terminal commands required)

1. Download the latest `.dmg` from the
   [Releases page](https://github.com/justinburnette/screenshot-to-applenotes/releases/latest).
2. Open the DMG, then double-click **Install.command** inside it.
3. macOS will warn that it's from an unidentified developer (this project
   isn't signed with a paid Apple Developer certificate) -- right-click
   **Install.command** and choose **Open** instead of double-clicking, then
   confirm. You only need to do this once.
4. A Terminal window runs the installer and closes when done.
5. Enable Accessibility setting "Speak Selection" with Siri voice (see below)

## Install from source

```
git clone git@github.com:justinburnette/screenshot-to-applenotes.git
cd screenshot-to-applenotes
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

In Apple Notes, select all (Command+a) then right-click and select **Speech > Start Speaking**

## Enable Accessibility setting "Speak Selection"

Use mac's Siri reader for the best experience. **System Settings > Accessibility > Read & Speak > Speak selection = ON; also System Voice > Siri**

<img width="473" height="480" alt="image" src="https://github.com/user-attachments/assets/f59c5a58-055a-4220-a172-0489d203c61d" />


## If you need help, you could use your favorite AI tool and copy and paste this webpage and ask it how to install and use this tool.

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
- `dist/make_dmg.sh` -- builds the release `.dmg`: compiles a universal
  (Apple Silicon + Intel) `bin/ocr` and bundles it with the Quick Action,
  scripts, and `dist/Install.command` so the DMG needs no compiler at all.
  Runs automatically via `.github/workflows/release.yml` on every `v*` tag
  push; can also be run locally (`./dist/make_dmg.sh 1.0.0`).
- `dist/Install.command` -- the double-clickable installer inside the DMG
  (Finder runs `.command` files in Terminal automatically). Just calls
  `quickaction/install.sh`.

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

## Progress and note reveal

OCR runs one screenshot at a time, so a large batch can take a while. Since
a bare `osascript` process has no window to render AppleScript's native
Progress panel into (that feature is drawn by whatever *hosts* the script --
Script Editor, a saved applet, Script Monitor -- and a plain CLI invocation
isn't any of those, so it silently never appears), progress is instead shown
via Notification Center banners every 20th image, plus a final "done" banner.
Once the note is created, Notes.app is brought to the front and the new note
is opened/selected automatically, so you don't have to go find it. If Focus /
Do Not Disturb is on, macOS suppresses these banners entirely -- turn it off
if you're not seeing them.

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
