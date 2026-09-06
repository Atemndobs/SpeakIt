#!/usr/bin/env bash
# Stop hook: publish the last assistant message to the voice/queue branch.
#
# Runs identically on macOS and in a Linux cloud sandbox, which is the whole
# point: the audio should follow the session, not the laptop. The old
# speakit-stop.sh gated on a macOS defaults key and delivered over a macOS URL
# scheme, so it could only ever work at the desk.
#
# Set CLAUDE_VOICE=0 to disable.
#
# There is no `set -e` here on purpose, and the exit is unconditional. Losing a
# spoken response is a minor annoyance. Interrupting a working session over a
# text-to-speech convenience is not a trade worth making.
set -uo pipefail

exit_clean() { exit 0; }
trap exit_clean ERR

[ "${CLAUDE_VOICE:-1}" = "0" ] && exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JQ="$(command -v jq)" || exit 0
PY="$(command -v python3)" || exit 0

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

transcript="$(printf '%s' "$payload" | "$JQ" -r '.transcript_path // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | "$JQ" -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

text="$("$here/lib/extract_response.sh" "$transcript" 2>/dev/null || true)"
[ -n "$text" ] || exit 0
text="$(printf '%s' "$text" | "$PY" "$here/lib/strip_markdown.py" 2>/dev/null || true)"
[ -n "$text" ] || exit 0

# owner/name from the remote, for display and so the watcher can attribute it.
remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
repo="$("$here/lib/repo_slug.sh" "$remote" 2>/dev/null || true)"
title="$(basename "$cwd" 2>/dev/null || true)"

tmp="$(mktemp -d)" || exit 0
trap 'rm -rf "$tmp"' EXIT

"$PY" "$here/lib/queue_item.py" --text "$text" --repo "$repo" --title "$title" \
  > "$tmp/item.json" 2>/dev/null || exit 0

id="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$tmp/item.json" 2>/dev/null || true)"
[ -n "$id" ] || exit 0

"$here/lib/publish_item.sh" "$cwd" "$tmp/item.json" "$id" >/dev/null 2>&1 || true
exit 0
