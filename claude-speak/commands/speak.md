---
description: Speak text aloud via SpeakIt
argument-hint: <text to speak>
allowed-tools: Bash
---

Run this command exactly, then reply with one short line confirming what was spoken:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/speakit-cli.sh" speak "$ARGUMENTS"
```
