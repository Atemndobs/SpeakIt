#!/usr/bin/env bash
# Last assistant message from a transcript, as concatenated text parts.
#
# Tool-use and thinking parts are skipped: only "text" parts are spoken.
# Every failure path yields empty output and exit 0, because a caller in a
# Stop hook must never abort a session over a missing transcript.
set -uo pipefail

transcript="${1:-}"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

JQ="$(command -v jq)" || exit 0

"$JQ" -sr '
  map(select(.type == "assistant"))
  | last
  | .message.content
  | map(select(.type == "text") | .text)
  | join("\n")
' "$transcript" 2>/dev/null | sed '/^null$/d'
exit 0
