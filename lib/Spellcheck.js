// Local, offline spellcheck for the editor ("Éditeur" tab) — hunspell,
// no Claude, no network. Gabriel's explicit instruction, 2026-08-29: check
// the WHOLE document, no attempt to distinguish Typst code from prose —
// he reviews each flagged word himself and knows perfectly well that
// `#align(right)` is code, so trying to be clever about scope here would
// just be unnecessary (and error-prone) complexity for no benefit.
//
// Two-phase design, arrived at after a real performance incident this
// same session: an early version ran hunspell's "-a" mode (which reports
// per-word suggestions) over the whole document on every edit debounce.
// Benchmarked live against Gabriel's own ~62KB stress-test document
// (`~/Downloads/test volumineux.typ`, code-heavy — lots of Typst
// identifiers hunspell doesn't recognize): 32 SECONDS, because
// suggestion generation (a fuzzy dictionary search) is the expensive
// part, run there for all ~400+ flagged words whether needed or not.
// Gabriel pointed out that Typesetter (codeberg.org/haydn/typesetter, a
// native GTK app) handles the same document live with no trouble —
// checked its Cargo.toml: it uses `libspelling` (GNOME's modern
// spellcheck library, incremental + suggestions on demand), never
// generating suggestions eagerly either. This module follows the same
// split:
//   1. Detection (cheap, run live on debounce): tokenize the document
//      ourselves, dedupe, run hunspell's "-l" mode (list misspelled
//      words, NO suggestion generation) on just the unique words.
//      Benchmarked on the same stress document: 53ms. Positions come
//      from our OWN tokenization pass, never from hunspell's own offset
//      reporting — sidesteps two real problems found while building the
//      first version: hunspell's per-line word-splitting has quirks
//      (attached punctuation, inconsistent between mid-line/end-of-line)
//      that don't reliably match a hand-written tokenizer, and its
//      reported offsets are UTF-8 BYTE offsets, not character offsets,
//      which silently misplaces everything after any accented character
//      earlier in the line if not converted. Checking our own exact
//      tokens against hunspell's flagged-word set avoids both issues
//      entirely — nothing to convert, nothing to match up.
//   2. Suggestions (on demand, one word at a time, when the user
//      right-clicks a flagged word): hunspell -a on that single word.
//      Benchmarked: 40-240ms per word, fine for a click-triggered menu.

var WORD_CHAR_CLASS = "A-Za-zÀ-ÖØ-öø-ÿ'’-"
var WORD_RE = new RegExp("[" + WORD_CHAR_CLASS + "]+", "g")

// Tokenizes text into {word, start, end} for every word-like run —
// French letters (incl. accents), apostrophe, hyphen. Punctuation,
// digits, and Typst markers (#, $, brackets...) are never part of a
// token, so they can never end up inside a misspelled-word span.
function tokenize(text) {
  var out = []
  var m
  WORD_RE.lastIndex = 0
  while ((m = WORD_RE.exec(text)) !== null) {
    out.push({ word: m[0], start: m.index, end: m.index + m[0].length })
  }
  return out
}

function buildDiscoverCommand() {
  return ["hunspell", "-D"]
}

function _basename(p) {
  var idx = p.lastIndexOf("/")
  return idx === -1 ? p : p.slice(idx + 1)
}

// hunspell -D prints its search path, a locale-dependent "available
// dictionaries" header, then the candidates — confirmed live on the real
// system, and NOT what an initial synthetic guess assumed: each
// candidate is a FULL PATH here (e.g. "/usr/share/hunspell/fr_FR"), one
// per search-path directory that has it (so real duplicates are normal,
// e.g. both /usr/share/hunspell/fr_FR and /usr/share/myspell/dicts/fr_FR
// for the one installed dictionary) — not a bare name as first assumed.
// A trailing "DICTIONNAIRES CHARGÉS" section (only present once a
// dictionary actually resolves) lists the literal .aff/.dic FILES, which
// are not valid -d values and are excluded. Returns the first candidate
// whose basename looks French, used as-is (full path or bare name,
// whichever hunspell gave) since -d accepts either — confirmed live,
// this is not assumed either.
function parseDiscoverOutput(text) {
  var lines = String(text || "").split("\n")
  var candidates = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (line.indexOf(":") !== -1) continue // header lines + the colon-separated search-path line
    if (/\.(aff|dic)$/i.test(line)) continue // "DICTIONNAIRES CHARGÉS" trailer — actual files, not -d values
    candidates.push(line)
  }
  var frExact = candidates.filter(function(c) { return /^fr[_-]fr$/i.test(_basename(c)) })
  if (frExact.length > 0) return frExact[0]
  var frAny = candidates.filter(function(c) { return /^fr/i.test(_basename(c)) })
  if (frAny.length > 0) return frAny[0]
  return ""
}

function buildDetectCommand(dictName) {
  return ["hunspell", "-l", "-d", dictName]
}

// Feeds one unique word per line — deliberately not the raw document
// text, see this file's header comment for why (avoids hunspell's own
// line-tokenization quirks entirely by only ever asking it about exact
// tokens we already extracted ourselves).
function buildDetectInput(uniqueWords) {
  return uniqueWords.join("\n") + "\n"
}

// hunspell -l's stdout is just the misspelled words, one per line (a
// subset of what was fed in) — no offsets to parse, no banner line
// either (that only appears in "-a" mode).
function parseDetectOutput(rawOutput) {
  var set = {}
  var lines = String(rawOutput || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var w = lines[i]
    if (w !== "") set[w] = true
  }
  return set
}

// Runs detection end-to-end over `text`: tokenizes, dedupes, and returns
// {misspelledSet} for the caller to combine with the *same* tokenize()
// call's positions — kept as two steps (tokenize, then this) rather than
// one, so Panel.qml can tokenize once and reuse the offsets after the
// async hunspell run completes without re-tokenizing (the buffer may
// have moved on by then, but re-tokenizing a *stale* snapshot the
// process was actually run against is still correct — the caller is
// responsible for using the tokens from the same tokenize() call whose
// text was fed to the process).
function uniqueWords(tokens) {
  var seen = {}
  var out = []
  for (var i = 0; i < tokens.length; i++) {
    var w = tokens[i].word
    if (!seen[w]) { seen[w] = true; out.push(w) }
  }
  return out
}

function buildSuggestCommand(dictName) {
  return ["hunspell", "-a", "-d", dictName]
}

function buildSuggestInput(word) {
  return "^" + word + "\n"
}

// Parses hunspell -a's output for a single-word query into a
// suggestions array (possibly empty — a real "no close match" result,
// not a parse failure).
function parseSuggestOutput(rawOutput) {
  var lines = String(rawOutput || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.charAt(0) === "&") {
      var m = line.match(/^&\s+\S+\s+\d+\s+\d+:\s*(.*)$/)
      if (m) return m[1].length > 0 ? m[1].split(", ") : []
    } else if (line.charAt(0) === "#") {
      return []
    }
  }
  return []
}
