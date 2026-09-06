import datetime as dt
import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "hooks" / "lib" / "queue_item.py"
spec = importlib.util.spec_from_file_location("queue_item", SCRIPT)
queue_item = importlib.util.module_from_spec(spec)
spec.loader.exec_module(queue_item)

FIXED = dt.datetime(2026, 9, 6, 12, 4, 31, tzinfo=dt.timezone.utc)


def test_carries_schema_version_one():
    item = queue_item.build_item("hi", "Atemndobs/SpeakIt", "SpeakIt", now=FIXED)
    assert item["v"] == 1


def test_id_starts_with_a_sortable_timestamp():
    item = queue_item.build_item("hi", "Atemndobs/SpeakIt", "SpeakIt", now=FIXED)
    assert item["id"].startswith("2026-09-06T12-04-31Z-")


def test_id_is_unique_for_identical_input():
    a = queue_item.build_item("hi", "r", "t", now=FIXED)
    b = queue_item.build_item("hi", "r", "t", now=FIXED)
    assert a["id"] != b["id"]


def test_created_at_is_iso_utc():
    item = queue_item.build_item("hi", "r", "t", now=FIXED)
    assert item["createdAt"] == "2026-09-06T12:04:31Z"


def test_source_identifies_claude_code():
    item = queue_item.build_item("hi", "r", "t", now=FIXED)
    assert item["source"] == "claude-code"


def test_text_is_carried_verbatim():
    item = queue_item.build_item("line one\nline two", "r", "t", now=FIXED)
    assert item["text"] == "line one\nline two"
