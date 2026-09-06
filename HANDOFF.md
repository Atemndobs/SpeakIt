# Handoff, 2026-09-06

Self-contained. You should not need the previous transcript.

**Read next, in this order:**
1. This file.
2. `docs/superpowers/specs/2026-09-06-on-the-go-listening-design.md` (the design)
3. `docs/superpowers/plans/2026-09-06-voice-queue-transport.md` (what to build)

---

## Why the previous session stopped

Not because the work finished. Auto mode's safety classifier began refusing
every state-changing action partway through (Bash, subagent spawns, MCP
writes), and said it would keep firing for the rest of that conversation. Reads
and file writes still worked, so the spec and plan were written. Nothing could
be committed or executed.

Everything marked "uncommitted" below is uncommitted for that reason alone.

---

## What is being built, and why

Three moments, ranked by the user's own pain:

1. Hearing Claude Code output on the phone, live, while working from the phone.
2. Seeing a link and getting it read with one action.
3. Listening to the day's accumulated pile while walking.

These are not three products. They are **three producers feeding one queue and
one consumer playing it**. Pain 3 falls out of solving 1 and 2.

That reframing is the point. There have already been five attempts at this
(readme-tts, Voicy, Audio-reader, and two Chrome extensions). All five were
built as "read this page aloud". None addressed pain 1, which is the worst one.
If you find yourself building a reader, you have drifted.

This plan builds **only the transport**: a Claude Code response leaving a cloud
session and arriving on a device as text, in under ten seconds. No audio, no
player, no share sheet. Those come in later plans, and are not worth planning
until this produces a real latency number.

---

## The constraint that shaped the whole design

A Claude Code cloud session runs behind an **allowlisting egress proxy**. This
was measured against a real cloud session, not assumed:

| Question | Answer | Evidence |
|---|---|---|
| Do repo-level Stop hooks execute there? | **Yes** | `hook_fired=yes host=Linux` |
| Can it reach arbitrary hosts? | No | `http=000 curl_exit=56`, TLS reset, with and without the CA bundle |
| Proxy or wall? | Allowlisting proxy | `api.github.com` 200, `api.anthropic.com` 401 |
| Can it reach Convex? | No | `*.convex.site` and `*.convex.cloud` both `exit=56` |
| Can it reach the Kokoro box? | No | `$KOKORO_HOST` `exit=56` |
| Can a hook `git push`? | **Yes** | `push_exit=0` to the in-scope repo |

**Therefore GitHub is the only channel out of the sandbox.** The hook pushes a
commit to a `voice/queue` branch. The phone polls GitHub. The phone is not
behind the proxy, so it calls Kokoro directly for audio later.

One question was left **deliberately unmeasured**: whether the sandbox can push
to an out-of-scope repo. `add_repo` was denied by the harness classifier, and
probing around that boundary was declined rather than worked around. The design
avoids needing the answer by pushing to the repo the session already has. Do
not go re-probe this; it is not a gap, it is a decision.

---

## Repo layout

| Repo | Holds | Why |
|---|---|---|
| `SpeakIt` (this one) | Plan Tasks 1 to 5, the hook | Already owns the `claude-speak` plugin, the transcript parser and the markdown stripper. Forking those guarantees drift. |
| `speakit-mobile` (new, not yet created) | Tasks 6 to 9, the watcher, later the app | The watcher is the first piece of the phone app, so it is born there rather than migrated later. |

The plan calls the new repo `earshot`; the user renamed it `speakit-mobile`.
The plan explicitly permits renaming before Task 6.

---

## Current state, including work only this file knows about

### SpeakIt worktree (`/Users/atem/sites/SpeakIt/.claude/worktrees/voxcpm-cpu-cost-d23d20`)

- Spec committed as `d816470`. **On a detached HEAD.** If no branch was created
  at it, nothing references that commit and it will be garbage collected. This
  is the only item here that can actually lose work.
- Plan is **on disk only, never committed**.
- The worktree was on `feature/menu-bar-icons` at session start. Something
  detached it mid-session; the cause was never identified.

### mobile_stack (`/Users/atem/sites/mobile_stack`)

Pushed earlier: `d8f8d35` (Convex and Clerk became the default backend),
`680c142` (dropped Expo Go from the diagram), `22e020b` (presets inherit the
default rather than pinning their own).

**Uncommitted right now**, three edits to `package.json`:
1. Description said Supabase, now says Convex and Clerk by default
2. Version `1.0.10` to `2.0.0`
3. `create-jnabs-app` bin alias removed, leaving only `mobile-stack`

The version bump matters: removing a published `bin` entry is breaking, and so
is the default backend flip. It also fixes a drift where the CLI banner already
printed `2.0.0` while `package.json` said `1.0.10`.

**The alias removal is incomplete.** Other references were never found because
Bash was blocked. Expect hits in README, `docs-site/`, and
`diagrams/mobile-stack.architecture.json`.

### hook-probe (`https://github.com/Atemndobs/hook-probe`)

Private throwaway created for the probes above. Branch `probe/push-test-2049`
still on it. **Keep it**: Task 9 uses it as the end-to-end test bed. Delete
after that with `gh repo delete Atemndobs/hook-probe`.

---

## Do this, in order

**1. Rescue the dangling commit, before anything else.**

```bash
cd /Users/atem/sites/SpeakIt/.claude/worktrees/voxcpm-cpu-cost-d23d20
git branch --show-current            # empty output means detached
git branch docs/on-the-go-listening-design d816470
git checkout docs/on-the-go-listening-design
```

**2. Commit the plan and this file.**

```bash
grep -rn $'\u2014' docs/superpowers/ HANDOFF.md    # must return nothing
git add docs/superpowers HANDOFF.md
git commit -m "docs: spec, plan and handoff for the voice queue transport"
```

**3. Finish the mobile_stack alias removal.**

```bash
cd /Users/atem/sites/mobile_stack
grep -rn "create-jnabs-app" . --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=graphify-out
```

Fix every hit. For the diagram, edit the `cli` node's sublabel in the JSON, then
re-render with Archify (`deliver` then `visual-check`) and copy the result to
`docs-site/public/diagrams/mobile-stack-architecture.html`, or the source and
the published HTML will disagree. Then commit.

**4. Execute the plan, starting at Task 1.**

Use `superpowers:subagent-driven-development`, one subagent per task.

---

## Traps

**Start at Task 1, not Task 6.** A previous fresh session went straight for
scaffolding the Expo app and had to be corrected. The ordering is
riskiest-first deliberately: Tasks 1 to 5 are the hook, need no network and no
app, and are where something could still genuinely fail. Scaffolding is the
least risky thing in the plan.

**Task 1 modifies a working macOS hook** so both hooks share one markdown
stripper. Characterization tests go in first so behaviour is provably
identical. If that feels too risky, duplicating the stripper instead is the
worse engineering answer and the safer one. It is the user's call, not yours.

**At Task 6, do not trust the global CLI binary.**

```bash
create-jnabs-app --help | grep -i backend
```

If that does not say `convex (default)`, it predates this work and must not be
used. Fall back to `node ~/sites/mobile_stack/dist/cli.js`. The Convex default
is local and unpublished, and the version number cannot distinguish a linked
copy from an installed one because it was never bumped before today. After
scaffolding, verify `convex/` exists and `supabase/` does not. If it is the
other way round, stop; every assumption downstream is wrong.

**Never use an em-dash, en-dash as punctuation, or a double hyphen standing in
for one.** Anywhere: code, comments, commit messages, docs. This is a hard user
rule. Verify with `grep -rn $'\u2014' . --exclude-dir=.git` before committing prose.

**Branch naming is `<what-is-being-built>/<specific-detail>`**, lowercase
kebab-case, never prefixed with a tool name.

**This is a git worktree.** The stash stack is shared with the main checkout and
other worktrees. Never use bare `git stash` or `git stash pop`.

---

## Known gaps, stated rather than hidden

The plan reads the GitHub token from `GITHUB_TOKEN`. The spec says it belongs in
the iOS keychain. The env var is correct for a CLI with no device app and wrong
for the phone; that requirement transfers to the app plan.

The design leans on an undocumented internal proxy allowlist inside someone
else's sandbox. GitHub being reachable is a measured fact today, not a promised
interface. This is acceptable **only** because the tool is for one person, and
the user confirmed that explicitly. If it ever becomes a product, the transport
has to be revisited before anything else.

`$KOKORO_HOST` runs without AVX2 at RTF 2.5. The k8s3 box is the
fast one, and is what Voicy uses today.
