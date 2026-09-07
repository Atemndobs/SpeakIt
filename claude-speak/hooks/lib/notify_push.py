#!/usr/bin/env python3
"""Send one Expo push notification for a queue item.

Runs in GitHub Actions, in whichever repo the hook published to. Stdlib only:
Actions runners have no third party packages by default, and installing some
would triple the job time for one HTTP request.

The payload deliberately carries no item text. It crosses Apple's
infrastructure, and this queue carries Claude Code session output. The app
fetches the item from GitHub itself once the notification is tapped.
"""
import json
import sys
import urllib.request

EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send"


def build_message(item: dict, token: str) -> dict:
    """One Expo push message.

    The visible line names the repo and nothing else. A first line of the
    response would be more useful and would also put session output on a lock
    screen, which is a decision recorded as deferred in the spec. Changing it
    means changing this function and nothing else.
    """
    repo = item.get("repo") or ""
    return {
        "to": token,
        "title": item.get("title") or "SpeakIt",
        "body": f"New response from {repo}" if repo else "New response",
        "sound": "default",
        "data": {"itemId": item.get("id") or "", "repo": repo},
    }


def send(message: dict) -> int:
    req = urllib.request.Request(
        EXPO_PUSH_URL,
        data=json.dumps(message).encode("utf-8"),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as res:
        body = json.loads(res.read().decode("utf-8"))

    if body.get("data", {}).get("status") == "ok":
        print("push accepted")
        return 0

    # DeviceNotRegistered means the app was removed or the token rotated.
    # There is nothing to retry, and failing the job would put a red X on every
    # session until someone noticed, which trains people to ignore Actions.
    print(f"push not delivered: {json.dumps(body)}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: notify_push.py <item.json> <expo-push-token>")
        sys.exit(1)
    with open(sys.argv[1], encoding="utf-8") as fh:
        sys.exit(send(build_message(json.load(fh), sys.argv[2])))
