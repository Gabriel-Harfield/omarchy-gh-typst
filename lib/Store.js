// Pure data + sanitizers, no file I/O (that lives in Panel.qml's FileView).
//
// GH Typst used to persist the last-open document (path + buffer) across a
// restart. REMOVED 2026-08-30 at Gabriel's own explicit instruction after a
// real data-loss incident: editing the same Dropbox-synced document from
// two machines let a stale remembered buffer from one silently overwrite
// newer saved content from the other — see the plugin's own memory/commit
// history for the full story. GH Typst now always starts on a blank,
// untitled document; there is no session.json anymore.

var MAX_DOC_PATH_LEN = 1024

function baseName(path) {
  var s = String(path || "")
  var idx = s.lastIndexOf("/")
  return idx === -1 ? s : s.slice(idx + 1)
}

// --- recent files (file-tree panel's quick-reopen list) -----------------
//
// A deliberately much safer alternative to the removed session-restore
// feature above, proposed by Gabriel 2026-08-30: only ever stores PATHS,
// never buffer content, and reopening one is an explicit click through
// the normal openDocument() flow — always reads whatever's actually on
// disk right now. No stale buffer, no autosave-triggered overwrite risk,
// none of the cross-machine bug class this file's own history is about.

var MAX_RECENT_FILES = 5

function sanitizeRecentFiles(raw) {
  var arr = Array.isArray(raw) ? raw : []
  var out = []
  for (var i = 0; i < arr.length && out.length < MAX_RECENT_FILES; i++) {
    var p = arr[i]
    if (typeof p === "string" && p.length > 0 && p.length <= MAX_DOC_PATH_LEN && out.indexOf(p) === -1) out.push(p)
  }
  return out
}

function parseRecentFiles(text) {
  var parsed = []
  try { parsed = JSON.parse(text || "[]") } catch (e) { parsed = [] }
  return sanitizeRecentFiles(parsed)
}

function serializeRecentFiles(list) {
  return JSON.stringify(sanitizeRecentFiles(list), null, 2) + "\n"
}

// Moves path to the front (or inserts it there), capped/deduped by
// sanitizeRecentFiles. Pure function — Panel.qml owns writing the result.
function pushRecentFile(list, path) {
  if (!path) return sanitizeRecentFiles(list)
  var out = sanitizeRecentFiles(list).filter(function(p) { return p !== path })
  out.unshift(path)
  return sanitizeRecentFiles(out)
}

// --- settings (separate file from session: durable preferences, not
// per-document state) --------------------------------------------------

var MIN_AUTOSAVE_MINUTES = 1
var MAX_AUTOSAVE_MINUTES = 60
var DEFAULT_AUTOSAVE_MINUTES = 5

var MIN_EDITOR_ZOOM = 0.6
var MAX_EDITOR_ZOOM = 2.5
var DEFAULT_EDITOR_ZOOM = 1.0

// "" means "don't pass --model/--effort at all" (claude -p's own
// default) — a durable preference, but deliberately not defaulted to any
// specific value here, so installing this feature never silently changes
// what model/effort every review already ran with before it existed.
var CLAUDE_MODELS = ["", "sonnet", "opus", "haiku", "fable"]
var CLAUDE_EFFORTS = ["", "low", "medium", "high", "xhigh", "max"]

function sanitizeSettings(raw) {
  var minutes = (raw && typeof raw.autosaveMinutes === "number" && isFinite(raw.autosaveMinutes))
    ? Math.round(raw.autosaveMinutes) : DEFAULT_AUTOSAVE_MINUTES
  minutes = Math.max(MIN_AUTOSAVE_MINUTES, Math.min(MAX_AUTOSAVE_MINUTES, minutes))
  var enabled = (raw && typeof raw.autosaveEnabled === "boolean") ? raw.autosaveEnabled : true
  var zoom = (raw && typeof raw.editorZoom === "number" && isFinite(raw.editorZoom))
    ? raw.editorZoom : DEFAULT_EDITOR_ZOOM
  zoom = Math.max(MIN_EDITOR_ZOOM, Math.min(MAX_EDITOR_ZOOM, zoom))
  var previewEnabled = (raw && typeof raw.previewEnabled === "boolean") ? raw.previewEnabled : true
  var lineNumbersEnabled = (raw && typeof raw.lineNumbersEnabled === "boolean") ? raw.lineNumbersEnabled : true
  var narrowMarginsEnabled = (raw && typeof raw.narrowMarginsEnabled === "boolean") ? raw.narrowMarginsEnabled : false
  var rightPaneHidden = (raw && typeof raw.rightPaneHidden === "boolean") ? raw.rightPaneHidden : false
  // "" means unconfigured — a fresh install has no sensible default
  // (it's meant to point at the user's own Logseq-style journal folder,
  // wherever that lives), so the Journal tab shows a "configure this in
  // Paramètres" prompt instead of guessing a path.
  var journalDir = (raw && typeof raw.journalDir === "string") ? raw.journalDir.slice(0, MAX_DOC_PATH_LEN) : ""
  var claudeModel = (raw && CLAUDE_MODELS.indexOf(raw.claudeModel) !== -1) ? raw.claudeModel : ""
  var claudeEffort = (raw && CLAUDE_EFFORTS.indexOf(raw.claudeEffort) !== -1) ? raw.claudeEffort : ""
  // "" = sync disabled — same convention as journalDir above (GH Grilles
  // uses the identical "" = off convention for its own syncDir).
  var commandsSyncDir = (raw && typeof raw.commandsSyncDir === "string") ? raw.commandsSyncDir.slice(0, MAX_DOC_PATH_LEN) : ""
  return { autosaveMinutes: minutes, autosaveEnabled: enabled, editorZoom: zoom, previewEnabled: previewEnabled, lineNumbersEnabled: lineNumbersEnabled, narrowMarginsEnabled: narrowMarginsEnabled, rightPaneHidden: rightPaneHidden, journalDir: journalDir, claudeModel: claudeModel, claudeEffort: claudeEffort, commandsSyncDir: commandsSyncDir }
}

function parseSettings(text) {
  var parsed = {}
  try { parsed = JSON.parse(text || "{}") } catch (e) { parsed = {} }
  if (!parsed || typeof parsed !== "object") parsed = {}
  return sanitizeSettings(parsed)
}

function serializeSettings(settings) {
  return JSON.stringify(sanitizeSettings(settings), null, 2) + "\n"
}

// --- commands bank ("Commandes" tab, Gabriel's ask 2026-09-05) ----------
//
// A personal library of frequently-reused Typst snippets — { id, title,
// command } — with a "Copier" button per entry (wl-copy, same as every
// other copy-to-clipboard action in this codebase; deliberately NOT an
// insert-at-cursor, Gabriel's explicit choice: he pastes it himself).
// Sync is the same additive-merge-via-shared-file design as GH Grilles'
// own criteria bank (see that plugin's lib/Store.js/Panel.qml runSync()) —
// copied here rather than shared, since these are two separate plugin
// repos with no shared dependency between them.

var MAX_COMMAND_TITLE_LEN = 120
var MAX_COMMAND_LEN = 4000
var MAX_COMMAND_ENTRIES = 400
var MAX_COMMAND_TOMBSTONES = 500

function sanitizeCommandEntry(raw) {
  if (!raw || typeof raw !== "object") return null
  var title = clip(raw.title, MAX_COMMAND_TITLE_LEN).trim()
  var command = clip(raw.command, MAX_COMMAND_LEN)
  if (!title || !command.trim()) return null
  var id = (typeof raw.id === "string" && raw.id.trim().length > 0) ? clip(raw.id, 64) : makeCommandId()
  return { id: id, title: title, command: command }
}

function makeCommandId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
}

// clip() and makeId() above are ghtypst's own — this file never had a
// generic clip() before, so it's defined here rather than duplicated;
// makeCommandId() stays separate from any other id generator in this file
// (there isn't one) to avoid coupling two unrelated features later.
function clip(s, max) {
  return String(s || "").slice(0, max)
}

function sanitizeCommandBank(raw) {
  var arr = Array.isArray(raw) ? raw : []
  var out = []
  var seenIds = {}
  for (var i = 0; i < arr.length && out.length < MAX_COMMAND_ENTRIES; i++) {
    var entry = sanitizeCommandEntry(arr[i])
    if (!entry || seenIds[entry.id]) continue
    seenIds[entry.id] = true
    out.push(entry)
  }
  return out
}

function parseCommandBank(text) {
  var parsed = []
  try { parsed = JSON.parse(text || "[]") } catch (e) { parsed = [] }
  return sanitizeCommandBank(parsed)
}

function serializeCommandBank(bank) {
  return JSON.stringify(sanitizeCommandBank(bank), null, 2) + "\n"
}

// Appended at the end (not merged into an existing entry) — unlike the
// criteria bank's (tag, text) upsert, a command's title and body can both
// legitimately change over time, and there's no natural identity key
// short of the id itself. Order is preserved: newest at the bottom, same
// as the on-screen list.
function addCommandEntry(bank, title, command) {
  var clean = sanitizeCommandBank(bank)
  var entry = sanitizeCommandEntry({ title: title, command: command })
  if (!entry) return clean
  return clean.concat([entry])
}

function removeCommandEntry(bank, id) {
  return sanitizeCommandBank(bank).filter(function(e) { return e.id !== id })
}

// Identity for sync merge/tombstones: (title, command) rather than the
// locally-generated id, since two machines each generate their own id for
// what's conceptually the same snippet — same reasoning as GH Grilles'
// entryKey() for its (tag, text) pairs.
function commandKey(title, command) {
  return String(title || "").trim().toLowerCase() + " " + String(command || "").trim()
}

function sanitizeCommandTombstones(raw) {
  var arr = Array.isArray(raw) ? raw : []
  var out = []
  var seen = {}
  for (var i = 0; i < arr.length && out.length < MAX_COMMAND_TOMBSTONES; i++) {
    var k = typeof arr[i] === "string" ? arr[i].slice(0, 300) : ""
    if (!k || seen[k]) continue
    seen[k] = true
    out.push(k)
  }
  return out
}

function parseCommandTombstones(text) {
  var parsed = []
  try { parsed = JSON.parse(text || "[]") } catch (e) { parsed = [] }
  return sanitizeCommandTombstones(parsed)
}

function serializeCommandTombstones(list) {
  return JSON.stringify(sanitizeCommandTombstones(list), null, 2) + "\n"
}

// Union-merges two command banks — NEVER deletes anything from either
// side except entries whose (title, command) key is in tombstoneKeys (a
// command removed locally since the last sync). Same "no deletion
// propagation" trade-off as GH Grilles: a local delete stops re-importing
// that entry on THIS machine, but the other machine keeps re-asserting
// its own copy until deleted there too.
function mergeCommandBanks(localBank, remoteBank, tombstoneKeys) {
  var localClean = sanitizeCommandBank(localBank)
  var remoteClean = sanitizeCommandBank(remoteBank)
  var seenKeys = {}
  var merged = []
  var all = localClean.concat(remoteClean)
  for (var i = 0; i < all.length; i++) {
    var key = commandKey(all[i].title, all[i].command)
    if (seenKeys[key]) continue
    seenKeys[key] = true
    merged.push(all[i])
  }
  var stones = {}
  var keys = Array.isArray(tombstoneKeys) ? tombstoneKeys : []
  for (var j = 0; j < keys.length; j++) stones[keys[j]] = true
  return merged.filter(function(e) { return !stones[commandKey(e.title, e.command)] })
}
