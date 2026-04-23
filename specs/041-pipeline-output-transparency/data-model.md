# Data Model: Pipeline Output Transparency

**Feature**: 041-pipeline-output-transparency  
**Date**: 2026-04-23  
**Note**: This feature introduces no new CSV columns or file schemas. The "data model" here defines the message formats and classification labels used in terminal output.

---

## Verdict Block (run_single.R)

Printed at end of `run_single.R`, after stage outputs, before `── Outputs:` line.

```
── Verdict ───────────────────────────────────────
  [SUCCESS]  both stages completed without errors
  [PARTIAL]  stage 1 OK; stage 2 skipped (no columns.csv)
  [PARTIAL]  stage 1 OK; stage 2 FAILED — <error>
  [FAILED]   stage 1 FAILED — <error_code>
─────────────────────────────────────────────────
```

**Derivation rules**:

| Condition | Verdict |
|-----------|---------|
| `stage1$success == TRUE` AND `stage2$success == TRUE` | `[SUCCESS]` |
| `stage1$success == TRUE` AND `stage2` skipped (no columns.csv) | `[PARTIAL]` |
| `stage1$success == TRUE` AND `stage2$success == FALSE` | `[PARTIAL]` |
| `stage1$success == FALSE` | `[FAILED]` |

---

## Classification Method Labels (0_index.R)

Appended to each file classification line and granularity line.

```
  × 154   data / ex2         combined   [LLM]
  ×   3   code / shared               [rules]
  └ granularity  individual  ^Exp[0-9]+_[0-9]+\.dat$  [rules]
  └ granularity  combined    (LLM inference)            [LLM]
```

**Label assignment**:
- `[rules]` — `classify_by_rules()` returned `certain = TRUE`
- `[LLM]` — `classify_by_rules()` returned `certain = FALSE` (file was sent to LLM batch)
- For granularity: `[rules]` when regex matched; `[LLM]` when granularity was inferred by LLM batch

---

## Codebook Coverage Display (run_single.R)

Replaces current `label_status=ok  labelled=N  unlabelled=N` line.

```
label_status=ok  labelled=N  unlabelled=N  coverage=matched/total (X%)
```

**Special cases**:
- If `n_codebook_vars == 0` (no codebook present): omit `coverage=` field entirely  
  → `label_status=no_codebook  labelled=0  unlabelled=N`
- Percentage formula: `round(n_matched_vars / n_codebook_vars * 100)` — integer, no decimals

---

## Zero-Columns Explanation Message (0_index.R, run_0_index_bulk.R)

**In `0_index.R`** — replaces bare `── No columns extracted`:
```
── No columns extracted — pipeline indexes combined-granularity files only;
   individual-granularity datasets produce zero columns by design
```

**In `run_0_index_bulk.R`** — appended to existing `⚠` warning:
```
  ⚠  N paper(s) had data files but zero columns
     (pipeline indexes combined-granularity files only; individual datasets produce zero columns by design)
```

---

## Granularity Legend (0_index.R)

Printed once per run, immediately before the first granularity output line.

```
── granularity: individual = one file per participant; combined = multiple participants per file
```

**Print condition**: Only printed on the first granularity inference of the run (flag variable `granularity_legend_printed`).

---

## File Type Legend (0_index.R)

Printed as a header line above the file inventory table.

```
── file types: data=participant data  code=scripts  codebk=codebook  asset=media
               suppl=supplemental  softw=software  output=generated output  other=unclassified
── groups inferred from folder structure
```

---

## psychDS Error Translations (3_psychds_convert.R)

Applied in the `tryCatch` error handler before printing the `✗  FAILED:` line.

| Raw R error pattern (regex) | Translated message |
|-----------------------------|--------------------|
| `replacement has (\d+) rows, data has (\d+)` | `column count mismatch building study table ($1 input rows vs $2 in data)` |
| `^no_data_files$` | `no data files found for this study group` |
| *(no match)* | raw error string (unchanged) |

---

## Retry Reason Format (helper.R)

**Current**: `── LLM [batch X/Y | chunk Z] retry N/3 ──`  
**New**: `── LLM [batch X/Y | chunk Z] retry N/3 — <reason> ──`

Where `<reason>` is `substr(conditionMessage(e), 1, 60)` trimmed of newlines.
