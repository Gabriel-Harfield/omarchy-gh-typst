// Re-confirmed in use 2026-08-27: the "ghost lines" bug blamed on this
// file's span density was a misdiagnosis — Gabriel confirmed the coloring
// itself always rendered fine; the real cause was the current-block
// highlight Rectangle that used to sit alongside these two TextEdits (see
// EditorTab.qml's comment and the ghtypst-plugin memory). Don't touch this
// file over a recurrence of that bug — look at what else changed instead.
//
// Single-pass highlighter — not a real Typst parser. Turns source text
// into an HTML fragment for a *read-only* underlay behind the actual
// plain-text-editable TextEdit (see EditorTab.qml): the underlay is purely
// cosmetic, so if it ever mis-highlights something the real editing
// experience (typing, cursor, selection) is completely unaffected.
//
// Color only, deliberately never weight/size: this HTML sits in a
// read-only underlay stacked exactly behind a plain-text-editable TextEdit
// showing the same string. Any styling that shifts glyph *metrics* (bold,
// italic, different size) desyncs the two layers' line wrapping and lands
// the visible cursor in the wrong place — confirmed live the hard way
// once already, not a theoretical concern.

var CODE_COLOR = "#5da8f2"     // #calls and their bracketed arguments
var KEYWORD_COLOR = "#c586c0"  // keywords inside a code span
var COMMENT_COLOR = "#7d8590"  // // and /* */
var HEADING_COLOR = "#e0af68"  // = / == / ... lines
var RAW_COLOR = "#73daca"      // `raw code` spans
var MATH_COLOR = "#f7768e"     // $math$ spans

var KEYWORDS = ["let", "if", "else", "for", "while", "import", "include", "set", "show",
  "return", "break", "continue", "and", "or", "not", "in", "as", "none", "auto",
  "true", "false", "function", "context"]

// Also converts embedded newlines to <br/> — needed because a multi-line
// #call[...] code span or a /* */ block comment gets its whole raw range
// (newlines included) fed through this function via span()/highlightCode
// Span(), not through toHtml()'s own top-level "\n" -> <br/> branch (that
// branch only ever sees single-line chunks, since its plain-run batching
// stops at "\n"). Without this, embedded newlines were emitted as literal
// \n characters inside a text node, which HTML whitespace-collapses —
// confirmed live 2026-08-27: a multi-line #align(...)[...] block visually
// merged onto one line despite the underlying plain text being untouched.
function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\n/g, "<br/>")
}

function span(color, text) {
  return "<span style=\"color:" + color + ";\">" + escapeHtml(text) + "</span>"
}

function isIdentStart(ch) { return /[A-Za-z_]/.test(ch || "") }
function isIdentChar(ch) { return /[A-Za-z0-9_]/.test(ch || "") }

// Scans a `#name` code marker plus any immediately-adjacent, balanced
// bracket groups that follow it (handles nesting and chaining, e.g.
// `#figure(image("x.png"))[Légende]`) — returns the index just past the
// whole span.
function scanCodeSpan(text, start) {
  var n = text.length
  var i = start + 1 // past '#'
  while (i < n && isIdentChar(text[i])) i++
  while (i < n && (text[i] === "(" || text[i] === "[" || text[i] === "{")) {
    var depth = 0
    do {
      var ch = text[i]
      if (ch === "(" || ch === "[" || ch === "{") depth++
      else if (ch === ")" || ch === "]" || ch === "}") depth--
      i++
    } while (i < n && depth > 0)
  }
  return i
}

// Recolors keywords found inside an already-isolated code-span substring,
// falling back to the base code color for everything else in it. Adjacent
// runs of the *same* color are merged into one <span> instead of emitting
// one per token/punctuation-run — a real fix, not just tidiness: with one
// span per token, a call like `image("x.png")` fragmented into 8+ tiny
// same-color spans, and that markup density was enough to make the rich
// text underlay's line-wrapping subtly diverge from the plain-text input
// layer's, which is what showed up as "ghost lines" — the two layers must
// wrap character-for-character identically for the overlay trick to work.
function highlightCodeSpan(text) {
  var n = text.length
  var i = 0
  var out = ""
  var pendingColor = null
  var pendingText = ""

  function flush() {
    if (pendingText === "") return
    out += span(pendingColor, pendingText)
    pendingText = ""
  }

  function push(color, chunk) {
    if (color === pendingColor) {
      pendingText += chunk
    } else {
      flush()
      pendingColor = color
      pendingText = chunk
    }
  }

  while (i < n) {
    if (isIdentStart(text[i]) || (text[i] === "#" && isIdentStart(text[i + 1]))) {
      var start = i
      if (text[i] === "#") i++
      while (i < n && isIdentChar(text[i])) i++
      var word = text.slice(start, i)
      var bare = word.charAt(0) === "#" ? word.slice(1) : word
      push(KEYWORDS.indexOf(bare) !== -1 ? KEYWORD_COLOR : CODE_COLOR, word)
      continue
    }
    var runStart = i
    while (i < n && !isIdentStart(text[i]) && text[i] !== "#") i++
    if (i === runStart) i++ // guarantee forward progress on stray symbols
    push(CODE_COLOR, text.slice(runStart, i))
  }
  flush()
  return out
}

// No coloring at all — same escaping/newline/whitespace handling as
// toHtml() (reuses escapeHtml() and the identical white-space:pre-wrap
// wrapper) but skips every span()-producing scan entirely. Added
// 2026-09-02 as a performance diagnostic: Gabriel wants to know whether
// the coloring logic itself is the cost, or whether QML's TextEdit/
// RichText relayout is expensive regardless of what's in the markup
// (same document size either way). Safe to swap in for toHtml() at any
// call site — same output shape (one wrapping <span>, <br/> for
// newlines), so nothing downstream needs to know which one ran.
function toPlainHtml(text) {
  return "<span style=\"white-space:pre-wrap;\">" + escapeHtml(text) + "</span>"
}

function toHtml(text) {
  var n = text.length
  var out = ""
  var i = 0
  var atLineStart = true

  while (i < n) {
    var ch = text[i]

    if (atLineStart && ch === "=") {
      var j = i
      while (j < n && text[j] === "=") j++
      if (text[j] === " ") {
        var eol = text.indexOf("\n", j)
        var stop = eol === -1 ? n : eol
        out += span(HEADING_COLOR, text.slice(i, stop))
        i = stop
        atLineStart = false
        continue
      }
    }

    if (ch === "/" && text[i + 1] === "*") {
      var blockEnd = text.indexOf("*/", i + 2)
      var stopB = blockEnd === -1 ? n : blockEnd + 2
      out += span(COMMENT_COLOR, text.slice(i, stopB))
      i = stopB
      atLineStart = false
      continue
    }

    if (ch === "/" && text[i + 1] === "/") {
      var eolC = text.indexOf("\n", i)
      var stopC = eolC === -1 ? n : eolC
      out += span(COMMENT_COLOR, text.slice(i, stopC))
      i = stopC
      atLineStart = false
      continue
    }

    if (ch === "`") {
      var closeR = text.indexOf("`", i + 1)
      var eolR = text.indexOf("\n", i + 1)
      var stopR = (closeR !== -1 && (eolR === -1 || closeR < eolR)) ? closeR + 1 : (eolR === -1 ? n : eolR)
      out += span(RAW_COLOR, text.slice(i, stopR))
      i = stopR
      atLineStart = false
      continue
    }

    if (ch === "$") {
      var closeM = text.indexOf("$", i + 1)
      var eolM = text.indexOf("\n", i + 1)
      var stopM = (closeM !== -1 && (eolM === -1 || closeM < eolM)) ? closeM + 1 : (eolM === -1 ? n : eolM)
      out += span(MATH_COLOR, text.slice(i, stopM))
      i = stopM
      atLineStart = false
      continue
    }

    if (ch === "#" && isIdentStart(text[i + 1])) {
      var end = scanCodeSpan(text, i)
      // A code span's own bracket-depth scan happily continues across
      // newlines (needed to find the real end of a multi-line call like
      // #columns(2, gutter: -3%)[ \ *A Cassandre* \ ... ]), but coloring
      // shouldn't: Gabriel's explicit ask is that hitting a newline,
      // even mid-bracket, reverts to the theme's default color — a
      // multi-line bracket body is very often prose (as in that exact
      // example), not code, past its first line. So only the segment up
      // to the first newline (if any) gets code-highlighted here; the
      // outer loop resumes normal top-level scanning right after that
      // newline, which lets any further #marker, heading, etc. on later
      // lines still highlight on its own terms rather than being frozen
      // into "still inside a code span" forever.
      var firstNl = text.indexOf("\n", i)
      var stop = (firstNl !== -1 && firstNl < end) ? firstNl : end
      out += highlightCodeSpan(text.slice(i, stop))
      i = stop
      atLineStart = false
      continue
    }

    if (ch === "\n") {
      out += "<br/>"
      i++
      atLineStart = true
      continue
    }

    // Plain run: batch everything up to the next character that could
    // start a special span, so long stretches of prose aren't escaped
    // one character at a time.
    var next = i + 1
    while (next < n && "/#`$\n".indexOf(text[next]) === -1) next++
    out += escapeHtml(text.slice(i, next))
    i = next
    atLineStart = false
  }

  // HTML collapses runs of whitespace by default, which silently eats
  // Typst's own leading-space indentation (e.g. a nested `#set` line) —
  // confirmed live 2026-08-27. `white-space:pre-wrap` preserves spaces
  // and still lets long lines wrap, unlike plain `pre` (no wrap at all).
  return "<span style=\"white-space:pre-wrap;\">" + out + "</span>"
}
