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

   > **If you see "damaged and can't be opened":**
   > 1. Click **Cancel** (not Move to Trash)
   > 2. Open **Terminal** (search for it in Spotlight with ⌘Space)
   > 3. Paste this command and hit Enter:
   > ```bash
   > xattr -cr ~/Downloads/"PDF Reader.app"
   > ```
   > 4. Double-click the app — it will open normally from now on
   >
   > *(This command just removes a quarantine flag macOS adds to downloaded files — it's safe)*

4. Drag **PDF Reader.app** to your Applications folder if you want it there permanently

## How to Use

### Step 1 — Make sure your PDF is searchable (OCR)

Annotation and highlighting only works on PDFs with selectable text. If your PDF is a scanned image (text isn't selectable when you try to highlight), you need to run it through OCR first.

**Recommended free tool:** [PDF24 OCR](https://tools.pdf24.org/en/ocr-pdf)

1. Go to [tools.pdf24.org/en/ocr-pdf](https://tools.pdf24.org/en/ocr-pdf)
2. Upload your PDF
3. Download the converted file
4. Open that file in PDF Reader

### Step 2 — Annotate

- Press **S** to enter highlight mode, then click and drag to highlight text
- In highlight mode, **right-click** any line to strikethrough it (useful for marking off answer choices)
- Press **A** to go back to cursor mode, **D** for strikethrough mode
- **⌘Z** to undo, **⌘⇧Z** to redo
- **⌘S** to save your annotations back to the PDF

### Step 3 — Quiz Checker

The built-in quiz checker is designed for 50-question exams.

1. Click the **checklist icon** (☑) in the toolbar to open it
2. Paste your **answer key** (e.g. `ABCDABC...`) into the left box — must be exactly 50 letters

   > **Tip:** If your answer key is in a PDF or image, paste it into [ChatGPT](https://chat.openai.com) or [Claude](https://claude.ai) and ask:
   > *"Give me just the answer key as a single string of letters, no spaces or numbers (e.g. ABCDABCD...)"*
   > Then paste the output directly into the answer key box.

3. If you've already done some questions, paste those answers in the **Already done** box so it starts at the right question
4. Click **Start**
5. Type each answer as you go — it auto-submits on each keypress and shows if you got it right
6. Press **⌘U** to undo the last answer
7. At the end you'll see your score and a list of missed questions
8. Use **copy** to copy your results for a spreadsheet

### Pro tip — Questions on one tab, answers on another

Open your question PDF in one tab and your answer key PDF in another. Press **Spacebar** or **F** to flip between them instantly while you work through the exam.

- Press **⌘O** to open a second PDF as a new tab
- **Spacebar** or **F** switches between tabs
- Each tab keeps its own page position, annotations, and quiz session independently

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
