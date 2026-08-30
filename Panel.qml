import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "lib/Store.js" as Store
import "lib/CodeReview.js" as CodeReview
import "lib/Spellcheck.js" as Spellcheck
import "lib/Outline.js" as Outline
import "lib/Calendar.js" as Calendar

// GH Typst: a personal Typst editor. Highlighting + live preview + real
// compiler diagnostics live in EditorTab.qml; the Claude-powered review
// tools and the Antidote round trip both live in RevisionTab.qml (merged
// from separate Claude/Antidote tabs 2026-08-29, Gabriel's UX request).
// Panel.qml owns file I/O, the compile pipeline, and the review pipeline
// — neither tab reaches into the other, same isolation discipline as
// every other plugin here.
//
// Panel kind, no bar icon — same reasoning as omaslide/dev-gallery: a
// real FloatingWindow, summon-only. `keepLoaded: true` in the manifest
// (same fix as GH Hub) — without it, closing the window would destroy
// this whole component, including any in-flight compile/review Process.
Item {
  id: root

  // --- host lifecycle ---------------------------------------------------

  property bool closingFromHost: false
  property var shell: null

  function open(payloadJson) {
    root.closingFromHost = false
    window.visible = true
  }

  // Unconditional hide — used internally once any unsaved-changes check
  // has already happened (or doesn't apply). Never call this directly
  // from an IPC/user-facing close path; go through requestClose().
  function close() {
    root.closingFromHost = true
    window.visible = false
    root.closingFromHost = false
  }

  // The one gate every "the user wants to close this" path should go
  // through: if there's something unsaved, ask first instead of hiding
  // straight away. Known limitation, told to Gabriel directly rather than
  // silently shipped: Hyprland's own window-close keybind (Super+W, his
  // usual way of closing this plugin) kills the Wayland toplevel directly
  // and never reaches this QML at all — Quickshell's FloatingWindow
  // exposes no vetoable "closing" signal (checked its .qmltypes, only
  // `visible`/`visibleChanged`) — so this only covers closes that go
  // through the shell's own IPC (`hide`/`close`/`toggle`, e.g. from
  // OmApp). The safety net for the Super+W path is still real, just
  // different: `keepLoaded` means the component (and the in-memory
  // buffer) survives a Super+W close untouched, so nothing is actually
  // lost even without a prompt — reopening restores it exactly.
  property bool showCloseConfirm: false

  function requestClose() {
    if (root.dirty) { root.showCloseConfirm = true; return }
    root.close()
  }

  // Same "ask first if there's something unsaved" gate as requestClose()
  // above, generalized for any action that would silently replace the
  // in-memory buffer — opening a different file (file-tree click, "Ouvrir")
  // or starting a blank one ("Nouveau"). Added 2026-08-28 after this exact
  // gap actually bit Gabriel's own unsaved work mid-testing: openDocument()
  // has no dirty-check of its own, so switching documents via the file
  // tree silently discarded whatever was unsaved in the previously open
  // one, no prompt at all.
  property bool showDiscardConfirm: false
  property var _pendingDiscardAction: null

  // Generalized so closeTab() (below) can reuse the same confirm dialog
  // for a tab that isn't necessarily the active one — requestDiscardAndThen
  // itself is unchanged for every existing caller (all of which only ever
  // meant "the active document").
  function _confirmThenRun(isDirty, action) {
    if (isDirty) {
      root._pendingDiscardAction = action
      root.showDiscardConfirm = true
    } else {
      action()
    }
  }

  function requestDiscardAndThen(action) {
    root._confirmThenRun(root.dirty, action)
  }

  IpcHandler {
    target: "io.github.gabrielharfield.ghtypst"
    function open(): void { root.open(null) }
    function close(): void { root.requestClose() }
    function show(): void { root.open(null) }
    function hide(): void { root.requestClose() }
    function toggle(): void { window.visible ? root.requestClose() : root.open(null) }
  }

  function fileBaseName(path) {
    var s = String(path || "")
    var idx = s.lastIndexOf("/")
    return idx === -1 ? s : s.slice(idx + 1)
  }

  // --- paths ---------------------------------------------------------------

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string pluginDir: homeDir + "/.config/omarchy/plugins/io.github.gabrielharfield.ghtypst"
  readonly property string stateDir: homeDir + "/.local/state/omarchy/plugins/io.github.gabrielharfield.ghtypst"
  readonly property string sessionPath: stateDir + "/session.json"
  readonly property string reviewsDir: stateDir + "/reviews"
  // Fixed, reused scratch files (not timestamped like reviewsDir) — this
  // is a high-frequency, single-flight operation with nothing to keep
  // per-run, same reasoning as previewSrcPath/pdfExportSrcPath below.
  // Two separate files/Process pairs (detect vs. suggest) so a detect
  // pass in flight never fights an on-demand suggestion query over one
  // FileView/Process pair — the exact class of bug the preview pipeline
  // hit once already (see this file's own history).
  readonly property string spellcheckWordsPath: stateDir + "/.ghtypst-spellcheck-words.txt"
  readonly property string spellcheckSuggestPath: stateDir + "/.ghtypst-spellcheck-suggest.txt"

  // --- theme tokens (same set OmaSlide uses) --------------------------------

  readonly property color fg: Color.foreground
  readonly property color bg: Color.background
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: Color.urgent
  readonly property color warningColor: "#c98a3a"
  // Pastel green, deliberately NOT theme-derived (no such token exists in
  // this shell's base Color palette — only foreground/background/accent/
  // urgent/muted) — same reasoning as warningColor's own fixed hex just
  // above. Gabriel's ask, 2026-08-29: distinguish Notes text from the
  // Typst document's own color without building real markdown syntax
  // highlighting (explicitly declined, citing this editor's own history).
  readonly property color notesColor: "#8fbf8f"
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.62)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.42)
  readonly property string uiFont: Style.font.family

  // --- document state --------------------------------------------------

  property string docPath: ""   // "" = untitled/new
  property string docText: ""
  property bool dirty: false
  property bool sessionLoaded: false
  property bool suppressDocLoad: false
  // Set while a session restore is in flight, so docFile's onLoaded/
  // onLoadFailed know to reconcile against the persisted buffer instead
  // of doing a plain "adopt whatever's on disk" open.
  property bool pendingRestore: false
  property string pendingRestoreBuffer: ""
  // Whether the persisted buffer was actually dirty (real unsaved edits)
  // when the session was last written — see docFile.onLoaded's own
  // comment for why this matters: a clean buffer must never be allowed
  // to override newer disk content just because it happens to differ
  // from whatever's on disk now.
  property bool pendingRestoreWasDirty: false

  readonly property string docDir: root.docPath ? root.docPath.slice(0, root.docPath.lastIndexOf("/")) : ""
  // Compile scratch files land next to the real document (so relative
  // asset paths like #image("photo.png") keep resolving) — falls back to
  // the plugin's own state dir only for a brand-new, never-saved doc.
  readonly property string previewDir: root.docDir ? root.docDir : (root.stateDir + "/preview")
  readonly property string previewSrcPath: root.previewDir + "/.ghtypst-preview.typ"
  readonly property string previewPagePrefix: ".ghtypst-preview-"

  // --- notes (Aperçu/Notes right-pane view) -------------------------------
  //
  // A plain-text .md file living next to the .typ document, associated by
  // name — Gabriel's ask, 2026-08-29, confirmed naming "<doc>.notes.md"
  // (dot separator). No path at all (untitled doc) means no notes file
  // can be associated yet — notesAvailable gates the Notes button itself
  // in EditorTab.qml, so this only ever gets a real path once the
  // document has one.
  readonly property string notesPath: {
    if (!root.docPath) return ""
    var dot = root.docPath.lastIndexOf(".")
    var slash = root.docPath.lastIndexOf("/")
    var base = (dot > slash) ? root.docPath.slice(0, dot) : root.docPath
    return base + ".notes.md"
  }
  property string rightPaneView: "apercu" // "apercu" | "notes"
  property string notesText: ""

  FileView {
    id: notesFile
    path: root.notesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.notesText = notesFile.text()
    onLoadFailed: root.notesText = "" // no notes file yet for this document — not an error
  }

  Timer {
    id: notesSaveDebounce
    interval: 500
    repeat: false
    onTriggered: if (root.docPath) notesFile.setText(root.notesText)
  }

  function onNotesEdited(newText) {
    root.notesText = newText
    if (root.docPath) notesSaveDebounce.restart()
  }

  // --- journal (Aperçu/Notes/Journal right-pane view) ---------------------
  //
  // Gabriel's ask, 2026-08-30: a small month calendar above a plain-text
  // view of that day's entry, reading/writing "<journalDir>/YYYY_MM_DD.md"
  // — Logseq's own journal filename convention exactly, so entries land in
  // the same folder Logseq already watches and either app can create/edit
  // a day the other one also understands. Deliberately GLOBAL, not
  // per-document like notesText above: the calendar shows the same journal
  // regardless of which .typ tab is active.
  //
  // journalDir is a plain Paramètres setting (see settings block below),
  // "" until configured — no sensible default exists for an arbitrary
  // install, so the Journal view prompts for one rather than guessing.
  property int journalViewYear: new Date().getFullYear()
  property int journalViewMonth: new Date().getMonth() + 1 // 1-12
  property int journalSelectedYear: new Date().getFullYear()
  property int journalSelectedMonth: new Date().getMonth() + 1
  property int journalSelectedDay: new Date().getDate()
  property string journalText: ""
  // {dayNumber: true}, scoped to journalViewYear/Month — rebuilt from a
  // directory listing whenever the visible month or the folder changes,
  // not a per-day existence check (31 stats vs. one `ls`).
  property var journalEntryDays: ({})

  readonly property string journalFilePath: {
    if (!root.journalDir || !root.journalSelectedDay) return ""
    var base = root.journalDir.replace(/\/+$/, "")
    return base + "/" + Calendar.dateKey(root.journalSelectedYear, root.journalSelectedMonth, root.journalSelectedDay) + ".md"
  }

  function journalPrevMonth() {
    var r = Calendar.addMonths(root.journalViewYear, root.journalViewMonth, -1)
    root.journalViewYear = r.year
    root.journalViewMonth = r.month
  }

  function journalNextMonth() {
    var r = Calendar.addMonths(root.journalViewYear, root.journalViewMonth, 1)
    root.journalViewYear = r.year
    root.journalViewMonth = r.month
  }

  function journalSelectDay(day) {
    root.journalSelectedYear = root.journalViewYear
    root.journalSelectedMonth = root.journalViewMonth
    root.journalSelectedDay = day
  }

  // Idempotent — cheap enough to call on every journalDir change without
  // worrying about it having already been created.
  function _ensureJournalDir() {
    if (!root.journalDir) return
    journalMkdirProc.command = ["mkdir", "-p", root.journalDir]
    journalMkdirProc.running = false
    journalMkdirProc.running = true
  }

  Process { id: journalMkdirProc }

  function _refreshJournalEntryDays() {
    if (!root.journalDir) { root.journalEntryDays = {}; return }
    journalListProc.command = ["ls", "-1", root.journalDir]
    journalListProc.running = false
    journalListProc.running = true
  }

  Process {
    id: journalListProc
    stdout: StdioCollector { id: journalListStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.journalEntryDays = {}; return }
      var lines = (journalListStdout.text || "").split("\n").filter(function(l) { return l.length > 0 })
      root.journalEntryDays = Calendar.daysWithEntries(lines, root.journalViewYear, root.journalViewMonth)
    }
  }

  onJournalDirChanged: { root._ensureJournalDir(); root._refreshJournalEntryDays() }
  onJournalViewYearChanged: root._refreshJournalEntryDays()
  onJournalViewMonthChanged: root._refreshJournalEntryDays()

  FileView {
    id: journalFile
    path: root.journalFilePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.journalText = journalFile.text()
    onLoadFailed: root.journalText = "" // no entry yet for this day — not an error
  }

  Timer {
    id: journalSaveDebounce
    interval: 500
    repeat: false
    onTriggered: {
      if (root.journalFilePath) {
        journalFile.setText(root.journalText)
        root._refreshJournalEntryDays()
      }
    }
  }

  // Deliberately does NOT create a file just from clicking/browsing to an
  // empty day (journalSelectDay above never touches the filesystem) — a
  // file only appears once there's actual text, same as notesFile above.
  // Otherwise every idle click while flipping through months would litter
  // Gabriel's real, Logseq-synced folder with empty entries.
  function onJournalTextEdited(newText) {
    root.journalText = newText
    if (root.journalFilePath) journalSaveDebounce.restart()
  }

  // --- open-documents tabs (multiple documents at once) -------------------
  //
  // Gabriel's ask, 2026-08-29: he needs more than one document open at a
  // time, but this plugin is a single keepLoaded Item with one
  // FloatingWindow — there's no "second instance" to open at the
  // Quickshell/plugin level. An in-window tab strip (bottom-left, per his
  // own spec) is the pragmatic equivalent, confirmed with him before
  // starting. Deliberate scope for this first round, told to him directly
  // rather than silently assumed: only the ACTIVE tab compiles, spell-
  // checks, or can have a review/Antidote correction applied to it — no
  // per-tab parallel Process/FileView pipelines, reusing this file's own
  // hard-won lesson (see the compile-pipeline history above) that
  // overlapping instances of those sharing singleton state is a real bug
  // class here, not a theoretical one. Session persistence (session.json)
  // still only remembers the single active document across a restart, same
  // as before this feature — the other open tabs are not yet durable.
  //
  // root.docPath/docText/dirty/notesText/rightPaneView stay exactly what
  // they always were: the ONE active document's live state, read/written
  // everywhere else in this file completely unchanged. `tabs` is a
  // lightweight side array caching the OTHER (inactive) open documents'
  // state, snapshotted/restored around a switch — this way nothing
  // downstream (the compile pipeline, spellcheck, notes, PDF export,
  // review, Antidote) needed to change at all, they just keep reading the
  // one "current document" surface they always did.
  property var tabs: [{ id: 1, path: "", text: "", dirty: false, notesText: "", rightPaneView: "apercu", loaded: false }]
  property int activeDocId: 1
  property int _nextDocId: 2

  // The tab bar's actual model: root.tabs with the active entry's path/
  // dirty overlaid from the LIVE root.docPath/root.dirty rather than
  // whatever was last snapshotted into it — so the bar's title and dirty
  // dot for the current tab update immediately on every keystroke/save,
  // without needing a snapshot on every single edit (only on an actual
  // switch, see _snapshotActiveIntoTabs below).
  readonly property var displayedTabs: root.tabs.map(function(t) {
    if (t.id !== root.activeDocId) return t
    return { id: t.id, path: root.docPath, text: "", dirty: root.dirty, notesText: "", rightPaneView: root.rightPaneView, loaded: true }
  })

  function tabTitle(t) {
    return t.path ? root.fileBaseName(t.path) : "Sans titre"
  }

  // A review result awaiting "Appliquer", or an Antidote correction
  // awaiting "Remplacer le document", both write straight into
  // root.docText/root.dirty with no idea which tab that currently means —
  // switching the active document out from under either one would apply
  // the wrong document's correction onto whatever's now showing. Simplest
  // safe rule rather than threading a "which document is this review for"
  // id through both pipelines: block switching away while either has an
  // unapplied result waiting, same spirit as the existing unsaved-changes
  // guard elsewhere in this file.
  readonly property bool _tabSwitchBlocked: root.reviewing || root.reviewHasResult || root.antidoteHasPreview

  function _snapshotActiveIntoTabs() {
    // Flush any pending (debounced) notes write for the outgoing document
    // before switching — otherwise notesSaveDebounce fires later against
    // whatever notesPath the newly-active document has by then (notesPath
    // is derived from docPath, which is about to change), silently
    // dropping the outgoing edit instead of saving it.
    if (notesSaveDebounce.running) {
      notesSaveDebounce.stop()
      if (root.docPath) notesFile.setText(root.notesText)
    }
    root.tabs = root.tabs.map(function(t) {
      if (t.id !== root.activeDocId) return t
      return { id: t.id, path: root.docPath, text: root.docText, dirty: root.dirty,
               notesText: root.notesText, rightPaneView: root.rightPaneView, loaded: true }
    })
  }

  // Loads a tabs[] entry into the live "current document" surface. Reuses
  // docFile's existing pendingRestore reconciliation (the same mechanism
  // session-restore already relies on) for a real path with cached
  // in-memory content — if the cached text differs from what's actually on
  // disk, the cache wins and dirty is set, exactly like restoring an
  // unsaved edit after a shell restart. A tab that's never been loaded yet
  // (freshly opened into a brand-new tab via "+") does a plain disk load
  // instead, same as an ordinary openDocument().
  function _loadTabIntoActive(tab) {
    root.activeDocId = tab.id
    root.rightPaneView = tab.rightPaneView || "apercu"
    // Undo history is per-EditorTab-instance, not per-tab (see EditorTab's
    // own undo()/redo() comment) — cleared explicitly at the one moment
    // the active document's identity actually changes, so undoing never
    // crosses between two different documents.
    editorTabItem.clearUndoHistory()
    // Cleared unconditionally rather than left stale — see previewVersion/
    // previewPageCount's own note in the compile pipeline: previewDir
    // updates the instant docPath does, and a stale version/page-count
    // paired with a new directory would briefly point at files that don't
    // exist there until the next compile finishes.
    root.compileErrors = []
    root.previewVersion = 0
    root.previewPageCount = 0
    root.suppressDocLoad = false
    if (tab.path === "") {
      // Untitled tab: no FileView involved at all, same as newDocument().
      root.pendingRestore = false
      root.docPath = ""
      root.docText = tab.text
      root.dirty = tab.dirty
      if (root.previewEnabled && root.docText !== "") root.scheduleCompile()
      return
    }
    if (tab.loaded) {
      root.pendingRestoreBuffer = tab.text
      // Same dirty-gated reconciliation as session restore (see
      // docFile.onLoaded's own comment) — this tab's own snapshotted
      // dirty flag, not left over from whatever the property last held.
      root.pendingRestoreWasDirty = tab.dirty
      root.pendingRestore = true
    } else {
      root.pendingRestore = false
    }
    if (tab.path === root.docPath) {
      // docPath binding won't refire on its own since the value isn't
      // actually changing — force it, same trick openDocument() already
      // uses for the identical case.
      docFile.reload()
    } else {
      root.docPath = tab.path
    }
  }

  function switchToTab(id) {
    if (id === root.activeDocId || root._tabSwitchBlocked) return
    root._snapshotActiveIntoTabs()
    var target = null
    for (var i = 0; i < root.tabs.length; i++) if (root.tabs[i].id === id) { target = root.tabs[i]; break }
    if (!target) return
    root._loadTabIntoActive(target)
  }

  function addTab() {
    if (root._tabSwitchBlocked) return
    root._snapshotActiveIntoTabs()
    var id = root._nextDocId++
    var t = { id: id, path: "", text: "", dirty: false, notesText: "", rightPaneView: "apercu", loaded: true }
    root.tabs = root.tabs.concat([t])
    root._loadTabIntoActive(t)
  }

  function closeTab(id) {
    var idx = -1
    for (var i = 0; i < root.tabs.length; i++) if (root.tabs[i].id === id) { idx = i; break }
    if (idx === -1) return
    var isActive = (id === root.activeDocId)
    if (isActive && root._tabSwitchBlocked) return
    var tabDirty = isActive ? root.dirty : root.tabs[idx].dirty
    root._confirmThenRun(tabDirty, function() {
      var remaining = root.tabs.filter(function(x) { return x.id !== id })
      if (remaining.length === 0) {
        // Always at least one tab open — recreate a blank one rather than
        // leaving nothing.
        var freshId = root._nextDocId++
        remaining = [{ id: freshId, path: "", text: "", dirty: false, notesText: "", rightPaneView: "apercu", loaded: true }]
      }
      root.tabs = remaining
      if (isActive) {
        var newActive = remaining[Math.min(idx, remaining.length - 1)]
        root._loadTabIntoActive(newActive)
      }
    })
  }

  property string tab: "editor" // "editor" | "revision" | "settings"

  function windowTitle() {
    var name = root.docPath ? root.fileBaseName(root.docPath) : "Sans titre"
    return "GH Typst — " + name + (root.dirty ? " •" : "")
  }

  function onTextEdited(newText) {
    root.docText = newText
    root.dirty = true
    // Skipped entirely when the preview is off — see previewEnabled below.
    // Gated here rather than inside startCompile() so a large document
    // doesn't even pay for the scratch-file write while the preview is
    // off, not just the typst process.
    if (root.previewEnabled) compileDebounce.restart()
    root.scheduleSessionSave()
  }

  function newDocument() {
    root.docPath = ""
    root.docText = ""
    root.dirty = false
    root.compileErrors = []
    root.previewVersion = 0
    root.previewPageCount = 0
    editorTabItem.clearUndoHistory()
    root.scheduleSessionSave()
  }

  // Typst Universe template picker (Paramètres tab) — opens in a brand-new
  // tab rather than replacing whatever's currently active, same reasoning
  // as addTab() itself: a template pick shouldn't require discarding
  // unrelated in-progress work. addTab() already applies the usual
  // _tabSwitchBlocked guard (no-op while a review/Antidote round-trip is
  // pending), and onTextEdited() drives the same compile/session-save path
  // a real keystroke would.
  function insertTemplate(command) {
    root.addTab()
    root.onTextEdited(command)
    root.tab = "editor"
  }

  function openDocument(path) {
    editorTabItem.clearUndoHistory()
    root.suppressDocLoad = false
    // Defensive reset: a stale true here (left over from an interrupted
    // session-restore) would make docFile.onLoaded treat this fresh open
    // as a restore-reconciliation instead of a plain load, silently
    // discarding the newly-opened file's content in favor of whatever the
    // old pendingRestoreBuffer held.
    root.pendingRestore = false
    if (path === root.docPath) {
      // Same file already open — docPath won't change, so the FileView's
      // path binding never re-fires on its own; force it.
      docFile.reload()
      return
    }
    root.docPath = path
    root.scheduleSessionSave()
  }

  function saveDocument() {
    if (!root.docPath) { root.beginPathEntry("saveAs", ""); return }
    docFile.setText(root.docText)
  }

  // A bare filename (no "/" at all) defaults into wherever the file
  // tree is currently showing, rather than an arbitrary process cwd —
  // matches Gabriel's own mental model of "save it near what I'm
  // looking at". ".typ" is appended when missing (case-insensitive
  // check, so "Doc.TYP" isn't doubled up) — Gabriel's explicit ask,
  // 2026-08-29, to stop having to type the extension himself every time.
  function _normalizeSaveAsPath(path) {
    var p = path.trim()
    if (p.indexOf("/") === -1) {
      var dir = root.fileTreeDir || root.fileTreeHomeDir()
      p = dir + "/" + p
    }
    if (!/\.typ$/i.test(p)) p += ".typ"
    return p
  }

  function saveDocumentAs(path) {
    var normalized = root._normalizeSaveAsPath(path)
    if (normalized === root.docPath) { docFile.setText(root.docText); return }
    root.suppressDocLoad = true
    root.docPath = normalized
    root.scheduleSessionSave()
  }

  // --- typed-path bar (Ouvrir / Enregistrer sous… / destination PDF) ----
  //
  // Not a stylistic choice — a native QtQuick.Dialogs.FileDialog reliably
  // crashes the *entire* Quickshell shell here, confirmed live 2026-08-27
  // via a real crash report: SIGABRT in GLib's D-Bus GVariant builder,
  // called from gvfs_dbus_mount_call_create_directory_monitor_sync in
  // libgvfscommon.so, itself called from libgtk-3.so the instant the
  // native dialog's directory-monitor D-Bus call fires. Same signature as
  // an earlier crash this plugin hit and worked around with this same
  // typed-path bar before reverting back to the native dialog on Gabriel's
  // own (reasonable at the time) pushback that the identical pattern
  // works fine elsewhere — it doesn't reproduce reliably everywhere, but
  // it just took down the whole shell here, not just this plugin, so the
  // native dialog is retired again rather than left as a live landmine.
  property string pathBarMode: "" // "" | "open" | "saveAs" | "exportPdf"

  // The bar's TextField (id: pathBarField, declared later in this same
  // file — QML ids are file-scoped, reachable from here regardless of
  // visual nesting) is seeded and read imperatively rather than through a
  // property binding: a TextField's `text` binding is destroyed the first
  // time the user types into it (normal QML semantics — an imperative
  // write to a bound property drops the binding), so a `text:
  // root.pathBarText`-style binding would only ever seed correctly once,
  // then show stale content on every later reopen of the bar.
  function beginPathEntry(mode, initial) {
    root.pathBarMode = mode
    pathBarField.text = initial || ""
  }

  function confirmPathEntry() {
    var path = pathBarField.text.trim()
    var mode = root.pathBarMode
    if (!path) return
    root.pathBarMode = ""
    if (mode === "open") root.requestDiscardAndThen(function() { root.openDocument(path) })
    else if (mode === "saveAs") root.saveDocumentAs(path)
    else if (mode === "exportPdf") root.startPdfExport(path)
  }

  function cancelPathEntry() {
    root.pathBarMode = ""
  }

  FileView {
    id: docFile
    path: root.docPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      // Deferred one event-loop turn — see onLoadFailed's own comment
      // below for why calling setText() synchronously from inside this
      // handler is unsafe, confirmed live, not theoretical.
      if (root.suppressDocLoad) { root.suppressDocLoad = false; Qt.callLater(function() { docFile.setText(root.docText) }); return }
      if (root.pendingRestore) {
        root.pendingRestore = false
        var diskText = docFile.text()
        // Only trust the persisted buffer over what's actually on disk
        // if it was genuinely DIRTY (real unsaved edits) when the
        // session was last written — never just because it happens to
        // differ from disk. Real bug, reported by Gabriel 2026-08-30:
        // editing the same Dropbox-synced document from a second
        // machine (Harfield X13) between two sessions on this one
        // (Ostrog) made a merely-stale-but-clean buffer here look
        // "different from disk" and silently overwrite the newer
        // content from the other machine once autosave fired. A clean
        // buffer is just a mirror of whatever was on disk when this
        // machine last touched the file — it has nothing worth
        // protecting, so disk always wins when pendingRestoreWasDirty
        // is false.
        if (root.pendingRestoreWasDirty && root.pendingRestoreBuffer !== diskText) {
          root.docText = root.pendingRestoreBuffer
          root.dirty = true
        } else {
          root.docText = diskText
          root.dirty = false
        }
        compileDebounce.restart()
        return
      }
      root.docText = docFile.text()
      root.dirty = false
      compileDebounce.restart()
    }
    onLoadFailed: function(error) {
      // Real bug, found live 2026-08-29: calling docFile.setText()
      // synchronously from inside this handler — i.e. while the FileView
      // is still inside its own "load just failed" signal emission —
      // silently breaks its own subsequent onSaved signal. The write
      // itself still lands on disk correctly (confirmed: the file exists
      // with the right content afterward), but onSaved never fires, so
      // root.dirty never clears and the file-tree-refresh hook below
      // never runs either. Deferring the call one event-loop turn via
      // Qt.callLater() — so it runs after this handler (and the
      // FileView's own internal load-failed bookkeeping) has fully
      // returned — fixes it. This is exactly the scenario "Enregistrer
      // sous…" to a path that doesn't exist yet goes through (via
      // suppressDocLoad), so any brand-new save was silently leaving the
      // title bar's dirty marker stuck and the file tree stale, even
      // though the save itself had actually succeeded.
      if (root.suppressDocLoad) { root.suppressDocLoad = false; Qt.callLater(function() { docFile.setText(root.docText) }); return }
      if (root.pendingRestore) {
        // The file that was open last session is gone/unreadable now —
        // fall back to whatever buffer was persisted, if any. Still
        // gated on pendingRestoreWasDirty for the same reason as
        // onLoaded above: a clean persisted buffer is nothing more than
        // a stale mirror, not real unsaved work worth flagging dirty.
        root.pendingRestore = false
        root.docText = root.pendingRestoreBuffer
        root.dirty = root.pendingRestoreWasDirty
        compileDebounce.restart()
        return
      }
      root.docText = ""
      root.dirty = false
    }
    onSaved: {
      root.dirty = false
      // "Enregistrer sous…" to a new path sets docPath first, which
      // reactively triggers this FileView's own load-fails-then-setText
      // chain (see suppressDocLoad above) — refreshFileTree() from
      // onDocPathChanged below fires too early in that sequence (before
      // this actual write has happened), so the new file never appeared
      // in the tree yet. This fires once the write is actually done.
      if (!root.fileTreeUserNavigated) root.refreshFileTree(root.docDir)
      // Flush session.json's dirty flag to false immediately rather than
      // waiting on the usual 400ms debounce — closes a real race where
      // saving right before shutting the machine down could leave a
      // stale "dirty: true" behind, which is exactly what would make a
      // future restore wrongly prefer this now-clean buffer over newer
      // disk content from another machine. See docFile.onLoaded's own
      // comment for the full story (Gabriel's cross-machine bug report,
      // 2026-08-30).
      if (root.sessionLoaded) {
        sessionSaveDebounce.stop()
        root._writeSessionNow()
      }
    }
  }

  // --- session persistence -----------------------------------------------
  //
  // Persists the buffer itself, not just which file was open — a plugin
  // reload (a shell restart, routine while this plugin is under active
  // development) must not destroy unsaved work, above all for an untitled
  // document that has nowhere else to live.

  FileView {
    id: sessionFile
    path: root.sessionPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSession(sessionFile.text())
    onLoadFailed: root.loadSession("")
  }

  // Persists dirty alongside the buffer/path — see docFile.onLoaded's own
  // comment for why: only a genuinely-dirty session is worth restoring
  // over disk on the next open.
  function _writeSessionNow() {
    sessionFile.setText(Store.serializeSession({ lastDocPath: root.docPath, bufferText: root.docText, dirty: root.dirty }))
  }

  Timer {
    id: sessionSaveDebounce
    interval: 400
    repeat: false
    onTriggered: root._writeSessionNow()
  }

  function scheduleSessionSave() {
    if (root.sessionLoaded) sessionSaveDebounce.restart()
  }

  function loadSession(text) {
    var parsed = Store.parseSession(text)
    root.sessionLoaded = true
    if (parsed.lastDocPath) {
      root.pendingRestoreBuffer = parsed.bufferText
      root.pendingRestoreWasDirty = parsed.dirty
      root.pendingRestore = true
      root.docPath = parsed.lastDocPath // triggers docFile's path binding -> async load, reconciled above
    } else if (parsed.bufferText) {
      // Untitled document with unsaved content — nothing to load from
      // disk at all (docFile's path never changes from "", so it never
      // fires loaded/loadFailed for this case).
      root.docText = parsed.bufferText
      root.dirty = true
      compileDebounce.restart()
    }
  }

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", root.stateDir, root.reviewsDir]
  }

  Component.onCompleted: {
    ensureDirsProc.running = true
    Qt.callLater(function() { sessionFile.reload() })
    Qt.callLater(function() { settingsFile.reload() })
    Qt.callLater(function() { root.refreshFileTree(root.fileTreeHomeDir()) })
  }

  // --- compile pipeline (live preview + real compiler diagnostics) -----

  property var compileErrors: []
  property bool compiling: false
  property int previewVersion: 0
  property int previewPageCount: 0
  // Array of "file://.../.ghtypst-preview-N.png?v=version" strings, one
  // per page — confirmed working live (Gabriel: the multi-page preview was
  // the one piece of the reverted round that actually worked), kept on
  // its own rather than reintroducing anything else from that round.
  readonly property var previewSources: {
    var out = []
    for (var i = 1; i <= root.previewPageCount; i++)
      out.push("file://" + root.previewDir + "/" + root.previewPagePrefix + i + ".png?v=" + root.previewVersion)
    return out
  }

  Timer {
    id: compileDebounce
    interval: 500
    repeat: false
    onTriggered: root.startCompile()
  }

  function scheduleCompile() { compileDebounce.restart() }

  function startCompile() {
    if (root.docText === "") { root.compileErrors = []; return }
    previewSrcFile.setText(root.docText)
  }

  FileView {
    id: previewSrcFile
    path: root.previewSrcPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: {
      root.compiling = true
      compileProc.command = ["bash", root.pluginDir + "/compile.sh", root.previewSrcPath, root.previewDir, root.previewDir, root.previewPagePrefix]
      compileProc.running = false
      compileProc.running = true
    }
  }

  Process {
    id: compileProc
    stdout: StdioCollector { id: compileStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.compiling = false
      var parsed = null
      try { parsed = JSON.parse(compileStdout.text || "") } catch (e) { parsed = null }
      if (!parsed) {
        root.compileErrors = [{ line: 0, col: 0, severity: "error", message: "Erreur interne du script de compilation." }]
        return
      }
      root.compileErrors = parsed.errors || []
      // On success, refresh the page count and bump the preview version
      // so every page Image's source string changes (filenames are
      // stable and overwritten in place each compile — the version query
      // string is what forces a reload). On failure both are left alone
      // so the last successful render keeps showing instead of blanking
      // on a typo.
      if (parsed.ok) {
        root.previewPageCount = parsed.pageCount || 0
        root.previewVersion += 1
      }
    }
  }

  // --- code review pipeline (Claude tab) --------------------------------

  property bool reviewing: false
  property string reviewKind: "" // "" | "code" | "orthographe" | "syntaxe"
  property string reviewSyntaxeMode: "strict" // only meaningful when reviewKind === "syntaxe"
  property bool reviewHasResult: false
  property string reviewLog: ""
  property string reviewError: ""
  property string reviewSrcPath: ""
  property string reviewOutPath: ""
  property string reviewLogPath: ""
  property string _pendingReviewRunDir: ""
  property bool _reviewCancelled: false
  // Live progress, Gabriel's explicit ask 2026-08-29 — a long review (his
  // real case: an orthographe pass on a large document) gave no sign of
  // life at all before this. reviewOutputTokens is a running sum of
  // output_tokens parsed from each --output-format stream-json "assistant"
  // event as it streams in (see reviewProc's stdout below) — an
  // approximation of total work done, not a billing-accurate figure.
  property int reviewElapsedMs: 0
  property int reviewOutputTokens: 0
  // Snapshot of docText at the moment the review started — the two-column
  // diff view's "left" side and the diff basis for the "right" side both
  // need a stable reference, not the live buffer (which the user is free
  // to keep editing while a review runs in the background).
  property string reviewOriginalText: ""
  property string _reviewCorrectedText: ""
  // Free-text box in the Révision tab (Gabriel's explicit ask,
  // 2026-08-29) for one-off instructions appended to whichever prompt
  // runs next — not persisted, this is meant to be per-run, not a
  // durable setting.
  property string reviewExtraInstructions: ""

  Timer {
    id: reviewElapsedTimer
    interval: 200
    repeat: true
    running: root.reviewing
    onTriggered: root.reviewElapsedMs += interval
  }

  function startCodeReview(kind, mode, extraInstructions) {
    if (root.reviewing || root.docText === "") return
    root.reviewKind = kind
    if (kind === "syntaxe") root.reviewSyntaxeMode = mode || "strict"
    root.reviewExtraInstructions = extraInstructions || ""
    var ts = Qt.formatDateTime(new Date(), "yyyyMMdd-hhmmss-zzz")
    root._pendingReviewRunDir = root.reviewsDir + "/" + ts
    root.reviewHasResult = false
    root.reviewError = ""
    root._reviewCancelled = false
    root.reviewElapsedMs = 0
    root.reviewOutputTokens = 0
    root.reviewOriginalText = root.docText
    ensureReviewDirProc.command = ["mkdir", "-p", root._pendingReviewRunDir]
    ensureReviewDirProc.running = false
    ensureReviewDirProc.running = true
  }

  // Gabriel's explicit ask, 2026-08-29 — a review on a large document ran
  // "très très longue" with no way to stop it. Killing reviewProc mid-run
  // is enough: it never touches docText itself (only the corrected-file
  // pipeline does, on an explicit Appliquer), so there's nothing to undo.
  function cancelCodeReview() {
    if (!root.reviewing) return
    root._reviewCancelled = true
    reviewProc.running = false
    root.reviewing = false
    root.reviewError = "Vérification annulée."
  }

  Process {
    id: ensureReviewDirProc
    onExited: {
      root.reviewSrcPath = root._pendingReviewRunDir + "/source.typ"
      root.reviewOutPath = root._pendingReviewRunDir + "/corrected.typ"
      root.reviewLogPath = root._pendingReviewRunDir + "/changelog.txt"
      reviewSrcFile.path = root.reviewSrcPath
      reviewSrcFile.setText(root.reviewOriginalText)
    }
  }

  FileView {
    id: reviewSrcFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: {
      root.reviewing = true
      var prompt
      if (root.reviewKind === "orthographe") {
        prompt = CodeReview.buildOrthographeReviewPrompt(root.reviewSrcPath, root.reviewOutPath, root.reviewLogPath, root.reviewExtraInstructions)
      } else if (root.reviewKind === "syntaxe") {
        prompt = CodeReview.buildSyntaxeReviewPrompt(root.reviewSrcPath, root.reviewOutPath, root.reviewLogPath, root.reviewSyntaxeMode, root.reviewExtraInstructions)
      } else {
        prompt = CodeReview.buildCodeReviewPrompt(root.reviewSrcPath, root.reviewOutPath, root.reviewLogPath, root.reviewExtraInstructions)
      }
      reviewProc.command = CodeReview.buildCommand(prompt, root.claudeModel, root.claudeEffort)
      reviewProc.workingDirectory = root._pendingReviewRunDir
      reviewProc.running = false
      reviewProc.running = true
    }
  }

  Process {
    id: reviewProc
    // --output-format stream-json (requires --verbose) emits one JSON
    // object per line as Claude works, rather than only at the very end —
    // parsed live here purely to drive reviewElapsedMs/reviewOutputTokens
    // above. Line-by-line via SplitParser, not StdioCollector.waitForEnd
    // like every other Process in this file: those all block until exit
    // by design (there's nothing to show mid-run), this one specifically
    // needs to react while still running.
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var evt = CodeReview.parseStreamEvent(line)
        if (!evt) return
        if (typeof evt.outputTokens === "number") root.reviewOutputTokens += evt.outputTokens
      }
    }
    stderr: StdioCollector { id: reviewStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.reviewing = false
      if (root._reviewCancelled) return // cancelCodeReview() already set the user-facing state
      if (exitCode !== 0) {
        root.reviewError = (reviewStderr.text || "").slice(0, 2000) || "Claude Code a échoué sans message d'erreur exploitable."
        return
      }
      reviewLogFile.path = root.reviewLogPath
      reviewLogFile.reload()
      reviewCorrectedFile.path = root.reviewOutPath
      reviewCorrectedFile.reload()
    }
  }

  FileView {
    id: reviewLogFile
    watchChanges: false
    printErrors: false
    onLoaded: { root.reviewLog = reviewLogFile.text(); root.reviewHasResult = true }
    onLoadFailed: root.reviewError = "Claude n'a pas produit de journal de modifications."
  }

  FileView {
    id: reviewCorrectedFile
    watchChanges: false
    printErrors: false
    onLoaded: root._reviewCorrectedText = reviewCorrectedFile.text()
    onLoadFailed: root.reviewError = "Claude n'a pas produit de fichier corrigé."
  }

  // finalText is whatever currently sits in the Claude tab's editable
  // right-hand column — Claude's proposal as-is if Gabriel left it
  // untouched, or his own edit in place of a given proposed change
  // otherwise (per-change accept/override, his explicit spec).
  function applyReviewCorrection(finalText) {
    if (!finalText) return
    root.docText = finalText
    root.dirty = true
    root.reviewHasResult = false
    compileDebounce.restart()
  }

  // --- Antidote round trip (Antidote tab) -------------------------------
  //
  // No non-pro API exists for Antidote (confirmed with Gabriel — a pro
  // integration would need an email/approval cycle that doesn't fit a
  // personal tool), so this is the honest equivalent of what he described
  // its own connectors doing: hand the whole document to his own logged-in
  // session on antidote.app/correcteur (his real pro subscription, no
  // credentials of ours involved), then pull the corrected text back in
  // as an explicit, reviewed, whole-document replace — never a silent
  // partial merge. `wl-copy`/`wl-paste` (Wayland clipboard CLIs, already
  // relied on this session for interactive testing) do the actual
  // clipboard I/O; `chromium --app=` opens the correcteur as a minimal
  // app-style window (no tabs/URL bar) rather than a full browser tab —
  // Gabriel's own choice, specifically because he's already logged into
  // Antidote in Chromium (not his default browser, which is Zen).

  readonly property string antidoteUrl: "https://antidote.app/correcteur"
  readonly property string typstDocsUrl: "https://typst.app/docs/"
  readonly property string typstUniverseUrl: "https://typst.app/universe/"
  readonly property string antidoteDictionaryUrl: "https://antidote.app/dictionnaires/fr/definitions/FRUAgAAAABGUgCJYwEAiWMBAEQAAACKTm9tIHByb3ByZYhBbnRpZG90ZYCAgA%3D%3D3e4a/RlLvh7c5MTAxN%2B%2BHt05vbSBwcm9wcmU%3D/RlLvh7c5MTAxN%2B%2BHt05vbSBwcm9wcmXvh7dBbnRpZG90Ze%2BHt2FudGlkb3Rl"

  // --- generic webapp launcher --------------------------------------------
  //
  // `chromium --app=<url>` opens a minimal, tab/URL-bar-less window —
  // reused as-is by Aide (Typst Docs), the Typst Universe template picker,
  // and the Antidote dictionary button, all sharing this one Process
  // instead of each repeating the same two-line pattern antidoteOpenProc
  // established first.
  function openWebapp(url) {
    webappOpenProc.command = ["chromium", "--app=" + url]
    webappOpenProc.running = false
    webappOpenProc.running = true
  }

  Process { id: webappOpenProc }

  property bool antidoteSending: false
  property string antidoteSendError: ""
  property bool antidoteFetching: false
  property string antidoteFetchError: ""
  property bool antidoteHasPreview: false
  property string antidotePreviewText: ""

  function sendToAntidote() {
    if (root.antidoteSending || root.docText === "") return
    root.antidoteSending = true
    root.antidoteSendError = ""
    antidoteCopyProc.command = ["wl-copy", root.docText]
    antidoteCopyProc.running = false
    antidoteCopyProc.running = true
  }

  Process {
    id: antidoteCopyProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.antidoteSending = false
        root.antidoteSendError = "Échec de la copie dans le presse-papier."
        return
      }
      antidoteOpenProc.command = ["chromium", "--app=" + root.antidoteUrl]
      antidoteOpenProc.running = false
      antidoteOpenProc.running = true
    }
  }

  Process {
    id: antidoteOpenProc
    onExited: function(exitCode) {
      root.antidoteSending = false
      if (exitCode !== 0) root.antidoteSendError = "Le document est copié, mais l'ouverture du navigateur a échoué."
    }
  }

  function fetchAntidoteClipboard() {
    if (root.antidoteFetching) return
    root.antidoteFetching = true
    root.antidoteFetchError = ""
    antidotePasteProc.running = false
    antidotePasteProc.running = true
  }

  Process {
    id: antidotePasteProc
    command: ["wl-paste", "--no-newline"]
    stdout: StdioCollector { id: antidotePasteStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.antidoteFetching = false
      if (exitCode !== 0 || !antidotePasteStdout.text) {
        root.antidoteFetchError = "Presse-papier vide ou illisible."
        return
      }
      root.antidotePreviewText = antidotePasteStdout.text
      root.antidoteHasPreview = true
    }
  }

  function applyAntidoteCorrection() {
    if (!root.antidotePreviewText) return
    root.docText = root.antidotePreviewText
    root.dirty = true
    root.antidoteHasPreview = false
    compileDebounce.restart()
    root.scheduleSessionSave()
  }

  // --- local system spellcheck (Éditeur tab) -----------------------------
  //
  // hunspell, offline, no Claude — Gabriel's explicit ask, 2026-08-29,
  // separate from and much cheaper than the Claude "orthographe" review
  // tool. Two-phase design (see lib/Spellcheck.js's own header comment
  // for the full story, including a real 32s-vs-53ms benchmark that
  // drove it): a cheap live detection pass on every edit (tokenize
  // ourselves, hunspell -l on the unique words only, no offsets/
  // suggestions from hunspell at all — positions come from our own
  // tokenize() call), and suggestions fetched one word at a time, only
  // when EditorTab.qml's right-click menu actually needs them.

  property bool spellcheckAvailable: false
  property string spellcheckDict: ""
  property var misspelledWords: [] // [{word,start,end}] — current detection result

  property bool _spellcheckBusy: false
  property bool _spellcheckHasPending: false
  property string _spellcheckPendingText: ""
  property var _spellcheckTokens: [] // tokens from the text the in-flight/last detect pass actually ran against
  // Last content actually written to spellcheckWordsPath — tracked
  // ourselves rather than trusted to FileView, because FileView.setText()
  // with content identical to what's already on disk is a real,
  // previously-confirmed no-op in this plugin (see the autosave/preview
  // history elsewhere in this file): it never fires onSaved, so anything
  // relying on onSaved to kick off the next step silently never runs.
  // Detecting that case ourselves and calling the process directly
  // sidesteps it instead of hoping the words never repeat exactly.
  property string _spellcheckLastWordsInput: ""
  // Root cause of a real bug, found live: FileView.setText() is a no-op
  // (never fires onSaved) when the content written is byte-identical to
  // what's already on disk — true not only within one session (which
  // _spellcheckLastWordsInput above already guards) but ACROSS restarts
  // too, since these scratch files persist on disk between sessions. The
  // very first detect/suggest request of a fresh session can easily
  // match whatever a previous session already left in the same scratch
  // file (same document, same words) — confirmed live: detection never
  // fired at all on a fresh restart, because the words file already
  // held byte-identical content from the prior session. A per-launch
  // nonce prefixed onto every write guarantees the first write of a
  // session always actually differs from whatever was there before,
  // without weakening the in-session repeat-request guard at all.
  readonly property string _spellcheckSessionNonce: "__session_" + Date.now() + "__"

  Process {
    id: dictDiscoverProc
    command: Spellcheck.buildDiscoverCommand()
    // Confirmed live: hunspell -D writes its whole report to STDERR, not
    // stdout (stdout is empty, exit code 0) — easy to get backwards
    // without testing, since -D "looks like" a normal listing command.
    stderr: StdioCollector { id: dictDiscoverOut; waitForEnd: true }
    onExited: {
      root.spellcheckDict = Spellcheck.parseDiscoverOutput(dictDiscoverOut.text)
      root.spellcheckAvailable = root.spellcheckDict !== ""
    }
    Component.onCompleted: running = true
  }

  function requestSpellcheck(text) {
    if (!root.spellcheckAvailable) return
    if (root._spellcheckBusy) {
      // Queue-on-busy, not a forced Process restart — confirmed the only
      // reliable pattern for "a new request arrives while one's still in
      // flight" in this environment (Process.running's own timing can't
      // be trusted for this, see the file-tree saga in this plugin's own
      // memory). _spellcheckBusy is a plain flag this code sets/clears
      // itself, not derived from Process.running.
      root._spellcheckPendingText = text
      root._spellcheckHasPending = true
      return
    }
    root._runSpellcheck(text)
  }

  function _runSpellcheck(text) {
    root._spellcheckBusy = true
    var tokens = Spellcheck.tokenize(text)
    root._spellcheckTokens = tokens
    var words = Spellcheck.uniqueWords(tokens)
    if (words.length === 0) {
      root._spellcheckBusy = false
      root.misspelledWords = []
      root._spellcheckDrainPending()
      return
    }
    // The nonce word is harmless noise in hunspell's misspelled-word set
    // (it's gibberish, so it's always "misspelled") — it never matches
    // any real document token, so it just sits unused in that set. Its
    // only job is making this write's content impossible to collide with
    // whatever a previous session already left on disk.
    var input = Spellcheck.buildDetectInput([root._spellcheckSessionNonce].concat(words))
    if (input === root._spellcheckLastWordsInput) {
      root._startSpellcheckDetectProc()
    } else {
      root._spellcheckLastWordsInput = input
      spellcheckWordsFile.setText(input)
    }
  }

  function _startSpellcheckDetectProc() {
    spellcheckDetectProc.command = Spellcheck.buildDetectCommand(root.spellcheckDict).concat([root.spellcheckWordsPath])
    spellcheckDetectProc.running = false
    spellcheckDetectProc.running = true
  }

  FileView {
    id: spellcheckWordsFile
    path: root.spellcheckWordsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root._startSpellcheckDetectProc()
  }

  Process {
    id: spellcheckDetectProc
    stdout: StdioCollector { id: spellcheckDetectOut; waitForEnd: true }
    onExited: {
      var misspelled = Spellcheck.parseDetectOutput(spellcheckDetectOut.text)
      var flagged = []
      for (var i = 0; i < root._spellcheckTokens.length; i++) {
        var t = root._spellcheckTokens[i]
        if (misspelled[t.word]) flagged.push(t)
      }
      root.misspelledWords = flagged
      root._spellcheckBusy = false
      root._spellcheckDrainPending()
    }
  }

  function _spellcheckDrainPending() {
    if (!root._spellcheckHasPending) return
    root._spellcheckHasPending = false
    var text = root._spellcheckPendingText
    root._spellcheckPendingText = ""
    root._runSpellcheck(text)
  }

  // On-demand suggestions for one flagged word (EditorTab.qml's
  // right-click menu). suggestWord/suggestReady form the "which word is
  // this for" handshake the UI uses to know when a fresh result has
  // actually landed, since the menu can be reopened for a different word
  // before an earlier query finishes.
  property string suggestWord: ""
  property var suggestions: []
  property bool suggestBusy: false
  // Same no-op-write guard as _spellcheckLastWordsInput above — right-
  // clicking the same misspelled word twice in a row (a completely
  // ordinary thing to do, e.g. reconsidering after the menu closed)
  // writes byte-identical content the second time, which FileView never
  // reports as onSaved. Confirmed live, not just reasoned about: the
  // menu hung on "Recherche de suggestions…" forever on a same-word
  // re-click before this fix.
  property string _lastSuggestInput: ""

  function requestSuggestions(word) {
    root.suggestWord = word
    root.suggestions = []
    root.suggestBusy = true
    // Nonce appended as a second, trailing line — Spellcheck.
    // parseSuggestOutput only ever reads the FIRST &/# result line it
    // finds (the real word's, processed first since it's line 1), so
    // the nonce's own result is never even reached. Same cross-session
    // disk-collision fix as _runSpellcheck's own nonce above, just
    // appended instead of prepended to keep the word being queried on
    // the first line.
    var input = Spellcheck.buildSuggestInput(word) + "^" + root._spellcheckSessionNonce + "\n"
    if (input === root._lastSuggestInput) {
      root._startSuggestProc()
    } else {
      root._lastSuggestInput = input
      spellcheckSuggestFile.setText(input)
    }
  }

  function _startSuggestProc() {
    spellcheckSuggestProc.command = Spellcheck.buildSuggestCommand(root.spellcheckDict).concat([root.spellcheckSuggestPath])
    spellcheckSuggestProc.running = false
    spellcheckSuggestProc.running = true
  }

  FileView {
    id: spellcheckSuggestFile
    path: root.spellcheckSuggestPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root._startSuggestProc()
  }

  Process {
    id: spellcheckSuggestProc
    stdout: StdioCollector { id: spellcheckSuggestOut; waitForEnd: true }
    onExited: {
      root.suggestions = Spellcheck.parseSuggestOutput(spellcheckSuggestOut.text)
      root.suggestBusy = false
    }
  }

  function applySuggestion(start, end, replacement) {
    var t = root.docText
    if (start < 0 || end > t.length || start >= end) return
    var newText = t.slice(0, start) + replacement + t.slice(end)
    root.onTextEdited(newText)
    root.requestSpellcheck(newText) // don't wait for the next debounce to clear this word's underline
  }

  // --- file tree panel (complements the typed-path bar, doesn't replace
  // it) ----------------------------------------------------------------
  //
  // Listing lives here, not in EditorTab, for the same reason the compile
  // and review pipelines do: Panel.qml owns file I/O, tabs stay reachable
  // only through plain props/signals. `ls -1p` (one entry per line,
  // trailing "/" marks directories) rather than a shell-parsed `ls -la`
  // dump — no JSON, no locale-dependent column layout to fight, and
  // passed as its own Process argv element (never through `bash -c`), so
  // a path containing spaces or shell metacharacters is never
  // reinterpreted.

  // "" | "files" | "headings" — the left panel is a single slot shared by
  // the file tree and the heading outline, one at a time (Gabriel's
  // explicit choice, 2026-08-29, over showing both stacked). Clicking the
  // already-active one collapses the panel entirely, same as the old
  // plain on/off showFileTree toggle this replaces.
  property string leftPanelMode: "files"
  property string fileTreeDir: ""
  property var fileTreeEntries: [] // [{name, isDir}]
  property bool fileTreeUserNavigated: false
  // Heading outline (=, ==, ===...) — a plain reactive binding, not
  // debounced: node-benchmarked at ~0ms even on the 62KB stress document
  // (lib/Outline.js's own comment), unlike the gutter/diff/spellcheck
  // computations that needed a debounce or a time budget.
  readonly property var headings: Outline.parseHeadings(root.docText)

  function fileTreeHomeDir() {
    return root.docDir || root.homeDir
  }

  // Not restarted with the usual "running = false; running = true" reset
  // — Gabriel reported that after a few quick clicks navigating folders,
  // the tree goes empty and stays empty no matter what's clicked next.
  // Most likely cause: forcing a running Process to restart before it has
  // actually exited doesn't behave like a clean abort-and-relaunch here —
  // either the forced restart is silently dropped (leaving fileTreeProc
  // never running again for any later call, matching "stuck empty
  // forever"), or an in-flight process's onExited arrives *after* a newer
  // one's and clobbers correct results with stale/empty ones. Queuing
  // instead sidesteps both: a request arriving while one is already in
  // flight is remembered (only the latest matters) and only actually
  // launched once the current run's onExited fires, so fileTreeProc is
  // never told to restart while still running.
  //
  // 2026-08-28 correction: the first version of this queue checked
  // `fileTreeProc.running` directly to decide "is one already in flight",
  // and Gabriel confirmed live that the stuck-empty-forever symptom
  // survived that fix too — still happening after "quelques dossiers
  // ouverts et retours en arrière" (a few folders opened and backed out
  // of), just taking longer to hit than the rapid-click case did before.
  // Root cause: `Process.running` reading false is not reliably
  // synchronous with `onExited` actually firing in this environment (this
  // codebase's compile pipeline already worked around the same class of
  // issue elsewhere by always forcing `running = false` before `= true`,
  // which only implies the reverse read is equally untrustworthy) — so
  // draining the queue *from inside* onExited by calling refreshFileTree()
  // again could see `fileTreeProc.running` still reporting true, requeue
  // instead of actually running, and then nothing is left to ever drain
  // that requeued entry: no further Process run means no further
  // onExited, means the queue never gets checked again — a permanent
  // deadlock, not a race. Fixed by tracking busy state ourselves instead
  // of trusting the Process's own `running` property: `_fileTreeBusy` is
  // set true right before launching and explicitly set false as the very
  // first thing in onExited, before the queue-drain call — so that
  // recursive call always sees a definitely-false busy flag, no ambiguity
  // about Process-internal timing at all.
  property bool _fileTreeBusy: false
  property string _fileTreePendingDir: ""

  function refreshFileTree(dir) {
    if (!dir) return
    if (root._fileTreeBusy) {
      root._fileTreePendingDir = dir
      return
    }
    root._fileTreeBusy = true
    root.fileTreeDir = dir
    fileTreeProc.command = ["ls", "-1p", dir]
    fileTreeProc.running = true
  }

  function fileTreeNavigate(dir) {
    root.fileTreeUserNavigated = true
    root.refreshFileTree(dir)
  }

  function fileTreeOpenEntry(name, isDir) {
    var base = root.fileTreeDir.charAt(root.fileTreeDir.length - 1) === "/" ? root.fileTreeDir : root.fileTreeDir + "/"
    var full = base + name
    if (isDir) root.fileTreeNavigate(full)
    else root.requestDiscardAndThen(function() { root.openDocument(full) })
  }

  function fileTreeGoUp() {
    var d = root.fileTreeDir.replace(/\/+$/, "")
    if (d === "" || d === "/") return
    var idx = d.lastIndexOf("/")
    root.fileTreeNavigate(idx <= 0 ? "/" : d.slice(0, idx))
  }

  function fileTreeGoHome() {
    root.fileTreeUserNavigated = false
    root.refreshFileTree(root.fileTreeHomeDir())
  }

  Process {
    id: fileTreeProc
    stdout: StdioCollector { id: fileTreeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root._fileTreeBusy = false
      if (exitCode !== 0) {
        root.fileTreeEntries = []
      } else {
        var lines = (fileTreeStdout.text || "").split("\n").filter(function(l) { return l.length > 0 })
        var dirs = []
        var files = []
        for (var i = 0; i < lines.length; i++) {
          var l = lines[i]
          if (l.charAt(l.length - 1) === "/") dirs.push(l.slice(0, -1))
          // Directories always shown regardless of contents — need to
          // browse through them to find a .typ file possibly nested inside.
          // Files filtered to .typ only, per Gabriel's request: this is a
          // Typst editor, not a general file manager.
          else if (/\.typ$/i.test(l)) files.push(l)
        }
        dirs.sort(function(a, b) { return a.localeCompare(b) })
        files.sort(function(a, b) { return a.localeCompare(b) })
        var entries = []
        for (var d = 0; d < dirs.length; d++) entries.push({ name: dirs[d], isDir: true })
        for (var f = 0; f < files.length; f++) entries.push({ name: files[f], isDir: false })
        root.fileTreeEntries = entries
      }
      // Drain the queue — a click (or several) that arrived while this
      // run was still in flight. Only the most recent one is kept, so a
      // burst of rapid navigation settles on wherever the user ended up,
      // not every intermediate stop.
      if (root._fileTreePendingDir) {
        var next = root._fileTreePendingDir
        root._fileTreePendingDir = ""
        root.refreshFileTree(next)
      }
    }
  }

  // Follows the open document's directory until the user explicitly
  // navigates the tree elsewhere — after that, respects their choice
  // rather than yanking them back on every file open.
  onDocPathChanged: {
    if (!root.fileTreeUserNavigated && root.docPath) root.refreshFileTree(root.docDir)
  }

  // --- settings (Paramètres tab) + auto-save -----------------------------

  readonly property string settingsPath: stateDir + "/settings.json"
  property bool settingsLoaded: false
  property bool autosaveEnabled: true
  property int autosaveMinutes: 5
  property real editorZoom: 1.0
  property bool previewEnabled: true
  property bool lineNumbersEnabled: true
  property bool narrowMarginsEnabled: false
  property bool rightPaneHidden: false
  property string journalDir: ""
  property string claudeModel: "" // "" | "sonnet" | "opus" | "haiku" | "fable" — "" = claude -p's own default
  property string claudeEffort: "" // "" | "low" | "medium" | "high" | "xhigh" | "max"

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettings(settingsFile.text())
    onLoadFailed: root.loadSettings("")
  }

  function loadSettings(text) {
    var parsed = Store.parseSettings(text)
    root.autosaveEnabled = parsed.autosaveEnabled
    root.autosaveMinutes = parsed.autosaveMinutes
    root.editorZoom = parsed.editorZoom
    root.previewEnabled = parsed.previewEnabled
    root.lineNumbersEnabled = parsed.lineNumbersEnabled
    root.narrowMarginsEnabled = parsed.narrowMarginsEnabled
    root.rightPaneHidden = parsed.rightPaneHidden
    root.journalDir = parsed.journalDir
    root.claudeModel = parsed.claudeModel
    root.claudeEffort = parsed.claudeEffort
    root.settingsLoaded = true
  }

  Timer {
    id: settingsSaveDebounce
    interval: 300
    repeat: false
    onTriggered: settingsFile.setText(Store.serializeSettings({
      autosaveEnabled: root.autosaveEnabled,
      autosaveMinutes: root.autosaveMinutes,
      editorZoom: root.editorZoom,
      previewEnabled: root.previewEnabled,
      lineNumbersEnabled: root.lineNumbersEnabled,
      narrowMarginsEnabled: root.narrowMarginsEnabled,
      rightPaneHidden: root.rightPaneHidden,
      journalDir: root.journalDir,
      claudeModel: root.claudeModel,
      claudeEffort: root.claudeEffort
    }))
  }

  function scheduleSettingsSave() {
    if (root.settingsLoaded) settingsSaveDebounce.restart()
  }

  function setAutosaveEnabled(enabled) {
    root.autosaveEnabled = enabled
    root.scheduleSettingsSave()
  }

  function setAutosaveMinutes(minutes) {
    root.autosaveMinutes = Math.max(1, Math.min(60, Math.round(minutes)))
    root.scheduleSettingsSave()
  }

  function setEditorZoom(zoom) {
    root.editorZoom = Math.max(0.6, Math.min(2.5, Math.round(zoom * 10) / 10))
    root.scheduleSettingsSave()
  }

  function setPreviewEnabled(enabled) {
    root.previewEnabled = enabled
    root.scheduleSettingsSave()
    // Re-enabling with no pending edit debounce in flight would otherwise
    // leave the last-known preview showing (stale, possibly from before
    // the toggle was flipped off) until the next actual keystroke.
    if (enabled && root.docText !== "") root.scheduleCompile()
  }

  function setLineNumbersEnabled(enabled) {
    root.lineNumbersEnabled = enabled
    root.scheduleSettingsSave()
  }

  function setNarrowMarginsEnabled(enabled) {
    root.narrowMarginsEnabled = enabled
    root.scheduleSettingsSave()
  }

  function setRightPaneHidden(hidden) {
    root.rightPaneHidden = hidden
    root.scheduleSettingsSave()
  }

  function setJournalDir(dir) {
    root.journalDir = dir
    root.scheduleSettingsSave()
  }

  function setClaudeModel(model) {
    root.claudeModel = model
    root.scheduleSettingsSave()
  }

  function setClaudeEffort(effort) {
    root.claudeEffort = effort
    root.scheduleSettingsSave()
  }

  // Only writes to disk when there's actually a path — an untitled
  // document has nowhere to auto-save *to* and is already covered
  // continuously by session persistence above, independent of this timer.
  Timer {
    id: autosaveTimer
    interval: root.autosaveMinutes * 60000
    running: root.autosaveEnabled
    repeat: true
    onTriggered: {
      if (root.dirty && root.docPath) root.saveDocument()
    }
  }

  // --- PDF export ---------------------------------------------------------

  property bool exportingPdf: false
  property string pdfExportError: ""
  property string pdfExportedPath: ""
  property string _pendingPdfPath: ""

  readonly property string pdfExportSrcPath: root.previewDir + "/.ghtypst-pdf-export.typ"

  function pdfPathFor(srcPath) {
    var m = srcPath.match(/\.[^./]+$/)
    return (m ? srcPath.slice(0, -m[0].length) : srcPath) + ".pdf"
  }

  function exportPdf() {
    if (root.exportingPdf || root.docText === "") return
    if (root.docPath) root.startPdfExport(root.pdfPathFor(root.docPath))
    else root.beginPathEntry("exportPdf", "")
  }

  function startPdfExport(destPath) {
    root._pendingPdfPath = destPath
    root.exportingPdf = true
    root.pdfExportError = ""
    root.pdfExportedPath = ""
    pdfExportSrcFile.setText(root.docText)
  }

  FileView {
    id: pdfExportSrcFile
    path: root.pdfExportSrcPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: {
      pdfExportProc.command = ["typst", "compile", "--root", root.previewDir, root.pdfExportSrcPath, root._pendingPdfPath]
      pdfExportProc.running = false
      pdfExportProc.running = true
    }
  }

  Process {
    id: pdfExportProc
    stderr: StdioCollector { id: pdfExportStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.exportingPdf = false
      if (exitCode !== 0) {
        root.pdfExportError = (pdfExportStderr.text || "Échec de l'export PDF.").slice(0, 500)
        return
      }
      root.pdfExportedPath = root._pendingPdfPath
    }
  }

  // ---------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: root.windowTitle()
    color: root.bg
    // Explicit, not incidental: `keepLoaded: true` in the manifest means
    // this whole Item — including this FloatingWindow — is instantiated
    // the moment the shell starts, not on first summon. A Quickshell
    // window's `visible` defaults to true, so without this line GH Typst
    // popped up unasked on every shell restart (confirmed live
    // 2026-08-27, same class of bug Gabriel remembered from an old
    // French-dictionary experiment). `root.open()` is the only thing that
    // should ever flip this true.
    visible: false
    implicitWidth: Style.space(1100)
    implicitHeight: Style.space(760)
    minimumSize: Qt.size(Style.space(700), Style.space(500))

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("io.github.gabrielharfield.ghtypst")
    }

    // Belt-and-suspenders opaque backdrop: `color: root.bg` above should be
    // enough on its own, but the window rendered with the desktop faintly
    // visible through the whole body area until this was added (same fix
    // GH Hub's PanelWindow needed for the same reason — an explicit filled
    // Rectangle, not just the window's own `color`, is what reliably paints
    // opaque in this environment).
    Rectangle {
      anchors.fill: parent
      color: root.bg
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.showCloseConfirm && closeConfirmDialog.handleKey(event)) event.accepted = true
        else if (root.showDiscardConfirm && discardConfirmDialog.handleKey(event)) event.accepted = true
        else if (root.tab === "editor" && event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)) {
          editorTabItem.toggleFindBar()
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(16)
        spacing: Style.space(10)

        // ------------------------------------------------------- header
        Item {
          width: parent.width
          height: Math.max(headerTitle.implicitHeight, toolbarRow.implicitHeight)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(14)

            Text {
              id: headerTitle
              anchors.verticalCenter: parent.verticalCenter
              text: root.windowTitle()
              color: root.fg
              font.family: root.uiFont
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Button {
                iconText: ""
                text: "Éditeur"
                selected: root.tab === "editor"
                foreground: root.fg
                accent: root.accentColor
                onClicked: root.tab = "editor"
              }
              Button {
                iconText: ""
                text: "Révision"
                selected: root.tab === "revision"
                foreground: root.fg
                accent: root.accentColor
                onClicked: root.tab = "revision"
              }
              Button {
                iconText: ""
                text: "Paramètres"
                selected: root.tab === "settings"
                foreground: root.fg
                accent: root.accentColor
                onClicked: root.tab = "settings"
              }
              Button {
                iconText: ""
                text: "Aide"
                foreground: root.fg
                accent: root.accentColor
                onClicked: root.openWebapp(root.typstDocsUrl)
              }
            }
          }

          Row {
            id: toolbarRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Button {
              iconText: ""
              text: "Nouveau"
              foreground: root.fg
              accent: root.accentColor
              onClicked: root.requestDiscardAndThen(root.newDocument)
            }
            Button {
              iconText: ""
              text: "Ouvrir"
              foreground: root.fg
              accent: root.accentColor
              onClicked: root.beginPathEntry("open", root.docPath)
            }
            Button {
              iconText: ""
              text: "Enregistrer"
              foreground: root.fg
              accent: root.accentColor
              onClicked: root.saveDocument()
            }
            Button {
              iconText: ""
              text: "Enregistrer sous…"
              foreground: root.fg
              accent: root.accentColor
              onClicked: root.beginPathEntry("saveAs", root.docPath)
            }
            Button {
              iconText: ""
              text: root.exportingPdf ? "Export…" : "Export PDF"
              foreground: root.fg
              accent: root.accentColor
              enabled: !root.exportingPdf && root.docText !== ""
              onClicked: root.exportPdf()
            }
          }
        }

        Text {
          visible: root.pdfExportError !== "" || root.pdfExportedPath !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.pdfExportError !== "" ? root.pdfExportError : ("PDF exporté : " + root.pdfExportedPath)
          color: root.pdfExportError !== "" ? root.urgentColor : root.dim
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Row {
          visible: root.pathBarMode !== ""
          width: parent.width
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.pathBarMode === "open" ? "Chemin à ouvrir :"
              : root.pathBarMode === "saveAs" ? "Enregistrer sous :"
              : "Exporter le PDF vers :"
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: pathBarField
            width: parent.width - Style.space(260)
            anchors.verticalCenter: parent.verticalCenter
            // Reactive, not one-shot: this Item is created once at
            // startup and only ever toggles `visible` afterward, so a
            // Component.onCompleted grab would fire just that first time
            // and never again on subsequent Ouvrir/Enregistrer-sous
            // clicks. Binding `focus` to the same condition re-grabs it
            // every time the bar reappears.
            focus: root.pathBarMode !== ""
            Keys.onReturnPressed: root.confirmPathEntry()
            Keys.onEnterPressed: root.confirmPathEntry()
            Keys.onEscapePressed: root.cancelPathEntry()
          }

          Button {
            text: "Confirmer"
            bordered: true
            foreground: root.fg
            accent: root.accentColor
            onClicked: root.confirmPathEntry()
          }
          Button {
            text: "Annuler"
            bordered: true
            foreground: root.fg
            accent: root.accentColor
            onClicked: root.cancelPathEntry()
          }
        }

        PanelSeparator { foreground: root.fg; width: parent.width }

        // -------------------------------------------------------- body
        Item {
          width: parent.width
          // Style.space(60): pre-existing budget for the header/pdf-status/
          // path-bar rows above. docTabBarRow.implicitHeight + Style.space(10):
          // room for the new open-documents tab bar below, plus the extra
          // Column spacing gap it introduces.
          height: parent.height - Style.space(60) - docTabBarRow.implicitHeight - Style.space(10)

          Item {
            id: editorBody
            anchors.fill: parent
            visible: root.tab === "editor"

            Rectangle {
              id: fileTreePanel
              visible: root.leftPanelMode === "files"
              width: Style.space(280)
              height: parent.height
              color: Qt.darker(root.bg, 1.05)
              border.color: root.faint
              border.width: 1
              radius: Style.cornerRadius
              clip: true

              Column {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  spacing: Style.space(4)

                  Button {
                    text: "⬆"
                    tooltipText: "Dossier parent"
                    foreground: root.fg
                    accent: root.accentColor
                    onClicked: root.fileTreeGoUp()
                  }
                  Button {
                    iconText: ""
                    tooltipText: "Dossier du document"
                    foreground: root.fg
                    accent: root.accentColor
                    onClicked: root.fileTreeGoHome()
                  }
                }

                Text {
                  width: parent.width
                  text: root.fileBaseName(root.fileTreeDir) || root.fileTreeDir
                  elide: Text.ElideMiddle
                  color: root.dim
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }

                PanelSeparator { foreground: root.fg; width: parent.width }

                // A real ListView, not Repeater-inside-Column-inside-
                // ScrollView — that composition relied on the Column's
                // implicitHeight propagating up through ScrollView's
                // auto-created Flickable every time root.fileTreeEntries
                // was replaced wholesale (a fresh array on every
                // navigation, not an incremental update), and Gabriel
                // confirmed live 2026-08-28 that after a few navigations
                // the list stopped rendering entirely — dir name and
                // up/home navigation both kept working correctly (proving
                // the data pipeline itself was fine), only the visible
                // list broke, which points at exactly this kind of
                // implicit-size-not-propagating gap rather than a data
                // bug. ListView computes and owns its own contentHeight
                // directly from its delegates — no wrapping, no implicit-
                // size relay to get stale.
                ListView {
                  id: fileTreeList
                  width: parent.width
                  height: parent.height - Style.space(70)
                  clip: true
                  model: root.fileTreeEntries
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  delegate: Item {
                    required property var modelData
                    width: fileTreeList.width
                    height: entryText.implicitHeight + Style.space(6)

                    Text {
                      id: entryText
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      text: (modelData.isDir ? "📁 " : "📄 ") + modelData.name
                      color: root.fg
                      font.family: root.uiFont
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                      width: parent.width
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.fileTreeOpenEntry(modelData.name, modelData.isDir)
                    }
                  }
                }
              }
            }

            // Heading outline (=, ==, ===...) — same panel slot and
            // visual style as the file tree, shown instead of it
            // (leftPanelMode is one of the two, never both — Gabriel's
            // explicit choice). Click-to-jump reuses editorTabItem's own
            // jumpToLine(), the same line-to-offset mechanism the
            // compiler-error list already relies on.
            Rectangle {
              id: headingsPanel
              visible: root.leftPanelMode === "headings"
              width: Style.space(280)
              height: parent.height
              color: Qt.darker(root.bg, 1.05)
              border.color: root.faint
              border.width: 1
              radius: Style.cornerRadius
              clip: true

              Column {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  text: "Titres du document"
                  color: root.dim
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }

                PanelSeparator { foreground: root.fg; width: parent.width }

                Text {
                  visible: root.headings.length === 0
                  width: parent.width
                  text: "Aucun titre (=, ==, ===...) dans ce document."
                  color: root.faint
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }

                ListView {
                  id: headingsList
                  width: parent.width
                  height: parent.height - Style.space(40)
                  clip: true
                  visible: root.headings.length > 0
                  model: root.headings
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  delegate: Item {
                    required property var modelData
                    width: headingsList.width
                    height: headingText.implicitHeight + Style.space(6)

                    Text {
                      id: headingText
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(14) * (modelData.level - 1)
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.title
                      color: modelData.level === 1 ? root.fg : root.dim
                      font.family: root.uiFont
                      font.bold: modelData.level === 1
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: editorTabItem.jumpToLine(modelData.line)
                    }
                  }
                }
              }
            }

            EditorTab {
              id: editorTabItem
              anchors.left: parent.left
              anchors.leftMargin: root.leftPanelMode !== "" ? (Style.space(280) + Style.space(10)) : 0
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              text: root.docText
              errors: root.compileErrors
              compiling: root.compiling
              previewSources: root.previewSources
              foreground: root.fg
              background: root.bg
              dim: root.dim
              faint: root.faint
              accentColor: root.accentColor
              urgentColor: root.urgentColor
              warningColor: root.warningColor
              notesColor: root.notesColor
              uiFont: root.uiFont
              zoom: root.editorZoom
              previewEnabled: root.previewEnabled
              lineNumbersEnabled: root.lineNumbersEnabled
              narrowMarginsEnabled: root.narrowMarginsEnabled
              rightPaneHidden: root.rightPaneHidden
              spellcheckAvailable: root.spellcheckAvailable
              misspelledWords: root.misspelledWords
              suggestWord: root.suggestWord
              suggestions: root.suggestions
              suggestBusy: root.suggestBusy
              rightPaneView: root.rightPaneView
              notesText: root.notesText
              notesAvailable: root.docPath !== ""
              leftPanelMode: root.leftPanelMode
              journalDir: root.journalDir
              journalViewYear: root.journalViewYear
              journalViewMonth: root.journalViewMonth
              journalSelectedYear: root.journalSelectedYear
              journalSelectedMonth: root.journalSelectedMonth
              journalSelectedDay: root.journalSelectedDay
              journalText: root.journalText
              journalEntryDays: root.journalEntryDays
              onTextEdited: function(newText) { root.onTextEdited(newText) }
              onZoomInRequested: root.setEditorZoom(root.editorZoom + 0.1)
              onZoomOutRequested: root.setEditorZoom(root.editorZoom - 0.1)
              onPreviewToggleRequested: root.setPreviewEnabled(!root.previewEnabled)
              onLineNumbersToggleRequested: root.setLineNumbersEnabled(!root.lineNumbersEnabled)
              onNarrowMarginsToggleRequested: root.setNarrowMarginsEnabled(!root.narrowMarginsEnabled)
              onRightPaneHiddenToggleRequested: root.setRightPaneHidden(!root.rightPaneHidden)
              onSpellcheckRequested: function(text) { root.requestSpellcheck(text) }
              onSuggestRequested: function(word) { root.requestSuggestions(word) }
              onApplySuggestionRequested: function(start, end, replacement) { root.applySuggestion(start, end, replacement) }
              onRightPaneViewRequested: function(view) { root.rightPaneView = view }
              onNotesEdited: function(newText) { root.onNotesEdited(newText) }
              onLeftPanelModeRequested: function(mode) { root.leftPanelMode = (root.leftPanelMode === mode) ? "" : mode }
              onJournalPrevMonthRequested: root.journalPrevMonth()
              onJournalNextMonthRequested: root.journalNextMonth()
              onJournalDaySelected: function(day) { root.journalSelectDay(day) }
              onJournalTextEdited: function(newText) { root.onJournalTextEdited(newText) }
            }
          }

          RevisionTab {
            anchors.fill: parent
            visible: root.tab === "revision"
            antidoteSending: root.antidoteSending
            antidoteSendError: root.antidoteSendError
            antidoteHasPreview: root.antidoteHasPreview
            antidotePreviewText: root.antidotePreviewText
            antidoteFetching: root.antidoteFetching
            antidoteFetchError: root.antidoteFetchError
            reviewing: root.reviewing
            reviewKind: root.reviewKind
            hasResult: root.reviewHasResult
            reviewLog: root.reviewLog
            reviewError: root.reviewError
            reviewOriginalText: root.reviewOriginalText
            reviewCorrectedText: root._reviewCorrectedText
            reviewElapsedMs: root.reviewElapsedMs
            reviewOutputTokens: root.reviewOutputTokens
            claudeModel: root.claudeModel
            claudeEffort: root.claudeEffort
            docEmpty: root.docText === ""
            foreground: root.fg
            dim: root.dim
            faint: root.faint
            accentColor: root.accentColor
            urgentColor: root.urgentColor
            uiFont: root.uiFont
            onSendRequested: root.sendToAntidote()
            onFetchRequested: root.fetchAntidoteClipboard()
            onAntidoteApplyRequested: root.applyAntidoteCorrection()
            onAntidoteDictionaryRequested: root.openWebapp(root.antidoteDictionaryUrl)
            onReviewRequested: function(kind, mode, extra) { root.startCodeReview(kind, mode, extra) }
            onApplyRequested: function(finalText) { root.applyReviewCorrection(finalText) }
            onCancelRequested: root.cancelCodeReview()
            onClaudeModelSet: function(model) { root.setClaudeModel(model) }
            onClaudeEffortSet: function(effort) { root.setClaudeEffort(effort) }
          }

          SettingsTab {
            anchors.fill: parent
            visible: root.tab === "settings"
            autosaveEnabled: root.autosaveEnabled
            autosaveMinutes: root.autosaveMinutes
            foreground: root.fg
            dim: root.dim
            faint: root.faint
            accentColor: root.accentColor
            uiFont: root.uiFont
            journalDir: root.journalDir
            onAutosaveEnabledSet: function(enabled) { root.setAutosaveEnabled(enabled) }
            onAutosaveMinutesSet: function(minutes) { root.setAutosaveMinutes(minutes) }
            onTypstUniverseOpenRequested: root.openWebapp(root.typstUniverseUrl)
            onTemplateLinkOpenRequested: function(url) { root.openWebapp(url) }
            onTemplateInsertRequested: function(command) { root.insertTemplate(command) }
            onJournalDirSet: function(dir) { root.setJournalDir(dir) }
          }
        }

        // ------------------------------------------ open-documents tabs
        //
        // Bottom-left, visible across Éditeur/Révision/Paramètres alike —
        // Gabriel's own spec, 2026-08-29. "+" sits first, directly under
        // the file-tree panel's own left edge.
        Item {
          width: parent.width
          height: docTabBarRow.implicitHeight

          Row {
            id: docTabBarRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              iconText: ""
              tooltipText: root._tabSwitchBlocked
                ? "Termine ou annule la vérification/correction en cours avant d'ouvrir un nouvel onglet."
                : "Nouvel onglet"
              enabled: !root._tabSwitchBlocked
              foreground: root.fg
              accent: root.accentColor
              onClicked: root.addTab()
            }

            Repeater {
              model: root.displayedTabs

              Row {
                id: tabEntry
                required property var modelData
                readonly property bool isActive: modelData.id === root.activeDocId
                readonly property bool switchBlocked: root._tabSwitchBlocked && !isActive
                spacing: Style.space(2)

                Button {
                  text: root.tabTitle(tabEntry.modelData) + (tabEntry.modelData.dirty ? " •" : "")
                  selected: tabEntry.isActive
                  enabled: !tabEntry.switchBlocked
                  tooltipText: tabEntry.switchBlocked
                    ? "Termine ou annule la vérification/correction en cours avant de changer de document."
                    : (tabEntry.modelData.path || "Document sans titre")
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.switchToTab(tabEntry.modelData.id)
                }
                Button {
                  iconText: ""
                  tooltipText: "Fermer l'onglet"
                  enabled: tabEntry.isActive ? !root._tabSwitchBlocked : true
                  foreground: root.dim
                  accent: root.accentColor
                  onClicked: root.closeTab(tabEntry.modelData.id)
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: closeConfirmDialog
        anchors.fill: parent
        opened: root.showCloseConfirm
        message: "Ce document contient des modifications non enregistrées. Fermer quand même ?"
        cancelText: "Annuler"
        confirmText: "Fermer sans enregistrer"
        selectedIndex: 0
        background: root.bg
        foreground: root.fg
        onCanceled: root.showCloseConfirm = false
        onConfirmed: {
          root.showCloseConfirm = false
          root.close()
        }
      }

      ConfirmDialog {
        id: discardConfirmDialog
        anchors.fill: parent
        opened: root.showDiscardConfirm
        message: "Ce document contient des modifications non enregistrées. Continuer et les perdre ?"
        cancelText: "Annuler"
        confirmText: "Continuer sans enregistrer"
        selectedIndex: 0
        background: root.bg
        foreground: root.fg
        onCanceled: {
          root.showDiscardConfirm = false
          root._pendingDiscardAction = null
        }
        onConfirmed: {
          root.showDiscardConfirm = false
          var action = root._pendingDiscardAction
          root._pendingDiscardAction = null
          if (action) action()
        }
      }
    }
  }

}
