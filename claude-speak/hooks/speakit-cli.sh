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
    /usr/bin/open "speakit://speak-response?requestSource=cli&action=replace&sanitizeMarkdown=1&text=$(encode "$text")"
    ;;
  file)
    path="${1:-}"
    [ -f "$path" ] || { echo "file: not found: $path" >&2; exit 1; }
    # Absolute path so SpeakIt's "open in Finder" control can reveal the file.
    abs="$(/usr/bin/python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$path")"
    /usr/bin/open "speakit://speak-response?text=$(encode "$(/bin/cat "$path")")&source=$(encode "$abs")&requestSource=cli&action=replace&sanitizeMarkdown=1"
    ;;
  stop|next|prev)
    /usr/bin/open "speakit://$cmd"
    ;;
  *)
    echo "usage: $0 {speak <text>|file <path>|stop|next|prev}" >&2
    exit 2
    ;;
esac
