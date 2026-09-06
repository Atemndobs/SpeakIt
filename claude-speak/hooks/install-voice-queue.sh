#!/usr/bin/env bash
# Wire the voice-queue Stop hook into a repo.
#
# The hook is committed to the target repo rather than installed globally on
# this Mac, because that is the entire point: it has to run in a cloud sandbox
# where nothing of yours is installed.
set -euo pipefail

target="${1:-.}"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$target/.git" ] || { echo "not a git repo: $target" >&2; exit 1; }

mkdir -p "$target/.claude/hooks/lib"
cp "$src/voice-queue-stop.sh" "$target/.claude/hooks/"

# Read the lib list out of the hook rather than hardcoding it. A hardcoded list
# drifts the moment a lib is added, and the failure is quiet: the hook keeps
# exiting 0 and simply stops doing part of its job. Missing repo_slug.sh, for
# instance, publishes items attributed to an empty repo.
libs="$(grep -oE 'lib/[a-zA-Z_]+\.(sh|py)' "$src/voice-queue-stop.sh" | sort -u)"
[ -n "$libs" ] || { echo "found no lib references in voice-queue-stop.sh" >&2; exit 1; }

for lib in $libs; do
  [ -f "$src/$lib" ] || { echo "hook references $lib but it does not exist" >&2; exit 1; }
  cp "$src/$lib" "$target/.claude/hooks/lib/"
done
chmod +x "$target/.claude/hooks/voice-queue-stop.sh" "$target/.claude/hooks/lib/"*

echo "Installed hook and $(printf '%s\n' $libs | wc -l | tr -d ' ') libs into $target/.claude/hooks/"

settings="$target/.claude/settings.json"
if [ -f "$settings" ]; then
  echo "A settings.json already exists. Add this Stop hook entry by hand:"
else
  cat > "$settings" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/voice-queue-stop.sh" }
        ]
      }
    ]
  }
}
JSON
  echo "Wrote $settings"
fi

cat <<'MSG'

  { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/voice-queue-stop.sh" }

Commit .claude/ so the hook travels with the repo into a cloud session.
Set CLAUDE_VOICE=0 to disable it without uninstalling.
MSG
