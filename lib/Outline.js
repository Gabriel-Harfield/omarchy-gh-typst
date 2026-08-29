// Extracts the heading outline (=, ==, ===...) from a Typst document, for
// the Éditeur tab's left-panel "titres" view (Gabriel's ask, 2026-08-29) —
// a click-to-jump structural map of the document, same spirit as the
// file-tree panel but for headings-within-a-document rather than
// files-on-disk. Deliberately its own file: a different concern from
// Highlighter.js (which recognizes the same `= heading` syntax but only
// to color it, never to extract a structured list from it).
//
// Same heading rule as Highlighter.js's own (kept independent rather than
// shared, since the two are simple enough that duplication is cheaper
// than coupling): one or more leading "=" at the very start of a line,
// followed by a space, is a heading. Level = number of "=" signs.

function parseHeadings(text) {
  var lines = String(text || "").split("\n")
  var headings = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var m = line.match(/^(=+)\s+(.*)$/)
    if (!m) continue
    var title = m[2].trim()
    if (title === "") continue
    headings.push({ level: m[1].length, title: title, line: i + 1 })
  }
  return headings
}
