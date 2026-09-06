#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../.."
SLUG="$PWD/hooks/lib/repo_slug.sh"
fails=0

if [ ! -x "$SLUG" ]; then echo "FAIL - $SLUG is missing or not executable"; exit 1; fi

check() {
  local actual; actual="$($SLUG "$2")"
  if [ "$3" = "$actual" ]; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       url:      $2"; echo "       expected: $3"; echo "       actual:   $actual"; fails=$((fails+1)); fi
}

check "scp style with .git"    "git@github.com:Atemndobs/SpeakIt.git"       "Atemndobs/SpeakIt"
check "scp style bare"         "git@github.com:Atemndobs/SpeakIt"           "Atemndobs/SpeakIt"
check "https with .git"        "https://github.com/Atemndobs/SpeakIt.git"   "Atemndobs/SpeakIt"
check "https bare"             "https://github.com/Atemndobs/SpeakIt"       "Atemndobs/SpeakIt"
check "https with token"       "https://x-token:abc@github.com/Atemndobs/SpeakIt.git" "Atemndobs/SpeakIt"
check "ssh scheme"             "ssh://git@github.com/Atemndobs/SpeakIt.git" "Atemndobs/SpeakIt"
check "ssh scheme with port"   "ssh://git@github.com:22/Atemndobs/SpeakIt.git" "Atemndobs/SpeakIt"
check "trailing slash"         "https://github.com/Atemndobs/SpeakIt/"      "Atemndobs/SpeakIt"
check "empty url gives empty"  ""                                          ""

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
