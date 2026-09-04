import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "lib/Highlighter.js" as Highlighter
import "lib/Calendar.js" as Calendar

// Isolated component: the code editor (single RichText TextEdit, colored
// in place on a debounce), the compiler-error list, and the live preview
// pane. Reaches into nothing outside the plain properties Panel.qml hands
// it.
//
// Fourth syntax-highlighting attempt (2026-08-27), same architecture as
// the third (single RichText TextEdit edited directly, no second layer —
// the two-layer colored-underlay/transparent-overlay trick is confirmed
// broken, see the ghtypst-plugin memory) but fixing the specific bug that
// sank attempt three: TextEdit.getText() on a RichText document returns
// U+2029 (paragraph separator) for line breaks, not "\n" — left
// unnormalized, that desyncs Highlighter.toHtml()'s "\n"-based <br/>
// insertion on the very next recolor pass, collapsing lines together.
// Every read of the live document's plain text goes through normalize()
// below before touching anything else.
Item {
  id: root

  required property string text
  required property var errors
  required property var previewSources
  required property color foreground
  required property color background
  required property color dim
  required property color faint
  required property color accentColor
  required property color urgentColor
  required property color warningColor
  required property color notesColor
  required property string uiFont
  required property real zoom
  required property bool previewEnabled
  required property bool lineNumbersEnabled
  required property bool narrowMarginsEnabled
  // Whether the whole Aperçu/Notes right pane is collapsed, giving the
  // editor the full width — Gabriel's ask, 2026-08-29 ("investigate
  // hiding the Aperçu/Notes section"). The toggle button itself moved out
  // to Panel.qml, 2026-09-02, to sit on the same top row as the left
  // panel's own hide/show button (Gabriel's alignment ask) — this
  // property is read-only from here now, purely to size/hide the pane
  // below.
  required property bool rightPaneHidden
  // Local system spellcheck (hunspell, no Claude) — Gabriel's explicit
  // ask, 2026-08-29. misspelledWords is Panel.qml's latest detection
  // result ([{word,start,end}], offsets into the *plain text*, always
  // computed against whatever text a completed detect pass actually ran
  // on — see lib/Spellcheck.js and Panel.qml's requestSpellcheck() for
  // why this is safe to run live rather than only on request.
  // suggestWord/suggestions/suggestBusy are the on-demand result of the
  // last right-click's suggestRequested(word) — suggestWord is included
  // so the context menu can tell whether the arriving result is still
  // for the word it's currently showing (the menu can be reopened for a
  // different word before an earlier query returns).
  required property bool spellcheckAvailable
  required property var misspelledWords
  required property string suggestWord
  required property var suggestions
  required property bool suggestBusy
  // Aperçu/Notes/Journal right-pane switcher (Gabriel's ask, 2026-08-29,
  // "journal" added 2026-08-30) — "apercu" | "notes" | "journal".
  // Independent of previewEnabled, which only controls whether Typst
  // compilation runs at all.
  required property string rightPaneView
  required property string notesText
  // Journal (Gabriel's ask, 2026-08-30) — a small month calendar above a
  // plain-text view of "<journalDir>/YYYY_MM_DD.md" (Logseq's own journal
  // filename convention). Deliberately GLOBAL state, not per-document like
  // notesText above: the same calendar/entry shows regardless of which
  // .typ tab is active. journalDir === "" means unconfigured — shows a
  // "set this in Paramètres" prompt instead of a broken calendar.
  required property string journalDir
  required property int journalViewYear
  required property int journalViewMonth
  required property int journalSelectedYear
  required property int journalSelectedMonth
  required property int journalSelectedDay
  required property string journalText
  required property var journalEntryDays

  signal textEdited(string newText)
  signal zoomInRequested()
  signal zoomOutRequested()
  signal lineNumbersToggleRequested()
  signal narrowMarginsToggleRequested()
  signal journalPrevMonthRequested()
  signal journalNextMonthRequested()
  signal journalDaySelected(int day)
  signal journalTextEdited(string newText)
  signal spellcheckRequested(string text)
  signal suggestRequested(string word)
  signal applySuggestionRequested(int start, int end, string replacement)
  signal notesEdited(string newText)
  signal showErrorLogRequested()

  // See notesField's own comment (below, in the right-pane Notes view)
  // for why this guard exists — imperative resync instead of a plain
  // `text:` binding.
  property bool _notesProgrammatic: false
  onNotesTextChanged: {
    if (!notesField || notesField.text === root.notesText) return
    root._notesProgrammatic = true
    notesField.text = root.notesText
    root._notesProgrammatic = false
  }

  // Same imperative-resync guard, same reason, for the Journal entry text
  // — journalText changes every time a different day is selected.
  property bool _journalProgrammatic: false
  onJournalTextChanged: {
    if (!journalField || journalField.text === root.journalText) return
    root._journalProgrammatic = true
    journalField.text = root.journalText
    root._journalProgrammatic = false
  }

  // Pure month-grid layout, computed locally (Calendar.js has no QML/file
  // dependencies of its own, same "isolated component" spirit as this
  // file's own use of Highlighter.js). journalWeeks is an array of weeks,
  // each exactly 7 cells (null padding or a 1-based day number);
  // journalCells flattens that into one list for a single Grid+Repeater
  // rather than nesting a nested Repeater-inside-Row-inside-Repeater.
  readonly property var journalWeeks: Calendar.buildMonthGrid(root.journalViewYear, root.journalViewMonth)
  readonly property var journalCells: {
    var out = []
    for (var w = 0; w < journalWeeks.length; w++) out = out.concat(journalWeeks[w])
    return out
  }
  readonly property string journalMonthLabel: Calendar.monthLabel(root.journalViewYear, root.journalViewMonth)
  // Evaluated once at load, not live-reactive — an app running across
  // midnight showing yesterday's date as "today" for the rest of the
  // session is a harmless, extremely unlikely edge case, not worth a
  // Timer to refresh it.
  readonly property var _journalToday: new Date()

  // --- rechercher / remplacer (Ctrl+F) ------------------------------------
  //
  // Gabriel's ask, 2026-08-29. Fully local to this component — findQuery/
  // replaceQuery are plain user-driven inputs, only ever written from
  // outside the fields themselves at openFindBar() time (seeding from a
  // selection), so findField/replaceField skip the declarative `text:`
  // binding entirely (same established trap as pathBarField/notesField
  // elsewhere in this codebase — a TextField's binding is destroyed the
  // instant the user types into it) and are seeded imperatively instead.
  //
  // Case-insensitive substring search only for this first version (no
  // regex) — the simplest thing that's actually useful for prose, and
  // still useful for Typst code even if it can over-match on
  // capitalization; a case-sensitive toggle would be a small, separate
  // follow-up if ever wanted.
  property bool findBarOpen: false
  property string findQuery: ""
  property string replaceQuery: ""
  property var findMatches: [] // [{start,end}], offsets into _lastPlainText
  property int findCurrentIndex: -1
  property int _lastReplaceAllCount: -1

  function _computeMatches(text, query) {
    var out = []
    if (!query) return out
    var hay = text.toLowerCase()
    var needle = query.toLowerCase()
    var i = 0
    while (true) {
      var idx = hay.indexOf(needle, i)
      if (idx === -1) break
      out.push({ start: idx, end: idx + needle.length })
      i = idx + needle.length
    }
    return out
  }

  // Recomputes findMatches against the current _lastPlainText WITHOUT
  // resetting findCurrentIndex to 0 — called after every re-render (see
  // renderPlainText()'s own Qt.callLater block) so a replaceCurrent()
  // "advances" for free: removing one match from the array naturally
  // shifts the next one into the same numeric index. Query-driven
  // searches (the user typing a new term) reset the index explicitly
  // themselves before calling this, via onFindQueryEdited below.
  function _recomputeFindMatches() {
    root.findMatches = root._computeMatches(root._lastPlainText, root.findQuery)
    if (root.findMatches.length === 0) {
      root.findCurrentIndex = -1
      inputEdit.deselect()
      return
    }
    if (root.findCurrentIndex < 0 || root.findCurrentIndex >= root.findMatches.length)
      root.findCurrentIndex = 0
    root._applySelection()
  }

  function _applySelection() {
    if (root.findCurrentIndex < 0 || root.findCurrentIndex >= root.findMatches.length) return
    var m = root.findMatches[root.findCurrentIndex]
    inputEdit.select(m.start, m.end)
    root.ensureCursorVisible()
  }

  function openFindBar() {
    root.findBarOpen = true
    root._lastReplaceAllCount = -1
    // Seed with the current selection, mirroring the usual Ctrl+F
    // convention elsewhere — only for a plain single-line selection, a
    // multi-line one is almost never what someone means to search for.
    var sel = inputEdit.selectedText
    if (sel && sel.length > 0 && sel.indexOf("\n") === -1) root.findQuery = sel
    // Imperative, not a binding — see findField's own comment for why.
    findField.text = root.findQuery
    root.findCurrentIndex = 0
    root._recomputeFindMatches()
    Qt.callLater(function() { findField.forceActiveFocus(); findField.selectAll() })
  }

  function closeFindBar() {
    root.findBarOpen = false
    inputEdit.deselect()
    inputEdit.forceActiveFocus()
  }

  // Ctrl+F now toggles (Gabriel's ask, 2026-08-29, alongside docking the
  // bar below the editor instead of floating over the text) — Panel.qml's
  // shortcut handler calls this instead of openFindBar() directly.
  function toggleFindBar() {
    if (root.findBarOpen) root.closeFindBar()
    else root.openFindBar()
  }

  function onFindQueryEdited(text) {
    root.findQuery = text
    root.findCurrentIndex = 0
    root._lastReplaceAllCount = -1
    root._recomputeFindMatches()
  }

  function findNext() {
    if (root.findMatches.length === 0) return
    root.findCurrentIndex = (root.findCurrentIndex + 1) % root.findMatches.length
    root._applySelection()
  }

  function findPrevious() {
    if (root.findMatches.length === 0) return
    root.findCurrentIndex = (root.findCurrentIndex - 1 + root.findMatches.length) % root.findMatches.length
    root._applySelection()
  }

  function replaceCurrent() {
    if (root.findCurrentIndex < 0 || root.findCurrentIndex >= root.findMatches.length) return
    var m = root.findMatches[root.findCurrentIndex]
    var t = root._lastPlainText
    var newText = t.slice(0, m.start) + root.replaceQuery + t.slice(m.end)
    root.textEdited(newText)
  }

  function replaceAll() {
    if (root.findMatches.length === 0) return
    var t = root._lastPlainText
    var parts = []
    var last = 0
    for (var i = 0; i < root.findMatches.length; i++) {
      var m = root.findMatches[i]
      parts.push(t.slice(last, m.start))
      parts.push(root.replaceQuery)
      last = m.end
    }
    parts.push(t.slice(last))
    root._lastReplaceAllCount = root.findMatches.length
    root.textEdited(parts.join(""))
  }

  // --- undo / redo (Ctrl+Z / Ctrl+R) --------------------------------------
  //
  // Gabriel's ask, 2026-08-29, prompted directly by the autosave incident
  // during find/replace testing — a proper undo would have been the
  // natural recovery tool instead of manually reconstructing the lost
  // text. Explicitly Ctrl+R for redo (not Ctrl+Shift+Z/Ctrl+Y), per his
  // own wording.
  //
  // A from-scratch app-level stack, NOT TextEdit's native undo — this
  // file's own history already established why: renderPlainText()
  // reassigns inputEdit.text wholesale on every recolor pass, which
  // confuses/resets Qt's native undo stack (see this file's header
  // comment history). Snapshots are plain-text strings, pushed once per
  // renderPlainText() call (i.e. once per "pause in typing", or once per
  // programmatic edit like replace/replace-all/Claude-apply/Antidote-
  // apply/tab-switch) rather than once per keystroke — same granularity
  // as the recolor debounce, which gives a natural "undo the last burst
  // of typing" feel rather than one character at a time.
  //
  // Deliberately NOT per-tab: this stack lives on EditorTab (a single,
  // persistent component reused across every open document, per the
  // multi-tab feature) rather than inside Panel.qml's tabs[] array —
  // switching documents (tab switch, Ouvrir, Nouveau) calls
  // clearUndoHistory() explicitly from Panel.qml at the exact moments the
  // active document's identity changes, so undo never crosses between two
  // different documents. Known, disclosed scope limit: switching away and
  // back to a tab loses that tab's undo history, unlike a real per-tab
  // stack would. Reasonable tradeoff given this was built under a tight
  // remaining-budget constraint the same session.
  property var _undoStack: []
  property int _undoPos: -1
  property bool _undoRedoInProgress: false
  readonly property int _undoStackLimit: 100

  function clearUndoHistory() {
    root._undoStack = []
    root._undoPos = -1
  }

  function _pushUndoSnapshot(text) {
    if (root._undoRedoInProgress) return
    if (root._undoPos >= 0 && root._undoStack[root._undoPos] === text) return
    var truncated = root._undoStack.slice(0, root._undoPos + 1)
    truncated.push(text)
    if (truncated.length > root._undoStackLimit) truncated.shift()
    root._undoStack = truncated
    root._undoPos = root._undoStack.length - 1
  }

  function undo() {
    if (root._undoPos <= 0) return
    root._undoPos -= 1
    root._undoRedoInProgress = true
    root.textEdited(root._undoStack[root._undoPos])
    root._undoRedoInProgress = false
  }

  function redo() {
    if (root._undoPos < 0 || root._undoPos >= root._undoStack.length - 1) return
    root._undoPos += 1
    root._undoRedoInProgress = true
    root.textEdited(root._undoStack[root._undoPos])
    root._undoRedoInProgress = false
  }

  readonly property string monoFont: "monospace"
  readonly property real editorFontSize: Math.max(6, Math.round(Style.font.body * root.zoom))
  // Extra breathing room added to both sides of the text column when
  // "marges étroites" is on — narrows the reading column on large
  // monitors without touching the line-number gutter, which stays
  // pinned to the left edge regardless.
  readonly property real narrowMarginExtra: root.narrowMarginsEnabled ? Style.space(160) : 0

  // Last plain text known to be reflected in inputEdit's rendered HTML —
  // the single source of truth used to decide whether an external `text`
  // change actually needs a re-render, and what jumpToError() should
  // split on (inputEdit.text is HTML in RichText mode, never plain).
  property string _lastPlainText: ""
  // Set for the duration of any programmatic inputEdit.text assignment
  // (external sync or a recolor pass) so inputEdit's own onTextChanged
  // doesn't mistake it for the user typing and re-emit/re-debounce.
  property bool _programmatic: false

  // Confirmed live 2026-08-27: Qt's TextEdit.getText() on a RichText
  // document returns U+2028 LINE SEPARATOR for a <br/>-induced line break
  // (not U+2029 PARAGRAPH SEPARATOR, which only applies to actual
  // multi-block documents \u2014 this editor only ever has one block, since
  // Highlighter.toHtml() never emits <p>/<div>). Original code here
  // normalized \u2029, which never matched anything and let raw
  // characters leak into docText/session.json/the compile pipeline \u2014
  // caught via a live paste test before Gabriel saw it. Normalizing both
  // is cheap insurance in case a future Qt version behaves differently.
  function normalize(t) {
    return String(t).replace(/[\u2028\u2029]/g, "\n")
  }

  // Re-renders inputEdit from a known-good plain-text string, preserving
  // the caret position across the HTML round-trip (assigning `text` on a
  // RichText TextEdit rebuilds its document, which otherwise resets the
  // cursor to 0).
  // Bumped once per renderPlainText(), one event-loop turn late (see
  // below) — the gutter Repeater reads this to know when it's safe to
  // re-query positionToRectangle().
  property int layoutVersion: 0

  // TEMPORARY diagnostic switch, 2026-09-02 round four — REDESIGNED after
  // two real bugs from the previous version (see git history/memory for
  // the full story: skipping the `inputEdit.text = ...` reassignment
  // entirely blanked the editor, twice, in two different ways). This
  // version NEVER skips the reassignment — inputEdit.text is reassigned
  // every recolor pass exactly like normal, so there is no "stale/frozen
  // buffer" failure mode possible this time. The only thing this flag
  // changes is WHICH html generator runs: Highlighter.toPlainHtml() (no
  // color scanning at all, same escaping/newline/whitespace handling)
  // instead of Highlighter.toHtml(). Isolates exactly what Gabriel wants
  // to know: is the coloring logic itself the cost, or is QML's
  // TextEdit/RichText relayout expensive regardless of markup content
  // (same document size, same wholesale-reassign pattern, either way)?
  // Flip back to false (or delete) once tested — coloring will be
  // visibly gone while this is true, that's the point.
  property bool _colorDiagnosticDisabled: false

  function renderPlainText(plain) {
    root._programmatic = true
    var savedPos = inputEdit.cursorPosition
    inputEdit.text = root._colorDiagnosticDisabled
      ? Highlighter.toPlainHtml(plain)
      : Highlighter.toHtml(plain)
    root._lastPlainText = plain
    root._pushUndoSnapshot(plain)
    // Gutter text lags one recolor pass behind _lastPlainText on purpose
    // — see _gutterText's own comment below for why.
    root._gutterText = plain
    // Same cadence as the recolor pass itself — detection alone (not
    // suggestion generation) is cheap enough for this now, see
    // lib/Spellcheck.js's header comment for the benchmark that
    // confirmed it (53ms on a 62KB stress document, was 32s before the
    // two-phase redesign).
    if (root.spellcheckAvailable) root.spellcheckRequested(plain)
    Qt.callLater(function() {
      inputEdit.cursorPosition = Math.min(savedPos, inputEdit.length)
      root._programmatic = false
      // Re-sync now that the swap has settled — see _updateCurrentLine()'s
      // own comment for why this can't just react to cursorPositionChanged
      // during the swap itself.
      root._updateCurrentLine()
      // Keeps the find/replace match list (and the current selection) in
      // sync with every re-render, not just ones triggered by find/replace
      // itself — covers live typing while the bar is open, and is also
      // what makes replaceCurrent()'s "advance to the next match" work for
      // free: removing one match from the array naturally shifts the next
      // one into the same numeric findCurrentIndex.
      if (root.findBarOpen) root._recomputeFindMatches()
    })
    // Confirmed live 2026-08-27: right after this synchronous text
    // assignment, positionToRectangle() on most of the document is still
    // wrong — not "returns (0,0)" (that would be obvious), but silently
    // off by one line's worth of geometry for a stretch starting right
    // after the first line, self-correcting a little over halfway down a
    // ~60-line document. Root layout mechanism not fully pinned down (Qt's
    // incremental block layout for a freshly-(re)assigned RichText
    // document, most likely).
    //
    // 2026-08-28 correction: neither a single Qt.callLater() turn nor a
    // blind fixed-delay Timer (tried 80ms) reliably covers this on a real
    // 500+-line document — confirmed live, gutter numbers came back wrong
    // both times after a restart. Qt's RichText layout for a large
    // document apparently completes across a variable, content-dependent
    // number of internal steps, not a fixed one or two. Settled on
    // debouncing off inputEdit.contentHeightChanged instead (wired below,
    // outside this function) — that signal only fires while Qt's layout
    // engine is still actively doing block/line layout work, so waiting
    // for it to go quiet for settleTimer's interval is a real "layout
    // finished" signal rather than a guessed delay. It does still fire on
    // every keystroke during live typing, but restarting a Timer is O(1)
    // — no positionToRectangle() calls happen until it actually elapses,
    // which live typing (never leaving a 120ms gap) never allows, so this
    // doesn't reintroduce the per-keystroke cost inputEdit.contentHeight
    // caused when it was a direct binding dependency instead (see the
    // gutter Repeater's own comment for that whole story).
    //
    // Defensive fallback: also restart directly here, in case a given
    // recolor pass happens to produce a document with exactly the same
    // contentHeight as before (no change signal would fire on its own).
    settleTimer.restart()
  }

  Timer {
    id: settleTimer
    interval: 120
    repeat: false
    onTriggered: {
      root.layoutVersion += 1
      root._updateCurrentLine()
    }
  }

  // Dictionary discovery (Panel.qml) is async and can still be in flight
  // when a document first loads — renderPlainText()'s own
  // spellcheckRequested emission is guarded on spellcheckAvailable, so
  // opening a document before discovery finishes would otherwise never
  // get checked at all until the user's next edit. Catches up once
  // availability actually flips true.
  onSpellcheckAvailableChanged: if (root.spellcheckAvailable) root.spellcheckRequested(root._lastPlainText)

  onTextChanged: {
    if (root.text === root._lastPlainText) return
    root.renderPlainText(root.text)
  }

  Component.onCompleted: root.renderPlainText(root.text)

  // Current-line highlight, third attempt (2026-08-28) — the second
  // attempt (2026-08-27, a `positionToRectangle()`-driven Rectangle
  // sibling of this single TextEdit, lineStart/lineEnd as plain readonly
  // bindings reacting to every inputEdit.cursorPosition change) caused a
  // real, Gabriel-confirmed flicker once auto-scroll was added and this
  // editor started seeing real fast typing on a large document. Root
  // cause: renderPlainText()'s recolor pass reassigns inputEdit.text
  // wholesale, which transiently disturbs cursorPosition (and therefore
  // positionToRectangle()'s results, which aren't reliable immediately
  // after a text swap either — see settleTimer's own story) before the
  // Qt.callLater cursor-restore lands one tick later. A binding that
  // reacts to every cursorPosition change recomputed — and briefly
  // mis-rendered — during that exact window, every ~300ms recolor pass
  // while typing. Fixed by making lineStart/lineEnd plain (non-binding)
  // properties, updated only by _updateCurrentLine() below, called
  // exactly at the moments a real, settled position is known: on a
  // genuine user-driven cursor move (not one caused by our own text
  // swap), and once after the swap's cursor-restore + layout settle have
  // both actually finished. Never recomputed mid-swap, so there's nothing
  // to flicker.
  property int lineStart: 0
  property int lineEnd: 0

  // TEMPORARY diagnostic switch, 2026-09-02 — same pattern as Panel.qml's
  // _spellcheckDiagnosticDisabled, same reason: Gabriel's own long-
  // standing suspicion (this feature's history already includes real
  // rendering bugs, see this file's header/lineStart comments) about
  // whether the current-block highlight is a remaining cost now that the
  // gutter/misspelled-word overlays are virtualized and spellcheck is
  // paused. Flip back to false (or delete) once the diagnostic test is
  // done. Gates BOTH the cheap string-scan in _updateCurrentLine() below
  // AND, more importantly, currentLineHighlight's own positionToRectangle()
  // calls further down — a true suspend, not just a hidden Rectangle
  // whose bindings still evaluate.
  property bool _currentLineHighlightDiagnosticDisabled: false

  function _updateCurrentLine() {
    if (root._currentLineHighlightDiagnosticDisabled) return
    var t = root._lastPlainText
    var p = Math.max(0, Math.min(inputEdit.cursorPosition, t.length))
    var s = t.lastIndexOf("\n", p - 1) + 1
    var e = t.indexOf("\n", p)
    root.lineStart = s
    root.lineEnd = (e === -1) ? t.length : e
  }

  // Text the gutter is built from — deliberately NOT root._lastPlainText.
  // _lastPlainText updates on every raw keystroke (inputEdit.onTextChanged
  // below), and lineOffsets recomputing on every keystroke forces the
  // Repeater under it to tear down and rebuild one delegate Item per
  // document line — each running its own positionToRectangle() call —
  // on every single character typed. Fine for a short document, but on
  // Gabriel's 518-line "test volumineux.typ" this was real, reproduced
  // input lag (confirmed 2026-08-28: keystroke-to-glyph delay, not just a
  // debounced-compile stutter). _gutterText only advances inside
  // renderPlainText() — i.e. on load and once per 300ms recolor pass,
  // exactly like the syntax coloring it sits next to — so the gutter
  // numbers lag up to one recolor behind an in-progress edit instead of
  // rebuilding on every keystroke. currentLineHighlight above stays on
  // _lastPlainText: it's two indexOf() calls, not a per-line Repeater
  // rebuild, so it was never the expensive part.
  property string _gutterText: ""

  // Line numbers gutter: start offset of every line in the known-good
  // plain text, so each number can be y-positioned via
  // positionToRectangle() the same way the current-line highlight already
  // is — no separate line-height math to keep in sync with wrapping.
  readonly property var lineOffsets: {
    var t = root._gutterText
    var offsets = [0]
    for (var i = 0; i < t.length; i++) {
      if (t[i] === "\n") offsets.push(i + 1)
    }
    return offsets
  }
  readonly property int lineCount: lineOffsets.length
  readonly property int gutterWidth: Style.space(16) + Math.ceil(String(Math.max(1, root.lineCount)).length * root.editorFontSize * 0.62)

  // Virtualization for the two per-line/per-word overlays below (gutter
  // numbers, misspelled-word underlines) — Gabriel's 2026-09-02 report:
  // with line numbers OFF, the editor still lagged on his 2500-line
  // stress document on a lower-clocked CPU (powersave governor / on
  // battery). Root cause, confirmed by actually counting flagged
  // occurrences in that file: spellcheck flags ~1500 token occurrences
  // (Typst identifiers hunspell doesn't know, not real typos), and —
  // independent of the line-numbers toggle — the misspelled-word
  // Repeater built one delegate PER OCCURRENCE, each calling
  // positionToRectangle() twice, re-evaluated on every recolor pass
  // (~300ms while typing). ~3000 native layout calls every pause is
  // real CPU cost. The line-number gutter (one delegate per document
  // line) would hit the exact same problem the moment it's switched
  // back on for a large document.
  //
  // Fix: feed both Repeaters only the lines/words inside (or near) the
  // visible viewport, computed via inputEdit.positionAt() — the inverse
  // of positionToRectangle() — using the same
  // inputEdit.y-plus-local-y convention ensureCursorVisible() already
  // relies on. A one-viewport-height buffer above and below keeps fast
  // scrolling from flashing empty numbers/underlines before the next
  // recompute lands. This binding re-runs on every scroll (reads
  // flick.contentY) AND every recolor (reads layoutVersion), but the
  // recompute itself is just two positionAt() calls plus a plain array
  // filter — no per-line native layout work — so it stays cheap
  // regardless of document size.
  readonly property var _visibleTextRange: {
    var _dep = root.layoutVersion // re-run once layout has settled after a recolor
    var flick = editorScroll.contentItem
    var fallback = { start: 0, end: root._lastPlainText.length }
    if (!flick || typeof flick.contentY !== "number") return fallback
    var buffer = editorScroll.height
    var topY = flick.contentY - inputEdit.y - buffer
    var botY = flick.contentY - inputEdit.y + editorScroll.height + buffer
    var startPos = inputEdit.positionAt(0, Math.max(0, topY))
    var endPos = inputEdit.positionAt(0, botY)
    return {
      start: startPos >= 0 ? startPos : 0,
      end: endPos >= 0 ? endPos : root._lastPlainText.length
    }
  }

  readonly property var visibleLineNumbers: {
    if (!root.lineNumbersEnabled) return []
    var offs = root.lineOffsets
    var r = root._visibleTextRange
    var out = []
    for (var i = 0; i < offs.length; i++) {
      if (offs[i] >= r.start && offs[i] <= r.end) out.push({ line: i + 1, offset: offs[i] })
    }
    return out
  }

  readonly property var visibleMisspelledWords: {
    var r = root._visibleTextRange
    var out = []
    var words = root.misspelledWords
    for (var i = 0; i < words.length; i++) {
      var w = words[i]
      if (w.end >= r.start && w.start <= r.end) out.push(w)
    }
    return out
  }

  function jumpToError(err) {
    if (!err || err.line <= 0) return
    root.jumpToLine(err.line, err.col || 1)
  }

  // Public, used by the heading outline panel (Panel.qml) — same line-to-
  // offset math jumpToError already needed, generalized to a plain line
  // number (optionally a column) rather than a compiler-error object.
  function jumpToLine(lineNum, col) {
    if (!lineNum || lineNum <= 0) return
    var lines = (root._lastPlainText || "").split("\n")
    var offset = 0
    for (var i = 0; i < lineNum - 1 && i < lines.length; i++) offset += lines[i].length + 1
    offset += Math.max(0, (col || 1) - 1)
    inputEdit.cursorPosition = Math.min(offset, inputEdit.length)
    inputEdit.forceActiveFocus()
    root.ensureCursorVisible()
  }

  // Plain TextEdit has no built-in "scroll the ancestor Flickable to keep
  // the caret visible" behavior (TextArea does, TextEdit doesn't) — so
  // typing past the bottom of editorScroll's viewport left the caret
  // rendering off-screen with no automatic follow, confirmed by Gabriel.
  // ScrollView (QtQuick.Controls 2) wraps a non-Flickable child in an
  // internal Flickable and exposes it back out as contentItem — accessed
  // defensively (typeof-guarded) rather than assumed, since that's an
  // implementation detail of ScrollView, not a documented contract.
  function ensureCursorVisible() {
    var flick = editorScroll.contentItem
    if (!flick || typeof flick.contentY !== "number") return
    var margin = Style.space(8)
    var cursorTop = inputEdit.y + inputEdit.cursorRectangle.y
    var cursorBottom = cursorTop + inputEdit.cursorRectangle.height
    var viewTop = flick.contentY
    var viewBottom = viewTop + editorScroll.height
    var newY = null
    if (cursorTop < viewTop + margin) {
      newY = Math.max(0, cursorTop - margin)
    } else if (cursorBottom > viewBottom - margin) {
      newY = Math.max(0, cursorBottom - editorScroll.height + margin)
    }
    if (newY !== null && Math.abs(newY - flick.contentY) > 0.5) flick.contentY = newY
  }

  // 2026-08-28 correction: the general ensureCursorVisible() above (still
  // used by jumpToError — a deliberate "take me there" navigation, where
  // scrolling up OR down to reveal an arbitrary target line is exactly
  // what's wanted) was also wired to every keystroke via
  // onCursorRectangleChanged, and Gabriel correctly called that out as
  // actively wrong for typing: editing a line that's already fully
  // visible should never move the viewport at all, and it was yanking
  // the current line down to the bottom of the frame on every edit
  // regardless of whether it needed to move — jarring on its own, and
  // very likely the source of the "clignotement" (flicker) he also
  // reported, since a recolor pass reassigns inputEdit.text wholesale,
  // transiently disturbing cursorRectangle before the cursor-position
  // restore lands, which this function would react to as a second,
  // spurious jump. Restricted to exactly what Gabriel described: follow
  // the document's actual last line, and only scroll *down*, and only if
  // that line has actually gone below the frame. Never scrolls up, never
  // fires for an edit anywhere else in the document.
  function ensureLastLineVisible() {
    var flick = editorScroll.contentItem
    if (!flick || typeof flick.contentY !== "number") return
    if (root._lastPlainText.indexOf("\n", inputEdit.cursorPosition) !== -1) return
    var margin = Style.space(8)
    var cursorBottom = inputEdit.y + inputEdit.cursorRectangle.y + inputEdit.cursorRectangle.height
    var viewBottom = flick.contentY + editorScroll.height
    if (cursorBottom > viewBottom - margin) {
      var newY = Math.max(0, cursorBottom - editorScroll.height + margin)
      if (Math.abs(newY - flick.contentY) > 0.5) flick.contentY = newY
    }
  }

  Row {
    anchors.fill: parent
    spacing: root.rightPaneHidden ? 0 : Style.space(14)

    // ------------------------------------------------ left: code editor
    Column {
      width: root.rightPaneHidden ? parent.width : parent.width * 0.52
      height: parent.height
      spacing: Style.space(8)

      Item {
        id: editorHeader
        width: parent.width
        height: editorHeaderLeft.implicitHeight

        Row {
          id: editorHeaderLeft
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            id: editorHeaderLabel
            anchors.verticalCenter: parent.verticalCenter
            text: "Éditeur"
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Button {
            text: "# lignes"
            selected: root.lineNumbersEnabled
            tooltipText: root.lineNumbersEnabled
              ? "Masquer la numérotation des lignes"
              : "Afficher la numérotation des lignes (utile pour repérer une erreur de compilation)"
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.lineNumbersToggleRequested()
          }
          Item { width: Style.space(6); height: 1 }
          Button {
            iconText: ""
            selected: root.narrowMarginsEnabled
            tooltipText: root.narrowMarginsEnabled
              ? "Désactiver les marges étroites"
              : "Marges étroites (réduit la largeur du texte pour les grands écrans)"
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.narrowMarginsToggleRequested()
          }
          Item { width: Style.space(10); height: 1 }
          Button {
            text: "−"
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.zoomOutRequested()
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(38)
            horizontalAlignment: Text.AlignHCenter
            text: Math.round(root.zoom * 100) + "%"
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            text: "+"
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.zoomInRequested()
          }
        }
      }

      // Wrapper, not just the ScrollView directly — see the WheelHandler
      // overlay declared right after editorScroll below (Item's default
      // property lets both be children here) for why: it needs to sit at
      // the SAME geometry as editorScroll but as a true sibling, not
      // nested inside its Flickable content, and a plain Column can't
      // overlap two children at the same position — this Item can.
      Item {
        id: editorScrollWrap
        width: parent.width
        height: parent.height - editorHeader.height - parent.spacing - errorList.height - (errorList.visible ? Style.space(8) : 0) - (findBarDock.visible ? (findBarDock.height + Style.space(8)) : 0)

      ScrollView {
        id: editorScroll
        // NOT anchors.fill — confirmed via journalctl to cause a real
        // "Binding loop detected for property height" (blanking the
        // whole editor: with the loop unresolved, Qt Quick apparently
        // gives up and never lays out inputEdit's text at all). Root
        // cause, best understanding: editorContent's own height binding
        // further below reads editorScroll.height directly
        // (Math.max(editorScroll.height, inputEdit.implicitHeight...)) —
        // that line is untouched, original code, and was always fine
        // with an explicit height property. But ScrollView (a Control)
        // also computes its own implicitHeight from its content's
        // implicit size internally, and anchors.fill's anchor-driven
        // height binding apparently interacts with that machinery
        // differently than a plain explicit height: property does,
        // creating the loop. Back to explicit width/height — the exact
        // pattern the original, always-working code used, just now
        // pointed at editorScrollWrap instead of the outer Column
        // directly (editorScrollWrap already carries the same formula).
        width: parent.width
        height: parent.height
        clip: true
        ScrollBar.vertical.policy: ScrollBar.AsNeeded

        Item {
          id: editorContent
          // Both the actual size (used by inputEdit's anchors.fill) and the
          // implicit size (what ScrollView actually reads to decide its
          // content size — a plain Item's implicitWidth/implicitHeight
          // default to 0 regardless of its explicit width/height, which is
          // why this ScrollView never scrolled at all before this fix, no
          // matter how tall the document got) must track the same value.
          width: editorScroll.availableWidth
          height: Math.max(editorScroll.height, inputEdit.implicitHeight + Style.space(24))
          implicitWidth: width
          implicitHeight: height

          // Behind the text, so it paints without affecting glyph layout.
          // Coordinates from positionToRectangle() are relative to
          // inputEdit's own top-left, not this Item's — offset by
          // inputEdit.x/y (its resolved anchors.margins) to land correctly
          // as a sibling rather than a child.
          Rectangle {
            id: currentLineHighlight
            // Re-enabled 2026-08-28 — Gabriel confirmed this was indeed
            // the flicker's source; see lineStart/lineEnd's own comment
            // above for the actual fix (freeze during the recolor swap
            // instead of reacting to every cursor-position change).
            //
            // _currentLineHighlightDiagnosticDisabled (see lineStart's own
            // comment) short-circuits _startRect/_endRect to a fixed
            // Qt.rect() below instead of calling positionToRectangle() at
            // all when true — a real suspend of the native call, not just
            // an invisible Rectangle whose bindings still evaluate it.
            visible: !root._currentLineHighlightDiagnosticDisabled && inputEdit.activeFocus && root._lastPlainText.length > 0
            color: Qt.rgba(0.5, 0.5, 0.5, 0.14)
            x: inputEdit.x
            width: inputEdit.width
            property rect _startRect: root._currentLineHighlightDiagnosticDisabled ? Qt.rect(0, 0, 0, 0) : inputEdit.positionToRectangle(root.lineStart)
            property rect _endRect: root._currentLineHighlightDiagnosticDisabled ? Qt.rect(0, 0, 0, 0) : inputEdit.positionToRectangle(Math.max(root.lineStart, root.lineEnd))
            y: inputEdit.y + _startRect.y
            height: Math.max(_startRect.height, (_endRect.y + _endRect.height) - _startRect.y)
          }

          // Line numbers gutter — one Text per line, y-positioned via the
          // same positionToRectangle() approach as currentLineHighlight
          // above, so it tracks wrapped-line geometry exactly instead of
          // assuming a fixed line height.
          //
          // positionToRectangle() is a plain function call, not a tracked
          // Qt property — a binding that only calls it (reading nothing
          // else that changes) never re-evaluates after the very first
          // layout, so a recolor pass (renderPlainText() reassigning
          // inputEdit.text) would silently leave every number at its
          // stale initial position. Explicitly reading root._lastPlainText
          // first gives the binding a real, tracked dependency that fires
          // on every edit and on the initial render alike.
          Repeater {
            // Filtered to the visible viewport (+ buffer), not the whole
            // document — see root._visibleTextRange/visibleLineNumbers'
            // own comment for why: a per-line Repeater over a 2500-line
            // document was real, reproduced input lag even before this,
            // and stays a live risk if left unfiltered now that the
            // misspelled-word overlay below has the same shape.
            model: root.visibleLineNumbers
            Text {
              required property var modelData
              text: String(modelData.line)
              color: root.faint
              font.family: root.monoFont
              font.pixelSize: root.editorFontSize
              width: root.gutterWidth - Style.space(4)
              horizontalAlignment: Text.AlignRight
              x: Style.space(12)
              y: {
                // Deliberately NOT inputEdit.contentHeight: it was in this
                // dependency list until 2026-08-28, and it's a genuine Qt
                // property that changes on every single keystroke (the
                // live document's laid-out height legitimately changes as
                // you type) — so every one of these per-line y bindings,
                // for every line, was re-calling positionToRectangle() on
                // every character typed, even though the Repeater's own
                // model (root.lineOffsets, via _gutterText) only rebuilds
                // once per 300ms recolor pass. That was the actual
                // remaining lag Gabriel confirmed live after the first
                // gutter fix. root._gutterText + root.layoutVersion alone
                // (both only advancing inside renderPlainText(), i.e. on
                // load and once per recolor pass) are enough for
                // correctness — confirmed via a real restart-and-verify
                // pass, not just theory — contentHeight was defensive
                // insurance that turned out to be the actual cost.
                var _layoutDep = root._gutterText + "|" + root.layoutVersion
                return inputEdit.y + inputEdit.positionToRectangle(Math.min(modelData.offset, inputEdit.length)).y
              }
            }
          }

          // Misspelled-word underlines (local system spellcheck) — same
          // positionToRectangle()-driven overlay technique as
          // currentLineHighlight and the gutter above, deliberately NOT a
          // change to inputEdit's own RichText HTML: this editor's HTML
          // generation (Highlighter.js) is the single most fragile part
          // of this codebase's history (see the ghtypst-plugin memory's
          // "ghost lines" saga) — reusing the one overlay technique
          // that's actually proven safe here is much lower risk than
          // threading a second, independent highlighting concern into it.
          Repeater {
            // Filtered to the visible viewport (+ buffer) — see
            // root._visibleTextRange/visibleMisspelledWords' own comment.
            // This was the real remaining cost even with line numbers
            // off: ~1500 flagged occurrences on Gabriel's stress
            // document, unconditionally rebuilt (2 positionToRectangle()
            // calls each) every recolor pass regardless of that toggle.
            model: root.visibleMisspelledWords
            Rectangle {
              required property var modelData
              // Both explicitly read root.layoutVersion so they
              // re-evaluate once RichText layout has actually settled
              // after a recolor swap — same reasoning as the gutter's own
              // _layoutDep trick above. misspelledWords itself can arrive
              // from Panel.qml's async hunspell process at any time
              // relative to that settle, so this is what makes the
              // underline correct eventually regardless of which lands
              // first.
              property rect _startRect: { var _dep = root.layoutVersion; return inputEdit.positionToRectangle(Math.min(modelData.start, inputEdit.length)) }
              property rect _endRect: { var _dep = root.layoutVersion; return inputEdit.positionToRectangle(Math.min(modelData.end, inputEdit.length)) }
              // A spellcheck token (Spellcheck.tokenize's word-char regex)
              // never contains a line break, so start/end should always
              // land on the same visual row — guarded anyway rather than
              // drawing a bar across the whole width if a wrap ever
              // lands exactly between them.
              visible: _startRect.y === _endRect.y && _endRect.x > _startRect.x
              x: inputEdit.x + _startRect.x
              y: inputEdit.y + _startRect.y + _startRect.height - Style.space(2)
              width: Math.max(2, _endRect.x - _startRect.x)
              height: Style.space(2)
              color: root.urgentColor
            }
          }

          // Right-click on a misspelled word opens a suggestion menu.
          // acceptedButtons restricted to RightButton so left-click/drag
          // text selection (inputEdit's own built-in selectByMouse
          // handling) is never intercepted — a MouseArea only claims the
          // buttons listed here, an ignored button's press falls through
          // to whatever's underneath untouched.
          MouseArea {
            anchors.fill: inputEdit
            acceptedButtons: Qt.RightButton
            onClicked: function(mouse) {
              if (!root.spellcheckAvailable) return
              var pos = inputEdit.positionAt(mouse.x, mouse.y)
              var hit = null
              for (var i = 0; i < root.misspelledWords.length; i++) {
                var w = root.misspelledWords[i]
                if (pos >= w.start && pos < w.end) { hit = w; break }
              }
              if (!hit) return
              spellcheckMenu.targetStart = hit.start
              spellcheckMenu.targetEnd = hit.end
              spellcheckMenu.targetWord = hit.word
              root.suggestRequested(hit.word)
              spellcheckMenu.popup()
            }
          }

          Menu {
            id: spellcheckMenu
            property int targetStart: -1
            property int targetEnd: -1
            property string targetWord: ""
            readonly property bool resultReady: !root.suggestBusy && root.suggestWord === targetWord

            MenuItem {
              visible: !spellcheckMenu.resultReady
              enabled: false
              text: "Recherche de suggestions…"
            }
            MenuItem {
              visible: spellcheckMenu.resultReady && root.suggestions.length === 0
              enabled: false
              text: "Aucune suggestion"
            }
            Repeater {
              model: spellcheckMenu.resultReady ? root.suggestions : []
              MenuItem {
                required property string modelData
                text: modelData
                onTriggered: root.applySuggestionRequested(spellcheckMenu.targetStart, spellcheckMenu.targetEnd, modelData)
              }
            }
          }

          // Single RichText TextEdit, edited in place, recolored on a
          // debounce after typing pauses — see root's comment for why this
          // is architecturally distinct from the two-layer trick (confirmed
          // broken) and what specifically sank the first try at this same
          // approach (the U+2029 normalization, handled in root.normalize()
          // and every read of the live document below).
          TextEdit {
            id: inputEdit
            anchors.fill: parent
            anchors.margins: Style.space(12)
            anchors.leftMargin: (root.lineNumbersEnabled ? (root.gutterWidth + Style.space(12)) : Style.space(12)) + root.narrowMarginExtra
            anchors.rightMargin: Style.space(12) + root.narrowMarginExtra
            textFormat: TextEdit.RichText
            color: root.foreground
            selectionColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.35)
            font.family: root.monoFont
            font.pixelSize: root.editorFontSize
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            persistentSelection: true
            cursorVisible: true

            // Intercepts Ctrl+Z/Ctrl+R before TextEdit's own native undo
            // (bound to Ctrl+Z by default) ever sees them — BeforeItem
            // priority runs this ahead of the item's built-in key
            // handling, and event.accepted = true stops it from falling
            // through afterward. Necessary because the native undo stack
            // is unusable here (see undo()/redo()'s own comment above):
            // renderPlainText()'s wholesale inputEdit.text reassignment on
            // every recolor pass confuses it.
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Z) {
                root.undo()
                event.accepted = true
              } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_R) {
                root.redo()
                event.accepted = true
              }
            }

            onCursorRectangleChanged: root.ensureLastLineVisible()
            // Skipped during a programmatic text swap (recolor pass) —
            // cursorPosition is transiently unstable in that exact window,
            // see lineStart/lineEnd's own comment for the flicker this
            // caused when it wasn't guarded. renderPlainText()'s
            // Qt.callLater block re-syncs once the swap has settled.
            onCursorPositionChanged: if (!root._programmatic) root._updateCurrentLine()
            // Debounced "layout finished" signal for the gutter — see
            // settleTimer's own comment above for the full story. Restarts
            // on every keystroke (cheap, just resets a countdown) but only
            // actually fires once contentHeight stops changing for
            // settleTimer.interval, which live typing never allows.
            onContentHeightChanged: settleTimer.restart()

            onTextChanged: {
              if (root._programmatic) return
              var plain = root.normalize(inputEdit.getText(0, inputEdit.length))
              if (plain === root._lastPlainText) return
              root._lastPlainText = plain
              recolorDebounce.restart()
              root.textEdited(plain)
            }
          }

          // Recolors from the last known-good plain text after the user
          // pauses typing — never mid-keystroke, so an in-progress word
          // isn't rebuilt out from under the caret on every character.
          //
          // Interval scales with document size — my own idea, 2026-09-02,
          // on top of Gabriel's diagnostic requests above: every recolor
          // reassigns inputEdit.text wholesale, forcing Qt to relayout the
          // WHOLE RichText document, not just the changed part (see this
          // file's header comment on the architecture). That cost grows
          // with document size but the interval never did, so a large
          // document paid full relayout cost every 300ms during a
          // sustained typing burst regardless of anything else running.
          // Widening the interval on a big document is a cheap, low-risk
          // lever — it doesn't touch Highlighter.js or the relayout
          // mechanism at all, just how often it runs — at the cost of
          // colors/gutter/current-line lagging a bit further behind while
          // typing fast. Thresholds are a first guess (Gabriel's stress
          // document is ~68KB), worth retuning together once tested live.
          Timer {
            id: recolorDebounce
            interval: root._lastPlainText.length > 50000 ? 600
              : (root._lastPlainText.length > 20000 ? 450 : 300)
            repeat: false
            onTriggered: root.renderPlainText(root._lastPlainText)
          }
        }
      }

      // Wheel-scroll overlay, 2026-09-02 round two — a TRUE sibling of
      // editorScroll (via editorScrollWrap above), not nested inside its
      // Flickable content like the first attempt was. Gabriel reported
      // "quasiment aucune inertie" even after drastically lowering
      // flickDeceleration and raising the velocity multiplier on that
      // first version — the most likely explanation is event-priority
      // ambiguity between a WheelHandler nested INSIDE a Flickable's own
      // content and that same Flickable's native wheelEvent() override
      // (a different, older event pathway); the Flickable may well have
      // still been doing its own default (slow, non-inertial) wheel
      // handling in parallel or instead. Declared here, AFTER editorScroll
      // in the same parent, this Item sits on top in both paint and
      // hit-test order — it always gets first look at a wheel event,
      // before the ScrollView underneath ever sees it, no ambiguity left.
      // A bare WheelHandler (no MouseArea) only ever claims wheel events,
      // never mouse press/click/drag, so text selection, scrollbar
      // dragging, and the misspelled-word right-click menu underneath all
      // keep working exactly as before.
      Item {
        anchors.fill: editorScrollWrap
        WheelHandler {
          target: null
          onWheel: function(event) {
            var flick = editorScroll.contentItem
            if (!flick || typeof flick.contentY !== "number") return
            // 2026-09-02, round three: Gabriel confirmed round two was a
            // real improvement but still needed "des dizaines" of notches
            // to move through a longer document — pushed hard again, both
            // the throw strength and the deceleration (longer coast).
            flick.flickDeceleration = 250
            var dy = event.angleDelta.y !== 0
              ? (event.angleDelta.y / 120) * 450
              : event.pixelDelta.y * 12
            flick.flick(0, dy * 20)
            event.accepted = true
          }
        }
      }
      }

      // ------------------------------------------------------ find/replace
      //
      // Docked below the editor, not floating over it — Gabriel found the
      // original floating overlay covered the text and couldn't be moved
      // out of the way. A normal Column child, sized to 0 and skipped by
      // Column's own layout when closed (visible: root.findBarOpen), same
      // pattern errorList below already uses — editorScroll's own height
      // formula above subtracts this bar's height when open, exactly like
      // it already does for errorList.
      Rectangle {
        id: findBarDock
        visible: root.findBarOpen
        width: parent.width
        height: findBarColumn.implicitHeight + Style.space(16)
        color: Qt.darker(root.background, 1.15)
        border.color: root.accentColor
        border.width: 1
        radius: Style.cornerRadius
        clip: true

        Column {
          id: findBarColumn
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: findField
              width: parent.width - Style.space(190)
              placeholderText: "Rechercher…"
              // No declarative `text:` binding — this codebase's own established
              // trap (see pathBarField/notesField's comments): a TextField's
              // binding is destroyed the instant the user types, so it would
              // only ever seed correctly once. findQuery only ever changes from
              // outside this field at openFindBar() time (seeding from a
              // selection), handled there via a direct imperative assignment.
              onTextChanged: root.onFindQueryEdited(text)
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.closeFindBar(); event.accepted = true }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (event.modifiers & Qt.ShiftModifier) root.findPrevious(); else root.findNext()
                  event.accepted = true
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(70)
              text: root.findMatches.length > 0
                ? (root.findCurrentIndex + 1) + "/" + root.findMatches.length
                : (root.findQuery ? "Aucun résultat" : "")
              color: root.faint
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              iconText: ""
              tooltipText: "Précédent (Maj+Entrée)"
              foreground: root.foreground
              accent: root.accentColor
              onClicked: root.findPrevious()
            }
            Button {
              iconText: ""
              tooltipText: "Suivant (Entrée)"
              foreground: root.foreground
              accent: root.accentColor
              onClicked: root.findNext()
            }
            Button {
              iconText: ""
              tooltipText: "Fermer (Ctrl+F, Échap)"
              foreground: root.foreground
              accent: root.accentColor
              onClicked: root.closeFindBar()
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: replaceField
              // Narrower reservation than findField's row above — this row's
              // two text buttons ("Remplacer"/"Tout remplacer") need more room
              // than row one's three icon-only ones.
              width: parent.width - Style.space(260)
              placeholderText: "Remplacer par…"
              onTextChanged: root.replaceQuery = text
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.closeFindBar(); event.accepted = true }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.replaceCurrent(); event.accepted = true }
              }
            }

            Button {
              text: "Remplacer"
              enabled: root.findMatches.length > 0
              bordered: true
              foreground: root.foreground
              accent: root.accentColor
              onClicked: root.replaceCurrent()
            }
            Button {
              text: "Tout remplacer"
              enabled: root.findMatches.length > 0
              bordered: true
              foreground: root.foreground
              accent: root.accentColor
              onClicked: root.replaceAll()
            }
          }

          Text {
            visible: root._lastReplaceAllCount >= 0
            width: parent.width
            text: root._lastReplaceAllCount + " remplacement(s) effectué(s)."
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      // ---------------------------------------------------- error list
      // root.errors already arrives deduplicated and capped from Panel.qml
      // (see compileErrorsInline there) — a single unclosed paren/bracket
      // sends the Typst compiler cascading into a dozen-plus near-identical
      // diagnostics, which used to flood this Column and squeeze the editor
      // out of view (its height is subtracted from editorScroll's, see the
      // height binding above). Each row's "count" (when > 1) reflects how
      // many times that exact message repeated in the raw compiler output;
      // the "Journal complet" button opens the untouched full list in its
      // own window — see Panel.qml's errorLogWindow.
      Column {
        id: errorList
        width: parent.width
        visible: root.errors.length > 0
        spacing: Style.space(4)

        Row {
          width: errorList.width
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.errors.length + (root.errors.length > 1 ? " erreurs" : " erreur")
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Journal complet"
            color: root.accentColor
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
            font.underline: errorLogMouse.containsMouse

            MouseArea {
              id: errorLogMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showErrorLogRequested()
            }
          }
        }

        Repeater {
          model: root.errors

          Row {
            width: errorList.width
            spacing: Style.space(6)

            Text {
              text: modelData.isMore ? "…" : (modelData.severity === "warning" ? "◐" : "✕")
              color: modelData.severity === "warning" ? root.warningColor : root.urgentColor
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: errorList.width - Style.space(30)
              textFormat: Text.PlainText
              text: (modelData.line > 0 ? ("L" + modelData.line + ":" + modelData.col + " — ") : "")
                + modelData.message
                + (modelData.count > 1 ? (" (×" + modelData.count + ")") : "")
              color: modelData.isMore ? root.accentColor : root.foreground
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
              font.italic: !!modelData.isMore
              wrapMode: Text.Wrap

              MouseArea {
                anchors.fill: parent
                cursorShape: (modelData.isMore || modelData.line > 0) ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: modelData.isMore ? root.showErrorLogRequested() : root.jumpToError(modelData)
              }
            }
          }
        }
      }
    }

    // --------------------------------------------------- right: preview
    Column {
      visible: !root.rightPaneHidden
      width: visible ? (parent.width - parent.spacing - (parent.width * 0.52)) : 0
      height: parent.height
      spacing: Style.space(8)


      Rectangle {
        width: parent.width
        height: parent.height - Style.space(30)
        color: Qt.darker(root.background, 1.05)
        border.color: root.faint
        border.width: 1
        radius: Style.cornerRadius
        clip: true
        visible: root.rightPaneView === "apercu"

        Text {
          visible: root.previewSources.length === 0
          anchors.centerIn: parent
          text: root.previewEnabled
            ? "L'aperçu apparaît après la première compilation."
            : "Aperçu désactivé."
          color: root.faint
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
        }

        ScrollView {
          id: previewScrollContent
          anchors.fill: parent
          anchors.margins: Style.space(8)
          visible: root.previewSources.length > 0
          clip: true
          ScrollBar.vertical.policy: ScrollBar.AsNeeded

          Column {
            width: previewScrollContent.availableWidth
            spacing: Style.space(10)

            Repeater {
              model: root.previewSources

              // One page per image, stacked — every page compiled, not
              // just the first. Sized to the pane's width, aspect ratio
              // preserved; the 1.414 fallback (≈A4) only matters for the
              // first frame before a page's real size is known.
              Image {
                id: pageImage
                required property string modelData
                width: previewScrollContent.availableWidth
                height: implicitWidth > 0 ? (width * implicitHeight / implicitWidth) : width * 1.414
                source: modelData
                asynchronous: true
                cache: false
                fillMode: Image.PreserveAspectFit
              }
            }
          }
        }

        // True sibling of previewScrollContent (this Rectangle, unlike a
        // Column, positions children by anchors rather than stacking them,
        // so an overlay at the same geometry is possible here) — declared
        // after it, so it sits on top for wheel hit-testing, same fix and
        // same reasoning as the editor's own overlay above (see its
        // comment for why the previous nested-WheelHandler attempt likely
        // did little).
        Item {
          anchors.fill: previewScrollContent
          WheelHandler {
            target: null
            onWheel: function(event) {
              var flick = previewScrollContent.contentItem
              if (!flick || typeof flick.contentY !== "number") return
              flick.flickDeceleration = 250
              var dy = event.angleDelta.y !== 0
                ? (event.angleDelta.y / 120) * 450
                : event.pixelDelta.y * 12
              flick.flick(0, dy * 20)
              event.accepted = true
            }
          }
        }
      }

      // Plain-text notes, associated with the current document (Gabriel's
      // ask, 2026-08-29) — deliberately no markdown highlighting/preview,
      // his own explicit choice, and consistent with this editor's
      // hard-won lesson that adding formatting to a live-edited TextEdit
      // is never as simple as it looks. Panel.qml owns the actual file
      // (load-on-open, debounced save-on-edit); this is just the box.
      Rectangle {
        width: parent.width
        height: parent.height - Style.space(30)
        color: Qt.darker(root.background, 1.05)
        border.color: root.faint
        border.width: 1
        radius: Style.cornerRadius
        clip: true
        visible: root.rightPaneView === "notes"

        ScrollView {
          id: notesScroll
          anchors.fill: parent
          anchors.margins: Style.space(8)
          clip: true
          ScrollBar.vertical.policy: ScrollBar.AsNeeded

          // text is seeded/re-synced imperatively, not via a plain
          // `text: root.notesText` binding — a TextArea's own binding is
          // destroyed the moment the user types into it (normal QML
          // semantics, same reasoning as Panel.qml's pathBarField), so a
          // declarative binding would only ever reflect the *first*
          // document's notes and silently stop following notesText after
          // that, including across a document switch. _notesProgrammatic
          // distinguishes "notesText changed because Panel.qml loaded a
          // different document" from "the user is typing" so the two
          // directions (external → field, field → notesEdited signal)
          // don't feed back into each other.
          TextArea {
            id: notesField
            width: notesScroll.availableWidth
            placeholderText: "Notes libres pour ce document (fichier .notes.md à côté du .typ)…"
            wrapMode: TextEdit.Wrap
            // Pastel green, deliberately distinct from the Typst
            // document's own text color — Gabriel's ask, 2026-08-29, so
            // Notes reads as visually separate at a glance without
            // needing real markdown syntax highlighting.
            color: root.notesColor
            font.family: root.monoFont
            font.pixelSize: root.editorFontSize
            background: null
            onTextChanged: if (!root._notesProgrammatic) root.notesEdited(text)
            Component.onCompleted: text = root.notesText
          }
        }
      }

      // Journal (Gabriel's ask, 2026-08-30) — a month calendar above a
      // plain-text view of the selected day's entry. See root's own
      // comments on journalDir/journalWeeks/journalCells for the data
      // model; this block is purely presentational.
      Rectangle {
        width: parent.width
        height: parent.height - Style.space(30)
        color: Qt.darker(root.background, 1.05)
        border.color: root.faint
        border.width: 1
        radius: Style.cornerRadius
        clip: true
        visible: root.rightPaneView === "journal"

        Text {
          visible: root.journalDir === ""
          anchors.fill: parent
          anchors.margins: Style.space(12)
          wrapMode: Text.Wrap
          text: "Configurez le dossier du journal dans l'onglet Paramètres pour activer cette vue."
          color: root.faint
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          id: journalRoot
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(8)
          visible: root.journalDir !== ""

          Column {
            id: journalCalendar
            width: parent.width
            spacing: Style.space(6)
            // Capped so the calendar stays a small, fixed-size widget even
            // on a wide/fullscreen pane — Gabriel's ask, 2026-08-30 ("le
            // calendrier prend beaucoup trop de place en plein écran").
            // Only shrinks below the cap on a genuinely narrow pane, never
            // grows past it.
            readonly property real cellSize: Math.min(Style.space(42), (width - Style.space(2) * 6) / 7)

            Row {
              width: parent.width
              height: journalMonthLabelText.implicitHeight

              Button {
                iconText: ""
                foreground: root.foreground
                accent: root.accentColor
                onClicked: root.journalPrevMonthRequested()
              }
              Text {
                id: journalMonthLabelText
                width: parent.width - Style.space(80)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
                text: root.journalMonthLabel
                color: root.foreground
                font.family: root.uiFont
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Button {
                iconText: ""
                foreground: root.foreground
                accent: root.accentColor
                onClicked: root.journalNextMonthRequested()
              }
            }

            Row {
              width: journalCalendar.cellSize * 7
              anchors.horizontalCenter: parent.horizontalCenter
              Repeater {
                model: ["L", "M", "M", "J", "V", "S", "D"]
                Text {
                  required property string modelData
                  width: journalCalendar.cellSize
                  horizontalAlignment: Text.AlignHCenter
                  text: modelData
                  color: root.faint
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Grid {
              width: journalCalendar.cellSize * 7 + Style.space(2) * 6
              anchors.horizontalCenter: parent.horizontalCenter
              columns: 7
              columnSpacing: Style.space(2)
              rowSpacing: Style.space(2)

              Repeater {
                model: root.journalCells

                Rectangle {
                  id: journalDayCell
                  required property var modelData
                  readonly property bool isDay: modelData !== null
                  readonly property bool isSelected: isDay && modelData === root.journalSelectedDay
                    && root.journalViewYear === root.journalSelectedYear
                    && root.journalViewMonth === root.journalSelectedMonth
                  readonly property bool isToday: isDay && modelData === root._journalToday.getDate()
                    && root.journalViewYear === root._journalToday.getFullYear()
                    && root.journalViewMonth === (root._journalToday.getMonth() + 1)
                  readonly property bool hasEntry: isDay && root.journalEntryDays[modelData] === true

                  width: journalCalendar.cellSize
                  height: journalCalendar.cellSize
                  radius: Style.cornerRadius
                  color: isSelected ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.35) : "transparent"
                  border.color: isToday ? root.accentColor : "transparent"
                  border.width: 1

                  Text {
                    visible: journalDayCell.isDay
                    anchors.centerIn: parent
                    text: journalDayCell.modelData || ""
                    color: root.foreground
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                  }

                  Rectangle {
                    visible: journalDayCell.hasEntry
                    width: Style.space(4)
                    height: Style.space(4)
                    radius: width / 2
                    color: root.accentColor
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(2)
                  }

                  MouseArea {
                    anchors.fill: parent
                    visible: journalDayCell.isDay
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.journalDaySelected(journalDayCell.modelData)
                  }
                }
              }
            }
          }

          ScrollView {
            id: journalScroll
            width: parent.width
            height: journalRoot.height - journalCalendar.height - journalRoot.spacing
            clip: true
            ScrollBar.vertical.policy: ScrollBar.AsNeeded

            // Same imperative text seed/resync as notesField above —
            // journalText changes every time a different day is clicked.
            TextArea {
              id: journalField
              width: journalScroll.availableWidth
              placeholderText: "Entrée de journal pour le jour sélectionné…"
              wrapMode: TextEdit.Wrap
              color: root.notesColor
              font.family: root.monoFont
              font.pixelSize: root.editorFontSize
              background: null
              onTextChanged: if (!root._journalProgrammatic) root.journalTextEdited(text)
              Component.onCompleted: text = root.journalText
            }
          }
        }
      }
    }
  }
}

