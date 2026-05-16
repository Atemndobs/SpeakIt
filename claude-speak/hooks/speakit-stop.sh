#!/usr/bin/env bash
# Stop hook: pipes Claude's last assistant message to SpeakIt via speakit:// URL scheme.
# Set CLAUDE_SPEAK=0 to disable without uninstalling the plugin.
set -euo pipefail

[ "${CLAUDE_SPEAK:-1}" = "0" ] && exit 0

payload="$(cat)"
transcript="$(printf '%s' "$payload" | /usr/bin/jq -r '.transcript_path // empty')"
[ -z "$transcript" ] || [ ! -f "$transcript" ] && exit 0

# Last assistant message → concatenated text parts.
text="$(/usr/bin/jq -sr '
  map(select(.type == "assistant"))
  | last
  | .message.content
  | map(select(.type == "text") | .text)
  | join("\n")
' "$transcript" 2>/dev/null || true)"

# Strip markdown so TTS doesn't say "asterisk asterisk".
text="$(printf '%s' "$text" | /usr/bin/python3 -c '
import re, sys
t = sys.stdin.read()
t = re.sub(r"```.*?```", "", t, flags=re.S)            # fenced code blocks
t = re.sub(r"`([^`]*)`", r"\1", t)                      # inline code
t = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", t)              # images
t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)          # links → text
# Tables: drop alignment row, flatten body rows into comma-separated text.
# Use [ \t|:-] (NOT \s) in the char class so matches stay within one line.
t = re.sub(r"^[ \t]*\|?[ \t|:\-]*-{2,}[ \t|:\-]*\|?[ \t]*$", "", t, flags=re.M)
t = re.sub(
    r"^[ \t]*\|(.+?)\|[ \t]*$",
    lambda m: ", ".join(c.strip() for c in m.group(1).split("|") if c.strip()),
    t,
    flags=re.M,
)
t = re.sub(r"^\s{0,3}#{1,6}\s+", "", t, flags=re.M)     # headers
t = re.sub(r"^\s{0,3}>\s?", "", t, flags=re.M)          # blockquotes
t = re.sub(r"^\s*[-*+]\s+", "", t, flags=re.M)          # bullets
t = re.sub(r"^\s*\d+\.\s+", "", t, flags=re.M)          # numbered lists
t = re.sub(r"\*\*([^*]+)\*\*", r"\1", t)                # bold
t = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"\1", t)     # italic *
t = re.sub(r"(?<!_)_([^_\n]+)_(?!_)", r"\1", t)         # italic _
t = re.sub(r"~~([^~]+)~~", r"\1", t)                    # strikethrough
t = re.sub(r"^\s*[-*_]{3,}\s*$", "", t, flags=re.M)     # hr
t = re.sub(r"<[^>]+>", "", t)                           # html tags
t = re.sub(r"\n{3,}", "\n\n", t).strip()
sys.stdout.write(t)
')"

[ -z "$text" ] && exit 0

encoded="$(printf '%s' "$text" | /usr/bin/jq -sRr @uri)"
/usr/bin/open "speakit://speak?text=${encoded}" >/dev/null 2>&1 || true
exit 0
