#!/usr/bin/env bash
# A remote URL to its owner/name slug.
#
# Inline in the hook this was untestable, and a wrong answer is not loud: the
# item still publishes, it is just attributed to a full URL instead of a repo,
# and the watcher groups it wrong. Every form git actually hands back is
# covered by tests rather than by inspection.
#
# One -e per rule, and no inline comments: BSD sed parses a trailing "#" inside
# an s/// as a flag and dies. This runs on macOS and on Linux, so it has to
# please both.
set -uo pipefail

url="${1:-}"
[ -n "$url" ] || exit 0

printf '%s' "$url" \
  | sed -E \
      -e 's#^[a-z+]+://##' \
      -e 's#^[^/@]*@##' \
      -e 's#^[^/:]+##' \
      -e 's#^:[0-9]+##' \
      -e 's#^[:/]##' \
      -e 's#\.git$##' \
      -e 's#/+$##'
