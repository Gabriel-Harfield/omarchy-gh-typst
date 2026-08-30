// Pure month-grid math for the Journal tab (Gabriel's ask, 2026-08-30) — a
// small calendar above a plain-text view of that day's Logseq-compatible
// journal entry. No file I/O, no QML — same "verify with node before
// wiring in" discipline as every other lib/*.js file here.
//
// Week starts Monday (French convention), unlike JS's own Date.getDay()
// (Sunday=0).

var MONTH_NAMES = ["Janvier", "Février", "Mars", "Avril", "Mai", "Juin",
  "Juillet", "Août", "Septembre", "Octobre", "Novembre", "Décembre"]

function daysInMonth(year, month) {
  // month is 1-12; day 0 of the next month is the last day of this one.
  return new Date(year, month, 0).getDate()
}

function mondayFirstWeekday(year, month, day) {
  return (new Date(year, month - 1, day).getDay() + 6) % 7
}

// Returns an array of weeks; each week is exactly 7 cells, either null
// (padding before day 1 / after the month's last day) or an integer
// day-of-month (1-based).
function buildMonthGrid(year, month) {
  var total = daysInMonth(year, month)
  var firstWeekday = mondayFirstWeekday(year, month, 1)
  var cells = []
  for (var i = 0; i < firstWeekday; i++) cells.push(null)
  for (var d = 1; d <= total; d++) cells.push(d)
  while (cells.length % 7 !== 0) cells.push(null)
  var weeks = []
  for (var w = 0; w < cells.length; w += 7) weeks.push(cells.slice(w, w + 7))
  return weeks
}

function addMonths(year, month, delta) {
  var idx = (month - 1) + delta
  var y = year + Math.floor(idx / 12)
  var m = ((idx % 12) + 12) % 12 + 1
  return { year: y, month: m }
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

// Matches Logseq's own journal filename convention exactly, so entries
// created here are also found by Logseq and vice versa.
function dateKey(year, month, day) {
  return year + "_" + pad2(month) + "_" + pad2(day)
}

function monthLabel(year, month) {
  return (MONTH_NAMES[month - 1] || "") + " " + year
}

// Parses "YYYY_MM_DD.md" filenames (as listed from the journal directory)
// into a lookup of which days-of-month already have an entry, scoped to
// one specific year+month — used to render the calendar's dot markers
// without needing a per-day existence check.
function daysWithEntries(filenames, year, month) {
  var prefix = year + "_" + pad2(month) + "_"
  var out = {}
  for (var i = 0; i < filenames.length; i++) {
    var name = filenames[i]
    if (name.indexOf(prefix) !== 0) continue
    var rest = name.slice(prefix.length)
    var m = rest.match(/^(\d{2})\.md$/)
    if (!m) continue
    out[parseInt(m[1], 10)] = true
  }
  return out
}
