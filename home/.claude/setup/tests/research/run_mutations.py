"""Make each check fail on purpose: break one thing in a copy of the scripts, expect red tests.

Usage: python -I -X utf8 run_mutations.py
Exit 0 when every mutation is caught by at least one test, 1 when a mutation survives.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = Path.home() / ".claude" / "skills" / "research" / "scripts"

MUTATIONS = [
    ("verify_evidence.py", "if found is None:", "if False:"),
    ("verify_evidence.py", "if len(tokens(text)) < MIN_WORDS:", "if False:"),
    ("common.py", 'if find_tokens(tokens(evidence["text"]), original) < 0:', "if False:"),
    ("common.py", "if not same_stem(used, original):", "if False:"),
    ("common.py", "if para_tokens is not None and find_tokens(para_tokens, words) < 0:", "if False:"),
    ("build_references.py", 'return None, "start words not found in the saved page"', "pass"),
    ("build_references.py", 'url = url.replace("(", "%28").replace(")", "%29")', "pass"),
    ("check_article.py", "if ch in BANNED:", "if False:"),
    ("check_article.py", "elif ARROWS[0] <= code <= ARROWS[1]:", "elif False:"),
    ("check_article.py", "if SPACED_HYPHEN.search(text):", "if False:"),
    ("check_article.py", "if normalize(quote) not in allowed:", "if False:"),
    ("check_article.py", "for n in sorted(set(cited) - set(entries)):", "for n in []:"),
    ("check_article.py", "for n in sorted(set(entries) - set(cited)):", "for n in []:"),
    ("check_article.py", "if order != sorted(order) or (order and order != list(range(1, len(order) + 1))):", "if False:"),
    ("check_article.py", "if RUN_RE.search(body):", "if False:"),
    ("check_article.py", "errors.append(f\"text fragment words not in the saved page", "pass  # errors.append(f\"text fragment words not in the saved page"),
    ("ai_patterns.py", "for name, rx in REGEXES:", "for name, rx in []:"),
    ("save_pages.py", 'elif len(normalize(value["text"])) < MIN_CHARS:', "elif False:"),
    ("save_pages.py", "and not (name not in PROVIDERS and is_reddit(u))]", "]"),
    ("save_pages.py", "if dedupe and digest in hashes:", "if False:"),
    ("save_pages.py", "if code is not None and not (200 <= int(code) < 300 or int(code) == 304):", "if False:"),
    ("save_pages.py", "if not public_for_third_party(url):", "if False:"),
    ("common.py", "if not ip.is_global:", "if False:"),
    ("common.py", "or parts.username:", ":"),
    ("save_pages.py", "if name in KEYS and not _key(name):", "if False:"),
    ("save_pages.py", "if resp.status_code in (401, 402):", "if False:"),
    ("save_pages.py", "elif looks_like_error_page(value[\"text\"]):", "elif False:"),
    ("save_pages.py", "min(30, float(resp.headers.get(\"Retry-After\", 5)))", "float(resp.headers.get(\"Retry-After\", 5))"),
    ("save_pages.py", "                ask_wayback = False\n", "                pass\n"),
    ("save_pages.py", "    elif crawl4ai_asked:\n", "    elif False:\n"),
    ("save_pages.py", "    if ok is False:\n        print(f\"WARNING crawl4ai unavailable", "    if False:\n        print(f\"WARNING crawl4ai unavailable"),
    ("save_pages.py", "crawl4ai_asked = venv_missing = True", "venv_missing = True"),
    ("save_pages.py", "crawl4ai_ok, crawl4ai_reason = previous_ok, previous_reason", "crawl4ai_ok, crawl4ai_reason = None, None"),
    ("save_pages.py", 'or any(used.get(u) == "crawl4ai" for u in results):', "or False:"),
    ("check_services.py", "        elif ok is False:\n            lines.append", "        elif False:\n            lines.append"),
    ("check_services.py", "return 1 if c4_bad else 0", "return 0"),
    ("common.py", "    if isinstance(data, list):\n        return data, None, None", "    if isinstance(data, list):\n        return [], None, None"),
    ("store_results.py", "if note.exists() or src.exists():", "if False:"),
    ("store_results.py", 'IMAGE_RE.sub("", raw)', "raw"),
    ("store_results.py", "if not SLUG_RE.match(slug):", "if False:"),
    ("store_results.py", "if not LANG_RE.match(lang):", "if False:"),
    ("store_results.py", "if not (work / \"pages\" / name).is_file():", "if False:"),
    ("common.py", 'path = parts.path.rstrip("/") if parts.path not in ("", "/") else parts.path', "path = parts.path"),
    ("save_pages.py", "if wayback_failures >= 3:", "if False:"),
    ("build_references.py", "if url is None:", "if False:"),
    ("build_references.py", "if number not in links:", "if False:"),
    ("build_references.py", "if sorted(numbers) != numbers:", "if False:"),
    ("build_references.py", 'return ISO_DATETIME.sub(r"\\1", text)', "return text"),
    ("build_references.py", "if text.casefold() in (domain.casefold(), bare):", "if False:"),
    ("build_references.py", "if text.casefold().endswith(slogan):", "if False:"),
    ("build_references.py", "segments = [s for s in segments if s.casefold() not in (domain.casefold(), bare)]",
     "segments = list(segments)"),
    ("build_references.py", 'item.get("type") or item.get("source_type") or ""', 'item.get("type") or ""'),
    ("build_references.py", 'url = clean_url(str(item.get("url") or ""))', 'url = str(item.get("url") or "")'),
    ("build_references.py", 'file_types.get(name) or url_types.get(header.get("url", "")) or', 'None or None or'),
    ("build_references.py", "if source_type not in labels:\n            source_type = (file_types.get(name)", "if False:\n            source_type = (file_types.get(name)"),
    ("build_references.py", 'warnings.append(f"page {name}: no source type in the page header, its evidence or the candidates")', "pass"),
    ("check_article.py", "if bare:", "if False:"),
    ("check_article.py", "if any(b <= a for a, b in zip(numbers, numbers[1:])):", "if False:"),
    ("check_article.py", "if ISO_TIMESTAMP.search(text_only):", "if False:"),
    ("check_article.py", "if not TYPE_LABEL.search(text_only):", "if False:"),
    ("check_article.py", "if JUNK_TITLE.search(text_only) or JUNK_AUTHOR.search(text_only):", "if False:"),
    ("check_article.py", "if TRACKING_URL.search(rest):", "if False:"),
    ("check_article.py", "if domain and sum(1 for s in segments if s.casefold() in domain_forms) > 1:", "if False:"),
    ("check_article.py", "if marker and any(w.casefold() in marker.group(1).casefold() for w in words_of_mark):",
     "if False:"),
    ("check_article.py", "if words < 6 or NO_SOURCE_SENTENCE.search(sentence):", "if False:"),
    ("check_article.py", "if words >= 45:", "if False:"),
    ("check_article.py", "if len(years) < 2 or min(years) > date.today().year - 2:", "if False:"),
    ("check_article.py", "if primary[\"id\"] in cited:", "if False:"),
    ("check_article.py", "if len(lines) < 2:", "if False:"),
    ("check_article.py", "if not 3 <= len(lines) <= 6:", "if False:"),
    ("check_article.py", "if len(words) > 15:", "if False:"),
    ("check_article.py", "if len(words) >= 3 and words in body_sentences:", "if False:"),
    ("check_article.py", "if counts[minor] >= 2 or not near_callout(folded, major, minor):", "if False:"),
    ("check_article.py", 'for match in re.finditer(r"(?<=[.!?])\\s+|\\n+", masked):',
     'for match in re.finditer(r"(?<=[.!?])\\s+", masked):'),
    ("check_article.py", "masked = re.sub(r'\"[^\"\\n]*\"', lambda m: re.sub(r\"[.!?]\", \"\\u0001\", m.group(0)), text)",
     "masked = text"),
    ("check_article.py", "if share > max_own and bullets < 2:", "if share > max_own:"),
    ("check_article.py", "if len(distinctive) < 4:", "if len(distinctive) < 3:"),
    ("check_article.py", "if hits / len(distinctive) < 0.7:", "if hits / len(distinctive) < 0.6:"),
    ("check_article.py", "hits = sum(1 for w in distinctive if w.casefold() in hay_set)",
     "hits = len(distinctive)"),
    ("check_article.py", "for sentence in split_sentences(clean):\n            if NO_SOURCE_SENTENCE.search(sentence):",
     "for sentence in split_sentences(clean):\n            if False:"),
    ("check_article.py", 'marker = re.match(r"\\s*\\(([^()]*)\\)", text[match.end():])',
     'marker = re.match(r"\\s*\\(([^()]*)\\)", text[match.end(): match.end() + 200])'),
    ("check_article.py", "for inner in translation_spans(block, lang):\n            covered += len(tokens(inner))",
     "for inner in []:\n            covered += len(tokens(inner))"),
    ("check_article.py", 'for inner in translation_spans(without_quotes, lang):\n            without_quotes = without_quotes.replace(f"({inner})", " ")',
     "pass"),
    ("check_article.py", 'if any(w.casefold() in m.group(1).casefold() for w in words):', "if False:"),
    ("check_article.py", 'looks_named = word[:1].isupper() or any(script_name(ch) == "nonlatin" for ch in word)',
     "looks_named = True"),
    ("check_article.py", "if not (named[a] or named[b]):", "if False:"),
    ("check_article.py", "for start in range(len(words) - 3):", "for start in []:"),
    ("common.py", '_SPACE_BEFORE_PUNCT.sub(r"\\1", _WS.sub(" ", text))', '_WS.sub(" ", text)'),
    ("common.py", "while match and out:", "while match and False:"),
    ("store_results.py", "if bare:", "if False:"),
    ('check_note.py', '    return chr(0xE000 + int(number))', '    return chr(0xE000 + int(number)) + str(number)'),
    ('check_note.py', 'VALUE_RE = re.compile(r"\\d(?:[\\d.,]*\\d)?(?:\\s*[-–]\\s*\\d(?:[\\d.,]*\\d)?)?")', 'VALUE_RE = re.compile(r"\\d[\\d.,]*")'),
    ('check_note.py', 'if all(YEAR.fullmatch(p) for p in re.findall(r"\\d+", value)):', 'if False:'),
    ('check_note.py', 'for part in (sentence[:match.start()], sentence[match.end():].split(";")[0]):', 'for part in (sentence[:match.start()], sentence[match.end():]):'),
    ('check_note.py', 'if len(set(numbers)) < 2:', 'if False:'),
    ('check_note.py', 'if len(sources) > 1:', 'if False:'),
    ('check_note.py', 'if not kinds or "primary" in kinds or kinds == {""}:', 'if True:'),
    ('check_note.py', "            if closed:\n                continue  # the quote carries the source sentence's own end", "            if False:\n                continue  # the quote carries the source sentence's own end"),
    ('check_note.py', 'elif last in hard:', 'elif False:'),
    ('check_note.py', 'elif last in soft:', 'elif False:'),
    ('check_note.py', 'if needle not in hay and needle_up in hay:', 'if False:'),
    ('check_note.py', 'if phrase in folded:', 'if False:'),
    ('check_note.py', 'if year not in years and year <= today.year:', 'if False:'),
    ('check_note.py', 'if not VALUE_RE.search(plain) or YEAR.search(plain):', 'if True:'),
    ('check_note.py', 'if len(kinds) > 1 and domain not in MIXED_TYPE_SITES:', 'if False:'),
    ('check_note.py', 'text = ACCESS_RE.sub(" ", URL_RE.sub(" ", rest))', 'text = URL_RE.sub(" ", rest)'),
    ('check_article.py', '                bodies.append(body)\n                break', '                return body'),
    ('check_note.py', '(?:abweichen|sich widersprechen)|', '(?:abweichen)|'),
    # the five new checks of the 10.3 correction order, part 2 (items 3, 4, 7, 9, 10)
    # and their calibration guards
    ('check_note.py', 'if NOT_YET_RE.search(sentence) and ABILITY_RE.search(sentence):', 'if False:'),
    ('check_note.py', 'if any(w in sentence for w in words) and absence_near(sentence, words):', 'if False:'),
    ('check_note.py', 'if word != "." and english_run_token(word):', 'if False:'),
    ('check_note.py', 'if not match or YEAR.search(plain):', 'if True:'),
    ('check_note.py', 'if here and there and here.isdisjoint(there):', 'if False:'),
    ('check_note.py', 'if abs(m.start() - (at + len(word))) <= 80:', 'if abs(m.start() - (at + len(word))) <= 100000:'),
    ('check_note.py', 'if strong or (weak and any(w.endswith(EN_SUFFIX) for w in folded)):', 'if strong or weak:'),
    ('check_note.py', '    if not word.isascii():\n        return False', '    if False:\n        return False'),
    ('check_note.py', r"[^\W\d_](?:[^\W\d_]|['_-])*", r"[A-Za-z](?:[A-Za-z'_-])*"),
]


def main():
    survivors = []
    for number, (name, old, new) in enumerate(MUTATIONS, 1):
        with tempfile.TemporaryDirectory(prefix="research-mutation-") as tmp:
            copy = Path(tmp) / "scripts"
            shutil.copytree(SCRIPTS, copy, ignore=shutil.ignore_patterns("__pycache__"))
            target = copy / name
            source = target.read_text(encoding="utf-8")
            if old not in source:
                print(f"{number:2} BROKEN MUTATION (text not found in {name}): {old[:60]}")
                survivors.append(number)
                continue
            target.write_text(source.replace(old, new, 1), encoding="utf-8", newline="\n")
            env = {**os.environ, "RESEARCH_SCRIPTS": str(copy)}
            proc = subprocess.run([sys.executable, "-I", "-X", "utf8", "-m", "unittest", "discover",
                                   "-s", str(HERE), "-p", "test_*.py"],
                                  capture_output=True, text=True, encoding="utf-8", env=env, timeout=600)
            caught = proc.returncode != 0
            print(f"{number:2} {'caught  ' if caught else 'SURVIVED'} {name}: {old[:60]}")
            if not caught:
                survivors.append(number)
    print(f"{len(MUTATIONS) - len(survivors)} of {len(MUTATIONS)} mutations caught")
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
