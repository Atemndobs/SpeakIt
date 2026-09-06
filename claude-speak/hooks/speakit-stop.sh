#!/usr/bin/env bash
# Stop hook: pipes Claude's last assistant message to SpeakIt via speakit:// URL scheme.
# Set CLAUDE_SPEAK=0 to disable without uninstalling the plugin.
set -euo pipefail

[ "${CLAUDE_SPEAK:-1}" = "0" ] && exit 0

# Honor the SpeakIt "Speak Claude Code responses" toggle at the source. When
# it's off, do nothing: never launch the app, never speak. This makes "off" mean
# off even when SpeakIt is quit, because the setting persists in the app's prefs.
# Flip it from the SpeakIt menu-bar panel. Unset (never toggled) counts as off.
if [ "$(/usr/bin/defaults read com.atem.SpeakIt autoSpeech.claudeCode.enabled 2>/dev/null || echo 0)" != "1" ]; then
  exit 0
fi

payload="$(cat)"
transcript="$(printf '%s' "$payload" | /usr/bin/jq -r '.transcript_path // empty')"
[ -z "$transcript" ] || [ ! -f "$transcript" ] && exit 0

# Project working directory → SpeakIt's "open folder" control points here.
cwd="$(printf '%s' "$payload" | /usr/bin/jq -r '.cwd // empty')"

# Last assistant message → concatenated text parts.
text="$(/usr/bin/jq -sr '
  map(select(.type == "assistant"))
  | last
  | .message.content
  | map(select(.type == "text") | .text)
  | join("\n")
' "$transcript" 2>/dev/null || true)"

# Strip markdown so TTS doesn't say "asterisk asterisk".
# Shared with the voice-queue hook; see hooks/lib/strip_markdown.py.
PY="$(command -v python3 || echo /usr/bin/python3)"
text="$(printf '%s' "$text" | "$PY" "$(dirname "${BASH_SOURCE[0]}")/lib/strip_markdown.py")"

[ -z "$text" ] && exit 0

encoded="$(printf '%s' "$text" | /usr/bin/jq -sRr @uri)"

# Point the "open in reader" control at the folder holding the most recently
# touched plan, so the web app lands where the plan lives instead of the repo
# root. Falls back to cwd when no plan file is found. Heavy dirs are pruned so
# the scan stays fast even in large repos.
src_path="$cwd"
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  latest_plan="$(find "$cwd" -maxdepth 8 \
      \( -name node_modules -o -name .git -o -name .build -o -name dist -o -name build -o -name .next \) -prune \
      -o -type f \( -path '*/.planning/*.md' -o -iname 'PLAN.md' -o -iname '*plan*.md' \) -print0 2>/dev/null \
    | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$latest_plan" ] && [ -f "$latest_plan" ] && src_path="$(dirname "$latest_plan")"
fi

src=""
[ -n "$src_path" ] && [ -d "$src_path" ] && src="&source=$(printf '%s' "$src_path" | /usr/bin/jq -sRr @uri)"

# Title the player with the project (repo) name so you can tell which chat is
# talking. Prefer the folder the source resolves to (the plan folder), else the
# project working directory's basename.
title_src="${src_path:-$cwd}"
title=""
if [ -n "$title_src" ]; then
  title="&title=$(printf '%s' "$(/usr/bin/basename "$title_src")" | /usr/bin/jq -sRr @uri)"
fi

# speak-response rather than speak: it carries the same source/title/origin,
# and routes through the request handler so markdown is stripped once.
/usr/bin/open "speakit://speak-response?text=${encoded}${src}${title}&origin=claude-code&requestSource=plugin&action=replace&sanitizeMarkdown=1" >/dev/null 2>&1 || true
exit 0
