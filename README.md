# GH Typst

A personal Typst editor for Omarchy: syntax-aware highlighting, a live
compiled preview, real compiler diagnostics, multi-document tabs, a
Logseq-compatible journal, and an optional Claude-powered review pass.
Built as a personal daily-driver, not a general-purpose IDE — it opens on a
blank document every time (see [No document memory](#no-document-memory)
below) and keeps its own footprint small: no bar icon, summon on demand.

## Install

```sh
omarchy plugin add https://github.com/Gabriel-Harfield/omarchy-gh-typst.git --enable
```

## Use

```sh
omarchy-shell shell summon io.github.gabrielharfield.ghtypst
```

## Éditeur

- Typst source editing with syntax highlighting (`#code` calls, keywords,
  comments, headings, raw/math spans), a line-number gutter, current-line
  highlight, adjustable zoom, and an optional narrow-margins mode for wide
  monitors.
- A live preview pane — real `typst compile` output, not an approximation —
  updated on a short debounce as you type, plus a manual refresh button.
  Multi-page documents render every page.
- Real compiler diagnostics parsed from `typst`'s own output, click to jump
  to the error's position.
- Multiple documents open at once via a tab strip; only the active tab
  compiles or spellchecks.
- Find/replace (`Ctrl+F`) and app-level undo/redo (`Ctrl+Z` / `Ctrl+R`).
- A recent-files list above the file tree — the last 5 documents opened or
  saved, one click to reopen. Toggle between the file tree and a
  click-to-jump heading outline with the `F`/`H` buttons.
- Local, offline spelling checks via `hunspell` — underlines misspelled
  words with right-click suggestions, no network involved.
- A right-pane switcher: **Aperçu** (the preview above), **Notes** (a plain
  text pad saved alongside the document, `<doc>.notes.md`), and **Journal**
  (below).

## Journal

A small month calendar above a plain-text box, reading and writing
`<journal folder>/YYYY_MM_DD.md` — the same filename convention
[Logseq](https://logseq.com) uses for its own daily journal, so entries
stay interoperable with it either way. Days that already have an entry get
a small marker. The folder is set in **Paramètres** and is empty by
default — nothing is read or written anywhere until it's configured.

## Révision

- **Antidote round trip**: copies the document to the clipboard and opens
  [Antidote](https://www.antidote.info)'s web corrector in a dedicated
  browser window (there's no official API for a non-enterprise account),
  then pulls the corrected text back from the clipboard for an explicit,
  reviewed replace — never a silent merge.
- **Claude review**: three independent checks — code (Typst syntax),
  spelling (French prose only), or syntax/grammar — run via the `claude`
  CLI. Each proposes a corrected version plus a plain-text change log; the
  correction is only applied after you review the log.

## Paramètres

- Auto-save toggle and interval, on by default.
- The Journal folder (above).
- A Typst Universe template picker: a couple of starter templates as
  clickable thumbnails, either pasted straight into a new document or
  opened on typst.app for ones that need `typst init` instead.

## No document memory

GH Typst never remembers the last document across a close or a restart —
closing it (any way: the window, a keybind, a full `omarchy plugin
restart`/shell restart) always drops back to a blank document next time,
whether or not there were unsaved changes. This is deliberate: an earlier
version restored the last-open document automatically, which caused real
data loss when the same document was edited from two machines sharing a
synced folder (e.g. Dropbox) — a stale remembered copy from one machine
could silently overwrite newer saved content from the other. The
[recent-files list](#éditeur) covers the common "get back to what I was
doing" case safely instead: it only ever remembers paths, and reopening one
always reads whatever's actually on disk.

If you only ever use GH Typst on one machine with no synced folder
involved, this trade-off doesn't buy you anything and just costs a click to
reopen your last file — no setting to change that today, but it's a
reasonable thing to ask for if it'd help your workflow.

## Files

- `Panel.qml` — the whole plugin's state and orchestration: document
  load/save, the file tree, tabs, settings, Journal, and the Antidote/Claude
  review pipelines.
- `EditorTab.qml` — the editor itself: highlighting, preview pane, find/
  replace, undo/redo, and the Journal's calendar UI. Reaches into nothing
  outside the plain properties `Panel.qml` hands it.
- `RevisionTab.qml` — the Antidote and Claude review UI.
- `SettingsTab.qml` — the Paramètres tab, including the Typst Universe
  picker.
- `lib/*.js` — pure data/logic, no file I/O: `Highlighter.js` (syntax
  coloring), `Outline.js` (heading extraction), `Calendar.js` (month-grid
  math), `Diff.js`, `Spellcheck.js`, `CodeReview.js` (Claude prompts/
  command building), `Store.js` (settings/recent-files sanitizers).
- `compile.sh` — wraps `typst compile`, reports pages and diagnostics as
  JSON.
- `assets/` — Typst Universe template thumbnails.

## Requirements

On the target machine:

- [`typst`](https://typst.app) — compiling, previewing, and exporting PDFs.
- [`claude`](https://claude.com/product/claude-code) (Claude Code) — the
  Révision tab's code/spelling/syntax review. Optional: everything else
  works without it.
- `wl-copy`/`wl-paste` — the Antidote round trip.
- `hunspell`, with a dictionary for whichever language you write in —
  local spellcheck underlines. Optional: the editor works without it.
- `chromium` — the Aide, Typst Universe, and Antidote-dictionary quick-open
  buttons.

## Remove

```sh
omarchy plugin remove io.github.gabrielharfield.ghtypst
```

State (settings, recent files) lives entirely under
`~/.local/state/omarchy/plugins/io.github.gabrielharfield.ghtypst/`, safe
to delete by hand too.
