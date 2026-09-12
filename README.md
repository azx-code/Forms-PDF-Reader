# Forms PDF Reader

A lightweight macOS PDF viewer with annotation tools and a built-in quiz checker.

## Features

- **Highlight & Strikethrough** — select text to highlight; right-click to strikethrough a line
- **Text boxes** — click to place resizable text annotations directly on the page
- **Find** — ⌘F to search text across the whole PDF
- **Undo / Redo** — full annotation history (⌘Z / ⌘⇧Z)
- **Multi-document tabs** — open multiple PDFs and switch with **Spacebar** or **F**
- **Quiz Checker** — built-in answer checker for 50-question exams with live scoring and missed-question log
- **Custom shortcuts** — remap every key shortcut from Settings (⌘,)
- **Auto-save prompt** — asked to save on close if you have unsaved annotations

---

## Installation

> **macOS 12 or later only.**

There are two ways to install. **Method 1 (Build from Source) is recommended** — it takes about 2 minutes and avoids the macOS security warning entirely.

---

### Method 1 — Build from Source ✅ Recommended

This builds the app directly on your Mac so macOS fully trusts it. No security warnings.

**Step 1 — Install Xcode Command Line Tools** (skip if you already have them)

Open **Terminal** (search with ⌘Space → type "Terminal") and paste:

```bash
xcode-select --install
```

A dialog will pop up — click **Install** and wait for it to finish (~5 minutes).

**Step 2 — Clone and build**

```bash
git clone https://github.com/azx-code/Forms-PDF-Reader.git
cd Forms-PDF-Reader
bash build.sh
```

The app will be built to the folder you cloned into (e.g. `~/Downloads/Forms PDF Reader.app`). Open it and you're done — no security prompts ever again.

---

### Method 2 — Download Pre-built App

1. Go to the [Releases page](https://github.com/azx-code/Forms-PDF-Reader/releases) and download **Forms.PDF.Reader.zip**
2. Unzip it — you'll get **Forms PDF Reader.app**
3. **Right-click → Open** the first time (don't double-click)

   ![Right-click Open](https://raw.githubusercontent.com/azx-code/Forms-PDF-Reader/main/right-click-open.png)

   Click **Open** in the dialog. You only need to do this once — after that you can double-click normally.

**If you see "damaged and can't be opened":**

1. Click **Cancel** (not Move to Trash)
2. Open **Terminal** and paste this, then press Enter:

```bash
xattr -cr ~/Downloads/"Forms PDF Reader.app"
```

3. Double-click the app — it will open normally from now on

> *This removes a quarantine flag macOS adds to downloaded files. It's safe.*

---

## How to Use

### Step 1 — Make sure your PDF has selectable text (OCR)

Highlighting only works on PDFs where you can click and drag to select text. If your PDF is a scanned image, run it through OCR first.

**Free tool:** [PDF24 OCR](https://tools.pdf24.org/en/ocr-pdf) — upload your PDF, download the converted file, open it here.

### Step 2 — Annotate

| Action | How |
|--------|-----|
| Highlight text | Press **S**, then drag over text |
| Strikethrough a line | Press **S**, then **right-click** any line |
| Cursor mode (remove annotations) | Press **A**, then click an annotation |
| Text box | Click the **T** button, then click anywhere on the page |
| Undo / Redo | ⌘Z / ⌘⇧Z |
| Save | ⌘S |

### Step 3 — Quiz Checker

Designed for 50-question multiple choice exams.

1. Click the **☑ checklist icon** in the toolbar to open it
2. Paste your **answer key** (e.g. `ABCDABCD…`) — must be exactly 50 letters

   > **Tip:** Paste your answer key into [ChatGPT](https://chat.openai.com) or [Claude](https://claude.ai) and ask:
   > *"Give me just the answer key as a single string of letters with no spaces or numbers"*
   > Then paste the result directly.

3. If you've already answered some questions, paste those in the **Already done** box
4. Click **Start** — type each answer as you go, it auto-checks on every keystroke
5. Press **⌘U** to undo the last answer
6. At the end, see your score and a list of missed questions

### Pro Tip — Questions on one tab, answers on another

Open your question PDF in one tab and your answer key PDF in another. Press **Spacebar** to flip between them while you work.

- **⌘O** — open a second PDF as a new tab
- **Spacebar** or **F** — switch between tabs
- Each tab keeps its own page position, annotations, and quiz session

---

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `A` | Cursor mode |
| `S` | Highlight mode |
| `D` | Strikethrough mode |
| `F` / `Space` | Switch between open PDFs |
| `⌘F` | Find text in PDF |
| `⌘Z` | Undo annotation |
| `⌘⇧Z` | Redo annotation |
| `⌘S` | Save |
| `⌘O` | Open PDF |
| `⌘W` | Close current tab |
| `⌘U` | Undo quiz answer |
| `⌘,` | Settings (remap shortcuts) |
| `←` / `→` | Previous / next page |

---

## Building from Source

Requires macOS 12+ and Xcode Command Line Tools.

```bash
git clone https://github.com/azx-code/Forms-PDF-Reader.git
cd Forms-PDF-Reader
bash build.sh
```

The app is built one folder up from wherever you cloned (e.g. if you cloned to `~/Downloads/Forms-PDF-Reader/`, the app appears at `~/Downloads/Forms PDF Reader.app`).

**Custom icon:** Drop any 1024×1024 PNG named `icon.png` into the repo folder before running `build.sh`. Without it, the build still works and uses the included icon automatically.
