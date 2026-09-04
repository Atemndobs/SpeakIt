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

Four tests, all currently skipping. Expected after the key is set:

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

## 2. Quota accounting, which is the interesting part

The point is to show the three-sentence lookahead is real, not asserted.

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
