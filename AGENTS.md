# AGENTS.md

Contract for AI agents working in this repository. Read before making changes.

## What this project is

SpeakIt is a system-wide macOS reader: it speaks selected text and coding-agent
output. Menu-bar app, global hotkey, Services menu entry, Chrome extension, and
a Claude Code plugin.

**Four speech engines behind one protocol** (`Sources/SpeakIt/TTSProvider.swift`):

| Engine | Cost | Notes |
|---|---|---|
| Apple Speech | free, offline | `AVSpeechProvider` |
| Microsoft Edge Neural | free, online | `EdgeTTSProvider`, shells out to the `edge-tts` CLI |
| Kokoro-82M | free, offline | `KokoroProvider`, resident Python daemon running ONNX |
| ElevenLabs | **paid, metered** | `ElevenLabsProvider` plus the `ElevenLabsKit` target |

The provider abstraction predates the ElevenLabs work by four months
(`6ad4473`, 2026-05-16). Adding the third and fourth engines required no
changes to calling code, which is the design working as intended. Keep it
that way.

## Layout

```
Sources/SpeakIt/          the @main executable. AppKit, SwiftUI, AVFoundation.
Sources/SpeechKit/        engine-agnostic logic: sentence scheduling shared by
                          every provider, plus the Kokoro voice catalogue,
                          install layout and daemon protocol.
Sources/ElevenLabsKit/    library target: API client, models, credentials,
                          retry policy, audio sniffing, read-state bookkeeping.
Tests/                    135 tests. 130 stubbed, 5 live/keychain-gated.
docs/                     including the live validation runbook.
scripts/build-app.sh      builds and installs ~/Applications/SpeakIt.app
scripts/kokoro-setup.sh   installs the local engine into ~/.speakit/kokoro
scripts/kokoro_daemon.py  the resident synthesis process
```

`SentenceQueue` lives in `SpeechKit`, not `ElevenLabsKit`, because both the
paid and the local provider need it. It is the one piece of scheduling logic
that must not be reimplemented per engine.

**Why `ElevenLabsKit` exists as a separate target:** `SpeakIt` is an `@main`
executable and executables are awkward to import from a test target. Anything
worth unit testing goes in the kit, which has no AppKit dependency. Every defect
found in three rounds of review was in state transitions, not audio code, so
put logic there and test it.

## Rules

1. **Run the tests.** `swift test`. 135 should pass or skip, none fail.
2. **`swift run SpeakIt` is not the installed app.** They are different
   binaries and only `~/Applications/SpeakIt.app` owns the menu bar. This has
   already caused a full afternoon of confusion: every test passed, the app
   appeared to work, and the API received nothing because reads were silently
   falling through to the offline engine. Before trusting any manual test:
   ```bash
   strings ~/Applications/SpeakIt.app/Contents/MacOS/SpeakIt | grep -c elevenlabs
   ps -p "$(pgrep -x SpeakIt | head -1)" -o lstart=
   ```
   Zero matches, or a start time older than your last build, means you are
   testing the wrong binary. Rebuild with `./scripts/build-app.sh`, quit, relaunch.
3. **Never commit `.env`.** It holds a bearer credential that bills money and
   this repository is public. It is gitignored; keep it that way.
4. **The API key belongs in the Keychain**, not `UserDefaults`. Note that
   `ELEVENLABS_API_KEY` in the environment **overrides** the Keychain, which
   silently masks a correctly saved key.
5. **Respect the spend cap.** Synthesis runs at most three sentences ahead of
   playback. Removing that bills a whole article the moment someone presses
   play, including the part they skip.
6. **Do not claim behaviour the code does not have.** A pull request description
   here once asserted audio caching that had been deleted on play. Review caught
   it. Verify before writing it down.
7. **No em dashes** in prose, comments or commit messages.
8. **Do not make the local engine a hard dependency.** Kokoro is absent until
   someone runs `scripts/kokoro-setup.sh`. `KokoroInstall.status` must keep
   distinguishing "never installed" from "half installed", because the two
   have different fixes.

## The ElevenLabs provider, and why it is shaped this way

Three things differ from the free engines. Each drove a design decision.

**It bills per character.** Hence `ReadState.isWithinLookahead`, a three-ahead
cap; hence audio cached for the whole read so a backward seek replays rather
than re-buys; hence pause gating the *next* request while letting the in-flight
one finish, because that one is billed either way.

**It has no speaking-rate parameter**, unlike `edge-tts` where rate is baked
into synthesis. Rate is applied at playback via `AVAudioPlayer.rate`.
`PlaybackRate.multiplier` maps the slider midpoint to exactly 1.0x, and there is
a test guarding that value because it is the setting almost everyone leaves
alone.

**Its failures need separating.** `APIError.isRetryable` splits fatal from
transient. A rejected key or exhausted quota stops the read; a rate limit or 5xx
gets three bounded attempts honouring `Retry-After`, clamped to four seconds
because someone is listening through every delay.

## Defects already found, do not reintroduce

| Defect | Guard |
|---|---|
| A failed sentence stalled the read while the rest kept billing | `SentenceQueue` steps over failures |
| Paid audio deleted on play, so backward seek re-billed | `audioCache` survives the read |
| Retryable errors classified then never retried | `RetryPolicy` |
| Pause did not stop spending | generator gated, not cancelled |
| A 2xx assumed to be audio | `AudioSniffer` checks magic bytes |
| A player-rejected file stayed cached, so playback could loop | `markPlaybackFailed` |
| A scoped key reported as an invalid key | `APIError.missingPermission` |
| Free-plan voice rejection surfaced as a raw status code | `APIError.paidPlanRequired` |

## The Kokoro provider, and why it is shaped this way

Added 2026-09-05, after measuring VoxCPM as a candidate and rejecting it.

**Why not VoxCPM.** Its own README reports RTF ~1.76 for the 2B model on
Apple silicon with Metal, which is slower than realtime. A reader that starts
talking after an agent stops cannot use an engine that renders slower than it
plays. Kokoro is 82M parameters and measures **RTF 0.155 on an M3 Max**
(fp32 weights, 5.1x faster than playback, 0.57 s one-off model load). That
is the entire argument.

**Why a daemon, not a process per sentence.** `EdgeTTSProvider` spawns a CLI
per sentence and that is fine, because the process only makes an HTTP call.
Here a process start means importing onnxruntime and loading 325 MB of
weights. Paying that per sentence would put the first word further away than
the network engine it replaces. One daemon starts on first use, stays
resident, and speaks JSON lines over a pipe.

Consequences of the pipe, each of which is load-bearing:

- **Framing.** One JSON object per line, and every reply carries the id of the
  request it answers. `LineBuffer` reassembles, because a pipe read can return
  half a line.
- **stdout is protocol.** onnxruntime and phonemizer both print on import, so
  the daemon redirects stdout to stderr for the duration of the imports.
  `KokoroProtocol.parse` returns nil for anything unrecognised rather than
  throwing, so one stray line cannot abort a working read.
- **stderr must be drained.** Without a reader the 64 KB pipe buffer fills and
  the daemon blocks on its next warning. That presents as a hang partway
  through a long read, with no error anywhere.
- **Shutdown has to drain.** Returning from the read loop on EOF or shutdown
  kills the worker thread mid-synthesis and drops replies the client is still
  waiting on. `jobs.join()` at both exits. This was a real bug: setup's
  verification step failed until it was fixed.
- **Cancellation is expected, not exceptional.** A seek cancels queued work.
  `cancelled` is separated from `error` so scrubbing does not fill the log.

**The lookahead cap is kept, for a different reason.** ElevenLabs caps
synthesis three sentences ahead to bound spend. Nothing is billed here, but
rendering forty sentences of an article the user abandons after two is real
CPU on their laptop. Six, because being wrong is cheaper than it is for the
paid engine.

**Kokoro has no German voices.** Its 54 voices cover nine languages, and
German is not among them. `EdgeTTSProvider` keeps the German neural voices,
so do not present the local engine as a full replacement for it.

## Live validation

`docs/elevenlabs-live-validation.md`. Read it before touching cost behaviour.

Key facts learned the hard way:

- A key needs `user_read`, `voices_read` and `text_to_speech`. Not `models_read`.
- Free accounts cannot use shared library voices via the API. Pick a voice from
  `/v1/voices` rather than pasting an ID from the docs.
- `character_count` on `/v1/user/subscription` **lags about twenty seconds**.
  Reading it immediately after synthesis shows no change, which looks exactly
  like the spend cap working. Use `/v1/history` instead: one entry per request,
  so you can count requests rather than infer from a total.

**Measured, 2026-09-04:** a nine-sentence read fired exactly three requests at
once, then paced the remaining six across 21 seconds. That is the cap binding.

## State as of 2026-09-05

ElevenLabs merged to `main` via PR #2, commit `bf60919`. Live API verified.
Kokoro added on `feature/kokoro-local-tts`. 135 tests.

Kokoro verified end to end on 2026-09-05: daemon spawns as a child of the
installed bundle using the *bundled* script, survives across reads (same pid,
CPU time growing), leaves no temporary wavs behind, and its hand-written WAV
output parses as `WAVE, 1 ch, 24000 Hz, Int16` with the duration it reports.

Outstanding, in rough priority order:

1. **Manual runbook items not yet done:** pause holding quota steady, and a
   backward seek not increasing quota. Both verify cost claims that review has
   already caught this project overstating once.
2. **Progressive playback.** Each sentence is fully downloaded before it plays.
   `AVAudioEngine` with buffer scheduling would start audio on the first chunk.
3. **One credential store.** `LLMSettings` has its own Keychain helper that
   deletes-and-re-adds, sets no accessibility attribute and ignores its
   `OSStatus`. `ElevenLabsCredentials` is the better implementation.
   Consolidating was deliberately left out of the provider change to avoid
   creating regression surface in an unrelated feature.
4. **Tune the lookahead.** Three is a guess. It should come from real reading
   behaviour.
5. **`EdgeTTSProvider` shares the stalled-sentence shape** that `SentenceQueue`
   fixed here. It matters less because a local process rarely fails mid-run, but
   the defect is the same. `KokoroProvider` already uses the shared queue, so
   Edge is now the only provider still carrying it.
6. **Kokoro playback is not progressive.** Same gap as the paid provider: a
   sentence is fully rendered before it plays. Cheaper to fix here, since the
   daemon could stream chunks over the same pipe.
7. **The lookahead of six is a guess**, like the paid provider's three.

## Provenance

Handed off from a Claude Code session on 2026-09-05 via the ATEM harness.
Full distilled state: `~/.atem/harness/sessions/claude-code:8597060e-06f2-4490-a260-108b76d487f2/`.
