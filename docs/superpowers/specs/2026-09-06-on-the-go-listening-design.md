# On-the-go listening: design

Date: 2026-09-06
Status: approved in outline, not yet implemented

## Why this exists

There have been three attempts at this already: readme-tts, Voicy, and
Audio-reader, plus two Chrome extensions. All five were built as "read this page
aloud". None of them delivered the thing actually wanted, and the reason is
visible once the goal is stated in the right order.

The three moments that matter, ranked by pain:

1. Hearing Claude Code output on the phone, live, while working from the phone.
2. Seeing a link and getting it read with one action.
3. Listening to the day's accumulated pile while walking.

Not one of the five previous attempts addressed the first, which is the worst
one. And the third is not a separate problem: if the first two fill a queue,
"listen to the pile" is a play button on that queue.

So this is not a fourth reader. It is a queue with three producers and one
consumer. That reframing is the whole design.

## Goals

- Claude Code responses reach the ear on a phone, within about ten seconds,
  from a session that is not running on the Mac.
- A link seen anywhere on the phone becomes audio with one physical action.
- Everything that arrives accumulates in one queue that can be played through.
- Personal tool for one person. Not a product yet.

## Non-goals

- Multi-user support, onboarding, or anything App Store facing.
- Replacing Voicy. Voicy stays as the desktop and web paste surface.
- Changing the macOS SpeakIt app. It keeps working as it does today.
- Android. The Expo codebase produces it for free, but it is untested and
  nobody is asking for it.
- High availability. A homelab dependency is acceptable at this stage.

## Measured constraints

These were established by probing a real cloud session on 2026-09-06, not
assumed. They are recorded here so the next person does not re-litigate them.

| Question | Answer | Evidence |
|---|---|---|
| Do repo-level Stop hooks execute in a cloud session? | Yes | `HOOKPROBE hook_fired=yes host=Linux` |
| Can that sandbox reach arbitrary hosts? | No | `http=000 curl_exit=56`, TLS reset, with and without the CA bundle |
| Is there a proxy, or a wall? | An allowlisting proxy | `api.github.com` 200, `api.anthropic.com` 401 |
| Can it reach Convex? | No | `combative-sparrow-474.convex.site` and `.convex.cloud` both `exit=56` |
| Can it reach the Kokoro box? | No | `$KOKORO_HOST` `exit=56` |
| Can a hook push to GitHub? | Yes | `git push` to the in-scope repo, `push_exit=0` |
| Can it push to an out-of-scope repo? | Unmeasured, and deliberately so | `add_repo` was denied by the harness classifier. Probing around that boundary was declined. The design avoids needing the answer. |

Two consequences follow, and they shape everything below.

**GitHub is the only way out of the sandbox.** The hook cannot talk to Convex or
to Kokoro. It can push a commit. That is the entire available channel.

**The queue lives in the repo the session already has.** A dedicated queue repo
would require cross-repo push, which is exactly the unmeasured question above.
Pushing to the current repo needs no additional scope and no per-session setup.

## Architecture

```
Claude Code session (Mac or cloud)
  └─ Stop hook ──git push──> voice/queue branch, in the current repo
                                        │
                                   (phone polls)
                                        │
iOS share sheet / Back Tap ──> Convex ──┤
                                        ▼
                                  Expo app queue
                                        │
                          calls Kokoro directly for audio
                                        ▼
                                     playback
```

The phone is not behind the sandbox proxy, so it reaches both GitHub and
`$KOKORO_HOST` without difficulty. The proxy constrains only the
hook.

Note that Convex is deliberately absent from producer 1's live path. It holds
the saved library and serves producer 2, where it earns its keep. Putting it in
the Claude Code path would mean an extra hop that the proxy forbids anyway.

## Components

### 1. The hook

A shell script committed to each repo, wired as a `Stop` hook in
`.claude/settings.json`. It runs identically on the Mac and in a cloud sandbox,
which is the property that makes this work at all.

Responsibilities, in order:

1. Exit immediately if `CLAUDE_VOICE=0`.
2. Read the hook payload from stdin, take `transcript_path`, extract the last
   assistant message, and strip markdown.
3. Write a queue item as JSON.
4. Push it to the `voice/queue` orphan branch of the current repo.

Reuse, do not rewrite, the transcript parsing and markdown stripping from
`hooks/speakit-stop.sh`. That logic is correct and was arrived at painfully.
Two things must change: the on/off gate moves from
`defaults read com.atem.SpeakIt` to an env var, and the delivery leg changes
from `open speakit://` to a git push. The absolute paths `/usr/bin/jq` and
`/usr/bin/python3` must become `command -v` lookups, since the sandbox is Linux.

Three hard requirements:

- **It must never touch the working tree.** Push from a temp clone under
  `$TMPDIR`. A hook that runs `git checkout` in the user's repo mid-session is
  a data-loss bug waiting to happen.
- **It must always exit 0.** A hook that fails must not interrupt the session.
  Voice is a convenience; losing a session over it is not a trade worth making.
- **It must be bounded in time.** Cap the push at a few seconds and give up
  quietly. A hung hook is worse than a missed item.

Concurrent sessions pushing to the same branch will collide. Item files are
uniquely named, so the resolution is a fetch and rebase and one retry, which
always succeeds because two sessions never write the same path.

### 2. The queue item

One JSON file per item, at `items/<createdAt>-<shortid>.json` on the
`voice/queue` branch.

```json
{
  "v": 1,
  "id": "2026-09-06T12-04-31Z-a1b2c3",
  "source": "claude-code",
  "repo": "Atemndobs/SpeakIt",
  "title": "SpeakIt",
  "text": "the response, markdown stripped",
  "createdAt": "2026-09-06T12:04:31Z"
}
```

Append-only, with a periodic prune of anything older than a few days. `v` is
present so the phone can ignore items it does not understand rather than crash
on them.

### 3. The watcher

On the phone. Answers "has anything new arrived" without being told which repo
to look at.

1. `GET /user/repos?sort=pushed&per_page=5`. A queue push necessarily makes that
   repo the most recently pushed, so the answer is always in this response.
2. For any repo whose `pushed_at` moved, `GET /repos/{owner}/{repo}/git/ref/heads/voice/queue`.
3. Fetch the tree, then the blobs for item ids not seen before.

About three calls per poll at a ten second interval, roughly 1080 per hour
against a 5000 per hour authenticated limit. Comfortable, with room to shorten
the interval if ten seconds proves too slow in practice.

Dedupe by item id, persisted, so a restart does not replay the queue.

This needs a GitHub PAT on the device. It is a credential and belongs in the
iOS keychain, never in app storage or a config file.

### 4. Synthesis

The phone calls `$KOKORO_HOST/v1/audio/speech` directly. Chunk the
text, request chunks with bounded concurrency, and begin playback on the first
chunk rather than waiting for the whole item. Voicy already does exactly this,
including the multi-part timeline and cross-part seeking; port that logic rather
than reinventing it.

### 5. The app

One Expo app generated by the mobile-stack CLI, which now defaults to Convex and
Clerk. Two surfaces: a queue list, and a player. Nothing else in version one.

### 6. Share extension and Back Tap

The iOS share sheet requires a native extension. This is not a preference: iOS
does not implement the Web Share Target API, so Safari can share to a native app
and never to a web app. This single fact is why the whole thing is native rather
than a PWA, and it is why the previous browser-based attempts could never have
closed pain 2.

The copy gesture from the Mac cannot be reproduced. iOS does not permit
background clipboard access, and any design promising it is wrong. The
replacement is a Shortcut bound to Back Tap or the Action Button: it reads the
clipboard when explicitly invoked and hands the text to the app. One physical
action, no app switching, and the same Shortcut handles a shared link.

Both post to Convex, which extracts and synthesizes. One code path for both.

## Error handling

The governing rule: **a failure in the voice path must never damage the thing it
is attached to.** The hook is attached to your working sessions, so it exits 0
on every error, writes nothing outside `$TMPDIR` and the queue branch, and gives
up rather than retrying forever.

- Push rejected: fetch, rebase, retry once, then discard the item. A lost
  response is annoying. A blocked session is not acceptable.
- Kokoro unreachable: the item stays in the queue unplayed and is marked as
  needing synthesis. Retry on next foreground.
- GitHub rate limited: back off, surface it in the UI rather than failing
  silently. Silent failure is what made the previous iterations feel broken.
- Malformed or future-version item: skip it, do not crash the queue.

## Testing

- Markdown stripping and JSON emission: unit tests against fixture transcripts,
  no network. This is the part most likely to regress.
- Hook end to end: push to a scratch repo, assert the item lands on the branch
  and the working tree is untouched. The working tree assertion is the important
  one.
- Watcher: against recorded GitHub responses, including the rate-limited and
  no-such-ref cases.
- The real test: start a cloud session from the phone, ask something, and time
  how long until audio. If that is not under about ten seconds, the design has
  not delivered its first goal.

## Known weaknesses

Stated plainly, because each is a real cost and none is hidden.

**A commit per response is a strange use of git**, and every repo worked in
accumulates a `voice/queue` branch. Contained, but not invisible.

**Latency is under ten seconds, not two.** That is the price of polling, which
is the price of the proxy.

**The Kokoro box is a single point of failure.** If the house loses power there
is no audio. Acceptable for a personal tool. Worth renting a twin before anyone
else depends on it.

**Background audio has a hard limit.** While actively listening, new items append
seamlessly. If the app is fully suspended, iOS delivers a notification to tap
and will not let anything start audio on a locked phone unprompted.

**The proxy allowlist is undocumented.** GitHub being reachable is a measured
fact today, not a promised interface, and it could change without warning. This
is acceptable precisely because the tool is for one person. It would not be an
acceptable foundation for anything other people depend on, and if this ever
becomes a product the transport has to be revisited first.

## Open questions

- Poll interval. Ten seconds is a guess. Measure battery cost before settling.
- Queue pruning. How long to retain, and whether the phone or a periodic job
  does it.
- Whether the macOS SpeakIt app should also consume this queue, so that what
  was heard on the phone is not repeated at the desk. Deliberately out of scope
  for version one.

## Next step

An implementation plan, ordered so that the riskiest thing is proven first. The
hook and the watcher are the parts that could still fail for reasons outside our
control, so they come before any player UI. Nothing about this design is worth
building if a cloud session cannot get a response onto a branch and a phone
cannot see it arrive.
