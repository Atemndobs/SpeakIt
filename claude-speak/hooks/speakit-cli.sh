#!/usr/bin/env bash
# Thin wrapper around SpeakIt's speakit:// URL scheme.
# Usage: speakit-cli.sh speak <text>
#        speakit-cli.sh file <path>
#        speakit-cli.sh stop|next|prev
set -euo pipefail

cmd="${1:-}"; shift || true

encode() { printf '%s' "$1" | /usr/bin/jq -sRr @uri; }

case "$cmd" in
  speak)
    text="${*:-}"
    [ -z "$text" ] && { echo "speak: missing text" >&2; exit 1; }
    /usr/bin/open "speakit://speak?text=$(encode "$text")"
    ;;
  file)
    path="${1:-}"
    [ -f "$path" ] || { echo "file: not found: $path" >&2; exit 1; }
    /usr/bin/open "speakit://speak?text=$(encode "$(/bin/cat "$path")")"
    ;;
  stop|next|prev)
    /usr/bin/open "speakit://$cmd"
    ;;
  *)
    echo "usage: $0 {speak <text>|file <path>|stop|next|prev}" >&2
    exit 2
    ;;
esac
