import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "hooks" / "lib" / "strip_markdown.py"


def strip(text):
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        input=text, capture_output=True, text=True, check=True,
    )
    return result.stdout


def test_removes_fenced_code_blocks():
    assert strip("before\n```\ncode here\n```\nafter") == "before\n\nafter"


def test_unwraps_inline_code():
    assert strip("run `npm test` now") == "run npm test now"


def test_links_become_their_text():
    assert strip("see [the docs](https://example.com)") == "see the docs"


def test_images_are_dropped():
    assert strip("![alt text](img.png)done") == "done"


def test_headers_lose_their_hashes():
    assert strip("## Section title") == "Section title"


def test_bullets_lose_their_markers():
    assert strip("- first\n- second") == "first\nsecond"


def test_numbered_lists_lose_their_numbers():
    assert strip("1. first\n2. second") == "first\nsecond"


def test_bold_and_italic_are_unwrapped():
    assert strip("**bold** and *italic* and _also_") == "bold and italic and also"


def test_tables_flatten_to_comma_separated_rows():
    table = "| a | b |\n| --- | --- |\n| 1 | 2 |"
    assert strip(table) == "a, b\n\n1, 2"


def test_blockquotes_lose_their_marker():
    assert strip("> quoted line") == "quoted line"


def test_html_tags_are_removed():
    assert strip("a <br/> b") == "a  b"


def test_runs_of_blank_lines_collapse():
    assert strip("a\n\n\n\n\nb") == "a\n\nb"


def test_empty_input_gives_empty_output():
    assert strip("") == ""
