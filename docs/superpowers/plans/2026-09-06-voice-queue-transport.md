# Voice Queue Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get a Claude Code response out of a cloud sandbox and onto a device as text, within about ten seconds, with no Mac involved.

**Architecture:** A `Stop` hook publishes the last assistant message as a JSON file on a `voice/queue` orphan branch in whatever repo the session is already working in, pushed with git plumbing so the working tree is never touched. A watcher polls the GitHub API for recently pushed repos, reads new items off that branch, and emits them. Audio and UI are explicitly not in this plan.

**Tech Stack:** bash, jq, python3 (hook side); TypeScript, Node 20, vitest (watcher side); git plumbing as the transport.

**Spec:** `docs/superpowers/specs/2026-09-06-on-the-go-listening-design.md`

## Repos

This one deliverable spans two repos, because the producer and the consumer
genuinely belong in different places. Every task below names which.

| Repo | Holds | Why |
|---|---|---|
| `SpeakIt` (existing) | Tasks 1 to 5, the hook | It already owns the `claude-speak` plugin, the transcript parser and the markdown stripper. Forking those would guarantee they drift apart. |
| `earshot` (new, this repo) | Tasks 6 to 9, the watcher | This code is the first piece of the phone app, so it is born here rather than migrated here later. Generated with `create-jnabs-app`, which now defaults to Convex and Clerk. |

The plan and the spec live in `earshot`, because that is the product. `SpeakIt`
gets a one line pointer in its README rather than a copy.

Rename `earshot` freely before Task 6; nothing downstream depends on the name.

## Global Constraints

- **Never use an em-dash (U+2014), en-dash (U+2013) as punctuation, or a double hyphen standing in for one.** Applies to code, comments, commit messages, and docs. Verify with `grep -rn $'\u2014' . --exclude-dir=.git` returning nothing.
- Branch naming: `<what-is-being-built>/<specific-detail>`, lowercase kebab-case, never prefixed with a tool name.
- **The hook must always exit 0.** A failure in the voice path must never interrupt a working session.
- **The hook must never modify the working tree, the index, `HEAD`, or any local branch.** It only creates objects and pushes a ref.
- The hook must be time-bounded. Give up quietly rather than hang.
- Never commit `.env`. Never print or commit a token. The GitHub PAT lives in the iOS keychain, never in app storage or a config file.
- The hook runs on both macOS and Linux. No `/usr/bin/...` absolute paths for `jq`, `python3`, or `basename`; resolve with `command -v`.
- Queue items carry `"v": 1`. Consumers skip items whose `v` they do not understand rather than crashing.

## File Structure

| Path | Responsibility |
|---|---|
| `hooks/lib/strip_markdown.py` | Markdown to speakable plain text. Pure function, no I/O beyond stdin/stdout. |
| `hooks/lib/extract_response.sh` | Transcript JSONL to the last assistant message's text. |
| `hooks/lib/queue_item.py` | Build one queue item JSON document. |
| `hooks/lib/publish_item.sh` | Push one item to `voice/queue` using git plumbing. The only file that talks to git. |
| `hooks/voice-queue-stop.sh` | The `Stop` hook. Wires the four above together. |
| `hooks/speakit-stop.sh` | Existing macOS hook. Modified in Task 1 to consume the shared stripper. |
| `tests/hooks/` | Fixtures and shell/python tests for the hook side. |
All four below are in `earshot`, not `SpeakIt`.

| Path | Responsibility |
|---|---|
| `src/voice-queue/select.ts` | Pure decision logic: given repos, refs and a seen set, what to fetch. |
| `src/voice-queue/github.ts` | Thin GitHub API client. The only file that makes network calls. |
| `src/voice-queue/watch.ts` | Poll loop composing the two above. |
| `scripts/voice-queue-watch.ts` | Prints new items to a terminal. Proves the transport before any UI exists. |

These live under `src/` rather than in a throwaway tools directory precisely
because the player plan imports `watch.ts` directly. Only the script is
disposable.

The split is by responsibility, not layer. `publish_item.sh` and `github.ts` are the only two files that touch the outside world, which is what makes everything else testable without a network.

---

### Task 1: Extract the markdown stripper, prove behaviour is unchanged

The stripper is currently inlined in `hooks/speakit-stop.sh` lines 33 to 61. It is correct and was arrived at painfully, so it gets moved, not rewritten. The characterization test comes first so the move is provably safe.

**Files:**
- Create: `hooks/lib/strip_markdown.py`
- Create: `tests/hooks/test_strip_markdown.py`
- Modify: `hooks/speakit-stop.sh:33-61`

**Interfaces:**
- Consumes: nothing.
- Produces: `hooks/lib/strip_markdown.py`, executable, reads markdown on stdin and writes plain text to stdout. Also importable as `strip_markdown(text: str) -> str`.

- [x] **Step 1: Write the failing test**

Create `tests/hooks/test_strip_markdown.py`:

```python
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "hooks" / "lib" / "strip_markdown.py"


def strip(text):
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        input=text, capture_output=True, text=True, check=True,
    )
    return result.stdout


def test_removes_fenced_code_blocks():
    assert strip("before\n```\ncode here\n```\nafter") == "before\n\nafter"


def test_unwraps_inline_code():
    assert strip("run `npm test` now") == "run npm test now"


def test_links_become_their_text():
    assert strip("see [the docs](https://example.com)") == "see the docs"


def test_images_are_dropped():
    assert strip("![alt text](img.png)done") == "done"


def test_headers_lose_their_hashes():
    assert strip("## Section title") == "Section title"


def test_bullets_lose_their_markers():
    assert strip("- first\n- second") == "first\nsecond"


def test_numbered_lists_lose_their_numbers():
    assert strip("1. first\n2. second") == "first\nsecond"


def test_bold_and_italic_are_unwrapped():
    assert strip("**bold** and *italic* and _also_") == "bold and italic and also"


def test_tables_flatten_to_comma_separated_rows():
    table = "| a | b |\n| --- | --- |\n| 1 | 2 |"
    assert strip(table) == "a, b\n\n1, 2"


def test_blockquotes_lose_their_marker():
    assert strip("> quoted line") == "quoted line"


def test_html_tags_are_removed():
    assert strip("a <br/> b") == "a  b"


def test_runs_of_blank_lines_collapse():
    assert strip("a\n\n\n\n\nb") == "a\n\nb"


def test_empty_input_gives_empty_output():
    assert strip("") == ""
```

- [x] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/hooks/test_strip_markdown.py -v`
Expected: FAIL, every test errors because `hooks/lib/strip_markdown.py` does not exist.

- [x] **Step 3: Write minimal implementation**

Create `hooks/lib/strip_markdown.py`, lifting the regex body verbatim from `hooks/speakit-stop.sh` lines 34 to 60. Do not improve it. Behaviour parity is the point of this task.

```python
#!/usr/bin/env python3
"""Markdown to speakable plain text.

Lifted verbatim from the inline stripper in hooks/speakit-stop.sh so the
macOS hook and the voice-queue hook cannot drift apart. Speech synthesis
reads punctuation aloud, so "**bold**" becomes "asterisk asterisk bold"
unless it is removed here.
"""
import re
import sys


def strip_markdown(t: str) -> str:
    t = re.sub(r"```.*?```", "", t, flags=re.S)            # fenced code blocks
    t = re.sub(r"`([^`]*)`", r"\1", t)                      # inline code
    t = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", t)              # images
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)          # links to text
    # Tables: drop the alignment row, flatten body rows to comma separated text.
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
    return t


if __name__ == "__main__":
    sys.stdout.write(strip_markdown(sys.stdin.read()))
```

Then `chmod +x hooks/lib/strip_markdown.py`.

- [x] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/hooks/test_strip_markdown.py -v`
Expected: PASS, 13 passed.

If a test fails, the expectation is wrong, not the stripper. Correct the test to match observed behaviour and note it, because parity with the shipped macOS hook matters more than any individual assertion here.

- [x] **Step 5: Point the macOS hook at the shared file**

In `hooks/speakit-stop.sh`, replace lines 33 to 61 with:

```bash
# Strip markdown so TTS doesn't say "asterisk asterisk".
PY="$(command -v python3)"
text="$(printf '%s' "$text" | "$PY" "$(dirname "${BASH_SOURCE[0]}")/lib/strip_markdown.py")"
```

- [x] **Step 6: Verify the macOS hook still speaks**

Run: `echo '{"transcript_path":"tests/hooks/fixtures/simple.jsonl","cwd":"'"$PWD"'"}' | ./hooks/speakit-stop.sh; echo "exit=$?"`
Expected: `exit=0`. With the SpeakIt toggle on, the app speaks. With it off, silence. Both are passes; the toggle gate is at line 12 and is untouched.

- [x] **Step 7: Commit**

```bash
git add hooks/lib/strip_markdown.py tests/hooks/test_strip_markdown.py hooks/speakit-stop.sh
git commit -m "refactor: extract the markdown stripper so both hooks share one copy"
```

---

### Task 2: Extract the transcript reader

**Files:**
- Create: `hooks/lib/extract_response.sh`
- Create: `tests/hooks/fixtures/simple.jsonl`
- Create: `tests/hooks/fixtures/multi_part.jsonl`
- Create: `tests/hooks/fixtures/no_assistant.jsonl`
- Create: `tests/hooks/test_extract_response.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `hooks/lib/extract_response.sh <transcript_path>`, writes the last assistant message's concatenated text parts to stdout. Exits 0 with empty output when there is no assistant message.

- [x] **Step 1: Write the fixtures**

`tests/hooks/fixtures/simple.jsonl`:

```
{"type":"user","message":{"content":"hi"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Hello there."}]}}
```

`tests/hooks/fixtures/multi_part.jsonl`, which also proves the *last* assistant message wins and tool-use parts are ignored:

```
{"type":"assistant","message":{"content":[{"type":"text","text":"First answer."}]}}
{"type":"user","message":{"content":"more"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Part one."},{"type":"tool_use","name":"Bash"},{"type":"text","text":"Part two."}]}}
```

`tests/hooks/fixtures/no_assistant.jsonl`:

```
{"type":"user","message":{"content":"hi"}}
```

- [x] **Step 2: Write the failing test**

Create `tests/hooks/test_extract_response.sh`:

```bash
#!/usr/bin/env bash
# Plain shell tests so the hook side needs no test framework.
set -uo pipefail
cd "$(dirname "$0")/../.."
EXTRACT=hooks/lib/extract_response.sh
fails=0

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

check "no assistant message gives empty output" \
  "" \
  "$($EXTRACT tests/hooks/fixtures/no_assistant.jsonl)"

check "missing file gives empty output and exit 0" \
  "" \
  "$($EXTRACT /nonexistent/path.jsonl)"

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
```

Then `chmod +x tests/hooks/test_extract_response.sh`.

- [x] **Step 3: Run test to verify it fails**

Run: `./tests/hooks/test_extract_response.sh`
Expected: FAIL on all four, `hooks/lib/extract_response.sh` not found.

- [x] **Step 4: Write minimal implementation**

Create `hooks/lib/extract_response.sh`:

```bash
#!/usr/bin/env bash
# Last assistant message from a transcript, as concatenated text parts.
#
# Tool-use and thinking parts are skipped: only "text" parts are spoken.
# Every failure path yields empty output and exit 0, because a caller in a
# Stop hook must never abort a session over a missing transcript.
set -uo pipefail

transcript="${1:-}"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

JQ="$(command -v jq)" || exit 0

"$JQ" -sr '
  map(select(.type == "assistant"))
  | last
  | .message.content
  | map(select(.type == "text") | .text)
  | join("\n")
' "$transcript" 2>/dev/null | sed '/^null$/d'
exit 0
```

Then `chmod +x hooks/lib/extract_response.sh`.

The `sed '/^null$/d'` matters: `last` on an empty array yields `null`, which jq prints as the string `null`. Without it, a transcript with no assistant message would publish the word "null".

- [x] **Step 5: Run test to verify it passes**

Run: `./tests/hooks/test_extract_response.sh`
Expected: `all passed`, exit 0.

- [x] **Step 6: Commit**

```bash
git add hooks/lib/extract_response.sh tests/hooks/
git commit -m "feat: extract the transcript reader with fixture tests"
```

---

### Task 3: Build the queue item

**Files:**
- Create: `hooks/lib/queue_item.py`
- Create: `tests/hooks/test_queue_item.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `hooks/lib/queue_item.py --text <str> --repo <owner/name> --title <str>`, writes one JSON document to stdout with keys `v`, `id`, `source`, `repo`, `title`, `text`, `createdAt`. Also importable as `build_item(text, repo, title, now=None) -> dict`.

- [x] **Step 1: Write the failing test**

Create `tests/hooks/test_queue_item.py`:

```python
import datetime as dt
import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "hooks" / "lib" / "queue_item.py"
spec = importlib.util.spec_from_file_location("queue_item", SCRIPT)
queue_item = importlib.util.module_from_spec(spec)
spec.loader.exec_module(queue_item)

FIXED = dt.datetime(2026, 9, 6, 12, 4, 31, tzinfo=dt.timezone.utc)


def test_carries_schema_version_one():
    item = queue_item.build_item("hi", "Atemndobs/SpeakIt", "SpeakIt", now=FIXED)
    assert item["v"] == 1


def test_id_starts_with_a_sortable_timestamp():
    item = queue_item.build_item("hi", "Atemndobs/SpeakIt", "SpeakIt", now=FIXED)
    assert item["id"].startswith("2026-09-06T12-04-31Z-")


def test_id_is_unique_for_identical_input():
    a = queue_item.build_item("hi", "r", "t", now=FIXED)
    b = queue_item.build_item("hi", "r", "t", now=FIXED)
    assert a["id"] != b["id"]


def test_created_at_is_iso_utc():
    item = queue_item.build_item("hi", "r", "t", now=FIXED)
    assert item["createdAt"] == "2026-09-06T12:04:31Z"


def test_source_identifies_claude_code():
    item = queue_item.build_item("hi", "r", "t", now=FIXED)
    assert item["source"] == "claude-code"


def test_text_is_carried_verbatim():
    item = queue_item.build_item("line one\nline two", "r", "t", now=FIXED)
    assert item["text"] == "line one\nline two"
```

- [x] **Step 2: Run test to verify it fails**

Run: `python3 -m pytest tests/hooks/test_queue_item.py -v`
Expected: FAIL, module not found.

- [x] **Step 3: Write minimal implementation**

Create `hooks/lib/queue_item.py`:

```python
#!/usr/bin/env python3
"""One queue item.

The id leads with a sortable UTC timestamp so a directory listing is in
chronological order without parsing anything, and ends with random hex so two
sessions finishing in the same second cannot collide on a filename. Collision
matters more than it looks: unique paths are what let two concurrent pushes
rebase onto each other cleanly.
"""
import argparse
import datetime as dt
import json
import secrets
import sys


def build_item(text, repo, title, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H-%M-%SZ")
    return {
        "v": 1,
        "id": f"{stamp}-{secrets.token_hex(3)}",
        "source": "claude-code",
        "repo": repo,
        "title": title,
        "text": text,
        "createdAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--text", required=True)
    p.add_argument("--repo", default="")
    p.add_argument("--title", default="")
    a = p.parse_args()
    json.dump(build_item(a.text, a.repo, a.title), sys.stdout, ensure_ascii=False)
```

Then `chmod +x hooks/lib/queue_item.py`.

- [x] **Step 4: Run test to verify it passes**

Run: `python3 -m pytest tests/hooks/test_queue_item.py -v`
Expected: PASS, 6 passed.

- [x] **Step 5: Commit**

```bash
git add hooks/lib/queue_item.py tests/hooks/test_queue_item.py
git commit -m "feat: build queue items with sortable collision-free ids"
```

---

### Task 4: Publish an item, without touching the working tree

This is the riskiest task in the plan and the reason for its ordering. It is also fully testable offline against a local bare repo, so no network or cloud session is needed to prove it.

**Files:**
- Create: `hooks/lib/publish_item.sh`
- Create: `tests/hooks/test_publish_item.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `hooks/lib/publish_item.sh <repo_dir> <item_json_path> <item_id>`, pushes `items/<item_id>.json` onto `refs/heads/voice/queue` on `origin`. Exits 0 always.

- [x] **Step 1: Write the failing test**

Create `tests/hooks/test_publish_item.sh`:

```bash
#!/usr/bin/env bash
# Offline proof of the transport. A local bare repo stands in for GitHub, so
# these tests need no network and no credentials.
set -uo pipefail
cd "$(dirname "$0")/../.."
PUBLISH="$PWD/hooks/lib/publish_item.sh"
fails=0

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

# An unreachable remote must not be fatal.
git -C "$work/repo" remote set-url origin "$work/does-not-exist.git"
"$PUBLISH" "$work/repo" "$work/one.json" "item-five" >/dev/null 2>&1
check "exits 0 when the remote is gone" "0" "$?"

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
```

Then `chmod +x tests/hooks/test_publish_item.sh`.

- [x] **Step 2: Run test to verify it fails**

Run: `./tests/hooks/test_publish_item.sh`
Expected: FAIL, `publish_item.sh` not found.

- [x] **Step 3: Write minimal implementation**

Create `hooks/lib/publish_item.sh`:

```bash
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
timeout_secs="${VOICE_QUEUE_TIMEOUT:-8}"

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

if command -v timeout >/dev/null 2>&1; then
  timeout "$timeout_secs" bash -c "$(declare -f attempt run); run" 2>/dev/null
else
  run
fi

# Clean up the tracking ref so it does not accumulate in the user's repo.
git -C "$repo" update-ref -d "${ref}-remote" 2>/dev/null

exit 0
```

Then `chmod +x hooks/lib/publish_item.sh`.

- [x] **Step 4: Run test to verify it passes**

Run: `./tests/hooks/test_publish_item.sh`
Expected: `all passed`, exit 0. Eight checks.

The `timeout` branch re-declares the functions inside a subshell because `timeout` execs a new process that does not inherit shell functions. If that proves awkward on macOS where `timeout` is often absent, the fallback path is already correct.

- [x] **Step 5: Commit**

```bash
git add hooks/lib/publish_item.sh tests/hooks/test_publish_item.sh
git commit -m "feat: publish queue items with git plumbing, never touching the working tree"
```

---

### Task 5: The Stop hook

**Files:**
- Create: `hooks/voice-queue-stop.sh`
- Create: `tests/hooks/test_voice_queue_stop.sh`

**Interfaces:**
- Consumes: `extract_response.sh`, `strip_markdown.py`, `queue_item.py`, `publish_item.sh`.
- Produces: a `Stop` hook reading the payload on stdin. No stdout contract.

- [x] **Step 1: Write the failing test**

Create `tests/hooks/test_voice_queue_stop.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../.."
HOOK="$PWD/hooks/voice-queue-stop.sh"
fails=0

check() {
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected: $2"; echo "       actual:   $3"; fails=$((fails+1)); fi
}

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
```

Then `chmod +x tests/hooks/test_voice_queue_stop.sh`.

- [x] **Step 2: Run test to verify it fails**

Run: `./tests/hooks/test_voice_queue_stop.sh`
Expected: FAIL, hook not found.

- [x] **Step 3: Write minimal implementation**

Create `hooks/voice-queue-stop.sh`:

```bash
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
repo="$(printf '%s' "$remote" | sed -E 's#(git@[^:]+:|https://[^/]+/)##; s#\.git$##' 2>/dev/null || true)"
title="$(basename "$cwd" 2>/dev/null || true)"

tmp="$(mktemp -d)" || exit 0
trap 'rm -rf "$tmp"' EXIT

"$PY" "$here/lib/queue_item.py" --text "$text" --repo "$repo" --title "$title" \
  > "$tmp/item.json" 2>/dev/null || exit 0

id="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$tmp/item.json" 2>/dev/null || true)"
[ -n "$id" ] || exit 0

"$here/lib/publish_item.sh" "$cwd" "$tmp/item.json" "$id" >/dev/null 2>&1 || true
exit 0
```

Then `chmod +x hooks/voice-queue-stop.sh`.

- [x] **Step 4: Run test to verify it passes**

Run: `./tests/hooks/test_voice_queue_stop.sh`
Expected: `all passed`, exit 0. Nine checks.

- [x] **Step 5: Commit**

```bash
git add hooks/voice-queue-stop.sh tests/hooks/test_voice_queue_stop.sh
git commit -m "feat: Stop hook publishing responses to the voice queue branch"
```

---

### Task 6: Watcher decision logic

Pure functions, no network. This is where the polling strategy is proven correct before any HTTP exists.

**Files:**
- Create: `tools/voice-queue-watch/package.json`
- Create: `tools/voice-queue-watch/tsconfig.json`
- Create: `src/voice-queue/types.ts`
- Create: `src/voice-queue/select.ts`
- Create: `src/voice-queue/select.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `interface Repo { fullName: string; pushedAt: string }`
  - `interface QueueItem { v: number; id: string; source: string; repo: string; title: string; text: string; createdAt: string }`
  - `reposToCheck(repos: Repo[], lastSeenPushedAt: Record<string, string>): Repo[]`
  - `unseenItemIds(treePaths: string[], seenIds: Set<string>): string[]`
  - `isPlayable(item: unknown): item is QueueItem`

- [x] **Step 1: Create the app and add a test runner**

The Expo app does not exist yet. Create it, from the mobile-stack checkout:

```bash
cd ~/sites && node ~/sites/mobile_stack/dist/cli.js create earshot --yes
```

This scaffolds Expo, React Native, Convex and Clerk, since Convex is now the
default backend. Confirm `earshot/convex/` exists and `earshot/supabase/` does
not; if it is the other way round the default did not apply and the rest of the
stack assumptions are wrong.

The generated app has TypeScript but no test runner. Add one:

```bash
cd ~/sites/earshot && npm install && npm install -D vitest@^2.1.0 tsx@^4.19.0
```

Add these to the generated `package.json` scripts block, leaving the Expo
scripts alone:

```json
"test": "vitest run",
"voice-queue:watch": "tsx scripts/voice-queue-watch.ts"
```

Then `mkdir -p src/voice-queue scripts`.

Initialise git and push it, so the plan and spec have somewhere to live:

```bash
cd ~/sites/earshot && git init -q && git add -A \
  && git commit -q -m "chore: scaffold the Expo app with Convex and Clerk" \
  && gh repo create earshot --private --source=. --push
```

Finally, move the design documents to the product:

```bash
mkdir -p ~/sites/earshot/docs/superpowers/{specs,plans}
cp ~/sites/SpeakIt/docs/superpowers/specs/2026-09-06-on-the-go-listening-design.md ~/sites/earshot/docs/superpowers/specs/
cp ~/sites/SpeakIt/docs/superpowers/plans/2026-09-06-voice-queue-transport.md ~/sites/earshot/docs/superpowers/plans/
```

- [x] **Step 2: Write the failing test**

`src/voice-queue/select.test.ts`:

```typescript
import { describe, expect, it } from 'vitest';
import { isPlayable, reposToCheck, unseenItemIds } from './select';

describe('reposToCheck', () => {
  it('returns a repo never seen before', () => {
    const repos = [{ fullName: 'a/b', pushedAt: '2026-09-06T12:00:00Z' }];
    expect(reposToCheck(repos, {})).toEqual(repos);
  });

  it('skips a repo whose pushedAt is unchanged', () => {
    const repos = [{ fullName: 'a/b', pushedAt: '2026-09-06T12:00:00Z' }];
    expect(reposToCheck(repos, { 'a/b': '2026-09-06T12:00:00Z' })).toEqual([]);
  });

  it('returns a repo that has been pushed since last poll', () => {
    const repos = [{ fullName: 'a/b', pushedAt: '2026-09-06T12:05:00Z' }];
    expect(reposToCheck(repos, { 'a/b': '2026-09-06T12:00:00Z' })).toEqual(repos);
  });

  it('checks every changed repo, not only the newest', () => {
    const repos = [
      { fullName: 'a/b', pushedAt: '2026-09-06T12:05:00Z' },
      { fullName: 'c/d', pushedAt: '2026-09-06T12:04:00Z' },
    ];
    expect(reposToCheck(repos, {}).map((r) => r.fullName)).toEqual(['a/b', 'c/d']);
  });
});

describe('unseenItemIds', () => {
  it('extracts ids from item paths', () => {
    expect(unseenItemIds(['items/one.json', 'items/two.json'], new Set())).toEqual(['one', 'two']);
  });

  it('excludes ids already seen', () => {
    expect(unseenItemIds(['items/one.json', 'items/two.json'], new Set(['one']))).toEqual(['two']);
  });

  it('ignores paths outside items/', () => {
    expect(unseenItemIds(['README.md', 'items/one.json'], new Set())).toEqual(['one']);
  });

  it('returns ids in chronological order because ids lead with a timestamp', () => {
    const paths = ['items/2026-09-06T12-05-00Z-bbb.json', 'items/2026-09-06T12-04-00Z-aaa.json'];
    expect(unseenItemIds(paths, new Set())).toEqual([
      '2026-09-06T12-04-00Z-aaa',
      '2026-09-06T12-05-00Z-bbb',
    ]);
  });
});

describe('isPlayable', () => {
  const valid = {
    v: 1, id: 'x', source: 'claude-code', repo: 'a/b',
    title: 't', text: 'hello', createdAt: '2026-09-06T12:00:00Z',
  };

  it('accepts a well formed v1 item', () => {
    expect(isPlayable(valid)).toBe(true);
  });

  it('rejects a future schema version rather than guessing', () => {
    expect(isPlayable({ ...valid, v: 2 })).toBe(false);
  });

  it('rejects an item with no text', () => {
    expect(isPlayable({ ...valid, text: '' })).toBe(false);
  });

  it('rejects malformed input without throwing', () => {
    expect(isPlayable(null)).toBe(false);
    expect(isPlayable('nonsense')).toBe(false);
    expect(isPlayable({})).toBe(false);
  });
});
```

- [x] **Step 3: Run test to verify it fails**

Run: `npx vitest run`
Expected: FAIL, cannot resolve `./select`.

- [x] **Step 4: Write minimal implementation**

`src/voice-queue/types.ts`:

```typescript
export interface Repo {
  fullName: string;
  pushedAt: string;
}

export interface QueueItem {
  v: number;
  id: string;
  source: string;
  repo: string;
  title: string;
  text: string;
  createdAt: string;
}
```

`src/voice-queue/select.ts`:

```typescript
import type { QueueItem, Repo } from './types';

/**
 * Which repos are worth a ref lookup this poll.
 *
 * A queue push necessarily makes its repo the most recently pushed, so the
 * repo list sorted by push time always surfaces it without anyone configuring
 * which repos to watch. Comparing pushedAt against the last seen value keeps
 * the common case at one API call: nothing moved, nothing to check.
 */
export function reposToCheck(repos: Repo[], lastSeenPushedAt: Record<string, string>): Repo[] {
  return repos.filter((r) => lastSeenPushedAt[r.fullName] !== r.pushedAt);
}

/**
 * Item ids present on the branch that have not been played yet.
 *
 * Sorted because ids lead with a UTC timestamp, so lexical order is
 * chronological order. Playing a backlog out of order would be disorienting.
 */
export function unseenItemIds(treePaths: string[], seenIds: Set<string>): string[] {
  return treePaths
    .filter((p) => p.startsWith('items/') && p.endsWith('.json'))
    .map((p) => p.slice('items/'.length, -'.json'.length))
    .filter((id) => !seenIds.has(id))
    .sort();
}

/**
 * Whether an item can be played.
 *
 * An unknown schema version is skipped rather than guessed at. A future hook
 * may add fields this build cannot interpret, and a queue that crashes on one
 * bad item is worse than one that quietly skips it.
 */
export function isPlayable(item: unknown): item is QueueItem {
  if (typeof item !== 'object' || item === null) return false;
  const i = item as Record<string, unknown>;
  return i.v === 1 && typeof i.text === 'string' && i.text.length > 0 && typeof i.id === 'string';
}
```

- [x] **Step 5: Run test to verify it passes**

Run: `npx vitest run`
Expected: PASS, 12 passed.

- [x] **Step 6: Commit**

```bash
git add src/voice-queue/ scripts/ package.json
git commit -m "feat: watcher decision logic with no network dependency"
```

---

### Task 7: GitHub client

**Files:**
- Create: `src/voice-queue/github.ts`
- Create: `src/voice-queue/github.test.ts`

**Interfaces:**
- Consumes: `Repo`, `QueueItem` from `./types`.
- Produces: `class GitHubClient { constructor(token: string, fetchImpl?: typeof fetch); listRecentlyPushed(limit?: number): Promise<Repo[]>; queueTreePaths(fullName: string): Promise<string[]>; readItem(fullName: string, id: string): Promise<unknown> }`. `queueTreePaths` returns `[]` when the branch does not exist. All methods throw `RateLimitError` on a 403 with a zero remaining header.

- [x] **Step 1: Write the failing test**

`src/voice-queue/github.test.ts`:

```typescript
import { describe, expect, it } from 'vitest';
import { GitHubClient, RateLimitError } from './github';

function stubFetch(routes: Record<string, { status: number; body: unknown; headers?: Record<string, string> }>) {
  return async (url: string | URL): Promise<Response> => {
    const key = url.toString();
    const hit = routes[key];
    if (!hit) throw new Error(`unexpected request: ${key}`);
    return new Response(JSON.stringify(hit.body), { status: hit.status, headers: hit.headers });
  };
}

const API = 'https://api.github.com';

describe('listRecentlyPushed', () => {
  it('maps the response to Repo objects', async () => {
    const f = stubFetch({
      [`${API}/user/repos?sort=pushed&per_page=5`]: {
        status: 200,
        body: [{ full_name: 'a/b', pushed_at: '2026-09-06T12:00:00Z' }],
      },
    });
    const client = new GitHubClient('token', f as typeof fetch);
    expect(await client.listRecentlyPushed()).toEqual([
      { fullName: 'a/b', pushedAt: '2026-09-06T12:00:00Z' },
    ]);
  });

  it('throws RateLimitError when the quota is exhausted', async () => {
    const f = stubFetch({
      [`${API}/user/repos?sort=pushed&per_page=5`]: {
        status: 403, body: {}, headers: { 'x-ratelimit-remaining': '0' },
      },
    });
    const client = new GitHubClient('token', f as typeof fetch);
    await expect(client.listRecentlyPushed()).rejects.toBeInstanceOf(RateLimitError);
  });
});

describe('queueTreePaths', () => {
  it('returns item paths from the branch tree', async () => {
    const f = stubFetch({
      [`${API}/repos/a/b/git/ref/heads/voice/queue`]: {
        status: 200, body: { object: { sha: 'commitsha' } },
      },
      [`${API}/repos/a/b/git/commits/commitsha`]: {
        status: 200, body: { tree: { sha: 'treesha' } },
      },
      [`${API}/repos/a/b/git/trees/treesha?recursive=1`]: {
        status: 200,
        body: { tree: [{ path: 'items/one.json', type: 'blob' }] },
      },
    });
    const client = new GitHubClient('token', f as typeof fetch);
    expect(await client.queueTreePaths('a/b')).toEqual(['items/one.json']);
  });

  it('returns an empty list when the branch does not exist', async () => {
    const f = stubFetch({
      [`${API}/repos/a/b/git/ref/heads/voice/queue`]: { status: 404, body: {} },
    });
    const client = new GitHubClient('token', f as typeof fetch);
    expect(await client.queueTreePaths('a/b')).toEqual([]);
  });
});
```

- [x] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/github.test.ts`
Expected: FAIL, cannot resolve `./github`.

- [x] **Step 3: Write minimal implementation**

`src/voice-queue/github.ts`:

```typescript
import type { Repo } from './types';

const API = 'https://api.github.com';
const BRANCH = 'voice/queue';

/** Distinguishable so the caller can back off instead of retrying blindly. */
export class RateLimitError extends Error {}

/**
 * The only file in this package that touches the network.
 *
 * fetchImpl is injectable so every other test can run offline. The token is
 * held in memory only and never logged: it belongs in the iOS keychain on the
 * device, and in the environment here.
 */
export class GitHubClient {
  constructor(
    private readonly token: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  private async get(path: string): Promise<Response> {
    const res = await this.fetchImpl(`${API}${path}`, {
      headers: {
        Authorization: `Bearer ${this.token}`,
        Accept: 'application/vnd.github+json',
      },
    });
    if (res.status === 403 && res.headers.get('x-ratelimit-remaining') === '0') {
      throw new RateLimitError('GitHub rate limit exhausted');
    }
    return res;
  }

  async listRecentlyPushed(limit = 5): Promise<Repo[]> {
    const res = await this.get(`/user/repos?sort=pushed&per_page=${limit}`);
    if (!res.ok) throw new Error(`listRecentlyPushed failed: ${res.status}`);
    const body = (await res.json()) as Array<{ full_name: string; pushed_at: string }>;
    return body.map((r) => ({ fullName: r.full_name, pushedAt: r.pushed_at }));
  }

  /** Empty list, not an error, when the repo has no queue branch. Most do not. */
  async queueTreePaths(fullName: string): Promise<string[]> {
    const ref = await this.get(`/repos/${fullName}/git/ref/heads/${BRANCH}`);
    if (ref.status === 404) return [];
    if (!ref.ok) throw new Error(`ref lookup failed: ${ref.status}`);
    const { object } = (await ref.json()) as { object: { sha: string } };

    const commit = await this.get(`/repos/${fullName}/git/commits/${object.sha}`);
    if (!commit.ok) throw new Error(`commit lookup failed: ${commit.status}`);
    const { tree } = (await commit.json()) as { tree: { sha: string } };

    const listing = await this.get(`/repos/${fullName}/git/trees/${tree.sha}?recursive=1`);
    if (!listing.ok) throw new Error(`tree lookup failed: ${listing.status}`);
    const body = (await listing.json()) as { tree: Array<{ path: string; type: string }> };
    return body.tree.filter((e) => e.type === 'blob').map((e) => e.path);
  }

  async readItem(fullName: string, id: string): Promise<unknown> {
    const res = await this.get(
      `/repos/${fullName}/contents/items/${id}.json?ref=${encodeURIComponent(BRANCH)}`,
    );
    if (!res.ok) throw new Error(`item read failed: ${res.status}`);
    const body = (await res.json()) as { content: string; encoding: string };
    const raw = Buffer.from(body.content, body.encoding as BufferEncoding).toString('utf8');
    return JSON.parse(raw);
  }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `npx vitest run`
Expected: PASS, 16 passed across both test files.

- [x] **Step 5: Commit**

```bash
git add src/voice-queue/github.ts src/voice-queue/github.test.ts
git commit -m "feat: GitHub client for reading the voice queue branch"
```

---

### Task 8: The poll loop and CLI

**Files:**
- Create: `src/voice-queue/watch.ts`
- Create: `src/voice-queue/watch.test.ts`
- Create: `scripts/voice-queue-watch.ts`
- Create: `docs/voice-queue.md`

**Interfaces:**
- Consumes: `GitHubClient`, `RateLimitError`, `reposToCheck`, `unseenItemIds`, `isPlayable`.
- Produces: `class QueueWatcher { constructor(client: GitHubClient); pollOnce(): Promise<QueueItem[]> }`. Returns newly arrived playable items in chronological order. Never returns the same item twice.

- [ ] **Step 1: Write the failing test**

`src/voice-queue/watch.test.ts`:

```typescript
import { describe, expect, it, vi } from 'vitest';
import { QueueWatcher } from './watch';
import { RateLimitError } from './github';

function item(id: string, text: string) {
  return { v: 1, id, source: 'claude-code', repo: 'a/b', title: 't', text, createdAt: '2026-09-06T12:00:00Z' };
}

function fakeClient(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    listRecentlyPushed: vi.fn().mockResolvedValue([{ fullName: 'a/b', pushedAt: 'T1' }]),
    queueTreePaths: vi.fn().mockResolvedValue(['items/one.json']),
    readItem: vi.fn().mockResolvedValue(item('one', 'hello')),
    ...overrides,
  };
}

describe('QueueWatcher.pollOnce', () => {
  it('returns a newly arrived item', async () => {
    const w = new QueueWatcher(fakeClient() as never);
    const got = await w.pollOnce();
    expect(got.map((i) => i.text)).toEqual(['hello']);
  });

  it('does not return the same item twice', async () => {
    const w = new QueueWatcher(fakeClient() as never);
    await w.pollOnce();
    expect(await w.pollOnce()).toEqual([]);
  });

  it('skips the ref lookup when nothing was pushed', async () => {
    const client = fakeClient();
    const w = new QueueWatcher(client as never);
    await w.pollOnce();
    client.queueTreePaths.mockClear();
    await w.pollOnce();
    expect(client.queueTreePaths).not.toHaveBeenCalled();
  });

  it('skips an item with an unknown schema version', async () => {
    const client = fakeClient({ readItem: vi.fn().mockResolvedValue({ ...item('one', 'hi'), v: 99 }) });
    const w = new QueueWatcher(client as never);
    expect(await w.pollOnce()).toEqual([]);
  });

  it('surfaces a rate limit rather than swallowing it', async () => {
    const client = fakeClient({
      listRecentlyPushed: vi.fn().mockRejectedValue(new RateLimitError('limit')),
    });
    const w = new QueueWatcher(client as never);
    await expect(w.pollOnce()).rejects.toBeInstanceOf(RateLimitError);
  });

  it('one repo failing does not lose items from another', async () => {
    const client = fakeClient({
      listRecentlyPushed: vi.fn().mockResolvedValue([
        { fullName: 'broken/x', pushedAt: 'T1' },
        { fullName: 'a/b', pushedAt: 'T1' },
      ]),
      queueTreePaths: vi.fn(async (name: string) => {
        if (name === 'broken/x') throw new Error('boom');
        return ['items/one.json'];
      }),
    });
    const w = new QueueWatcher(client as never);
    expect((await w.pollOnce()).map((i) => i.text)).toEqual(['hello']);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run src/watch.test.ts`
Expected: FAIL, cannot resolve `./watch`.

- [ ] **Step 3: Write minimal implementation**

`src/voice-queue/watch.ts`:

```typescript
import { GitHubClient, RateLimitError } from './github';
import { isPlayable, reposToCheck, unseenItemIds } from './select';
import type { QueueItem } from './types';

/**
 * Turns "poll GitHub" into "here is what is new".
 *
 * State is in memory here. On the device this must be persisted, otherwise a
 * restart replays the entire backlog into your ear.
 */
export class QueueWatcher {
  private lastSeenPushedAt: Record<string, string> = {};
  private readonly seenIds = new Set<string>();

  constructor(private readonly client: GitHubClient) {}

  async pollOnce(): Promise<QueueItem[]> {
    const repos = await this.client.listRecentlyPushed();
    const changed = reposToCheck(repos, this.lastSeenPushedAt);
    const fresh: QueueItem[] = [];

    for (const repo of changed) {
      try {
        const paths = await this.client.queueTreePaths(repo.fullName);
        for (const id of unseenItemIds(paths, this.seenIds)) {
          const raw = await this.client.readItem(repo.fullName, id);
          // Mark seen either way. A malformed item retried forever would
          // block every item behind it.
          this.seenIds.add(id);
          if (isPlayable(raw)) fresh.push(raw);
        }
        // Only record progress for a repo that was read without error, so a
        // transient failure is retried on the next poll instead of skipped.
        this.lastSeenPushedAt[repo.fullName] = repo.pushedAt;
      } catch (err) {
        if (err instanceof RateLimitError) throw err;
        // One unreachable repo must not cost us the others.
      }
    }

    return fresh;
  }
}
```

`scripts/voice-queue-watch.ts`:

```typescript
import { GitHubClient, RateLimitError } from '../src/voice-queue/github';
import { QueueWatcher } from '../src/voice-queue/watch';

/**
 * Proves the transport with no app: run it, ask a cloud session something, and
 * watch the response appear here. If this does not work, nothing built on top
 * of it will either.
 */
const token = process.env.GITHUB_TOKEN;
if (!token) {
  console.error('GITHUB_TOKEN is not set. A classic or fine-grained PAT with repo read access.');
  process.exit(1);
}

const intervalMs = Number(process.env.POLL_INTERVAL_MS ?? 10_000);
const watcher = new QueueWatcher(new GitHubClient(token));

console.log(`watching, every ${intervalMs}ms. ctrl-c to stop.`);

for (;;) {
  try {
    for (const item of await watcher.pollOnce()) {
      console.log(`\n[${item.createdAt}] ${item.title} (${item.repo})`);
      console.log(item.text);
    }
  } catch (err) {
    if (err instanceof RateLimitError) {
      console.error('rate limited, backing off for a minute');
      await new Promise((r) => setTimeout(r, 60_000));
      continue;
    }
    console.error('poll failed:', err instanceof Error ? err.message : err);
  }
  await new Promise((r) => setTimeout(r, intervalMs));
}
```

`docs/voice-queue.md` in `earshot`:

```markdown
# voice-queue

Reads Claude Code responses off the `voice/queue` branch of whichever repo was
pushed to most recently, and prints them. No audio, no UI. This exists to prove
the transport before anything is built on top of it.

## Use

    export GITHUB_TOKEN=<a PAT with repo read access>
    npm run voice-queue:watch

Then start a Claude Code session on any repo that has the voice-queue Stop hook
wired up, ask it something, and the response should appear here within about
ten seconds.

## Why polling

The cloud sandbox a Claude Code session runs in routes egress through an
allowlisting proxy. GitHub is reachable from there; Convex and the Kokoro box
are not. So the hook pushes a commit, and this polls for it. See
`docs/superpowers/specs/2026-09-06-on-the-go-listening-design.md` for the
measurements behind that.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run`
Expected: PASS, 22 passed across three test files.

- [ ] **Step 5: Commit**

```bash
git add src/voice-queue/ scripts/ package.json
git commit -m "feat: poll loop and CLI proving the queue transport end to end"
```

---

### Task 9: Wire it up and prove it end to end

The first task that requires the network, a cloud session, and a real device. Everything before this was provable offline, which was the point of the ordering.

**Files:**
- Create: `hooks/install-voice-queue.sh`
- Create: `docs/voice-queue.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing further depends on this task.

- [ ] **Step 1: Write the installer**

Create `hooks/install-voice-queue.sh`:

```bash
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
cp "$src/lib/extract_response.sh" "$src/lib/strip_markdown.py" \
   "$src/lib/queue_item.py" "$src/lib/publish_item.sh" "$target/.claude/hooks/lib/"
chmod +x "$target/.claude/hooks/voice-queue-stop.sh" "$target/.claude/hooks/lib/"*

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
```

Then `chmod +x hooks/install-voice-queue.sh`.

- [ ] **Step 2: Install into the probe repo and commit it there**

```bash
./hooks/install-voice-queue.sh ~/sites/hook-probe
cd ~/sites/hook-probe && git add .claude && git commit -m "feat: publish responses to the voice queue" && git push
```

- [ ] **Step 3: Verify locally before trusting the cloud**

```bash
cd ~/sites/hook-probe && claude -p "Say hello in one sentence."
git fetch origin 'refs/heads/voice/queue:refs/heads/voice/queue' && git show voice/queue --stat
```

Expected: one `items/<id>.json` on the branch. Also confirm `git status` in that repo is unchanged, which is the assertion that matters most.

- [ ] **Step 4: Start the watcher**

```bash
cd ~/sites/earshot && GITHUB_TOKEN=<pat> npm run voice-queue:watch
```

Expected: `watching, every 10000ms.`

- [ ] **Step 5: The real test**

From your phone, start a cloud session on `hook-probe` and ask it anything. Time from its reply appearing on the phone to the text appearing in the watcher.

Expected: under ten seconds.

If nothing arrives, check in this order, because it isolates the failure fastest: does the branch exist on GitHub (hook problem), does `queueTreePaths` see it (token scope problem), does `pollOnce` return it (dedupe or schema problem).

- [ ] **Step 6: Write it down**

Create `docs/voice-queue.md` recording the measured end-to-end latency, the token scope that worked, and anything that surprised you. The next person to touch this will not have watched it happen.

- [ ] **Step 7: Commit**

```bash
git add hooks/install-voice-queue.sh docs/voice-queue.md
git commit -m "feat: installer and end to end verification for the voice queue"
```

---

## Self-review

**Spec coverage.** The hook (spec section "The hook") is Tasks 1 to 5. The queue item shape ("The queue item") is Task 3, matching the spec's field list exactly including `v`. The watcher ("The watcher") is Tasks 6 to 8, using the `/user/repos?sort=pushed` strategy and the three-calls-per-poll budget the spec describes. Error handling is distributed rather than separate: exit-0 survivability in Tasks 4 and 5, rate-limit and per-repo isolation in Task 8, unknown-version skipping in Tasks 6 and 8. The spec's testing section maps to the fixture tests in Task 2, the working-tree assertions in Task 4, the recorded-response tests in Task 7, and the timed end-to-end run in Task 9.

**Deliberately out of scope**, and covered by later plans: synthesis, the player, the Expo app, the share extension, Convex, and queue pruning. The spec's "Open questions" are untouched by design.

**One gap I am naming rather than hiding.** The spec says the PAT belongs in the iOS keychain. This plan reads it from `GITHUB_TOKEN` because there is no device app yet. That is correct for a CLI and wrong for the phone, and the keychain requirement transfers to the app plan.

**Type consistency.** `Repo`, `QueueItem`, `reposToCheck`, `unseenItemIds`, `isPlayable`, `GitHubClient`, `RateLimitError` and `QueueWatcher` are used with identical names and signatures in Tasks 6, 7 and 8. The item JSON keys written by `queue_item.py` in Task 3 match the `QueueItem` interface in Task 6 field for field.
