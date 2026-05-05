# Quickstart: Verifying Pipeline Output Transparency

**Feature**: 041-pipeline-output-transparency  
**Date**: 2026-04-23

Use `run_single.R` (or `runners/run_single.R`) to manually verify each FR against a known test paper.

---

## Setup

```r
source("runners/run_single.R")
```

Or pick a specific paper:

```r
paper_id <- "0956797615569001"   # known combined-granularity paper with codebook
source("runners/run_single.R")
```

---

## FR-001: Verdict Block

**Look for** — at the end of the run, before `── Outputs:`:
```
── Verdict ───────────────────────────────────────
  [SUCCESS]  both stages completed without errors
─────────────────────────────────────────────────
```

**Verify**:
- Run a paper that has codebook files → expect `[SUCCESS]`
- Run a paper with no `columns.csv` → expect `[PARTIAL]` with "stage 2 skipped" note
- Run an invalid paper ID → expect `[FAILED]` with error code

---

## FR-002: Classification Method Labels

**Look for** — in the file classification section:
```
  × 154   data / ex2   combined   [LLM]
  ×   3   code / shared           [rules]
```

And in granularity output:
```
  └ granularity  individual  ^Exp[0-9]+_[0-9]+\.dat$  [rules]
```

**Verify**: Every classification line has either `[rules]` or `[LLM]` appended.

---

## FR-003/FR-006: Zero-Columns Explanation

Use a known individual-granularity paper (one file per participant) or a paper with unsupported formats.

**Look for**:
```
── No columns extracted — pipeline indexes combined-granularity files only;
   individual-granularity datasets produce zero columns by design
```

**Verify**: This message replaces the bare `── No columns extracted` message.

---

## FR-004: psychDS Error Translation

Run a paper known to fail psychDS conversion (e.g. a paper with column-count mismatch).

**Look for** — in the `[psychds]` section:
```
  all    ✗  FAILED: column count mismatch building study table (3 input rows vs 100 in data)
```
(instead of the raw R error `replacement has 3 rows, data has 100`)

---

## FR-005: Coverage Percentage

**Look for** — in Stage 2 summary:
```
label_status=ok  labelled=42  unlabelled=37  coverage=8/11 (73%)
```

**Verify**:
- Percentage is `n_matched_vars / n_codebook_vars * 100`, rounded to integer
- When no codebook: coverage field is absent (`label_status=no_codebook  labelled=0  unlabelled=N`)

---

## FR-007: Terminology Legend

**Look for** — above the first granularity line:
```
── granularity: individual = one file per participant; combined = multiple participants per file
```

**Look for** — above the file inventory table:
```
── file types: data=participant data  code=scripts  codebk=codebook ...
── groups inferred from folder structure
```

**Verify**: Legend prints only once per run (not once per file).

---

## FR-008: Retry Reason

Trigger an LLM retry by running a paper that experiences LLM parse failures (check `logs/llm_batch_errors.log` after run to confirm retry occurred).

**Look for**:
```
── LLM [batch 1/1 | chunk 1] retry 1/3 — JSON parse error: unexpected end of input ──
```

**Verify**: Reason is ≤60 characters; no newlines in the reason string.
