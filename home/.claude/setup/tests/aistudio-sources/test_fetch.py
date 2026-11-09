"""Page assignment keeps the query and never guesses by position (Part 1 steps 4-5)."""

from testlib import page

import check_sources as cs


def page_with_url(tmp_path, name, url):
    text = ('---\nurl: "%s"\nfinal_url: "%s"\n---\n# Seite\n\nText.\n' % (url, url))
    return str(page(tmp_path, name, text))


def test_saved_query_page_does_not_fill_a_different_query(tmp_path):
    a = page_with_url(tmp_path, "a.md", "https://youtube.com/watch?v=A")
    srcs = [{"number": 1, "url": "https://youtube.com/watch?v=A"},
            {"number": 2, "url": "https://youtube.com/watch?v=B"}]
    assigned = cs.assign_pages(srcs, [{"page": a}])
    assert assigned == {1: a}


def test_two_unmatched_pages_are_not_assigned_by_position(tmp_path):
    a = page_with_url(tmp_path, "a.md", "https://one.example/x")
    b = page_with_url(tmp_path, "b.md", "https://two.example/y")
    srcs = [{"number": 1, "url": "https://source.example/1"},
            {"number": 2, "url": "https://source.example/2"}]
    assert cs.assign_pages(srcs, [{"page": a}, {"page": b}]) == {}


def test_base_match_only_when_the_base_is_unique(tmp_path):
    lost = page_with_url(tmp_path, "lost.md", "https://example.org/page")
    srcs = [{"number": 1, "url": "https://example.org/page?id=7"}]
    assert cs.assign_pages(srcs, [{"page": lost}]) == {1: lost}

    srcs2 = [{"number": 1, "url": "https://example.org/page?id=7"},
             {"number": 2, "url": "https://example.org/page?id=8"}]
    assert cs.assign_pages(srcs2, [{"page": lost}]) == {}


def test_duplicate_key_keeps_the_query(tmp_path):
    a = page_with_url(tmp_path, "a.md", "https://youtube.com/watch?v=A")
    b = page_with_url(tmp_path, "b.md", "https://youtube.com/watch?v=B")
    assert cs.page_identity(a) != cs.page_identity(b)
