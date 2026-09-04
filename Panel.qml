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

  // Gabriel's explicit ask, 2026-08-30, after a real cross-machine
  // data-loss incident (see the "no session persistence, by design"
  // comment further down for the full story): closing this app must
  // forget whatever was open, ALWAYS, no exceptions — not just across a
  // shell restart, but on every ordinary close too, dirty or not. First
  // tried gating this on whether anything was genuinely unsaved (so nothing
  // was ever silently destroyed) — Gabriel explicitly rejected that
  // nuance too: "je ne veux aucune mémoire, jamais, de rien du tout... si
  // j'ai oublié de sauvegarder un fichier, c'est tant pis pour moi." So
  // this is now truly unconditional — an unsaved buffer left open when
  // the window closes is simply gone, full stop. The one remaining
  // safety net is requestClose()'s own confirm dialog (below), for the
  // one close path where intercepting it is technically possible at all.
  function _forgetEverythingOnClose() {
    root.tabs = [{ id: 1, path: "", text: "", dirty: false, notesText: "", rightPaneView: "apercu", loaded: false }]
    root._nextDocId = 2
    root.activeDocId = 1
    root.newDocument()
    root.notesText = ""
    editorTabItem.clearUndoHistory()
    root.errorLogWindowVisible = false
  }

  // The one gate every "the user wants to close this" path should go
  // through: if there's something unsaved, ask first instead of hiding
  // straight away. Known limitation, told to Gabriel directly rather than
  // silently shipped: Hyprland's own window-close keybind (Ctrl+W/Super+W,
  // his usual way of closing this plugin) kills the Wayland toplevel
  // directly and never reaches this QML at all — Quickshell's
  // FloatingWindow exposes no vetoable "closing" signal (checked its
  // .qmltypes, only `visible`/`visibleChanged`) — so this confirm dialog
  // only ever fires for closes that go through the shell's own IPC
  // (`hide`/`close`/`toggle`, e.g. from OmApp). Confirmed with Gabriel
  // directly, 2026-08-30: he accepts this gap as-is (a keybind-driven
  // close silently discards unsaved work, same as every other close now)
  // rather than wanting anything more elaborate here.
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
  readonly property string reviewsDir: stateDir + "/reviews"
  readonly property string recentFilesPath: stateDir + "/recent.json"
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
  property bool suppressDocLoad: false
  // Set while switching to an already-open tab (_loadTabIntoActive()), so
  // docFile's onLoaded/onLoadFailed know to reconcile against that tab's
  // cached buffer instead of doing a plain "adopt whatever's on disk"
  // open. NOT used for restoring across a restart anymore — see this
  // file's "no session persistence, by design" comment further down for
  // why that was removed entirely.
  property bool pendingRestore: false
  property string pendingRestoreBuffer: ""
  // Whether that tab's own buffer was actually dirty (real unsaved
  // edits) when it was last snapshotted away — see docFile.onLoaded's own
  // comment for why this matters: a clean buffer must never be allowed to
  // override newer disk content just because it happens to differ from
  // whatever's on disk now.
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
  property string rightPaneView: "apercu" // "apercu" | "notes" | "journal"
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

  // --- MultiDoc / Projet (left-panel "Projet" view) -----------------------
  //
  // Gabriel's idea, 2026-09-02, second round — an Ulysses-style workflow:
  // "Projet" (a third left-panel mode alongside Fichiers/Titres, see
  // leftPanelMode below and EditorTab.qml's own header-row buttons) holds
  // a staging list of other .typ files that get woven into THIS document's
  // compile output as generated #include lines — injected only into the
  // two shadow compile files this plugin already maintains for preview/PDF
  // export (previewSrcFile/pdfExportSrcFile further down and
  // startPdfExport()), never into docText itself. Back to this design
  // after briefly trying the opposite (auto-inserting real #include text
  // into docText) — Gabriel confirmed invisible/auto-synced is what he
  // actually wants for this workflow: the staging list drives the compiled
  // "manuscript" the way Ulysses' sheet list does, and free-form editing
  // of the actual .typ files happens by switching between the file-tree
  // entries, not by hand-managing #include lines. That does mean typst's
  // reported error line numbers land in the SHADOW file, offset by however
  // many prelude lines were prepended — compileProc.onExited corrects for
  // that before anything reaches jumpToError (see its own comment there).
  //
  // The staging list is persisted the same way notes are: a plain sidecar
  // next to the document, "<doc>.multidoc.json", entirely disk-driven
  // (multidocPaths is NOT cached in tabs[], same as notesText already
  // isn't — see _loadTabIntoActive's own comment on why: the sidecar
  // FileView's path is derived from docPath, so it reloads on its own the
  // instant docPath changes on a tab switch).
  readonly property string multidocPath: {
    if (!root.docPath) return ""
    var dot = root.docPath.lastIndexOf(".")
    var slash = root.docPath.lastIndexOf("/")
    var base = (dot > slash) ? root.docPath.slice(0, dot) : root.docPath
    return base + ".multidoc.json"
  }
  readonly property bool multidocAvailable: root.docPath !== ""
  property var multidocPaths: []

  FileView {
    id: multidocListFile
    path: root.multidocPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = null
      try { parsed = JSON.parse(multidocListFile.text() || "[]") } catch (e) { parsed = null }
      root.multidocPaths = (parsed instanceof Array) ? parsed : []
    }
    onLoadFailed: root.multidocPaths = [] // no MultiDoc list for this document yet — not an error
  }

  Timer {
    id: multidocSaveDebounce
    interval: 500
    repeat: false
    onTriggered: if (root.docPath) multidocListFile.setText(JSON.stringify(root.multidocPaths))
  }

  // Every mutator below reassigns root.multidocPaths to a brand-new array
  // rather than mutating in place — required for the property-change
  // notification EditorTab.qml's Repeater relies on to redraw the list at
  // all (see EditorTab.qml's own comment on its MultiDoc row delegate for
  // why that's also fine UX-wise despite rebuilding every row).
  function multidocAdd() {
    if (!root.multidocAvailable) return
    root.multidocPaths = root.multidocPaths.concat([""])
    multidocSaveDebounce.restart()
  }

  function multidocRemove(index) {
    if (index < 0 || index >= root.multidocPaths.length) return
    var next = root.multidocPaths.slice()
    next.splice(index, 1)
    root.multidocPaths = next
    multidocSaveDebounce.restart()
  }

  function multidocPathEdited(index, newPath) {
    if (index < 0 || index >= root.multidocPaths.length) return
    var next = root.multidocPaths.slice()
    next[index] = newPath.trim()
    root.multidocPaths = next
    multidocSaveDebounce.restart()
  }

  // The Projet panel's row "eye" button (Gabriel's ask, 2026-09-02) —
  // opens that staged file in a fresh tab so he can look at/edit it
  // directly, same addTab()-then-load sequencing insertTemplate() already
  // uses elsewhere in this file.
  // Also used directly by the Projet panel's maître.typ/lib.typ head
  // buttons below, not just the per-row eye button.
  function openPathInNewTab(path) {
    if (!path || root._tabSwitchBlocked) return
    root.addTab()
    root.openDocument(path)
  }

  function multidocOpenInNewTab(index) {
    if (index < 0 || index >= root.multidocPaths.length) return
    var p = root.multidocPaths[index]
    if (!p || p.charAt(0) !== "/") return
    root.openPathInNewTab(p)
  }

  // Row display, Gabriel's ask 2026-09-02: a committed row shows just the
  // filename (matching tabTitle()'s own fileBaseName() convention
  // elsewhere in this file), not the full absolute path — friendlier to
  // scan once a project has more than a couple of chapters. An empty or
  // malformed row (no leading "/") is left as-is so the placeholder text
  // still shows through.
  function multidocDisplayName(path) {
    if (!path || path.charAt(0) !== "/") return path || ""
    return root.fileBaseName(path)
  }

  function multidocReordered(fromIndex, toIndex) {
    if (fromIndex === toIndex) return
    if (fromIndex < 0 || fromIndex >= root.multidocPaths.length) return
    if (toIndex < 0 || toIndex >= root.multidocPaths.length) return
    var next = root.multidocPaths.slice()
    var moved = next.splice(fromIndex, 1)[0]
    next.splice(toIndex, 0, moved)
    root.multidocPaths = next
    multidocSaveDebounce.restart()
  }

  // Lowest common ancestor of two absolute directory paths (no trailing
  // slash on either, except the root "/" itself) — used below to compute
  // how far the typst --root needs to widen to cover every MultiDoc entry.
  function _commonAncestorDir(a, b) {
    var as = a.split("/")
    var bs = b.split("/")
    var out = []
    for (var i = 0; i < as.length && i < bs.length; i++) {
      if (as[i] !== bs[i]) break
      out.push(as[i])
    }
    var result = out.join("/")
    return result === "" ? "/" : result
  }

  // typst resolves a relative #include path against the FILE that contains
  // it, not against --root — --root only gates which files are reachable
  // at all. So the generated #include lines stay relative to docDir (exactly
  // like a hand-written one would be), and only the compiler's --root needs
  // widening to cover paths outside docDir. See _multidocEffectiveRoot().
  function _relativePath(fromDir, toPath) {
    var fromParts = fromDir.split("/").filter(function(s) { return s !== "" })
    var toParts = toPath.split("/").filter(function(s) { return s !== "" })
    var i = 0
    while (i < fromParts.length && i < toParts.length && fromParts[i] === toParts[i]) i++
    var ups = fromParts.length - i
    var segs = []
    for (var k = 0; k < ups; k++) segs.push("..")
    return segs.concat(toParts.slice(i)).join("/")
  }

  // The --root actually passed to `typst compile` for both the live
  // preview and PDF export — widened to cover every valid MultiDoc entry
  // when there are any, otherwise identical to the old always-docDir
  // behavior (previewDir), so a document with no MultiDoc list compiles
  // exactly as before this feature existed.
  function _multidocEffectiveRoot() {
    var base = root.previewDir
    if (!base) return base
    var validPaths = (root.multidocPaths || []).filter(function(p) { return p && p.charAt(0) === "/" })
    var ancestor = base
    for (var i = 0; i < validPaths.length; i++) {
      var dir = validPaths[i].slice(0, validPaths[i].lastIndexOf("/"))
      ancestor = root._commonAncestorDir(ancestor, dir === "" ? "/" : dir)
    }
    return ancestor
  }

  function _multidocIncludeLines() {
    if (!root.docDir) return []
    var out = []
    for (var i = 0; i < (root.multidocPaths || []).length; i++) {
      var p = root.multidocPaths[i]
      if (!p || p.charAt(0) !== "/") continue
      out.push('#include "' + root._relativePath(root.docDir, p).replace(/"/g, '\\"') + '"')
    }
    return out
  }

  // Marked so a curious `cat` of the shadow file (or a stray look at
  // pdfExportSrcPath) reads as obviously generated, not hand-written.
  readonly property string _multidocMarkerBegin: "// --- MultiDoc : inclusions générées, ne pas modifier ici ---"
  readonly property string _multidocMarkerEnd: "// --- fin MultiDoc ---"

  // Appended AFTER docText (not prepended before it) — Gabriel's bug
  // report, 2026-09-02: with the includes placed first, any config
  // maître.typ itself sets up (`#show: conf.with(...)`, in his real case)
  // only takes effect on content that comes AFTER it in the document, so
  // everything pulled in by MultiDoc was rendering under Typst's plain
  // defaults — no header/footer, no indent, numbered-text misplaced.
  // Appending instead means docText's own imports/show/set rules always
  // run first, then the staged files render under whatever configuration
  // maître.typ already established, exactly like maître.typ acting as a
  // shell that hands off to its chapters. Leading "\n" is defensive: keeps
  // the marker on its own line even if docText doesn't end in one.
  function _multidocAppendix() {
    var lines = root._multidocIncludeLines()
    if (lines.length === 0) return ""
    return "\n" + root._multidocMarkerBegin + "\n" + lines.join("\n") + "\n" + root._multidocMarkerEnd + "\n"
  }

  // Number of lines docText itself occupies at the front of the shadow
  // file — any compiler diagnostic landing beyond this line is inside the
  // appended MultiDoc block (or an included file), not in docText, so it
  // has no real-document line to point jumpToError() at (see
  // compileProc.onExited).
  function _docTextLineCount() {
    return root.docText === "" ? 0 : root.docText.split("\n").length
  }

  // --- Projet: "Créer un nouveau projet" scaffold -------------------------
  //
  // Gabriel's ask, 2026-09-02: a one-click starting point matching his own
  // teaching-document convention — a folder holding a maître.typ (imports
  // conf from lib.typ, right next to it, and applies it) and a lib.typ
  // (conf/indented/numbered-text, literal text he gave me verbatim). No
  // @local package involved at all — his first version of maître.typ tried
  // that and it broke: the package only ever existed inside Typesetter's
  // Flatpak sandbox, invisible to the system typst GH Typst calls, and
  // even once the import path itself was fixed, an #include'd chapter
  // still can't see identifiers the master document imported (Typst gives
  // each included file its own scope) — importing from a plain sibling
  // lib.typ sidesteps both problems by keeping everything local to the
  // project folder. maître.typ only imports `conf`: indented/numbered-text
  // only ever affect the specific body they're called on, so they belong
  // at whatever call site actually needs them (typically wrapping one
  // particular #include), not the default scaffold. Sequenced through
  // three Process/FileView steps (check → mkdir → write master → write
  // lib) because each depends on the previous one actually having
  // succeeded — see createNewProject() below for the guard against
  // silently overwriting an existing project.
  property string _pendingNewProjectDir: ""
  property string newProjectError: ""
  readonly property string _newProjectMasterPath: root._pendingNewProjectDir ? (root._pendingNewProjectDir + "/maître.typ") : ""
  readonly property string _newProjectLibPath: root._pendingNewProjectDir ? (root._pendingNewProjectDir + "/lib.typ") : ""

  // Imports lib.typ directly (not the @local/modele-general package) —
  // Gabriel's own correction, 2026-09-02, after the package proved to
  // only exist inside Typesetter's Flatpak sandbox, invisible to the
  // system typst GH Typst calls. Only `conf` is imported here (not
  // numbered-text/indented, his own second correction, same day): those
  // two only ever affect the specific body they're called on, so they
  // belong at the call site that actually needs them (typically wrapping
  // one particular #include from the Projet panel's staging list), not in
  // this default scaffold. titre/classe are literal values he gave
  // directly, not placeholders — his own explicit content this time.
  readonly property string _newProjectMasterTemplate: [
    '#import "lib.typ": conf',
    '#show: conf.with(',
    '  titre: "Correction - Commentaire",',
    '  classe: "1SCHA - 2026-2027",',
    ')',
    ''
  ].join("\n")

  readonly property string _newProjectLibTemplate: [
    '#let conf(',
    '  titre: "Intitulé du parcours",',
    '  classe: "Classe - Année Scolaire",',
    '  body,',
    ') = {',
    '  set page(',
    '    paper: "a4",',
    '    margin: 2.5cm,',
    '    footer: context [',
    '      #set align(left)',
    '      #set text(10pt)',
    '      #emph[M.Harfield - #classe]',
    '      #h(1fr)',
    '      #counter(page).display()',
    '    ],',
    '    header: context [',
    '      #set align(right)',
    '      #set text(11pt)',
    '      *#titre*',
    '    ],',
    '  )',
    '  set text(',
    '    lang: "fr",',
    '    size: 12pt,',
    '  )',
    '  set par(justify: true, leading: 1.15em)',
    '  body',
    '}',
    '',
    '#let indented(body) = {',
    '  set par(first-line-indent: 1.5em)',
    '  body',
    '}',
    '',
    '#let line-offset = counter("line-offset")',
    '#let numbered-text(n, step: 5, body) = [',
    '  #show: doc => context {',
    '    let prev = line-offset.get().first()',
    '    set par.line(numbering: i => {',
    '      let rel = i - prev',
    '      if calc.rem(rel, step) == 0 or rel == 1 { rel }',
    '    })',
    '    doc',
    '    line-offset.update(x => x + n)',
    '  }',
    '  #body',
    ']',
    ''
  ].join("\n")

  // Entry point (Projet panel's "Créer un nouveau projet" button, via the
  // typed-path bar's "newProject" mode). Checks first rather than letting
  // `mkdir -p` + an unconditional write silently clobber an existing
  // maître.typ in a folder Gabriel already has a project in.
  function createNewProject(path) {
    var normalized = path.trim().replace(/\/+$/, "")
    if (!normalized) return
    root.newProjectError = ""
    root._pendingNewProjectDir = normalized
    newProjectCheckProc.command = ["test", "-e", normalized + "/maître.typ"]
    newProjectCheckProc.running = false
    newProjectCheckProc.running = true
  }

  Process {
    id: newProjectCheckProc
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.newProjectError = "Un maître.typ existe déjà dans ce dossier — projet non créé."
        root._pendingNewProjectDir = ""
        return
      }
      newProjectMkdirProc.command = ["mkdir", "-p", root._pendingNewProjectDir]
      newProjectMkdirProc.running = false
      newProjectMkdirProc.running = true
    }
  }

  Process {
    id: newProjectMkdirProc
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root._pendingNewProjectDir) {
        root.newProjectError = "Impossible de créer le dossier du projet."
        root._pendingNewProjectDir = ""
        return
      }
      newProjectMasterFile.setText(root._newProjectMasterTemplate)
    }
  }

  FileView {
    id: newProjectMasterFile
    path: root._newProjectMasterPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: newProjectLibFile.setText(root._newProjectLibTemplate)
  }

  FileView {
    id: newProjectLibFile
    path: root._newProjectLibPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: {
      var masterPath = root._newProjectMasterPath
      var dir = root._pendingNewProjectDir
      root._pendingNewProjectDir = ""
      root.refreshFileTree(dir)
      root.requestDiscardAndThen(function() { root.openDocument(masterPath) })
    }
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
  // class here, not a theoretical one. No tab (active or otherwise)
  // survives a restart — see this file's "no session persistence, by
  // design" comment further down.
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
    if (multidocSaveDebounce.running) {
      multidocSaveDebounce.stop()
      if (root.docPath) multidocListFile.setText(JSON.stringify(root.multidocPaths))
    }
    root.tabs = root.tabs.map(function(t) {
      if (t.id !== root.activeDocId) return t
      return { id: t.id, path: root.docPath, text: root.docText, dirty: root.dirty,
               notesText: root.notesText, rightPaneView: root.rightPaneView, loaded: true }
    })
  }

  // Loads a tabs[] entry into the live "current document" surface. Reuses
  // docFile's existing pendingRestore reconciliation for a real path with
  // cached in-memory content — if that tab was genuinely dirty (real
  // unsaved edits) when last switched away from, the cache wins and dirty
  // is set; a clean tab always defers to whatever's actually on disk (see
  // docFile.onLoaded's own comment for why that distinction matters). A
  // tab that's never been loaded yet (freshly opened into a brand-new tab
  // via "+") does a plain disk load instead, same as an ordinary
  // openDocument().
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
  }

  function newDocument() {
    root.docPath = ""
    root.docText = ""
    root.dirty = false
    root.compileErrors = []
    root.previewVersion = 0
    root.previewPageCount = 0
    editorTabItem.clearUndoHistory()
  }

  // Typst Universe template picker (Paramètres tab) — opens in a brand-new
  // tab rather than replacing whatever's currently active, same reasoning
  // as addTab() itself: a template pick shouldn't require discarding
  // unrelated in-progress work. addTab() already applies the usual
  // _tabSwitchBlocked guard (no-op while a review/Antidote round-trip is
  // pending), and onTextEdited() drives the same compile path a real
  // keystroke would.
  function insertTemplate(command) {
    root.addTab()
    root.onTextEdited(command)
    root.tab = "editor"
  }

  function openDocument(path) {
    editorTabItem.clearUndoHistory()
    root.suppressDocLoad = false
    // Defensive reset: a stale true here (left over from an interrupted
    // tab switch, see _loadTabIntoActive()) would make docFile.onLoaded
    // treat this fresh open as a restore-reconciliation instead of a
    // plain load, silently discarding the newly-opened file's content in
    // favor of whatever old pendingRestoreBuffer held.
    root.pendingRestore = false
    if (path === root.docPath) {
      // Same file already open — docPath won't change, so the FileView's
      // path binding never re-fires on its own; force it.
      docFile.reload()
      return
    }
    root.docPath = path
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
    else if (mode === "newProject") root.createNewProject(path)
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
        // Only trust the OTHER tab's cached buffer over what's actually
        // on disk if it was genuinely DIRTY (real unsaved edits) when
        // that tab was last snapshotted away — never just because it
        // happens to differ from disk. This same comparison used to also
        // run for restoring the last-open document across a shell
        // restart, and THAT was a real, serious bug (reported by Gabriel
        // 2026-08-30: editing the same Dropbox-synced document from a
        // second machine — Harfield X13 — between two sessions on this
        // one — Ostrog — made a merely-stale-but-clean buffer look
        // "different from disk" and silently overwrite newer content
        // from the other machine once autosave fired). That whole
        // restore-on-launch feature was removed entirely as the actual
        // fix (see "no session persistence, by design" below) — this
        // `pendingRestore` mechanism now only ever fires for same-
        // session, same-machine tab switches, where the equivalent risk
        // doesn't exist, but the same "don't trust a clean buffer over
        // disk" discipline is still correct here too.
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
      root._recordRecentFile(root.docPath)
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
        // The tab being switched to points at a file that's gone/
        // unreadable now — fall back to whatever buffer was cached for
        // it, if any. Still gated on pendingRestoreWasDirty for the same
        // reason as onLoaded above: a clean cached buffer is nothing
        // more than a stale mirror, not real unsaved work worth flagging
        // dirty.
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
      root._recordRecentFile(root.docPath)
      // "Enregistrer sous…" to a new path sets docPath first, which
      // reactively triggers this FileView's own load-fails-then-setText
      // chain (see suppressDocLoad above) — refreshFileTree() from
      // onDocPathChanged below fires too early in that sequence (before
      // this actual write has happened), so the new file never appeared
      // in the tree yet. This fires once the write is actually done.
      if (!root.fileTreeUserNavigated) root.refreshFileTree(root.docDir)
    }
  }

  // --- no session persistence, by design ----------------------------------
  //
  // GH Typst used to remember the last-open document (path + buffer)
  // across a restart, to protect an untitled/unsaved buffer from being
  // destroyed by a routine `omarchy-restart-shell` during development.
  // REMOVED 2026-08-30, Gabriel's own explicit, direct instruction after a
  // real data-loss incident: editing the same Dropbox-synced document from
  // two machines (Ostrog/Harfield X13) let a stale remembered buffer from
  // one machine silently overwrite newer saved content from the other via
  // autosave, once this plugin's `keepLoaded` auto-restore reopened it.
  // A dirty-flag-gated fix was tried first and explained to him, but he
  // found it too hard to reason about and confirm safe given real-world
  // sync-timing risk (Dropbox can lag behind by seconds to minutes,
  // especially reconnecting after being offline) — his own words: "il ne
  // devrait y avoir aucune mémoire du dernier document. Quand on ferme
  // l'appli, elle oublie. Quand on l'ouvre, on est sur un document vide."
  // GH Typst now ALWAYS starts on a blank, untitled document — no
  // `session.json`, no restore-on-launch code path at all. The
  // `pendingRestore`/`pendingRestoreBuffer`/`pendingRestoreWasDirty`
  // properties and the reconciliation logic in docFile.onLoaded/
  // onLoadFailed above are NOT removed — `_loadTabIntoActive()` (switching
  // between tabs already open in the SAME running session) still needs
  // them, and that use is safe: it's same-machine, same-session, never
  // exposed to the cross-restart/cross-machine staleness this bug was
  // actually about.

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", root.stateDir, root.reviewsDir]
  }

  Component.onCompleted: {
    ensureDirsProc.running = true
    Qt.callLater(function() { settingsFile.reload() })
    Qt.callLater(function() { recentFilesFile.reload() })
    Qt.callLater(function() { root.refreshFileTree(root.fileTreeHomeDir()) })
  }

  // --- compile pipeline (live preview + real compiler diagnostics) -----

  // Raw, un-deduplicated diagnostics straight from compile.sh — kept around
  // untouched for errorLogWindow (Gabriel wants the option to see the real
  // full output, not just the collapsed inline view).
  property var compileErrors: []
  property bool compiling: false
  // Whether the full-log window (below) is open.
  property bool errorLogWindowVisible: false

  // A single syntax slip (Gabriel's report 2026-09-04: an unclosed
  // `#h(1fr)`) can send the Typst compiler cascading into a dozen-plus
  // near-identical diagnostics in one compile pass. Shown raw, that flooded
  // EditorTab's inline error Column, whose height is subtracted from the
  // editor viewport's own (see EditorTab's editorScroll height binding) —
  // enough rows and the editor itself got squeezed out from under him
  // mid-edit. This collapses exact-message repeats into one row with a
  // "(×N)" count, then caps the inline list so it can never do that again;
  // anything over the cap folds into a single "+N autres" row that opens
  // errorLogWindow instead of jumping to a line.
  function _dedupedErrors(list) {
    var seen = {}
    var out = []
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      var idx = seen[e.message]
      if (idx === undefined) {
        seen[e.message] = out.length
        out.push({ line: e.line, col: e.col, severity: e.severity, message: e.message, count: 1 })
      } else {
        out[idx].count += 1
      }
    }
    return out
  }

  readonly property int _inlineErrorCap: 6
  readonly property var compileErrorsInline: {
    var deduped = root._dedupedErrors(root.compileErrors)
    if (deduped.length <= root._inlineErrorCap) return deduped
    var shown = deduped.slice(0, root._inlineErrorCap - 1)
    var hiddenCount = 0
    for (var i = root._inlineErrorCap - 1; i < deduped.length; i++) hiddenCount += deduped[i].count
    shown.push({
      line: 0, col: 0, severity: "error", isMore: true,
      message: "+" + hiddenCount + (hiddenCount > 1 ? " autres erreurs" : " autre erreur") + " — voir le journal complet"
    })
    return shown
  }
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
    previewSrcFile.setText(root.docText + root._multidocAppendix())
  }

  FileView {
    id: previewSrcFile
    path: root.previewSrcPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: {
      root.compiling = true
      compileProc.command = ["bash", root.pluginDir + "/compile.sh", root.previewSrcPath, root._multidocEffectiveRoot(), root.previewDir, root.previewPagePrefix]
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
      // Diagnostics come back with line numbers into the shadow file
      // (docText + appendix), not into docText alone — see startCompile()'s
      // own _multidocAppendix() comment. docText's own lines are unshifted
      // (the appendix comes after, not before), so no offset math is
      // needed for a real docText line — only a clamp: anything beyond
      // docText's own line count is inside the appended MultiDoc block (or
      // an included file), with no real-document line to point at, so it's
      // shown with line 0 (no jump) rather than a wrong one.
      var maxLine = root._docTextLineCount()
      root.compileErrors = (parsed.errors || []).map(function(e) {
        if (e.line <= 0 || e.line <= maxLine) return e
        return { line: 0, col: e.col, severity: e.severity, message: e.message }
      })
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

  // TEMPORARY diagnostic switch, 2026-09-02 — Gabriel suspects local
  // spellcheck (the hunspell detect pass + the misspelled-word overlay it
  // feeds) is the remaining source of editor lag on his stress document,
  // even after virtualizing the overlay's Repeater. Flip this back to
  // false (or delete it) once the diagnostic test is done — it's the ONE
  // thing gating requestSpellcheck() below, nothing else changed.
  property bool _spellcheckDiagnosticDisabled: false

  function requestSpellcheck(text) {
    if (root._spellcheckDiagnosticDisabled) return
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

  // "files" | "headings" | "project" — the left panel is a single slot
  // shared by the file tree, the heading outline, and Projet, one at a
  // time (Gabriel's explicit choice, 2026-08-29, over showing both
  // stacked; "project" added 2026-09-02). Always one of the three now,
  // never "" — see leftPanelHidden below for why.
  property string leftPanelMode: "files"

  // Whether the whole left-panel slot is collapsed — split out as its own
  // flag, 2026-09-02, after Gabriel hit a real dead end: leftPanelMode
  // used to double as "hidden" via "", but the toggle row itself was only
  // visible while a mode was active, so collapsing it (clicking the
  // already-active mode button) hid the ONE thing that could bring it
  // back. Independent axis now, same relationship as EditorTab.qml's own
  // rightPaneHidden/rightPaneView on the opposite side: which mode is
  // selected and whether the panel is currently shown are orthogonal.
  property bool leftPanelHidden: false

  // The three mode buttons' click handler — selecting a mode also reveals
  // the panel if it was hidden (same as clicking Aperçu/Notes/Journal on
  // the right always implies "shown"); the dedicated toggle button further
  // down is the only thing that hides it again.
  function selectLeftPanelMode(mode) {
    root.leftPanelMode = mode
    root.leftPanelHidden = false
  }
  property string fileTreeDir: ""
  property var fileTreeEntries: [] // [{name, isDir}]
  property bool fileTreeUserNavigated: false

  // --- recent files (file-tree panel's quick-reopen list) -----------------
  //
  // Gabriel's own proposal, 2026-08-30, after the removed session-restore
  // feature turned out too risky: only paths are ever remembered, never
  // buffer content — reopening one is a plain, explicit openDocument()
  // call that always reads whatever's actually on disk. See lib/Store.js's
  // own comment for why this sidesteps the whole bug class that feature
  // had.
  property var recentFiles: [] // [path, ...], most-recent-first, max 5

  FileView {
    id: recentFilesFile
    path: root.recentFilesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.recentFiles = Store.parseRecentFiles(recentFilesFile.text())
    onLoadFailed: root.recentFiles = []
  }

  function _recordRecentFile(path) {
    if (!path) return
    root.recentFiles = Store.pushRecentFile(root.recentFiles, path)
    recentFilesFile.setText(Store.serializeRecentFiles(root.recentFiles))
  }
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
  // document has nowhere to auto-save *to*. Since session persistence was
  // removed (see "no session persistence, by design" above), an untitled
  // document's content does NOT survive a shell restart at all anymore —
  // a deliberate, accepted trade-off, not an oversight.
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
    pdfExportSrcFile.setText(root.docText + root._multidocAppendix())
  }

  FileView {
    id: pdfExportSrcFile
    path: root.pdfExportSrcPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: {
      pdfExportProc.command = ["typst", "compile", "--root", root._multidocEffectiveRoot(), root.pdfExportSrcPath, root._pendingPdfPath]
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
      // Fires for every path that makes the window invisible — including
      // Super+W, which bypasses requestClose() entirely — so this is the
      // one place that reliably runs on every close, not just the IPC
      // path. See _forgetEverythingOnClose()'s own comment for why it's
      // still safe even here.
      if (!visible) root._forgetEverythingOnClose()
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
          height: Math.max(headerTitle.implicitHeight, fileMenuButton.implicitHeight)

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

          // Nouveau/Ouvrir/Enregistrer/Enregistrer sous/Export PDF,
          // collapsed into one dropdown behind a plain hamburger icon
          // (Gabriel's ask, 2026-09-02: five separate buttons crowded
          // and wrapped awkwardly on a narrower or split screen). Popup
          // (not the full Dropdown component from qs.Ui — that one's
          // built for picking a persistent value, wrong shape for a
          // list of one-shot actions) mirrors exactly how Dropdown.qml
          // itself positions its own popup: nested inside the trigger
          // Button, x/y relative to it, no explicit `parent:` needed —
          // proven pattern already used elsewhere in this shell
          // (RevisionTab.qml's two Dropdowns).
          Button {
            id: fileMenuButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: "Fichier"
            selected: fileMenuPopup.opened
            foreground: root.fg
            accent: root.accentColor
            onClicked: fileMenuPopup.opened ? fileMenuPopup.close() : fileMenuPopup.open()

            Popup {
              id: fileMenuPopup
              y: fileMenuButton.height + Style.space(4)
              x: fileMenuButton.width - width
              width: Style.space(200)
              padding: Style.space(6)
              closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

              background: Rectangle {
                color: Qt.darker(root.bg, 1.05)
                border.color: root.faint
                border.width: 1
                radius: Style.cornerRadius
              }

              contentItem: Column {
                width: fileMenuPopup.availableWidth
                spacing: Style.space(2)

                Button {
                  width: parent.width
                  text: "Nouveau"
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: { fileMenuPopup.close(); root.requestDiscardAndThen(root.newDocument) }
                }
                Button {
                  width: parent.width
                  text: "Ouvrir"
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: { fileMenuPopup.close(); root.beginPathEntry("open", root.docPath) }
                }
                Button {
                  width: parent.width
                  text: "Enregistrer"
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: { fileMenuPopup.close(); root.saveDocument() }
                }
                Button {
                  width: parent.width
                  text: "Enregistrer sous…"
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: { fileMenuPopup.close(); root.beginPathEntry("saveAs", root.docPath) }
                }
                Button {
                  width: parent.width
                  text: root.exportingPdf ? "Export…" : "Export PDF"
                  enabled: !root.exportingPdf && root.docText !== ""
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: { fileMenuPopup.close(); root.exportPdf() }
                }
              }
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
              : root.pathBarMode === "newProject" ? "Nouveau projet (dossier) :"
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

            // Every tab/panel-visibility icon — both sides — on one
            // shared row, full width, at the very top of editorBody
            // (Gabriel's explicit correction, 2026-09-02, after two failed
            // attempts: this is NOT split across editorHeader/
            // previewHeaderRow anymore, and it does NOT live one level
            // down inside either column — only "Éditeur" and its own
            // lignes/marges/zoom controls sit below this row, on the
            // editor's own header. Left cluster: leftPanelHidden toggle +
            // Fichiers/Titres/Projet (collapse together). Right cluster:
            // Aperçu/Notes/Journal + the previewEnabled eye + the
            // rightPaneHidden toggle, in that exact order — Gabriel's ask
            // that the pane-hide button sit immediately to the right of
            // the eye button, not above it. Both hide/show toggles
            // (leftPanelHideButton/rightPanelHideButton) stay put at the
            // two far edges regardless of anything collapsing, so neither
            // side can ever strand the user with no way back.
            Item {
              id: topIconRow
              anchors.left: parent.left
              anchors.right: parent.right
              height: leftPanelHideButton.implicitHeight

              Button {
                id: leftPanelHideButton
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.leftPanelHidden ? "" : ""
                selected: root.leftPanelHidden
                tooltipText: root.leftPanelHidden
                  ? "Réafficher le panneau"
                  : "Masquer le panneau (l'éditeur prend toute la largeur)"
                foreground: root.fg
                accent: root.accentColor
                onClicked: root.leftPanelHidden = !root.leftPanelHidden
              }

              Row {
                visible: !root.leftPanelHidden
                anchors.left: leftPanelHideButton.right
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Button {
                  iconText: ""
                  tooltipText: "Fichiers"
                  selected: root.leftPanelMode === "files"
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.selectLeftPanelMode("files")
                }
                Button {
                  iconText: ""
                  tooltipText: "Titres du document"
                  selected: root.leftPanelMode === "headings"
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.selectLeftPanelMode("headings")
                }
                Button {
                  iconText: ""
                  tooltipText: "Projet"
                  selected: root.leftPanelMode === "project"
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.selectLeftPanelMode("project")
                }
              }

              Button {
                id: rightPanelHideButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.rightPaneHidden ? "" : ""
                selected: root.rightPaneHidden
                tooltipText: root.rightPaneHidden
                  ? "Réafficher le panneau Aperçu/Notes"
                  : "Masquer le panneau Aperçu/Notes (l'éditeur prend toute la largeur)"
                foreground: root.fg
                accent: root.accentColor
                onClicked: root.setRightPaneHidden(!root.rightPaneHidden)
              }

              Row {
                visible: !root.rightPaneHidden
                anchors.right: rightPanelHideButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                // Aperçu/Notes: which content the right pane shows — not
                // the same axis as the eye icon further right, which is
                // whether Typst compilation even runs at all (Gabriel's
                // explicit split, 2026-08-29): you can be looking at Notes
                // while the preview keeps compiling in the background, or
                // looking at Aperçu with compilation paused on a large
                // document.
                Button {
                  text: "Aperçu"
                  selected: root.rightPaneView === "apercu"
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.rightPaneView = "apercu"
                }
                Button {
                  text: "Notes"
                  selected: root.rightPaneView === "notes"
                  enabled: root.docPath !== ""
                  tooltipText: root.docPath !== "" ? "" : "Enregistre d'abord le document pour lui associer des notes."
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.rightPaneView = "notes"
                }
                Button {
                  text: "Journal"
                  selected: root.rightPaneView === "journal"
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.rightPaneView = "journal"
                }
                Text {
                  visible: root.compiling
                  anchors.verticalCenter: parent.verticalCenter
                  text: "· compilation…"
                  color: root.faint
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }
                // Icon-only, monochrome (Font Awesome eye/eye-slash) —
                // purely about whether the Typst compile pipeline runs,
                // independent of which view (Aperçu/Notes/Journal) is
                // currently shown.
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.previewEnabled ? "" : ""
                  tooltipText: root.previewEnabled
                    ? "Désactiver l'aperçu (utile sur un document volumineux)"
                    : "Réactiver l'aperçu"
                  selected: root.previewEnabled
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.setPreviewEnabled(!root.previewEnabled)
                }
              }
            }

            Rectangle {
              id: fileTreePanel
              visible: !root.leftPanelHidden && root.leftPanelMode === "files"
              anchors.top: topIconRow.bottom
              anchors.topMargin: Style.space(6)
              width: Style.space(280)
              height: parent.height - topIconRow.height - Style.space(6)
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

                // Recent files — Gabriel's own proposal, 2026-08-30, a
                // safer replacement for the removed auto-restore-last-
                // document feature: paths only, reopening is an explicit
                // click through the normal openDocument()/discard-guard
                // flow, so it always reads whatever's actually on disk
                // right now, never a stale remembered buffer.
                Column {
                  width: parent.width
                  spacing: Style.space(2)
                  visible: root.recentFiles.length > 0

                  Text {
                    text: "Récents"
                    color: root.faint
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                  }

                  Repeater {
                    model: root.recentFiles

                    Item {
                      id: recentEntry
                      required property string modelData
                      width: parent.width
                      height: recentEntryText.implicitHeight + Style.space(4)

                      Text {
                        id: recentEntryText
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        elide: Text.ElideMiddle
                        text: "📄 " + root.fileBaseName(recentEntry.modelData)
                        color: root.fg
                        font.family: root.uiFont
                        font.pixelSize: Style.font.bodySmall

                        ToolTip.visible: recentMouseArea.containsMouse
                        ToolTip.text: recentEntry.modelData
                      }

                      MouseArea {
                        id: recentMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          var targetPath = recentEntry.modelData
                          root.requestDiscardAndThen(function() { root.openDocument(targetPath) })
                        }
                      }
                    }
                  }
                }

                PanelSeparator { foreground: root.fg; width: parent.width; visible: root.recentFiles.length > 0 }

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
              visible: !root.leftPanelHidden && root.leftPanelMode === "headings"
              anchors.top: topIconRow.bottom
              anchors.topMargin: Style.space(6)
              width: Style.space(280)
              height: parent.height - topIconRow.height - Style.space(6)
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

            // Projet (Gabriel's idea, 2026-09-02, second round) — same
            // panel slot/style as Fichiers/Titres above, shown instead of
            // them (leftPanelMode is one of the three, never more than
            // one — same rule as Fichiers/Titres already followed). Two
            // parts: a scaffold button (createNewProject(), above) and the
            // MultiDoc staging list — reorder by dragging the ≡ handle,
            // #include lines get generated from this list invisibly at
            // compile time (see this file's own "--- MultiDoc / Projet"
            // comment further up). No "Insérer" action here on purpose —
            // that was the SECOND design tried for this feature and
            // Gabriel corrected it back to invisible/auto-synced; the
            // document itself is edited by switching between file-tree
            // entries, not by hand-placing #include lines.
            Rectangle {
              id: projectPanel
              visible: !root.leftPanelHidden && root.leftPanelMode === "project"
              anchors.top: topIconRow.bottom
              anchors.topMargin: Style.space(6)
              width: Style.space(280)
              height: parent.height - topIconRow.height - Style.space(6)
              color: Qt.darker(root.bg, 1.05)
              border.color: root.faint
              border.width: 1
              radius: Style.cornerRadius
              clip: true

              Column {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(6)

                Button {
                  width: parent.width
                  text: "Créer un nouveau projet"
                  bordered: true
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.beginPathEntry("newProject", (root.fileTreeDir || root.fileTreeHomeDir()) + "/nouveau-projet")
                }

                Text {
                  visible: root.newProjectError !== ""
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: root.newProjectError
                  color: root.urgentColor
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }

                PanelSeparator { foreground: root.fg; width: parent.width }

                // Quick access to the two files every project scaffolded by
                // "Créer un nouveau projet" always has (Gabriel's ask,
                // 2026-09-02) — same openPathInNewTab() the row eye buttons
                // below use, just against a fixed name in docDir instead of
                // a staged path. Disabled rather than hidden when there's
                // no docDir yet (untitled document) — same reasoning as the
                // rest of this panel's availability gating.
                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Button {
                    text: "maître.typ"
                    enabled: root.docDir !== ""
                    foreground: root.fg
                    accent: root.accentColor
                    onClicked: root.openPathInNewTab(root.docDir + "/maître.typ")
                  }
                  Button {
                    text: "lib.typ"
                    enabled: root.docDir !== ""
                    foreground: root.fg
                    accent: root.accentColor
                    onClicked: root.openPathInNewTab(root.docDir + "/lib.typ")
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Fichiers .typ inclus dans ce document à la compilation, dans cet ordre (glisse ≡ pour réordonner) :"
                  color: root.faint
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  visible: !root.multidocAvailable
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Enregistre d'abord ce document pour lui associer une liste."
                  color: root.faint
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }

                Item {
                  id: multidocListArea
                  width: parent.width
                  visible: root.multidocAvailable
                  readonly property real rowHeight: Style.space(32)
                  height: root.multidocPaths.length * rowHeight

                  Repeater {
                    model: root.multidocPaths

                    Rectangle {
                      id: multidocRow
                      required property int index
                      required property string modelData
                      width: multidocListArea.width
                      height: multidocListArea.rowHeight - Style.space(4)
                      y: index * multidocListArea.rowHeight
                      z: dragHandle.drag.active ? 100 : 0
                      color: dragHandle.drag.active ? Qt.darker(root.bg, 1.15) : "transparent"
                      radius: Style.cornerRadius
                      border.color: dragHandle.drag.active ? root.accentColor : "transparent"
                      border.width: 1

                      MouseArea {
                        id: dragHandle
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Style.space(18)
                        cursorShape: Qt.SizeVerCursor
                        drag.target: multidocRow
                        drag.axis: Drag.YAxis
                        drag.minimumY: 0
                        drag.maximumY: Math.max(0, (root.multidocPaths.length - 1) * multidocListArea.rowHeight)
                        onReleased: {
                          var targetIndex = Math.round(multidocRow.y / multidocListArea.rowHeight)
                          targetIndex = Math.max(0, Math.min(root.multidocPaths.length - 1, targetIndex))
                          if (targetIndex !== multidocRow.index) root.multidocReordered(multidocRow.index, targetIndex)
                          else multidocRow.y = multidocRow.index * multidocListArea.rowHeight
                        }

                        Text {
                          anchors.centerIn: parent
                          text: "≡"
                          color: root.faint
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      TextField {
                        id: multidocPathField
                        anchors.left: dragHandle.right
                        anchors.leftMargin: Style.space(4)
                        anchors.right: multidocViewButton.left
                        anchors.rightMargin: Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter
                        font.pixelSize: Style.font.bodySmall
                        placeholderText: "/chemin/fichier.typ"
                        // No declarative `text:` binding — same trap as
                        // pathBarField/notesField elsewhere in this file (a
                        // TextField's binding is destroyed the instant the
                        // user types). Committed on focus-out/Entrée
                        // (onEditingFinished) rather than on every
                        // keystroke: committing live would reassign
                        // root.multidocPaths (a fresh array, see this
                        // section's own header comment) on every character
                        // typed, rebuilding this entire Repeater —
                        // including the very field being typed into — and
                        // dropping focus mid-word.
                        //
                        // Shows the filename only once committed (Gabriel's
                        // ask, 2026-09-02) — Component.onCompleted seeds
                        // that friendly form, and every commit triggers the
                        // same reseed for free (multidocPathEdited always
                        // reassigns root.multidocPaths, rebuilding this
                        // whole Repeater). Gaining focus swaps back to the
                        // real full path so there's something meaningful to
                        // edit; onEditingFinished's own commit above fires
                        // on blur, right before the reseed takes over.
                        Component.onCompleted: text = root.multidocDisplayName(multidocRow.modelData)
                        onActiveFocusChanged: if (activeFocus) text = multidocRow.modelData
                        onEditingFinished: root.multidocPathEdited(multidocRow.index, text)

                        DropArea {
                          anchors.fill: parent
                          // A file dragged in from Nautilus lands as a
                          // text/uri-list "file:///..." URL, not a plain
                          // path — untested against this specific
                          // GTK-app-to-QtQuick Wayland DnD path, confirm
                          // live. Falls back to hasText for a plain path
                          // pasted via drag from somewhere else.
                          onDropped: function(drop) {
                            var raw = ""
                            if (drop.hasUrls && drop.urls.length > 0) raw = drop.urls[0].toString()
                            else if (drop.hasText) raw = drop.text
                            raw = raw.trim()
                            if (raw.indexOf("file://") === 0) raw = decodeURIComponent(raw.slice(7))
                            if (!raw) return
                            multidocPathField.text = raw
                            root.multidocPathEdited(multidocRow.index, raw)
                          }
                        }
                      }

                      // Monochrome eye (Gabriel's ask, 2026-09-02) — same
                      // Font Awesome glyph (U+F06E) already confirmed to
                      // render in this shell's icon font by the Aperçu
                      // eye-toggle button in EditorTab.qml.
                      Button {
                        id: multidocViewButton
                        anchors.right: multidocRemoveButton.left
                        anchors.rightMargin: Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: ""
                        enabled: multidocRow.modelData && multidocRow.modelData.charAt(0) === "/"
                        tooltipText: "Ouvrir dans un nouvel onglet"
                        foreground: root.fg
                        accent: root.accentColor
                        onClicked: root.multidocOpenInNewTab(multidocRow.index)
                      }

                      Button {
                        id: multidocRemoveButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "✕"
                        tooltipText: "Retirer cette ligne"
                        foreground: root.fg
                        accent: root.urgentColor
                        onClicked: root.multidocRemove(multidocRow.index)
                      }
                    }
                  }
                }

                Text {
                  visible: root.multidocAvailable && root.multidocPaths.length === 0
                  text: "Aucun fichier ajouté."
                  color: root.faint
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                }

                Button {
                  visible: root.multidocAvailable
                  text: "+ Ajouter une ligne"
                  bordered: true
                  foreground: root.fg
                  accent: root.accentColor
                  onClicked: root.multidocAdd()
                }
              }
            }

            EditorTab {
              id: editorTabItem
              anchors.left: parent.left
              anchors.leftMargin: !root.leftPanelHidden ? (Style.space(280) + Style.space(10)) : 0
              anchors.top: topIconRow.bottom
              anchors.topMargin: Style.space(6)
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              text: root.docText
              errors: root.compileErrorsInline
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
              onLineNumbersToggleRequested: root.setLineNumbersEnabled(!root.lineNumbersEnabled)
              onNarrowMarginsToggleRequested: root.setNarrowMarginsEnabled(!root.narrowMarginsEnabled)
              onSpellcheckRequested: function(text) { root.requestSpellcheck(text) }
              onSuggestRequested: function(word) { root.requestSuggestions(word) }
              onApplySuggestionRequested: function(start, end, replacement) { root.applySuggestion(start, end, replacement) }
              onNotesEdited: function(newText) { root.onNotesEdited(newText) }
              onShowErrorLogRequested: root.errorLogWindowVisible = true
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

  // ---------------------------------------------------------- error log
  // window
  //
  // The raw, un-deduplicated compile.sh output (root.compileErrors) shown
  // in full — Gabriel's ask 2026-09-04, companion to the inline list's own
  // dedup+cap (see compileErrorsInline above): the inline view stays short
  // and readable, and this is where the complete picture still lives on
  // request. A separate FloatingWindow (not a Popup over `window`) because
  // he specifically asked for "une fenêtre à part" — room to actually read
  // a long cascade without it fighting the editor for space.
  FloatingWindow {
    id: errorLogWindow
    title: "GH Typst — Journal complet"
    color: root.bg
    visible: root.errorLogWindowVisible
    implicitWidth: Style.space(640)
    implicitHeight: Style.space(600)
    minimumSize: Qt.size(Style.space(400), Style.space(300))

    onVisibleChanged: {
      if (!visible) root.errorLogWindowVisible = false
    }

    Rectangle {
      anchors.fill: parent
      color: root.bg
    }

    Column {
      anchors.fill: parent
      anchors.margins: Style.space(16)
      spacing: Style.space(10)

      Item {
        width: parent.width
        height: logHeaderText.implicitHeight

        Text {
          id: logHeaderText
          text: root.compileErrors.length + (root.compileErrors.length > 1 ? " diagnostics" : " diagnostic")
          color: root.fg
          font.family: root.uiFont
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Button {
          anchors.right: parent.right
          text: "Fermer"
          foreground: root.fg
          accent: root.accentColor
          onClicked: root.errorLogWindowVisible = false
        }
      }

      ScrollView {
        id: errorLogScroll
        width: parent.width
        height: parent.height - logHeaderText.implicitHeight - parent.spacing
        clip: true
        ScrollBar.vertical.policy: ScrollBar.AsNeeded

        Column {
          width: errorLogScroll.availableWidth
          spacing: Style.space(8)

          Repeater {
            model: root.compileErrors

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: modelData.severity === "warning" ? "◐" : "✕"
                color: modelData.severity === "warning" ? root.warningColor : root.urgentColor
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                width: parent.width - Style.space(20)
                textFormat: Text.PlainText
                text: (modelData.line > 0 ? ("L" + modelData.line + ":" + modelData.col + " — ") : "") + modelData.message
                color: root.fg
                font.family: root.uiFont
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap

                MouseArea {
                  anchors.fill: parent
                  cursorShape: modelData.line > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: {
                    if (modelData.line <= 0) return
                    root.tab = "editor"
                    editorTabItem.jumpToLine(modelData.line, modelData.col || 1)
                    root.errorLogWindowVisible = false
                  }
                }
              }
            }
          }
        }
      }
    }
  }

}
