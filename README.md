# PDF Reader

A lightweight macOS PDF viewer with annotation tools and a built-in quiz checker.

## Features

- **Highlight & Strikethrough** — select text to highlight; right-click to strikethrough a line
- **Undo / Redo** — full annotation history (⌘Z / ⌘⇧Z)
- **Multi-document tabs** — open multiple PDFs and switch between them with **Spacebar** or **F**
- **Quiz Checker** — built-in answer checker for 50-question exams, with live scoring, undo, and a missed-questions summary
- **Auto-save prompt** — asked to save on close if you have unsaved annotations

## Installation

> **macOS only.** Requires macOS 12 or later.

1. Download **PDF.Reader.zip** from the [Releases](https://github.com/azx-code/Forms-PDF-Reader/releases) page
2. Unzip it — you'll get **PDF Reader.app**
3. **Right-click → Open** the first time (see below) — after that you can double-click normally

   ![Right-click Open](https://raw.githubusercontent.com/azx-code/Forms-PDF-Reader/main/right-click-open.png)

   macOS shows a warning because the app isn't signed with an Apple developer certificate. Click **Open** in the dialog to proceed. You only need to do this once.

   > **If you see "damaged and can't be opened"** — this is a macOS Gatekeeper issue with browser-downloaded apps. Fix it by running this in Terminal, then double-click normally:
   > ```bash
   > xattr -cr ~/Downloads/"PDF Reader.app"
   > ```
   > (adjust the path if you moved the app elsewhere, e.g. `/Applications/PDF\ Reader.app`)

4. Drag **PDF Reader.app** to your Applications folder if you want it there permanently

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `A` | Cursor mode |
| `S` | Highlight mode |
| `D` | Strikethrough mode |
| `F` / `Space` | Switch between open PDFs |
| `⌘Z` | Undo annotation |
| `⌘⇧Z` | Redo annotation |
| `⌘S` | Save |
| `⌘O` | Open PDF |
| `⌘U` | Undo quiz answer |
| `←` / `→` | Previous / next page |

## Building from Source

Requires Xcode command-line tools.

```bash
git clone https://github.com/azx-code/Forms-PDF-Reader.git
cd Forms-PDF-Reader
bash build.sh
```

The app will be built to your Desktop/Projects folder.
