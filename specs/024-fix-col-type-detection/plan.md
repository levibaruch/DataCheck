# Implementation Plan: Fix Column Type Detection

**Branch**: `024-fix-col-type-detection` | **Date**: 2026-03-28 | **Spec**: `specs/024-fix-col-type-detection/spec.md`
**Input**: Feature specification from `specs/024-fix-col-type-detection/spec.md`

> Two clarify sessions have shaped this plan (2026-03-28). See `spec.md §Clarifications` for all decisions.

## Summary

Fix four classification bugs in the column type pipeline, plus introduce dedicated LLM classification for character columns:
1. Expand ID name-pattern rule — hard-classify directly as `id`, no LLM, no value-type guard.
2. New `constant` col_type for 1-unique-value columns, deflating the inflated `binary` rate.
3. Narrow `COLUMN_TYPE_PROMPT` to 6 types for the numeric LLM batch; add a new `CHAR_COLUMN_TYPE_PROMPT` for the character LLM batch.
4. Character columns that rules can't deterministically classify now route to a dedicated second LLM batch (replacing rules 9/10 hard-coding), with up to 20 sampled unique values and an independent `MAX_CHAR_COL_TYPE_LLM_CALLS` cap.

## Technical Context

**Language/Version**: R (base R, no new packages)
**Primary Dependencies**: `metacheck` (`llm_batch()`), `haven`, `readxl`, `jsonlite` — all already installed
**Storage**: CSV files on local filesystem — `outputs/<paper_id>/columns.csv`
**Testing**: Manual verification against known datasets; batch run on representative sample
**Target Platform**: macOS / local pipeline
**Project Type**: Data pipeline (batch processing)
**Performance Goals**: No regression in per-paper processing time; ID columns no longer incur an LLM call (net reduction). Character columns gain LLM calls — net cost depends on column mix.
**Constraints**: No new packages; base R only; must not break existing `columns.csv` consumers
**Scale/Scope**: ~306k classified columns across hundreds of papers

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Crash Resilience | PASS | No change to bulk runner or CSV write order |
| II. Paper ID Preservation | PASS | No change to paper ID handling |
| III. Conservative Resource Limits | **AMENDMENT REQUIRED** | New `MAX_CHAR_COL_TYPE_LLM_CALLS` constant must be added to constitution §III and the constants table |
| IV. Centralised Helpers & Prompts | PASS | New `CHAR_COLUMN_TYPE_PROMPT` goes in `prompts.R`; new constant in `0_index.R` |
| V. Structured Error Classification | PASS | `constant` is a col_type value, not an error code |

**Principle III Amendment**: Add to the resource limits list: "Maximum LLM calls per paper (character column classification): `MAX_CHAR_COL_TYPE_LLM_CALLS`" (default: 3, i.e., 90 character columns at batch size 30). Add to the constants table. This is a MINOR amendment (new limit added, backward compatible).

## Project Structure

### Documentation (this feature)

```text
specs/024-fix-col-type-detection/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (modified files only)

```text
pipeline/
├── helper.R             # classify_col_type_rules(): expanded ID rule, constant rule,
│                        #   binary narrowed, rules 9/10 replaced with char-ambiguous routing
├── 0_index.R            # VALID_COL_TYPES + "constant"; split LLM batches (numeric vs char);
│                        #   MAX_CHAR_COL_TYPE_LLM_CALLS; 20-sample cap for char columns;
│                        #   invalid-type logging; text fallback for char unknown
└── prompts.R            # COLUMN_TYPE_PROMPT narrowed (6 types);
│                        #   CHAR_COLUMN_TYPE_PROMPT (new, 6 char-relevant types)

docs/
└── output-schemas.md    # constant added; binary/id descriptions updated

.specify/memory/
└── constitution.md      # Principle III: add MAX_CHAR_COL_TYPE_LLM_CALLS limit + table row
```

## Implementation Design

### Change 1 — `pipeline/helper.R`: `classify_col_type_rules()`

**Full rule table (post-feature)**:

| # | Trigger | Returns | Change |
|---|---------|---------|--------|
| 1 | `n_noNA == 0` | `empty` | None |
| 2 | Name matches ID pattern | `id`, `ambiguous=FALSE` | Expanded regex; hard-classify; no LLM |
| 3 | `n_unique == 1` | `constant`, `ambiguous=FALSE` | New |
| 4 | `n_unique == 2` | `binary`, `ambiguous=FALSE` | Narrowed from `<=2` |
| 5 | ≥70% date-parseable | `date`, `ambiguous=FALSE` | None |
| 6 | Median `nchar > 40` | `text`, `ambiguous=FALSE` | None — stays deterministic |
| 7a | Decimal numeric | `continuous`, `ambiguous=FALSE` | None |
| 7 | Integer numeric, >20 unique | `continuous`, `ambiguous=FALSE` | None |
| 7 | Integer numeric, 3–20 unique | `NA`, `ambiguous=TRUE`, `is_numeric=TRUE` | None — first LLM batch |
| 8 | Comma-decimal ≥95% | `continuous_comma_decimal` | None |
| 8 | Comma-decimal 80–95% | `continuous_outliers_excluded` | None |
| 9 | *(any remaining character column)* | `NA`, `ambiguous=TRUE`, `is_numeric=FALSE` | **Replaces** former categorical/text rules — routes to second LLM batch |

Rules 9/10 (former `categorical` and text fallback) are **retired** as classification endpoints. All character columns not caught by rules 1–8 now return `ambiguous = TRUE, is_numeric = FALSE`.

---

### Change 2 — `pipeline/0_index.R`

**New constant** (alongside other constants, ~line 49):

```r
if (!exists("MAX_CHAR_COL_TYPE_LLM_CALLS")) MAX_CHAR_COL_TYPE_LLM_CALLS <- 3L
```

**`VALID_COL_TYPES`**: add `"constant"` (already done; kept here for completeness).

**`sample_values_unique` computation** — increase cap to 20 for char-ambiguous columns:

```r
sample_vals_unique <- vapply(seq_along(names(df)), function(i) {
  if (!ambiguous_idx[i]) return(NA_character_)
  x_noNA <- df[[names(df)[i]]]
  x_noNA <- x_noNA[!is.na(x_noNA)]
  cap    <- if (isTRUE(is_numeric_vec[i])) 10L else 20L   # more samples for char columns
  uniq_v <- unique(x_noNA)[seq_len(min(cap, length(unique(x_noNA))))]
  paste(as.character(uniq_v), collapse = ", ")
}, character(1))
```

**Split LLM batches** — replace the single `ambig_rows` block with two sequential batches:

```r
# ── Batch 1: integer-numeric ambiguous columns (COLUMN_TYPE_PROMPT) ──────────
num_ambig_rows <- which(is.na(columns_df$col_type) & columns_df$is_numeric)
if (length(num_ambig_rows) > 0) {
  max_num_cols <- MAX_COL_TYPE_LLM_CALLS * LLM_BATCH_SIZE
  if (!FULL_RUN && length(num_ambig_rows) > max_num_cols)
    num_ambig_rows <- num_ambig_rows[seq_len(max_num_cols)]
  # ... llm_batch() with COLUMN_TYPE_PROMPT ...
  # invalid types → "unknown"; numeric unknown → "continuous" (existing fallback)
}

# ── Batch 2: character-ambiguous columns (CHAR_COLUMN_TYPE_PROMPT) ────────────
char_ambig_rows <- which(is.na(columns_df$col_type) & !columns_df$is_numeric)
if (length(char_ambig_rows) > 0) {
  max_char_cols <- MAX_CHAR_COL_TYPE_LLM_CALLS * LLM_BATCH_SIZE
  if (!FULL_RUN && length(char_ambig_rows) > max_char_cols)
    char_ambig_rows <- char_ambig_rows[seq_len(max_char_cols)]
  # ... llm_batch() with CHAR_COLUMN_TYPE_PROMPT ...
  # invalid types → "text" (not "unknown") for char columns
  # char "unknown" → "text" as last resort
}
```

**Invalid-type logging** (both batches): emit a `message()` with count and names of unexpected types.

---

### Change 3 — `pipeline/prompts.R`

**`COLUMN_TYPE_PROMPT`** (numeric batch — already narrowed, kept as-is):
Types: `continuous`, `ordinal`, `categorical`, `binary`, `id`, `unknown`.

**`CHAR_COLUMN_TYPE_PROMPT`** (new — character batch):

```
col_type — pick one:
  categorical : unordered group or category label — condition names, gender codes,
                language labels, response options like "yes"/"no"/"maybe"
  ordinal     : ordered scale stored as strings — "low"/"medium"/"high", letter
                grades, Likert labels ("strongly agree" etc.)
  binary      : exactly two distinct values (yes/no, true/false, present/absent)
  text        : free-form written response — sentences, phrases, open-ended answers
  id          : participant or row identifier — the PRIMARY signal is the column NAME;
                keep for edge cases (e.g. alphanumeric codes not caught by name rules)
  unknown     : ONLY when name AND all sample values give absolutely no classifiable
                signal — virtually never correct; always prefer another type

Output ONLY the JSON array. No notes, no text outside the array.
```

---

### Change 4 — `docs/output-schemas.md`

Already updated for `constant`. No additional changes required from this plan revision.

---

### Change 5 — `.specify/memory/constitution.md`

Add to Principle III resource limits list:
```
- Maximum LLM calls per paper (character column classification): MAX_CHAR_COL_TYPE_LLM_CALLS (default: 3, i.e., 90 columns at batch size 30)
```

Add to constants table:
```
| MAX_CHAR_COL_TYPE_LLM_CALLS | 3 | 0_index.R | Max LLM calls for character column classification |
```

Bump version: 1.2.0 → 1.3.0 (MINOR — new resource limit added to Principle III).

---

## Complexity Tracking

| Note | Justification |
|------|---------------|
| Two LLM batches per paper instead of one | Character columns require a different prompt and more samples; bundling with the numeric batch would require a unified prompt that's worse for both column types |
| Constitution amendment (Principle III) | New resource limit `MAX_CHAR_COL_TYPE_LLM_CALLS` must be declared per governance rules — this is expected and correct |
