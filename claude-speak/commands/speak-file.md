---
description: Speak the contents of a file via SpeakIt
argument-hint: <path>
allowed-tools: Bash
---

Run this command exactly with the user-provided path, then reply with one short line confirming what file was sent:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/speakit-cli.sh" file "$ARGUMENTS"
```
