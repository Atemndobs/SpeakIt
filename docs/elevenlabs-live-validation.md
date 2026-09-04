# ElevenLabs live validation runbook

Everything in this PR is verified against a stubbed `URLSession`. That proves
the code matches my belief about the API, not that the belief is right. This
runbook closes that gap.

**Run it before merging.** Expect it to take about fifteen minutes and a few
hundred characters of quota.

## 0. Get the key in without leaking it

The key is a bearer credential that bills money. Do not paste it into a chat, a
commit, or a command that lands in shell history.

**Preferred: the app's own UI.** Build and run SpeakIt, set Engine to
ElevenLabs, paste the key into the settings field and press **Save key**. It
goes straight to the Keychain and never touches a shell.

```bash
swift run SpeakIt
```

**For the test suite**, which reads the environment first, use a hidden prompt
so nothing is echoed or recorded:

```bash
read -rs "?ElevenLabs API key: " ELEVENLABS_API_KEY && export ELEVENLABS_API_KEY
```

`read -rs` does not echo, and because the value never appears as a command
argument it does not enter `~/.zsh_history`.

**When finished:**

```bash
unset ELEVENLABS_API_KEY
```

Note that the environment variable **shadows the Keychain** by design
(`ElevenLabsCredentials.readFromKeychain`), so leaving it set will mask what the
app has stored.

## 1. Automated live tests

```bash
swift test --filter LiveAPITests
```

Four tests. **All four passed on 2026-09-04**, first live run. Expected results:

| Test | Proves |
|---|---|
| `testLiveKeyIsValidAndQuotaIsReadable` | subscription and quota retrieval |
| `testLiveVoiceCatalogueDecodes` | live voice discovery, and that the decoder survives the real payload |
| `testLiveSynthesisReturnsPlayableMP3` | real synthesis, verified by MP3 frame header rather than byte count |
| `testLiveBadKeyIsRejectedCleanly` | invalid-key handling against the real 401, not a stub |

The synthesis test prints the byte count, the elapsed time and the voice used,
and writes the audio to a temp file. **Listen to it.** A test that asserts bytes
exist is not proof that it sounds right.

```
[live] wrote /var/folders/.../speakit-live-test.mp3
```

Record the numbers below.

### First run, 2026-09-04

```
tier: free, 10,000 character limit, 0 used at start
voices returned: 21
voice used: Roger (american)
synthesis: 36,407 bytes in 0.21s
audio: ID3v2.4, MPEG layer III, 128 kbps, 44.1 kHz mono, 2.27s, verified with ffprobe
quota after: 17 characters, visible only after ~20s delay
bad key: rejected cleanly as unauthorized
```

Still outstanding: the manual checks in section 3, which need the app running.

## 1b. Two things the first live run taught us

**The API key needs scopes.** A key created with restricted permissions returns
`401` with the same shape as a bad key. Grant these three at
elevenlabs.io/app/settings/api-keys:

| Scope | Needed for |
|---|---|
| `user_read` | quota and the settings panel |
| `voices_read` | the voice picker |
| `text_to_speech` | synthesis |

`models_read` is **not** needed; nothing here calls `/v1/models`.

**Free accounts cannot use shared library voices through the API.** A hardcoded
premade voice ID returns `402 paid_plan_required`. Voices already on the account
work: the first live run synthesized fine with "Roger" from the account's own
catalogue of 21. Always pick a voice from `/v1/voices` rather than pasting an ID
from the docs.

## 2. Quota accounting, which is the interesting part

**`character_count` lags by roughly twenty seconds.** Reading it immediately
after a synthesis shows no change, which looks exactly like the spend cap
working when it is really just latency. Wait before taking Q1, or the whole
measurement is worthless.

**`/v1/history` is the better instrument.** It records one entry per synthesis
request with the exact character count of each:

```bash
curl -s -H "xi-api-key: $ELEVENLABS_API_KEY" \
  "https://api.elevenlabs.io/v1/history?page_size=20" | python3 -m json.tool
```

That lets you **count the requests**, not just the characters, which is a direct
measurement of the three-sentence lookahead rather than an inference from a
total. Play four sentences of a twenty-sentence article, stop, and expect at
most seven entries. Twenty entries means the cap is broken.

### The Q0 / Q1 method

Still valid as a cross-check, as long as you respect the delay above.

**Before anything:**

```bash
swift test --filter testLiveKeyIsValidAndQuotaIsReadable
```

Note `character_count`. Call it **Q0**.

**Then** run the app, pick a long article of at least twenty sentences, start it,
let three or four sentences play, and press **stop**.

Check quota again. Call it **Q1**.

| Expectation | Why |
|---|---|
| `Q1 - Q0` is roughly the characters of the sentences played plus at most three more | The lookahead cap is doing its job |
| `Q1 - Q0` is **not** the whole article | If it is, the cap is broken and the cost claim in the PR is wrong |

Write both numbers into the PR. This is the single most falsifiable claim in the
whole change and it is worth having a real measurement behind it.

### Measured result, 2026-09-04

A nine-sentence read through the app:

```
22:53:25   49 chars  ┐
22:53:25   66 chars  ├─ three fired at once, the lookahead window
22:53:25   14 chars  ┘
22:53:26   46 chars
22:53:27   13 chars
22:53:32   58 chars     each gated on playback advancing
22:53:39   18 chars
22:53:44   36 chars
22:53:46   80 chars
                        9 requests, 380 characters
```

Exactly three immediately, the rest paced across 21 seconds. An unbounded
prefetch would have fired all nine inside the first second. **The cap binds.**

## 2b. Check you are testing the app you think you are

The measurement above took a detour worth recording, because it will happen
again.

Every test passed and the app appeared to work: text read aloud, correct voices,
no errors. The API saw nothing.

The menu-bar app was a `.app` built days earlier, before the provider existed.
**`swift run` produces a different binary from the installed bundle, and only
the bundle owns the menu bar.** Reads were silently going through Apple Speech
offline, which is precisely why nothing looked wrong.

Before trusting any manual measurement:

```bash
strings ~/Applications/SpeakIt.app/Contents/MacOS/SpeakIt | grep -c elevenlabs
ps -p "$(pgrep -x SpeakIt | head -1)" -o lstart=
```

Zero matches, or a start time older than your last build, means you are testing
the wrong binary. Rebuild and relaunch:

```bash
./scripts/build-app.sh
osascript -e 'tell application "SpeakIt" to quit'
open ~/Applications/SpeakIt.app
```

The binary changes identity, so macOS may require re-granting Accessibility.

## 3. Manual checks the tests cannot make

Run the app for these.

### Pause and resume

1. Start a long read.
2. Pause mid-sentence. Note quota.
3. Wait thirty seconds. **Check quota again: it must not have moved.**
4. Resume. Playback should continue from where it stopped, and the sentence that
   was in flight when you paused should play without a gap.

This checks the fix from `5ffe77a`: the in-flight request finishes and is
cached, but the next one does not start.

### Backward seek without quota increasing

1. Let five or six sentences play.
2. Note quota. Call it **Q2**.
3. Seek back to sentence one and listen to it replay.
4. **Check quota: it must equal Q2.**

If it moved, the cache is not being reused and the PR's cost claim is wrong
again. This is the finding review caught the first time, so it is worth
confirming with real numbers.

### Language handling

Read a paragraph of German and one of French. Confirm the voice handles both and
that nothing in the pipeline mangles the umlauts or accents.

### Induced retryable failure, if practical

Optional, and only if it can be done cleanly.

1. Start a read.
2. Turn off wi-fi for about five seconds mid-article, then back on.
3. Expect: a short gap, then playback continues. The log shows
   `retrying sentence N in 0.4s (attempt 1)`.
4. Expect **not**: the read dying, or the rest of the article being skipped.

If the network drops for longer than the three bounded attempts, the sentence is
skipped and the read continues. That is the designed behaviour. Confirm it does
not stall.

### Invalid key

1. Settings, **Remove** the key.
2. Paste a deliberately wrong one, save.
3. Expect a clear "ElevenLabs rejected the API key" in the panel, not a silent
   failure, and no voices loaded.

## 4. Record the results

Fill this in and paste it into the PR before merging.

```
Date:
Model:            eleven_turbo_v2_5
Voice used:

Quota Q0 (before):
Quota Q1 (after 3-4 sentences, stopped):
Delta:                                    (expect: played + <= 3 sentences)
Full article length in characters:        (expect: delta much smaller than this)

Quota Q2 (before backward seek):
Quota after backward seek:                (expect: identical to Q2)

Synthesis latency, first sentence:        ms
Audio bytes, first sentence:
Listened and sounds correct:              yes / no

Pause held quota steady for 30s:          yes / no
Resume continued without a gap:           yes / no
German and French correct:                yes / no
Invalid key reported clearly:             yes / no
Induced network failure recovered:        yes / no / not attempted
```

## 5. Only after all of the above

1. Paste the results into PR #2.
2. Update the application's field 13 answer to remove the "no live call" caveat.
3. Add ElevenLabs to the SpeakIt bullet on the CV and re-render.
4. Merge the PR.
5. Confirm the integration is visible on public `main`.
6. Final application review, then submit.

Do not reorder these. Steps 2 and 3 make public claims that only step 1 can
support.
