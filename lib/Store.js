// Pure data + sanitizers, no file I/O (that lives in Panel.qml's FileView).
//
// Persisted session state is the buffer itself, not just "which file was
// open" — kept from a later fix, deliberately not reverted with the rest:
// without it, every plugin reload (a shell restart, routine during
// development) silently destroyed unsaved work, worst of all for an
// untitled document that has nowhere else to live at all. Confirmed this
// happened for real, not a hypothetical.

var MAX_DOC_PATH_LEN = 1024
var MAX_DOC_BYTES = 5242880 // 5 MB — generous for a .typ source file

function sanitizeSession(raw) {
  var lastDocPath = (raw && typeof raw.lastDocPath === "string") ? raw.lastDocPath.slice(0, MAX_DOC_PATH_LEN) : ""
  var bufferText = (raw && typeof raw.bufferText === "string") ? raw.bufferText.slice(0, MAX_DOC_BYTES) : ""
  return { lastDocPath: lastDocPath, bufferText: bufferText }
}

function parseSession(text) {
  var parsed = {}
  try { parsed = JSON.parse(text || "{}") } catch (e) { parsed = {} }
  if (!parsed || typeof parsed !== "object") parsed = {}
  return sanitizeSession(parsed)
}

function serializeSession(session) {
  return JSON.stringify(sanitizeSession(session), null, 2) + "\n"
}

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
  var claudeModel = (raw && CLAUDE_MODELS.indexOf(raw.claudeModel) !== -1) ? raw.claudeModel : ""
  var claudeEffort = (raw && CLAUDE_EFFORTS.indexOf(raw.claudeEffort) !== -1) ? raw.claudeEffort : ""
  return { autosaveMinutes: minutes, autosaveEnabled: enabled, editorZoom: zoom, previewEnabled: previewEnabled, lineNumbersEnabled: lineNumbersEnabled, claudeModel: claudeModel, claudeEffort: claudeEffort }
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
