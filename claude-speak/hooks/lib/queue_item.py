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
