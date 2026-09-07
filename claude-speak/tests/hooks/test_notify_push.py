import importlib.util
import json
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "hooks" / "lib" / "notify_push.py"
spec = importlib.util.spec_from_file_location("notify_push", SCRIPT)
notify_push = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notify_push)

ITEM = {
    "v": 1,
    "id": "2026-09-07T10-00-00Z-abc123",
    "source": "claude-code",
    "repo": "Atemndobs/SpeakIt",
    "title": "SpeakIt",
    "text": "a private sentence that must not travel",
    "createdAt": "2026-09-07T10:00:00Z",
}


def test_addresses_the_given_device():
    assert notify_push.build_message(ITEM, "ExponentPushToken[x]")["to"] == "ExponentPushToken[x]"


def test_carries_the_item_id_so_the_app_can_fetch_it():
    assert notify_push.build_message(ITEM, "t")["data"]["itemId"] == ITEM["id"]


def test_carries_the_repo():
    assert notify_push.build_message(ITEM, "t")["data"]["repo"] == "Atemndobs/SpeakIt"


def test_never_carries_the_item_text_anywhere():
    # The payload crosses Apple's infrastructure. This is a test rather than a
    # comment because it is the property a well-meaning later change breaks.
    assert "a private sentence" not in json.dumps(notify_push.build_message(ITEM, "t"))


def test_the_visible_line_names_the_repo_and_nothing_else():
    assert notify_push.build_message(ITEM, "t")["body"] == "New response from Atemndobs/SpeakIt"


def test_missing_fields_do_not_raise():
    msg = notify_push.build_message({"id": "x"}, "t")
    assert msg["data"]["itemId"] == "x"
    assert msg["data"]["repo"] == ""
