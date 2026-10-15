Sources: https://github.com/blader/humanizer @ 225a6f39ac85f76ee48dbad772ea4abe4ed6c9d8 (MIT), https://github.com/marmbiz/humanizer-de @ 924831533ffd86716845a74c10b476f1d7d92ab7 (MIT; pattern text CC BY-SA 4.0). Condensed by hand, nothing installed, no code taken.

# Style rules for the writer's own words

Scope: only your own words: connectors, lead, key points, headings, closing. Never touch a quote or a verbatim fragment. A pattern inside a source sentence stays: it is the source's, not yours.
`scripts/check_article.py` checks the mechanical patterns: word and phrase lists (English and German), "not X but Y", dashes, quotes. They are not repeated here. Do not run a humanizer skill or script.
Section 9 of `~/.claude/docs/research-standard.md` wins over this file (straight quotes only and no dashes, even where a German rule asks for typographic quotes).
One pattern alone is rarely a problem; a cluster is. Fix in this order, strongest first. Format: avoid -> use.

## 1. "Not X but Y" / "nicht X, sondern Y"
- Avoid a negative half that rebuts something nobody claimed: "not just X, but Y", "nicht nur X, sondern auch Y", "weniger X als vielmehr Y", "X, nicht Y." as a sentence tail, "kein Raten."
- Use the direct claim. Keep a contrast only when a source states that correction.
- Example: "Die Stadt ist nicht nur ein Handelszentrum, sondern auch ein Kulturzentrum." -> "Die Stadt ist Handels- und Kulturzentrum."
- Also avoid arguing with no one ("This isn't about...", "I'm not saying...", "A tempting approach would be..."): state the claim.

## 2. Forced groups of three
- Avoid three parallel items only to sound complete, and suspiciously round lists of 5, 7 or 10.
- Use the number the sources give. Merge, or keep the strongest. Keep three when the meaning has three parts.
- Example: "vielfältig, kreativ und widerstandsfähig" -> "kreativ und widerstandsfähig" (when only two are sourced).
- Avoid "from X to Y" spans that only suggest breadth ("Ob du X oder Y bist").

## 3. Dramatic one-sentence closers
- Avoid a short sentence that restates or praises what was just said ("That is the real win.", "Das ist der Punkt.", "Damit war ein Meilenstein erreicht."), rows of fragments, a generic line right after a heading.
- Use the last concrete fact as the end. Keep a short sentence only when it carries a new fact.
- Avoid a heading repeated as the first sentence under it.

## 4. Staged run-up before the statement
- Avoid "Let's dive in", "here is what you need to know", "Die Sache ist die", "Schauen wir uns an", "Warum das wichtig ist:", "Honestly?".
- Avoid the announcing split sentence: "Was mich überrascht hat, war die Ladezeit." -> "Die Ladezeit hat mich überrascht." (one is fine, a cluster is not).
- Avoid a rhetorical question that is answered at once ("Aber was bedeutet das?"): state the answer.
- Avoid authority tags ("the real question is", "at its core", "Im Kern", "Worauf es wirklich ankommt") and fake nuance ("Genauer gesagt", "Fairerweise") that adds no condition, exception or number.
- Avoid universal openings ("In today's digital world", "In der heutigen digitalen Welt", "Seit jeher"): start with the subject.

## 5. Inflated significance and empty abstractions
- Avoid "stands as a testament", "pivotal moment", "evolving landscape", "plays a key role", "steht als Zeugnis für", "spielt eine wichtige Rolle", "grenzenlose Möglichkeiten". Keep the fact, drop the weight.
- Avoid tacked-on analysis: ", highlighting...", ", was X unterstreicht/verdeutlicht/belegt", "und zeigt damit, dass". Test: if the main clause stands alone, the tail was empty. Delete it.
- Avoid abstract stacks ("verschiedene Maßnahmen", "zahlreiche Aspekte", "innovative Lösungen"): name the thing only if a source names it, otherwise leave it out.
- Avoid sales words (breathtaking, renowned, atemberaubend, einzigartig) and borrowed authority ("experts argue", "Branchenberichte zeigen"): name the source or cut.
- Use "is" and "has", not "serves as", "boasts", "fungiert als", "dient als", "verfügt über", "stellt ... dar".
- Do not invent an actor ("Die Strategie entschied"). Use a named actor only if the source names one.
- Repeat the base word or use a pronoun. Do not rotate synonyms for one thing (die Studie, die Untersuchung, die Analyse).

## 6. Generic transitions and closing formulas
- Avoid mechanical connectors (Additionally, Moreover, darüber hinaus, außerdem, ferner, gleichzeitig, ebenfalls) used as filler. At most one per paragraph.
- Use a neutral join or merge the sentences. A connector that claims a relation (because, therefore, however) needs a source that states it (standard section 4).
- Avoid summary signals ("In conclusion", "zusammenfassend", "abschließend", "insgesamt", "kurz gesagt"), a "Fazit" section that repeats the text, and send-offs ("the future looks bright", "bestens aufgestellt").
- Avoid editorial remarks ("es ist wichtig zu bemerken", "zu beachten ist, dass", "it is worth noting"): say the thing.

## 7. Typical AI words
- The lists are in `check_article.py`. Replace a hit with the plain word: "beleuchten" -> "untersuchen" or "beschreiben"; "spannend" -> delete or give the reason; "die digitale Landschaft" -> the concrete field.
- Do not swap one flagged word for another of the same kind. Keep technical senses (robust statistics, dynamic routing, a milestone in a project plan).

## 8. Chatbot leftovers
- Delete "I hope this helps", "Great question!", "Natürlich!", "Gerne!", offers to continue, "let me know".
- Delete knowledge-limit lines ("as of my last update", "Stand [Datum]", "nach meinem Wissen"). Say "not found in the sources" instead.
- Delete guesses that fill a gap ("vermutlich", "likely grew up..."). Standard section 12 applies.
- Delete tool residue: oaicite, contentReference, turn0search0, utm_source=chatgpt.com.

## 9. Statements about the text instead of the topic
- Avoid "this article will", "the table below compares", "in diesem Text", "wie oben gezeigt", "keine Diskussion wäre vollständig ohne".
- Avoid change-log wording in a finished text ("wurde jetzt ergänzt", "neu hinzugefügt"). Write what holds now.
- The required section "How this text was made" is the one place that may describe the text.

## 10. Decorative bold and headings
- Use bold rarely, never as decoration; no label-and-colon bullet lists ("- **Aspekt:** ...") where a sentence works.
- Headings: sentence case, descriptive, no emojis, no colon-titles built the same way, no skipped level, no H1 repeated as an H2.
- No horizontal rules between sections. No bullets made from the character U+2022.
- Table of one row: write a sentence.

## 11. Same openings and same sentence length
- Avoid three sentences in a row that start alike or run the same length (within about 5 words).
- Use one short sentence (3 to 5 words) next to a long one, but only where the content carries it. Do not break grammar, do not add fragments to look human.
- Avoid four or more main clauses in a row without a subordinate clause; build at least every third sentence as main plus subordinate clause.
- Avoid equal-length paragraphs and sections throughout.

## 12. German nominal style
- Avoid noun chains that hide who does what: "Die Durchführung der Analyse erfolgte unter Nutzung der Daten." -> "Wir haben die Daten analysiert." (use "wir" only if the text has a speaker; else "Die Daten wurden analysiert.").
- Verb back from noun only when actor and action are in the text: "die Analyse durchführen" -> "analysieren"; "die Nutzung von" -> "nutzen".
- Avoid stacked passive and subjectless fragments ("es wird empfohlen", "Keine Konfiguration nötig.") -> a full sentence.
- Do not turn every abstract noun into colloquial speech. Keep fixed technical, legal and scientific terms and dense headings.

## False positives (do not flag, do not rewrite)
- Quotes and verbatim fragments, always. Source sentences, even when they contain a listed pattern.
- A single transition such as "darüber hinaus" or "Moreover" is not wrong. Count clusters, not single signals.
- Clean grammar, a single dash or consistent straight quotes alone are no tell.
- A real contrast a source states ("nicht Montag, sondern Dienstag" as a factual correction).
- Three items when the source lists exactly three. A collective noun followed by its list ("drei Maßnahmen: A, B, C").
- Technical words in their technical sense, project terms, glossary, data sheet, FAQ and legal outline structure.
- A colon in a single title or label (source, time, place). Particles such as "schon", "mal", "ja" in a quoted or spoken sentence.
- Regional Austrian and Swiss usage (Greißler, Helvetismen).
- If only false positives remain, change nothing and say so.

## Hard limits for the writer
- Never change a claim, number, name, date or quote anchor to fix style. Never add an anecdote, opinion or experience.
- Never insert typos, fragments or filler to look human.
- A rule here never overrides the evidence ids, the fragments listed in the paragraph comment or the standard.
