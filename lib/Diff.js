// Word-level diff for the Claude tab's two-column comparison view (left:
// original text, right: Claude's proposal, changed portions highlighted
// red). Standard Myers O(ND) shortest-edit-script algorithm over
// whitespace/word tokens, so results are lossless (joining every token of
// either side reconstructs that side's exact text, newlines included) and
// changes come out as whole words, not scattered characters.
//
// Deliberately its own file, not folded into Highlighter.js: Highlighter
// is about recognizing Typst *syntax* categories, this is about comparing
// two arbitrary strings — unrelated concerns that happen to both produce
// colored RichText HTML.

function tokenize(text) {
  return String(text).match(/\s+|\S+/g) || []
}

function _snapshot(v) {
  var out = {}
  for (var key in v) out[key] = v[key]
  return out
}

// Real incident, 2026-08-29: a large document (~9000 tokens) with many
// scattered changes (~30% of words touched — a realistic outcome of an
// orthographe pass over a long document) took Myers' O(ND) diff ~4s in a
// plain node benchmark, and the equivalent real run inside the plugin
// froze Quickshell's single-threaded QML JS engine so hard it stopped
// answering IPC entirely and needed a `kill -9` — not a theoretical risk,
// a confirmed one. D (edit-script length) grows with every scattered
// change, not just with document size, so no fixed token-count cutoff is
// safe: a short document with heavy scattered edits can be just as
// expensive as a long one. A wall-clock budget checked periodically
// during the search, independent of exactly what makes a given diff
// expensive, is the only guard that actually bounds worst-case UI-thread
// blocking. On timeout, _shortestEditTrace returns null and callers fall
// back to an unhighlighted render rather than hanging.
var TIME_BUDGET_MS = 1200

function _shortestEditTrace(a, b) {
  var n = a.length, m = b.length, max = n + m
  var v = { 1: 0 }
  var trace = []
  var startedAt = Date.now()
  for (var d = 0; d <= max; d++) {
    if ((d & 63) === 0 && Date.now() - startedAt > TIME_BUDGET_MS) return null
    trace.push(_snapshot(v))
    for (var k = -d; k <= d; k += 2) {
      var x
      if (k === -d || (k !== d && (v[k - 1] || 0) < (v[k + 1] || 0))) {
        x = v[k + 1] || 0
      } else {
        x = (v[k - 1] || 0) + 1
      }
      var y = x - k
      while (x < n && y < m && a[x] === b[y]) { x++; y++ }
      v[k] = x
      if (x >= n && y >= m) return trace
    }
  }
  return trace
}

function _backtrack(a, b, trace) {
  var x = a.length, y = b.length
  var result = []
  for (var d = trace.length - 1; d >= 0; d--) {
    var v = trace[d]
    var k = x - y
    var prevK
    if (k === -d || (k !== d && (v[k - 1] || 0) < (v[k + 1] || 0))) {
      prevK = k + 1
    } else {
      prevK = k - 1
    }
    var prevX = v[prevK] || 0
    var prevY = prevX - prevK
    while (x > prevX && y > prevY) {
      result.push({ op: "equal", token: a[x - 1] })
      x--; y--
    }
    if (d > 0) {
      if (x === prevX) {
        result.push({ op: "insert", token: b[y - 1] })
      } else {
        result.push({ op: "delete", token: a[x - 1] })
      }
    }
    x = prevX; y = prevY
  }
  result.reverse()
  return result
}

// Returns an ordered list of {op:"equal"|"insert"|"delete", token}
// covering every token of both inputs exactly once, or null if the
// search exceeded TIME_BUDGET_MS (see _shortestEditTrace's own comment)
// — callers must handle null by falling back, not by assuming a result.
function diffTokens(a, b) {
  if (a.length === 0 && b.length === 0) return []
  var trace = _shortestEditTrace(a, b)
  if (trace === null) return null
  return _backtrack(a, b, trace)
}

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

// Builds a RichText HTML fragment rendering newText, with every token
// that isn't shared with oldText wrapped in a changeColor span. Deletions
// (tokens only in oldText) never appear — this renders the *proposed*
// text, not a merged view; the left column of the comparison shows
// oldText as-is separately. Adjacent same-op tokens are merged into one
// span, same reasoning as Highlighter.js's own span-merging: fewer,
// larger spans, lighter markup.
//
// Returns {html, highlighted}. When the diff itself hit the time budget
// (see _shortestEditTrace), highlighted is false and html is newText
// rendered plainly, no per-word color — the caller (ClaudeTab.qml) should
// tell the user why nothing's highlighted rather than silently showing
// an unmarked proposal.
function buildCorrectionHtml(oldText, newText, changeColor) {
  var ops = diffTokens(tokenize(oldText), tokenize(newText))
  if (ops === null) {
    var plain = "<span style=\"white-space:pre-wrap;\">" + escapeHtml(newText).replace(/\n/g, "<br/>") + "</span>"
    return { html: plain, highlighted: false }
  }

  var out = ""
  var pendingChanged = null
  var pendingText = ""

  function flush() {
    if (pendingText === "") return
    var body = escapeHtml(pendingText).replace(/\n/g, "<br/>")
    out += pendingChanged
      ? ("<span style=\"color:" + changeColor + ";\">" + body + "</span>")
      : body
    pendingText = ""
  }

  for (var i = 0; i < ops.length; i++) {
    var entry = ops[i]
    if (entry.op === "delete") continue
    var changed = entry.op === "insert"
    if (changed !== pendingChanged) {
      flush()
      pendingChanged = changed
    }
    pendingText += entry.token
  }
  flush()
  return { html: "<span style=\"white-space:pre-wrap;\">" + out + "</span>", highlighted: true }
}
