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
  return { autosaveMinutes: minutes, autosaveEnabled: enabled, editorZoom: zoom, previewEnabled: previewEnabled, lineNumbersEnabled: lineNumbersEnabled, narrowMarginsEnabled: narrowMarginsEnabled, rightPaneHidden: rightPaneHidden, journalDir: journalDir, claudeModel: claudeModel, claudeEffort: claudeEffort }
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
