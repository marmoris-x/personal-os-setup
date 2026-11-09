"""All Reddit comments from the Arctic Shift tree (Part 1 step 6)."""

import json

import check_sources as cs


TREE = {
    "data": [
        {"kind": "t1", "data": {"id": "c1", "body": "Top level", "score": 5,
                                "replies": {"data": [
                                    {"kind": "t1", "data": {"id": "c2", "body": "Child",
                                                            "score": 2, "replies": ""}}]}}},
        {"kind": "more", "data": {"id": "m1", "children": ["c9"]}},
    ]
}


def test_tree_url_uses_t3_and_9999():
    tree, search = cs.archive_urls("abc123")
    assert "comments/tree" in tree
    assert "link_id=t3_abc123" in tree
    assert "limit=9999" in tree
    assert "comments/search" in search
    assert "limit=auto" in search


def test_flatten_tree_keeps_nested_comments():
    rows = cs.flatten_comments(TREE)
    assert [r["body"] for r in rows] == ["Top level", "Child"]


def test_get_comments_reads_the_tree_from_cache(tmp_path, monkeypatch):
    cache = tmp_path / "reddit-comments"
    cache.mkdir()
    (cache / "abc123.json").write_text(json.dumps(TREE), encoding="utf-8")

    def fail(*args, **kwargs):
        raise AssertionError("network must not be used for a cached post")

    monkeypatch.setattr(cs.urllib.request, "urlopen", fail)
    rows = cs.get_comments("abc123", tmp_path)
    assert [r["body"] for r in rows] == ["Top level", "Child"]
