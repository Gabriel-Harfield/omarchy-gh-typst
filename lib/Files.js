// Bounded, argv-only read of one named file inside a directory — used only
// to read commands.json back from the user-chosen "Commandes" sync folder
// (Gabriel's ask 2026-09-05). Straight copy of GH Grilles' own lib/Files.js
// (itself a trimmed copy of local.frenchdict-float-experiment's), unchanged:
// a sync folder can be a Dropbox-style location this plugin doesn't fully
// control between the moment it writes a file and the moment it reads it
// back, so the cap belongs on the producing side of the pipe, not in JS
// after the fact.
//
// find refuses anything over the cap outright (-size -Nc) rather than
// truncating it, head is the second ceiling in case the file grows between
// the stat and the read, and timeout bounds a filesystem that stops
// answering. A missing/oversized/unreadable file produces no output at
// all — callers treat empty output exactly like "no file here yet".

var MAX_NAME_LENGTH = 255
var MIN_CAP = 1024
var MAX_CAP = 16777216

function isReadableName(name) {
  var text = String(name || "")
  if (text.length === 0 || text.length > MAX_NAME_LENGTH) return false
  if (text.indexOf("..") !== -1) return false
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(text)
}

function isDirectoryPath(directory) {
  var text = String(directory || "")
  return text.length > 1 && text.charAt(0) === "/"
    && text.indexOf("\n") === -1 && text.indexOf("\r") === -1
}

function capBytes(bytes) {
  var cap = Math.floor(Number(bytes) || 0)
  return Math.max(MIN_CAP, Math.min(MAX_CAP, cap))
}

function readCommand(directory, name, cap, timeoutSeconds) {
  if (!isDirectoryPath(directory) || !isReadableName(name)) return null

  var limit = capBytes(cap)
  var seconds = Math.max(1, Math.min(30, Math.floor(Number(timeoutSeconds) || 5)))

  return [
    "timeout", "-k", "1", String(seconds),
    "find", String(directory), "-mindepth", "1", "-maxdepth", "1",
    "-name", String(name), "-type", "f", "-size", "-" + limit + "c",
    "-exec", "head", "-c", String(limit), "--", "{}", "+"
  ]
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_NAME_LENGTH: MAX_NAME_LENGTH,
    MIN_CAP: MIN_CAP,
    MAX_CAP: MAX_CAP,
    isReadableName: isReadableName,
    isDirectoryPath: isDirectoryPath,
    capBytes: capBytes,
    readCommand: readCommand
  }
}
