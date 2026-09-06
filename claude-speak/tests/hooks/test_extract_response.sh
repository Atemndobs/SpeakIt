#!/usr/bin/env bash
# Plain shell tests so the hook side needs no test framework.
set -uo pipefail
cd "$(dirname "$0")/../.."
EXTRACT=hooks/lib/extract_response.sh
fails=0

# Guard: three of the checks below expect empty output, which a missing script
# would also produce. Without this the suite would go green against nothing.
if [ ! -x "$EXTRACT" ]; then
  echo "FAIL - $EXTRACT is missing or not executable"
  exit 1
fi

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    echo "       expected: $(printf '%q' "$expected")"
    echo "       actual:   $(printf '%q' "$actual")"
    fails=$((fails + 1))
  fi
}

check "single text part" \
  "Hello there." \
  "$($EXTRACT tests/hooks/fixtures/simple.jsonl)"

check "last message wins, tool_use parts ignored" \
  "$(printf 'Part one.\nPart two.')" \
  "$($EXTRACT tests/hooks/fixtures/multi_part.jsonl)"

out="$($EXTRACT tests/hooks/fixtures/no_assistant.jsonl)"; code=$?
check "no assistant message gives empty output" "" "$out"
check "no assistant message still exits 0" "0" "$code"

out="$($EXTRACT /nonexistent/path.jsonl)"; code=$?
check "missing file gives empty output" "" "$out"
check "missing file still exits 0" "0" "$code"

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
