#!/usr/bin/env bash
# Compiles a Typst source file to one PNG per page and reports diagnostics
# as JSON. The caller (Panel.qml) is responsible for writing the current
# editor buffer to <src> first — this script only runs the compiler and
# parses its output, no buffer/session logic here.
#
# Pages land as <out-dir>/<out-prefix>1.png, <out-prefix>2.png, ... (never
# padded — matches typst's own {p} substitution verified live). Existing
# page files under that prefix are deleted before compiling and the result
# JSON reports the real page count, so a document edited down to fewer
# pages doesn't leave stale higher-numbered pages for the caller to
# mistakenly keep displaying.
#
# Usage: compile.sh <src.typ> <root-dir> <out-dir> <out-prefix>
set -uo pipefail

SRC="${1:-}"
ROOT="${2:-}"
OUT_DIR="${3:-}"
OUT_PREFIX="${4:-}"
MAX_STDERR_BYTES=65536
MAX_PAGES=500 # sane ceiling so a runaway document can't loop forever below

if [ -z "$SRC" ] || [ -z "$ROOT" ] || [ -z "$OUT_DIR" ] || [ -z "$OUT_PREFIX" ]; then
  printf '{"ok":false,"pageCount":0,"errors":[{"line":0,"col":0,"severity":"error","message":"usage: compile.sh <src.typ> <root-dir> <out-dir> <out-prefix>"}]}\n'
  exit 1
fi

page_path() { printf '%s' "${OUT_DIR}/${OUT_PREFIX}${1}.png"; }

# Clean slate: delete any page files from a previous compile so a doc that
# just got shorter doesn't leave old, now-stale higher-numbered pages
# sitting on disk.
i=1
while [ -f "$(page_path "$i")" ] && [ "$i" -le "$MAX_PAGES" ]; do
  rm -f "$(page_path "$i")"
  i=$((i + 1))
done

# Same reasoning as before for avoiding a pipe here: command substitution
# keeps `$?` as typst's own exit status, not a downstream pipe stage's.
STDERR_RAW=$(typst compile --diagnostic-format short --ppi 200 --root "$ROOT" "$SRC" "$(page_path '{p}')" 2>&1 1>/dev/null)
EXIT_CODE=$?
STDERR_RAW="${STDERR_RAW:0:$MAX_STDERR_BYTES}"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr '\n' '\036')"
  s="${s//$'\036'/\\n}"
  printf '%s' "$s"
}

# `typst compile`'s --diagnostic-format short line shape:
#   <path>:<line>:<col>: error: <message>
#   <path>:<line>:<col>: warning: <message>
# Parsed with awk rather than a single sed/grep pass — needs to split on
# the FIRST two colons after the path only (the message itself may
# contain colons), and the path may itself contain colons on some setups
# (rare, but don't assume it can't).
ERRORS_JSON="[]"
if [ -n "$STDERR_RAW" ]; then
  ERRORS_JSON=$(printf '%s\n' "$STDERR_RAW" | awk -F': ' '
    /^.+:[0-9]+:[0-9]+: (error|warning): /  {
      n = split($1, parts, ":")
      line = parts[n-1]
      col = parts[n]
      severity = $2
      msg = $0
      sub(/^.+: (error|warning): /, "", msg)
      printf "%s\t%s\t%s\t%s\n", line, col, severity, msg
    }
  ' | while IFS=$'\t' read -r line col severity msg; do
    printf '{"line":%s,"col":%s,"severity":"%s","message":"%s"},' \
      "${line:-0}" "${col:-0}" "$severity" "$(json_escape "$msg")"
  done)
  ERRORS_JSON="[${ERRORS_JSON%,}]"
fi

PAGE_COUNT=0
i=1
while [ -f "$(page_path "$i")" ] && [ "$i" -le "$MAX_PAGES" ]; do
  PAGE_COUNT=$i
  i=$((i + 1))
done

if [ "$EXIT_CODE" -eq 0 ] && [ "$PAGE_COUNT" -gt 0 ]; then
  printf '{"ok":true,"pageCount":%s,"errors":%s}\n' "$PAGE_COUNT" "$ERRORS_JSON"
else
  [ "$ERRORS_JSON" = "[]" ] && ERRORS_JSON='[{"line":0,"col":0,"severity":"error","message":"La compilation a échoué sans diagnostic exploitable."}]'
  printf '{"ok":false,"pageCount":%s,"errors":%s}\n' "$PAGE_COUNT" "$ERRORS_JSON"
fi
