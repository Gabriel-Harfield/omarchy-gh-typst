import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "lib/Highlighter.js" as Highlighter

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
  required property bool compiling
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
  // Aperçu/Notes right-pane switcher (Gabriel's ask, 2026-08-29) —
  // "apercu" | "notes". Independent of previewEnabled, which only
  // controls whether Typst compilation runs at all.
  required property string rightPaneView
  required property string notesText
  // Left panel (file tree / heading outline) — "" | "files" | "headings".
  // Lives in Panel.qml (it owns the actual panel layout, a sibling of
  // this whole component, not a child of it) but the toggle buttons
  // themselves sit in THIS component's own header row, next to the
  // "Éditeur" label — Gabriel's explicit placement correction,
  // 2026-08-29, moved down from the outer tab bar.
  required property string leftPanelMode
  required property bool notesAvailable

  signal textEdited(string newText)
  signal zoomInRequested()
  signal zoomOutRequested()
  signal previewToggleRequested()
  signal lineNumbersToggleRequested()
  signal spellcheckRequested(string text)
  signal suggestRequested(string word)
  signal applySuggestionRequested(int start, int end, string replacement)
  signal rightPaneViewRequested(string view)
  signal notesEdited(string newText)
  signal leftPanelModeRequested(string mode)

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

  readonly property string monoFont: "monospace"
  readonly property real editorFontSize: Math.max(6, Math.round(Style.font.body * root.zoom))

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

  function renderPlainText(plain) {
    root._programmatic = true
    var savedPos = inputEdit.cursorPosition
    inputEdit.text = Highlighter.toHtml(plain)
    root._lastPlainText = plain
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

  function _updateCurrentLine() {
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
    spacing: Style.space(14)

    // ------------------------------------------------ left: code editor
    Column {
      width: parent.width * 0.52
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

          // Left-panel toggle pair (file tree / heading outline) —
          // repositioned here, next to the "Éditeur" label, per Gabriel's
          // explicit correction 2026-08-29 (was on the outer tab bar).
          Button {
            iconText: ""
            tooltipText: "Fichiers"
            selected: root.leftPanelMode === "files"
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.leftPanelModeRequested("files")
          }
          Button {
            iconText: ""
            tooltipText: "Titres du document"
            selected: root.leftPanelMode === "headings"
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.leftPanelModeRequested("headings")
          }

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

      ScrollView {
        id: editorScroll
        width: parent.width
        height: parent.height - editorHeader.height - parent.spacing - errorList.height - (errorList.visible ? Style.space(8) : 0)
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
            visible: inputEdit.activeFocus && root._lastPlainText.length > 0
            color: Qt.rgba(0.5, 0.5, 0.5, 0.14)
            x: inputEdit.x
            width: inputEdit.width
            property rect _startRect: inputEdit.positionToRectangle(root.lineStart)
            property rect _endRect: inputEdit.positionToRectangle(Math.max(root.lineStart, root.lineEnd))
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
            model: root.lineNumbersEnabled ? root.lineOffsets : []
            Text {
              required property int index
              required property var modelData
              text: String(index + 1)
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
                return inputEdit.y + inputEdit.positionToRectangle(Math.min(modelData, inputEdit.length)).y
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
            model: root.misspelledWords
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
            anchors.leftMargin: root.lineNumbersEnabled ? (root.gutterWidth + Style.space(12)) : Style.space(12)
            textFormat: TextEdit.RichText
            color: root.foreground
            selectionColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.35)
            font.family: root.monoFont
            font.pixelSize: root.editorFontSize
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            persistentSelection: true
            cursorVisible: true

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
          Timer {
            id: recolorDebounce
            interval: 300
            repeat: false
            onTriggered: root.renderPlainText(root._lastPlainText)
          }
        }
      }

      // ---------------------------------------------------- error list
      Column {
        id: errorList
        width: parent.width
        visible: root.errors.length > 0
        spacing: Style.space(4)

        Repeater {
          model: root.errors

          Row {
            width: errorList.width
            spacing: Style.space(6)

            Text {
              text: modelData.severity === "warning" ? "◐" : "✕"
              color: modelData.severity === "warning" ? root.warningColor : root.urgentColor
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: errorList.width - Style.space(30)
              textFormat: Text.PlainText
              text: (modelData.line > 0 ? ("L" + modelData.line + ":" + modelData.col + " — ") : "") + modelData.message
              color: root.foreground
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap

              MouseArea {
                anchors.fill: parent
                cursorShape: modelData.line > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.jumpToError(modelData)
              }
            }
          }
        }
      }
    }

    // --------------------------------------------------- right: preview
    Column {
      width: parent.width - parent.spacing - (parent.width * 0.52)
      height: parent.height
      spacing: Style.space(8)

      Item {
        width: parent.width
        height: previewHeaderRow.implicitHeight

        Row {
          id: previewHeaderRow
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          // Aperçu/Notes: which content the right pane shows — not the
          // same axis as the eye icon below, which is whether Typst
          // compilation even runs at all (Gabriel's explicit split,
          // 2026-08-29): you can be looking at Notes while the preview
          // keeps compiling in the background, or looking at Aperçu with
          // compilation paused on a large document.
          Button {
            text: "Aperçu"
            selected: root.rightPaneView === "apercu"
            foreground: root.dim
            accent: root.accentColor
            onClicked: root.rightPaneViewRequested("apercu")
          }
          Button {
            text: "Notes"
            selected: root.rightPaneView === "notes"
            enabled: root.notesAvailable
            tooltipText: root.notesAvailable ? "" : "Enregistre d'abord le document pour lui associer des notes."
            foreground: root.dim
            accent: root.accentColor
            onClicked: root.rightPaneViewRequested("notes")
          }
          Text {
            visible: root.compiling
            text: "· compilation…"
            color: root.faint
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }
        }

        // Icon-only, monochrome (Font Awesome eye/eye-slash — confirmed
        // available in this shell's icon font, same family already used
        // elsewhere in Omarchy's own shell source) — Gabriel's explicit
        // ask, 2026-08-29, replacing the old "👁 Actif"/"👁 Coupé" text
        // button. Purely about whether the Typst compile pipeline runs,
        // independent of which view (Aperçu/Notes) is currently shown.
        Button {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.previewEnabled ? "" : ""
          tooltipText: root.previewEnabled
            ? "Désactiver l'aperçu (utile sur un document volumineux)"
            : "Réactiver l'aperçu"
          selected: root.previewEnabled
          foreground: root.foreground
          accent: root.accentColor
          onClicked: root.previewToggleRequested()
        }
      }

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
    }
  }
}
