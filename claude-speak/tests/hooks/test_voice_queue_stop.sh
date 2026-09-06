#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../.."
HOOK="$PWD/hooks/voice-queue-stop.sh"
fails=0

check() {
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected: $2"; echo "       actual:   $3"; fails=$((fails+1)); fi
}

# Guard: several checks below assert an item count that a never-running hook
# would also fail to change. Refuse to report anything on a missing hook.
if [ ! -x "$HOOK" ]; then
  echo "FAIL - $HOOK is missing or not executable"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git init -q --bare "$work/origin.git"
git init -q "$work/repo"
git -C "$work/repo" remote add origin "$work/origin.git"
git -C "$work/repo" commit -q --allow-empty -m init
git -C "$work/repo" push -q origin HEAD:refs/heads/main

cp tests/hooks/fixtures/simple.jsonl "$work/t.jsonl"
payload="{\"transcript_path\":\"$work/t.jsonl\",\"cwd\":\"$work/repo\"}"

echo "$payload" | "$HOOK" >/dev/null 2>&1
check "exits 0" "0" "$?"
check "published one item" "1" \
  "$(git -C "$work/origin.git" ls-tree -r --name-only refs/heads/voice/queue 2>/dev/null | wc -l | tr -d ' ')"

body="$(git -C "$work/origin.git" show "refs/heads/voice/queue:$(git -C "$work/origin.git" ls-tree -r --name-only refs/heads/voice/queue)")"
check "text is stripped and present" "Hello there." "$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])')"

# The off switch.
CLAUDE_VOICE=0 bash -c "echo '$payload' | '$HOOK'" >/dev/null 2>&1
check "disabled by CLAUDE_VOICE=0" "0" "$?"
check "nothing new published when disabled" "1" \
  "$(git -C "$work/origin.git" ls-tree -r --name-only refs/heads/voice/queue | wc -l | tr -d ' ')"

# Survivability.
echo '{"transcript_path":"/nope.jsonl","cwd":"'"$work/repo"'"}' | "$HOOK" >/dev/null 2>&1
check "missing transcript exits 0" "0" "$?"
echo 'not json at all' | "$HOOK" >/dev/null 2>&1
check "garbage payload exits 0" "0" "$?"
printf '' | "$HOOK" >/dev/null 2>&1
check "empty payload exits 0" "0" "$?"

cp tests/hooks/fixtures/no_assistant.jsonl "$work/empty.jsonl"
echo "{\"transcript_path\":\"$work/empty.jsonl\",\"cwd\":\"$work/repo\"}" | "$HOOK" >/dev/null 2>&1
check "no assistant message publishes nothing" "1" \
  "$(git -C "$work/origin.git" ls-tree -r --name-only refs/heads/voice/queue | wc -l | tr -d ' ')"

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
