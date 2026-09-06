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
