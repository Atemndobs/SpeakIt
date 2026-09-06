#!/usr/bin/env bash
# Push one queue item to refs/heads/voice/queue on origin.
#
# This uses git plumbing rather than a checkout, deliberately. A Stop hook runs
# inside a session that is actively working, so switching branches or writing
# the index would be a data-loss bug. hash-object, read-tree against a private
# GIT_INDEX_FILE, commit-tree and a ref push create objects and move a remote
# ref without the working tree, the real index, or HEAD ever changing.
#
# A temp clone would have been simpler but would not inherit the session's
# credentials. Pushing from the existing repo reuses the remote that is already
# configured and already known to work.
#
# Note the absence of `set -e`. Every failure here must be survivable.
set -uo pipefail

repo="${1:-}"; item="${2:-}"; id="${3:-}"
branch="${VOICE_QUEUE_BRANCH:-voice/queue}"
ref="refs/heads/${branch}"
timeout_secs="${VOICE_QUEUE_TIMEOUT:-8}"   # 0 disables the time bound

[ -n "$repo" ] && [ -d "$repo" ] && [ -n "$item" ] && [ -f "$item" ] && [ -n "$id" ] || exit 0
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || exit 0
git -C "$repo" remote get-url origin >/dev/null 2>&1 || exit 0

tmp="$(mktemp -d)" || exit 0
trap 'rm -rf "$tmp"' EXIT

# Everything below writes to a private index, never the repo's own.
export GIT_INDEX_FILE="$tmp/index"

attempt() {
  rm -f "$GIT_INDEX_FILE"

  local parent="" base=""
  if git -C "$repo" fetch -q --depth 1 origin "+${ref}:${ref}-remote" 2>/dev/null; then
    parent="$(git -C "$repo" rev-parse "${ref}-remote" 2>/dev/null)"
    base="$parent"
  fi

  if [ -n "$base" ]; then
    git -C "$repo" read-tree "$base" 2>/dev/null || return 1
  else
    git -C "$repo" read-tree --empty 2>/dev/null || return 1
  fi

  local blob
  blob="$(git -C "$repo" hash-object -w --stdin < "$item" 2>/dev/null)" || return 1
  git -C "$repo" update-index --add --cacheinfo "100644,${blob},items/${id}.json" 2>/dev/null || return 1

  local tree commit
  tree="$(git -C "$repo" write-tree 2>/dev/null)" || return 1
  commit="$(printf 'voice: %s\n' "$id" \
    | git -C "$repo" commit-tree "$tree" ${parent:+-p "$parent"} 2>/dev/null)" || return 1

  git -C "$repo" push -q origin "${commit}:${ref}" 2>/dev/null
}

# One retry. A rejection means someone else pushed between our fetch and our
# push; refetching and rebuilding always succeeds because item paths are unique.
run() {
  attempt || attempt
}

if [ "$timeout_secs" != "0" ] && command -v timeout >/dev/null 2>&1; then
  # `timeout` execs a new process, so the functions are re-declared into it.
  # `declare -f` carries the function bodies but NOT the variables they read,
  # so these must be exported or every git call below runs against an empty
  # path and silently does nothing. Linux always has `timeout`, so getting
  # this wrong breaks precisely the cloud sandbox this transport exists for.
  export repo item id ref
  timeout "$timeout_secs" bash -c "$(declare -f attempt run); run" 2>/dev/null
else
  run
fi

# Clean up the tracking ref so it does not accumulate in the user's repo.
git -C "$repo" update-ref -d "${ref}-remote" 2>/dev/null

exit 0
