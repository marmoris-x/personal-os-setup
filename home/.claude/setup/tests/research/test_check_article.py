"""Tests for check_article.py. Each check is made to fail on purpose on a broken copy."""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from testlib import E1, E2, E3, E4, Work, run_script  # noqa: E402

E5 = {**E1, "id": "E5", "text": "Sie nannte es „einzigartig“ und das war ihr Wort",
      "lines": [15, 15]}

GOOD = """# Wien

Wien ist die Hauptstadt von Österreich. [[E1]]
<!-- compose {"ids": ["E1"], "frags": [["E1", "Wien ist die Hauptstadt von Österreich"]]} -->

Der Bürgermeister sagte: "Wir bauen – trotz aller Hürden – weiter an der Stadt". [[E3]]
<!-- compose {"ids": ["E3"], "frags": []} -->

Sie nannte es „einzigartig“ und das war ihr Wort, so steht es dort. [[E5]]
<!-- compose {"ids": ["E5"], "frags": [["E5", "Sie nannte es „einzigartig“ und das war ihr Wort"]]} -->

<!-- references -->
"""


class CheckArticle(unittest.TestCase):
    def setUp(self):
        self.work = Work()
        self.addCleanup(self.work.cleanup)
        self.work.verified([E1, E2, E3, E4, E5])

    def build(self, draft=GOOD, lang="de"):
        self.work.write("draft/draft.md", draft)
        code, out = run_script("build_references.py", self.work.path, "--draft", "draft/draft.md",
                               "--out", "draft/article.md", "--lang", lang, "--accessed", "2026-10-06")
        self.assertEqual(code, 0, out)
        return (self.work.path / "draft" / "article.md").read_text(encoding="utf-8")

    def check(self, article, lang="de", *extra):
        path = self.work.write("draft/check.md", article)
        return run_script("check_article.py", path, "--workdir", self.work.path, "--lang", lang, *extra)

    def test_good_article_passes_and_prints_the_own_word_share(self):
        code, out = self.check(self.build())
        self.assertEqual(code, 0, out)
        self.assertIn("SUMMARY errors=0", out)
        self.assertIn("INFO paragraph 2: own words", out)

    def test_comments_separated_by_blank_lines_belong_to_their_paragraph(self):
        # the writer may put any number of blank lines between a paragraph and its
        # compose comment; the comment still belongs to the paragraph above it
        draft = GOOD.replace("\n<!-- compose", "\n\n<!-- compose")
        draft = draft.replace("[[E3]]\n\n<!-- compose", "[[E3]]\n\n\n\n  \n<!-- compose")
        article = self.build(draft)
        code, out = self.check(article)
        self.assertEqual(code, 0, out)

    def test_source_characters_inside_quotes_and_fragments_are_not_checked(self):
        article = self.build()
        self.assertIn("–", article)       # en dash inside the quote
        self.assertIn("„", article)       # typographic quote inside the fragment
        code, out = self.check(article)
        self.assertEqual(code, 0, out)

    def test_excluded_characters_in_own_words_fail(self):
        article = self.build()
        cases = {
            "em dash": "Der Bürgermeister — sagte:",
            "en dash": "Der Bürgermeister – sagte:",
            "ellipsis character": "Der Bürgermeister sagte…:",
            "typographic quote": "Der „Bürgermeister“ sagte:",
            "bullet": "Der • Bürgermeister sagte:",
            "no-break space": "Der Bürgermeister sagte:",
            "arrow": "Der → Bürgermeister sagte:",
            "emoji": "Der Bürgermeister \U0001F600 sagte:",
            "spaced hyphen": "Der Bürgermeister - sagte:",
            "transliteration letter": "Der Bürgermeister ḥ sagte:",
        }
        for name, replacement in cases.items():
            with self.subTest(name):
                code, out = self.check(article.replace("Der Bürgermeister sagte:", replacement))
                self.assertEqual(code, 1, out)
                self.assertIn("ERROR paragraph 3", out)

    def test_umlauts_are_fine_in_german_but_only_a_warning_in_english(self):
        article = self.build()
        code, out = self.check(article)
        self.assertEqual(code, 0, out)
        code, out = self.check(article, "en")
        self.assertEqual(code, 1)
        # the German quote in an English text now needs a translation; the umlaut stays a warning
        self.assertIn("foreign-language quote of 9 words without a translation marker", out)
        self.assertIn("WARNING paragraph 3: letter", out)

    def test_arabic_is_allowed_where_the_text_is_arabic_and_transliteration_is_not(self):
        draft = ('# مرجع\n\nالْعِلْمُ نُورٌ. [[E4]]\n<!-- compose {"ids": ["E4"], "frags": '
                 '[["E4", "الْعِلْمُ نُورٌ"]]} -->\n\n<!-- references -->\n')
        article = self.build(draft, "ar")
        code, out = self.check(article, "ar")
        self.assertEqual(code, 0, out)
        code, out = self.check(article.replace("نُورٌ.", "نُورٌ nūr."), "ar")
        self.assertEqual(code, 1, out)

    def test_number_without_list_entry_and_entry_without_number_fail(self):
        article = self.build()
        entry = article.split("[3] ")[0]  # the list holds [1] and [2] at most
        self.assertNotIn("[3] ", entry)
        code, out = self.check(article.replace("so steht es dort. [", "so steht es dort. [9](https://example.org/x) ["))
        self.assertEqual(code, 1)
        self.assertIn("number [9] is cited but has no list entry", out)
        extra = article.replace("<!-- references:end -->", "\n[7] Noch eine Quelle. https://example.org/z\n<!-- references:end -->")
        code, out = self.check(extra)
        self.assertEqual(code, 1)
        self.assertIn("list entry [7] is never cited", out)

    def test_numbers_out_of_order_fail(self):
        draft = ('# T\n\nErster. [[E1]]\n<!-- compose {"ids": ["E1"], "frags": []} -->\n\n'
                 'Zweiter. [[E4]]\n<!-- compose {"ids": ["E4"], "frags": []} -->\n\n<!-- references -->\n')
        article = self.build(draft)
        swapped = article.replace("[1](https://example.org", "[X](https://example.org").replace(
            "[2](https://arabic", "[1](https://arabic").replace("[X](https://example.org", "[2](https://example.org")
        code, out = self.check(swapped)
        self.assertEqual(code, 1)
        self.assertIn("not in order of first appearance", out)

    def test_list_entry_without_url_and_link_not_matching_entry_fail(self):
        article = self.build()
        stripped = "\n".join(line.replace("https://example.org/wien", "") if line.startswith("[1] ") else line
                             for line in article.split("\n"))
        code, out = self.check(stripped)
        self.assertEqual(code, 1)
        self.assertIn("list entry [1] has no URL", out)
        other = article.replace("[1] Stadt Wien. Wien: Fakten. example.org. 2025-03-01. Quellenart: Primärquelle. "
                                "Abgerufen 2026-10-06. https://example.org/wien",
                                "[1] Stadt Wien. Wien. example.org. 2025-03-01. https://example.org/anders")
        code, out = self.check(other)
        self.assertEqual(code, 1)
        self.assertIn("does not match the URL", out)

    def test_missing_reference_list_fails(self):
        article = self.build().split("<!-- references:start -->")[0]
        code, out = self.check(article)
        self.assertEqual(code, 1)
        self.assertIn("no reference list", out)

    def test_more_than_three_numbers_in_a_row_warns(self):
        article = self.build().replace("so steht es dort. [", "so steht es dort. " + "[1](https://example.org/wien) " * 4 + "[")
        code, out = self.check(article)
        self.assertIn("WARNING more than three reference numbers in a row", out)

    def test_statement_without_number_warns(self):
        article = self.build().replace("Wien ist die Hauptstadt von Österreich. [1](", "Wien ist die Hauptstadt von Österreich. (")
        code, out = self.check(article)
        self.assertIn("statements without a reference number", out)

    def test_quote_that_is_not_word_for_word_fails(self):
        article = self.build().replace("trotz aller Hürden", "trotz aller Schwierigkeiten")
        code, out = self.check(article)
        self.assertEqual(code, 1)
        self.assertIn("quote not word for word in its evidence", out)

    def test_quote_without_compose_comment_fails(self):
        article = self.build() + '\nEin Satz mit "einem Zitat ohne Beleg" im Text.\n'
        article = article.replace("\n<!-- references:start -->", "\nEin Satz mit \"einem Zitat ohne Beleg\" im Text.\n\n<!-- references:start -->", 1)
        code, out = self.check(article)
        self.assertEqual(code, 1)
        self.assertIn("quote without a compose comment", out)

    def test_fragment_missing_in_paragraph_or_evidence_fails(self):
        article = self.build()
        gone = article.replace("Wien ist die Hauptstadt von Österreich. [1]", "Ein anderer Satz. [1]")
        code, out = self.check(gone)
        self.assertEqual(code, 1)
        self.assertIn("is not in the paragraph", out)
        invented = article.replace('"frags": [["E1", "Wien ist die Hauptstadt von Österreich"]]',
                                   '"frags": [["E1", "Wien ist die größte Stadt"]]')
        code, out = self.check(invented)
        self.assertEqual(code, 1)

    def test_text_fragment_must_come_from_the_saved_page(self):
        article = self.build()
        self.assertIn("#:~:text=", article)
        code, out = self.check(article.replace("text=Wien%20ist", "text=Berlin%20ist"))
        self.assertEqual(code, 1)
        self.assertIn("text fragment words not in the saved page", out)

    def test_ai_patterns_in_own_words_warn_but_not_inside_quotes(self):
        own = ('# T\n\nDas ist nicht nur eine Stadt, sondern auch ein Symbol. [[E1]]\n'
               '<!-- compose {"ids": ["E1"], "frags": []} -->\n\n<!-- references -->\n')
        code, out = self.check(self.build(own))
        self.assertEqual(code, 0, out)
        self.assertIn("style pattern 'not X but Y'", out)
        self.assertNotIn("style_hits=0", out)
        quoted = ('# T\n\nDer Text sagt: "Wir bauen – trotz aller Hürden – weiter an der Stadt". [[E3]]\n'
                  '<!-- compose {"ids": ["E3"], "frags": []} -->\n\n<!-- references -->\n')
        code, out = self.check(self.build(quoted))
        self.assertIn("style_hits=0", out)

    def test_word_and_phrase_lists_and_connector_budget(self):
        text = ('# T\n\nEs ist wichtig zu beachten: Wien ist ein faszinierendes Zusammenspiel. '
                'Darüber hinaus gibt es außerdem mehr. [[E1]]\n<!-- compose {"ids": ["E1"], "frags": []} -->\n\n'
                '<!-- references -->\n')
        code, out = self.check(self.build(text))
        for hit in ("zusammenspiel", "faszinierend", "2 mechanical connectors"):
            self.assertIn(hit, out)

    def test_fail_on_warnings_turns_warnings_into_exit_1(self):
        article = self.build()  # holds a warning (no key-point block), no error
        code, out = self.check(article)
        self.assertEqual(code, 0, out)
        code, _ = self.check(article, "de", "--fail-on-warnings")
        self.assertEqual(code, 1)

    def test_high_share_of_own_words_warns(self):
        own = ('# T\n\nDas ist ein sehr langer eigener Satz ohne jeden Beleg aus der Quelle selbst gebaut. [[E1]]\n'
               '<!-- compose {"ids": ["E1"], "frags": []} -->\n\n<!-- references -->\n')
        code, out = self.check(self.build(own))
        self.assertIn("own words 100%", out)
        self.assertIn("is above 40%", out)

    def test_unreadable_compose_comment_fails(self):
        article = self.build().replace('"ids": ["E3"], "frags": []}', '"ids": ["E3"], "frags": [')
        code, out = self.check(article)
        self.assertEqual(code, 1)
        self.assertIn("compose comment", out)

    def test_bare_number_after_a_link_fails(self):
        article = re.sub(r"(\[1\]\([^)]*\))", r"\1 [1]", self.build(), count=1)
        code, out = self.check(article)
        self.assertEqual(code, 1)
        self.assertIn("bare reference numbers without a link", out)

    def test_numbers_not_ascending_in_one_group_fail(self):
        article = self.build("# T\n\nStart. [[E1]]\n\nDann [[E4]] [[E1]] hier.\n")
        grouped = re.sub(r"(\[1\]\([^)]*\))(\[2\]\([^)]*\))", r"\2\1", article, count=1)
        code, out = self.check(grouped)
        self.assertEqual(code, 1)
        self.assertIn("not ascending in one group", out)

    def test_foreign_quote_above_five_words_needs_a_translation(self):
        quote = "الْعِلْمُ نُورٌ يَقْذِفُهُ اللَّهُ فِي قَلْبِ مَنْ يَشَاءُ"
        draft = (f'# T\n\nDer Text sagt: "{quote}". [[E4]]\n'
                 '<!-- compose {"ids": ["E4"], "frags": []} -->\n\n<!-- references -->\n')
        article = self.build(draft)
        code, out = self.check(article)
        self.assertEqual(code, 1)
        self.assertIn("without a translation marker", out)
        fixed = article.replace(f'"{quote}".', f'"{quote}" (Übersetzung: Das Wissen ist ein Licht).')
        code, out = self.check(fixed)
        self.assertEqual(code, 0, out)

    def test_a_long_translation_is_not_own_words_or_sentence_length(self):
        quote = "الْعِلْمُ نُورٌ يَقْذِفُهُ اللَّهُ فِي قَلْبِ مَنْ يَشَاءُ"
        trans = ("Das Wissen ist ein Licht, das Gott in das Herz von wem er will hineinwirft, "
                 "so steht es geschrieben, und diese Uebersetzung ist absichtlich sehr lang "
                 "geraten, damit sie die fruehere Grenze von zweihundert Zeichen klar "
                 "ueberschreitet und die Pruefung sie trotzdem finden muss")
        draft = (f'# T\n\nDer Text sagt: "{quote}" (Übersetzung: {trans}). [[E4]]\n'
                 '<!-- compose {"ids": ["E4"], "frags": []} -->\n\n<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertEqual(code, 0, out)
        self.assertNotIn("sentence has", out)
        self.assertNotIn("is above", out)

    def test_interpretation_without_a_number_fails_unless_sources_are_silent(self):
        sentence = "Das Bild ist damit das einer Schutzwehr vor jedem Schaden."
        article = self.build().replace("\n<!-- references:start -->",
                                       f"\n{sentence}\n\n<!-- references:start -->", 1)
        code, out = self.check(article)
        self.assertEqual(code, 1)
        self.assertIn("statement without a reference number", out)
        quiet = article.replace(sentence, "Die Quellen nennen zu dieser Frage nichts.")
        code, out = self.check(quiet)
        self.assertEqual(code, 0, out)

    def test_comparing_sources_from_different_years_needs_a_year(self):
        page = self.work.path / "pages" / "001-example.org.md"
        page.write_text(page.read_text(encoding="utf-8").replace('published: "2025-03-01"',
                                                                 'published: "2017-04-20"'), encoding="utf-8")
        page2 = self.work.path / "pages" / "002-arabic.example.net.md"
        page2.write_text(page2.read_text(encoding="utf-8").replace('lang: "ar"',
                                                                   'published: "2026-01-02"\nlang: "ar"'),
                         encoding="utf-8")
        draft = ('# T\n\nAlte und neue Quelle im Vergleich. [[E1]] [[E4]] Hier steht keine Jahreszahl.\n'
                 '<!-- compose {"ids": ["E1","E4"], "frags": []} -->\n\n<!-- references -->\n')
        article = self.build(draft)
        code, out = self.check(article)
        self.assertIn("compares sources from 2017 to 2026 without naming a year", out)
        with_year = article.replace("Hier steht keine Jahreszahl.", "2017 galt anderes als 2026.")
        code, out = self.check(with_year)
        self.assertNotIn("without naming a year", out)
        single = self.build('# T\n\nNur eine Quelle hier ohne Jahr. [[E1]]\n'
                            '<!-- compose {"ids": ["E1"], "frags": []} -->\n\n<!-- references -->\n')
        code, out = self.check(single)
        self.assertNotIn("without naming a year", out)

    def test_a_primary_source_carrying_the_fragment_is_named(self):
        e9 = {**E2, "id": "E9", "page": "002-arabic.example.net.md", "type": "secondary",
              "text": "Die Stadt gründet sich auf eine römische Siedlung namens Vindobona."}
        self.work.verified([E1, E2, E3, E4, E5, e9])
        frag = "Die Stadt gründet sich auf eine römische Siedlung namens Vindobona"
        draft = (f'# T\n\n{frag}. [[E9]]\n<!-- compose {{"ids": ["E9"], "frags": [["E9", "{frag}"]]}} -->\n\n'
                 '<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertIn("primary evidence E2 carries this fragment", out)
        cited = (f'# T\n\n{frag}. [[E2]]\n<!-- compose {{"ids": ["E2"], "frags": [["E2", "{frag}"]]}} -->\n\n'
                 '<!-- references -->\n')
        code, out = self.check(self.build(cited))
        self.assertNotIn("carries this fragment", out)

    def test_an_already_cited_primary_is_not_hinted_again(self):
        frag = "Die Stadt gründet sich auf eine römische Siedlung namens Vindobona"
        e9 = {**E2, "id": "E9", "page": "002-arabic.example.net.md", "type": "secondary",
              "text": frag + ", die im ersten Jahrhundert entstand."}
        self.work.verified([E1, E2, E3, E4, E5, e9])
        draft = (f'# T\n\n{frag}. [[E9]] [[E2]]\n'
                 f'<!-- compose {{"ids": ["E9", "E2"], "frags": [["E9", "{frag}"]]}} -->\n\n'
                 '<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertNotIn("carries this fragment", out)

    def test_a_missing_key_point_block_warns(self):
        code, out = self.check(self.build())
        self.assertIn("no key-point block after the lead", out)

    def test_primary_hint_ignores_a_short_fragment_of_common_words(self):
        # the real case: a forum fragment "da die Entfernung nicht über 20 km ist" shares only
        # generic words with an official table page (Entfernung, nicht, 20)
        e6 = {**E1, "id": "E6", "text": "Bei einer Entfernung von mehr als 20 km bis 40 km gilt "
                                        "nicht der kleine Satz."}
        e9 = {**E2, "id": "E9", "page": "002-arabic.example.net.md", "type": "secondary",
              "text": "Unser Fall: da die Entfernung nicht über 20 km ist, bleibt die kleine "
                      "Pauschale."}
        self.work.verified([E1, E2, E3, E4, E5, e6, e9])
        frag = "da die Entfernung nicht über 20 km ist"
        draft = (f'# T\n\nUnser Fall: {frag}, bleibt die kleine Pauschale. [[E9]]\n'
                 f'<!-- compose {{"ids": ["E9"], "frags": [["E9", "{frag}"]]}} -->\n\n'
                 '<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertNotIn("carries this fragment", out)

    def test_primary_hint_matches_a_mostly_carried_long_fragment(self):
        e6 = {**E1, "id": "E6", "text": "Die Einleitung bewahrt und schützt den Wortschatz der "
                                        "klassischen Dichtung."}
        e9 = {**E2, "id": "E9", "page": "002-arabic.example.net.md", "type": "secondary",
              "text": "Das Dokument bewahrt und schützt den Wortschatz der klassischen Sprache."}
        self.work.verified([E1, E2, E3, E4, E5, e6, e9])
        frag = "bewahrt und schützt den Wortschatz der klassischen Sprache"
        draft = (f'# T\n\nDas Dokument {frag}. [[E9]]\n'
                 f'<!-- compose {{"ids": ["E9"], "frags": [["E9", "{frag}"]]}} -->\n\n'
                 '<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertIn("primary evidence E6 carries this fragment", out)

    def test_primary_hint_ignores_a_weak_long_overlap(self):
        e6 = {**E1, "id": "E6", "text": "Der Text bewahrt den Wortschatz der klassischen Zeit."}
        e9 = {**E2, "id": "E9", "page": "002-arabic.example.net.md", "type": "secondary",
              "text": "Das Dokument bewahrt und schützt den Wortschatz der klassischen Sprache."}
        self.work.verified([E1, E2, E3, E4, E5, e6, e9])
        frag = "bewahrt und schützt den Wortschatz der klassischen Sprache"
        draft = (f'# T\n\nDas Dokument {frag}. [[E9]]\n'
                 f'<!-- compose {{"ids": ["E9"], "frags": [["E9", "{frag}"]]}} -->\n\n'
                 '<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertNotIn("carries this fragment", out)

    def test_primary_hint_ignores_scattered_common_words(self):
        # the real case: 'individual objects instead of using one global lock' (a secondary
        # explainer) shares objects/instead/using/global with a primary that scatters those
        # words over unrelated sentences - no shared phrase, so no hint
        e6 = {**E1, "id": "E6", "text": "Only references to objects must instead be "
                                        "allocated through the standard APIs when using the "
                                        "default global configuration."}
        e9 = {**E2, "id": "E9", "page": "002-arabic.example.net.md", "type": "secondary",
              "text": "The design locks individual objects instead of using one global lock "
                      "for everything."}
        self.work.verified([E1, E2, E3, E4, E5, e6, e9])
        frag = "individual objects instead of using one global lock"
        draft = (f'# T\n\nThe design locks {frag}. [[E9]]\n'
                 f'<!-- compose {{"ids": ["E9"], "frags": [["E9", "{frag}"]]}} -->\n\n'
                 '<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertNotIn("carries this fragment", out)

    def test_primary_hint_needs_four_distinctive_words_for_the_fuzzy_path(self):
        # a short fragment of common words hints only when its whole text appears as one
        # exact run ('die Entfernung ... 20 km ...'): three distinctive words and a shared
        # generic window are not enough
        e6 = {**E1, "id": "E6", "text": "Die Entfernung über 20 km ist für den kleinen "
                                        "Satz entscheidend."}
        e9 = {**E2, "id": "E9", "page": "002-arabic.example.net.md", "type": "secondary",
              "text": "Der Fall: die Entfernung über 20 km ist entscheidend, sagt die Praxis."}
        self.work.verified([E1, E2, E3, E4, E5, e6, e9])
        frag = "die Entfernung über 20 km ist entscheidend"
        draft = (f'# T\n\nDer Fall: {frag}. [[E9]]\n'
                 f'<!-- compose {{"ids": ["E9"], "frags": [["E9", "{frag}"]]}} -->\n\n'
                 '<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertNotIn("carries this fragment", out)

    def test_a_sources_say_nothing_note_is_not_own_words(self):
        frag = "Wien ist die Hauptstadt von Österreich und hat rund 2 Millionen Einwohner"
        draft = (f'# T\n\n{frag}. Zusätzlich fehlen hier noch weitere Angaben für den Vergleich. '
                 'Die Quellen nennen zu dieser Frage nichts. [[E1]]\n'
                 f'<!-- compose {{"ids": ["E1"], "frags": [["E1", "{frag}"]]}} -->\n\n'
                 '<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertIn("own words 32% of 28", out)
        self.assertNotIn("is above", out)

    def test_lead_and_key_points_limits(self):
        draft = ("# T\n\nErster Satz hier. Zweiter Satz hier. Dritter Satz hier. Vierter Satz hier. [[E1]]\n"
                 '<!-- compose {"ids": ["E1"], "frags": []} -->\n\n'
                 "- Eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf dreizehn vierzehn fünfzehn sechzehn. [[E1]]\n"
                 "- Zweiter kurzer Punkt. [[E1]]\n"
                 '<!-- compose {"ids": ["E1"], "frags": []} -->\n\n<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertIn("lead has 4 sentences", out)
        self.assertIn("key point 1 has 16 words (limit 15)", out)
        self.assertIn("key-point block has 2 lines", out)

    def test_key_point_block_is_not_one_long_sentence(self):
        words = "eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf"
        draft = ("# T\n\nالراغب الأصفهاني sagt es. Genauer steht es hier. [[E4]]\n"
                 '<!-- compose {"ids": ["E4"], "frags": []} -->\n\n'
                 + "\n".join(f"- {words} [[E4]]" for _ in range(6)) + "\n"
                 '<!-- compose {"ids": ["E4"], "frags": []} -->\n\n<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertEqual(code, 0, out)
        self.assertNotIn("paragraph 3: sentence has", out)
        self.assertNotIn("paragraph 3: own words 100% is above", out)

    def test_key_point_repeating_a_sentence_warns(self):
        sentence = "Wien ist die Hauptstadt von Österreich"
        draft = (f'# T\n\n{sentence}. [[E1]]\n'
                 f'<!-- compose {{"ids": ["E1"], "frags": [["E1", "{sentence}"]]}} -->\n\n'
                 f"- {sentence}. [[E1]]\n- Zweiter Punkt. [[E1]]\n- Dritter Punkt. [[E1]]\n"
                 '<!-- compose {"ids": ["E1"], "frags": []} -->\n\n<!-- references -->\n')
        code, out = self.check(self.build(draft))
        self.assertIn("key point 1 repeats a sentence of the text word for word", out)

    def test_two_spellings_of_one_name_warn(self):
        filler = " ".join(["هذا نص طويل جدا بلا معنى هنا"] * 8)
        draft = ("# T\n\nالراغب الأصفهاني sagt etwas Wichtiges. [[E4]]\n\n"
                 f"{filler} [[E4]]\n\n"
                 "Zum Schluss steht الأصبهاني allein. [[E4]]\n\n<!-- references -->\n")
        code, out = self.check(self.build(draft))
        self.assertIn("two spellings for one name", out)
        callout = ("# T\n\nالراغب الأصفهاني (auch الأصبهاني) sagt etwas. [[E4]]\n\n"
                   "Und الأصفهاني noch einmal. [[E4]]\n\n<!-- references -->\n")
        code, out = self.check(self.build(callout))
        self.assertNotIn("two spellings for one name", out)

    def test_lowercase_inflected_forms_are_not_name_variants(self):
        filler = ("Zwischen den beiden Stellen steht genug anderer Text, damit die Woerter weit "
                  "auseinander liegen und die Naehepruefung nicht greift. [[E1]]")
        draft = ("# T\n\nEr sagte, dass ihm gehorcht und nicht widersprochen wurde. [[E1]]\n\n"
                 f"{filler}\n\n"
                 "## Wo die Quellen sich widersprechen\n\n"
                 "Der Abschnitt beginnt hier. [[E1]]\n\n<!-- references -->\n")
        code, out = self.check(self.build(draft))
        self.assertNotIn("two spellings for one name", out)

    def test_reference_entry_format_problems_fail(self):
        article = self.build()
        cases = {
            "date is an ISO timestamp": article.replace("2025-03-01.", "2025-03-01T08:00:00Z."),
            "no source type": article.replace("Quellenart: Primärquelle. ", ""),
            "site placeholder": article.replace("Wien: Fakten. example.org.",
                                                "Reddit - The heart of the internet. example.org."),
            "tracking or challenge parameters": article.replace("https://example.org/wien#",
                                                                "https://example.org/wien?utm_source=x#"),
            "the domain appears more than once": article.replace("[1] Stadt Wien. Wien: Fakten. example.org.",
                                                                 "[1] example.org. Wien: Fakten. example.org."),
        }
        for expected, broken in cases.items():
            with self.subTest(expected):
                code, out = self.check(broken)
                self.assertEqual(code, 1, out)
                self.assertIn(expected, out)
        tracked_entry = article.replace("https://example.org/wien\n",
                                        "https://example.org/wien?utm_source=x\n")
        code, out = self.check(tracked_entry)
        self.assertEqual(code, 1, out)
        self.assertIn("tracking or challenge parameters in a URL", out)

    def test_very_long_sentence_warns(self):
        long_sentence = "Wort " * 44 + "Ende."
        article = self.build().replace("\n<!-- references:start -->",
                                       f"\n{long_sentence} [[E1]]\n\n<!-- references:start -->", 1)
        code, out = self.check(article)
        self.assertIn("sentence has 45 words (limit 45, aim 35)", out)

    def test_a_quote_matches_despite_whitespace_before_punctuation(self):
        # the real case: the page writes "[16] ," and the quote of the same words writes "[16],"
        evidence = {**E1, "id": "E6", "lang": "en", "text": "This overhead is expected, "
                     "although it is larger than the slowdowns reported by the Python "
                     "developers HOWTO [16] , that showed average penalties of 8%."}
        self.work.verified([E1, E2, E3, E4, E5, evidence])
        draft = ('# T\n\nThey write that "This overhead is expected, although it is larger '
                 'than the slowdowns reported by the Python developers HOWTO [16], that '
                 'showed average penalties of 8%." [[E6]]\n'
                 '<!-- compose {"ids": ["E6"], "frags": []} -->\n\n<!-- references -->\n')
        code, out = self.check(self.build(draft, "en"), "en")
        self.assertEqual(code, 0, out)
        self.assertNotIn("not word for word", out)

    def test_punctuation_inside_a_quote_does_not_split_the_sentence(self):
        """A quotation is one sentence: periods inside it are not sentence ends.

        Without the masking in split_sentences the long quoted sentence would
        count on its own and draw a length warning for text the writer did not
        write.
        """
        first = "Wort " * 48 + "hier."
        second = "Kurz darauf endete es."
        quoted = f"{first} {second}"
        evidence = {**E1, "id": "E6", "lines": [19, 19], "claim": "quote", "text": quoted}
        self.work.verified([E1, E2, E3, E4, E5, evidence])
        draft = (f'# T\n\nDer Redner sagte: "{quoted}" [[E6]]\n'
                 '<!-- compose {"ids": ["E6"], "frags": []} -->\n\n<!-- references -->\n')
        article = self.build(draft)
        code, out = self.check(article)
        self.assertEqual(code, 0, out)
        self.assertNotIn("sentence has", out)


if __name__ == "__main__":
    unittest.main()
