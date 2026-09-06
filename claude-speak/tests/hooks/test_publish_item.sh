#!/usr/bin/env bash
# Offline proof of the transport. A local bare repo stands in for GitHub, so
# these tests need no network and no credentials.
set -uo pipefail
cd "$(dirname "$0")/../.."
PUBLISH="$PWD/hooks/lib/publish_item.sh"
fails=0

# Guard: the three "untouched" checks compare before against after, so they
# would go green even if nothing ever ran. Refuse to report success on a
# missing implementation.
if [ ! -x "$PUBLISH" ]; then
  echo "FAIL - $PUBLISH is missing or not executable"
  exit 1
fi

check() {
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected: $2"; echo "       actual:   $3"; fails=$((fails+1)); fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git init -q --bare "$work/origin.git"
git init -q "$work/repo"
git -C "$work/repo" remote add origin "$work/origin.git"
git -C "$work/repo" commit -q --allow-empty -m "initial"
git -C "$work/repo" branch -M main
git -C "$work/repo" push -q origin main

# A dirty working tree and a staged file. Neither may be disturbed.
echo "uncommitted work" > "$work/repo/WIP.txt"
echo "staged work" > "$work/repo/STAGED.txt"
git -C "$work/repo" add STAGED.txt
before_status="$(git -C "$work/repo" status --porcelain)"
before_head="$(git -C "$work/repo" rev-parse HEAD)"
before_branch="$(git -C "$work/repo" rev-parse --abbrev-ref HEAD)"

echo '{"v":1,"id":"item-one","text":"first"}' > "$work/one.json"
"$PUBLISH" "$work/repo" "$work/one.json" "item-one" >/dev/null 2>&1
check "exits 0" "0" "$?"

check "item landed on the branch" \
  "items/item-one.json" \
  "$(git -C "$work/origin.git" ls-tree -r --name-only refs/heads/voice/queue)"

check "working tree untouched" "$before_status" "$(git -C "$work/repo" status --porcelain)"
check "HEAD untouched"         "$before_head"   "$(git -C "$work/repo" rev-parse HEAD)"
check "branch untouched"       "$before_branch" "$(git -C "$work/repo" rev-parse --abbrev-ref HEAD)"

# A second item must append, not replace.
echo '{"v":1,"id":"item-two","text":"second"}' > "$work/two.json"
"$PUBLISH" "$work/repo" "$work/two.json" "item-two" >/dev/null 2>&1
check "second item appended" \
  "$(printf 'items/item-one.json\nitems/item-two.json')" \
  "$(git -C "$work/origin.git" ls-tree -r --name-only refs/heads/voice/queue | sort)"

# A concurrent push from elsewhere must not cost us the item.
git clone -q "$work/origin.git" "$work/other" -b voice/queue 2>/dev/null
echo '{"v":1,"id":"item-three","text":"third"}' > "$work/other/items/item-three.json"
git -C "$work/other" add -A
git -C "$work/other" -c user.email=o@l -c user.name=o commit -q -m "concurrent"
git -C "$work/other" push -q origin voice/queue

echo '{"v":1,"id":"item-four","text":"fourth"}' > "$work/four.json"
"$PUBLISH" "$work/repo" "$work/four.json" "item-four" >/dev/null 2>&1
check "retries after a non-fast-forward rejection" \
  "$(printf 'items/item-four.json\nitems/item-one.json\nitems/item-three.json\nitems/item-two.json')" \
  "$(git -C "$work/origin.git" ls-tree -r --name-only refs/heads/voice/queue | sort)"

# Both time-bound branches must publish. The timeout branch execs a new bash,
# which does NOT inherit shell variables, so a regression there silently
# publishes nothing while still exiting 0. Linux always has `timeout`, so that
# branch is the one the cloud sandbox actually takes; pin both explicitly
# rather than testing whichever one this host happens to pick.
shim="$work/shim"; mkdir -p "$shim"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$shim/timeout"
chmod +x "$shim/timeout"

echo '{"v":1,"id":"item-six","text":"sixth"}' > "$work/six.json"
PATH="$shim:$PATH" "$PUBLISH" "$work/repo" "$work/six.json" "item-six" >/dev/null 2>&1
check "publishes via the timeout branch" \
  "items/item-six.json" \
  "$(git -C "$work/origin.git" ls-tree -r --name-only refs/heads/voice/queue | grep six)"

echo '{"v":1,"id":"item-seven","text":"seventh"}' > "$work/seven.json"
VOICE_QUEUE_TIMEOUT=0 "$PUBLISH" "$work/repo" "$work/seven.json" "item-seven" >/dev/null 2>&1
check "publishes via the unbounded branch" \
  "items/item-seven.json" \
  "$(git -C "$work/origin.git" ls-tree -r --name-only refs/heads/voice/queue | grep seven)"

# An unreachable remote must not be fatal.
git -C "$work/repo" remote set-url origin "$work/does-not-exist.git"
"$PUBLISH" "$work/repo" "$work/one.json" "item-five" >/dev/null 2>&1
check "exits 0 when the remote is gone" "0" "$?"

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
