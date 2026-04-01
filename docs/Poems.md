# Poems

*One poem per feature, in order of creation.*

---

## 002 — Column Type Classification

A column arrives, anonymous, raw —
is it continuous? binary? a flaw?
The rules step in first, then the model is called,
to name what the data has always enthralled.
Continuous flows, binary splits,
categorical sorts, ordinal sits —
each column assigned its place in the scheme,
so statistics downstream can finally mean.

---

## 004 — Reduce Unknown Col Types

Too many unknowns, the model shrugged and guessed,
leaving half the columns unaddressed.
So the rules were sharpened — decimals caught by eye,
integer scales no longer asking why.
The LLM called less, the fallback rate fell,
and `unknown` became a rarer thing to tell.

---

## 005 — Codebook Column Labelling

Somewhere in the repo, a codebook waits —
a dictionary of columns, variables, fates.
We parse it out, we match it by name,
attach the description, so nothing's the same.
Now every column knows what it means,
not just a header, but the thing it convenes.

---

## 006 — LLM Fuzzy Matching

When the variable names don't quite align —
`resp_time` meets `ResponseTime`, a borderline sign —
the rules step back and the model steps in,
reading semantics through the noise and the din.
And `label_method` records the truth:
did rules find it, or was it the LLM's sleuth?

---

## 007 — Per-ID Output Structure

Everything lived in one flat directory,
a pile of CSVs, disorderly.
Now each paper gets a room of its own —
`outputs/<paper_id>/`, a place to call home.
Crash and resume, the pipeline picks back up,
knowing exactly whose files fill whose cup.

---

## 008 — Bulk Label Runners

A script that runs once is a script for one —
but science needs hundreds of papers done.
The runners took shape: bulk, resumable, sure,
appending their rows to a log that endures.
If the process dies, it picks up the thread —
no paper re-run for the papers already read.

---

## 009 — Multi-Format Codebooks

Not all codebooks come clean in a CSV —
some live in Word documents, PDFs, RTF.
The parser learned to strip the formatting free,
extracting the text so the model could see.
Now `.docx` and `.pdf` yield their hidden store,
no codebook too dressed up to be ignored.

---

## 010 — Fix Label Ambiguity

A label that conflicts is no label at all —
when two definitions answer the same call.
The fix was specificity: most precise wins,
the ambiguous flag no longer begins
for synonyms that meant the same thing twice.
One label per column, exact and concise.

---

## 011 — Merge Columns Output

A second script was clobbering the first,
erasing the statistics — the worst.
Stage one had done its careful, thorough run;
stage two arrived and undid what was done.
The fix was a merge, a preservation of truth:
all columns intact, with their metrics as proof.

---

## 012 — Single Dataset Runner

One script to run the whole thing, end to end —
a random paper chosen, pipeline to send.
`run_single.R`, a tool for the curious hand,
testing the pipeline as it was planned.
Pick a paper, watch it flow through each stage —
the whole machine on a single page.

---

## 013 — Fix R File Misclassification

Four bugs arrived dressed up as edge cases:
R files mistyped, empty CSVs with blank faces,
duplicate files counted more than once,
and data reads that spun like a dunce.
Extension rules applied after sentinels expand,
the cap enforced — now the pipeline can stand.

---

## 014 — Fix Multilevel CSV Headers

Some CSVs arrive with two rows at the top —
one for the group, one for the column — a prop.
The parser learned to look one row below,
find the true header, let the data flow.
And `col_header_group` remembers the tier,
for the wide-to-long pivot that may appear.

---

## 015 — Verbatim Codebook Labels

The model was summarising when it should have copied —
paraphrasing labels, slightly lopsided.
Now the prompt says: write it exactly as found,
no rewording the variable, keep it bound.
Verbatim means verbatim — the author's own word,
not a synonym the model preferred.

---

## 016 — Pipeline Quality Report

After the bulk run, what actually worked?
Which papers failed, which columns were shirked?
The report was born: a Markdown review
of coverage, failures, timings run through.
Now every bulk run ends with a page —
a reckoning written at the end of the stage.

---

## 017 — LLM Temperature Testing

At temperature zero, the model is cold,
repeating the same answer as told.
At temperature one, it wanders and drifts —
consistent no more, but full of small shifts.
The sweep was run to find the sweet zone:
where reproducible outputs are grown.

---

## 018 — Fix CSV Codebook Parsing

Some CSV codebooks resist a clean read —
wrong encoding, odd headers, an unusual creed.
The parser now retries with a different guess,
expands the column patterns, handles the mess.
And when all else fails, the model steps in —
no codebook left unread because of its skin.

---

## 019 — Fix Index Labelled Stats

Haven returns a labelled class — a disguise
that R's `rbind` sees through different eyes.
A type mismatch, a zero-row edge case too,
two quiet bugs that nobody knew.
Now the labelled column sheds its extra coat,
and zero-row papers stay afloat.

---

## 020 — Validation GUI

The researcher sits at the keyboard and types —
`d` for data, `s` for the supplemental gripes.
A Shiny GUI, a file list, a preview,
ground truth accumulating, paper by paper, true.
Shift-click for ranges, Cmd-click to toggle free —
the human in the loop, annotating with glee.

---

## 021 — PsychDS Conversion

The dataset, processed, now takes its final form —
PsychDS-compliant, riding the norm.
JSON metadata, study folders by group,
the original files preserved in a loop.
A standard emerges from the structured pile:
psychology's data, readable, reconciled.

---

## 022 — File Type Taxonomy Refactor

`doc` became `supplemental`, `other` was refined,
`shared` found its boundary, more clearly defined.
The type source column appeared in the log —
no silent reclassification lost in the fog.
Each file now knows how it earned its name,
and cross-batch consistency isn't a game.

---

## 023 — Sentinel Aggregate Revamp

A folder with a thousand files arrives —
the sentinel system wakes and contrives
to find the pattern: `sub-01`, `sub-02`, the series,
classifying the aggregate, quieting our queries.
Phase 2 receives the context from Phase 1,
and the group label follows from what was begun.

---

## 024 — Fix Col Type Detection

`participant_id` was coming back `unknown` —
the model unsure of seeds that were sown.
Now a name pattern is enough to decide:
`id` by label, the heuristic applied.
And `constant` appeared for the single-value case —
a degenerate column, given its rightful place.

---

## 025 — Add N Unique Stat

How many distinct values does this column hold?
A cardinality question, simple and old.
`n_unique` arrived in `columns.csv`,
counting the non-NA values, free of NA.
One small column, a wealth of information —
downstream checks built on a solid foundation.

---

## 026 — Add Output File Type

A figure rendered from a script is not a manuscript —
the `supplemental` bucket had it conscripted.
`output` arrived to take its proper slot:
rendered notebooks, figures, logs — the lot.
What a human wrote and what a script produced
are two different things, no longer confused.

---

## 027 — LLM Retry Logging

The chunk failed. The model returned a string
that `jsonlite` could not parse into anything.
But now the pipeline doesn't simply fall —
it retries three times before accepting the call.
And when the retries are finally spent,
the log records exactly what was sent:
the system prompt, the user's listed files,
the raw response — preserved across the miles.
`llm_error` sits in the sentinel column, still,
a marker of failure, visible, until
a human reads the log and finds the cause —
and the pipeline, at last, earns its applause.
