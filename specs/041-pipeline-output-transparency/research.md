# Research: Pipeline Output Transparency

**Feature**: 041-pipeline-output-transparency  
**Date**: 2026-04-23  
**Source**: Codebase exploration of `pipeline/*.R` and `runners/*.R`

---

## FR-001 — Dataset-Level Verdict (`run_single.R`)

**Current state**: `run_single.R` prints stage-level results (lines 67–111) but ends without a final verdict. Stage 1 success line is `success=TRUE  files=N  data_files=N  columns=N  elapsed=Xs`. Stage 2 success line is `label_status=ok  labelled=N  unlabelled=N  elapsed=Xs`. There is no summary line that classifies the overall run.

**Decision**: Add a verdict block at the end of `run_single.R` (after stage 2 output, before the `── Outputs:` line).  
**Verdict taxonomy**:
- `[SUCCESS]` — both stages ran without error
- `[PARTIAL]` — stage 1 succeeded, stage 2 failed or was skipped due to missing `columns.csv`
- `[FAILED]` — stage 1 failed (error code written to CSV)

**Rationale**: `run_single.R` already tracks `stage1` and `stage2` result objects with `$success` and `$error` fields. The verdict is a pure derivation from existing return values — no new state needed.

**Alternatives considered**: Adding verdict to bulk runner (`run_0_index_bulk.R`). Rejected — bulk runner already has a detailed summary block; the gap is the per-paper terminal output in `run_single.R` used for dev/smoke-testing.

---

## FR-002 — Classification Method Labels (`0_index.R`)

**Current state**: File classification is printed at `0_index.R:759-762` as `× [count] [path/.ext] → [type / group]`. The `classify_by_rules()` function (in `helper.R`) returns a list with a `certain` boolean — `certain=TRUE` means the rule engine was confident; `certain=FALSE` means the file was sent to the LLM. This `certain` field is available at the call site in `0_index.R` but is not forwarded to the print statement.

**Decision**: At each classification print site in `0_index.R`, append `[rules]` when `certain=TRUE` and `[LLM]` when the LLM was used. Same for granularity decisions — the granularity inference in `0_index.R:994` currently shows `└ granularity  individual  <regex>` with no method label; add `[rules]` or `[LLM]` based on whether the regex matched or the LLM inferred it.

**Rationale**: `classify_by_rules()` already returns the information needed. No new LLM calls. The `certain` field is the correct signal — it is already used internally to decide whether to send to LLM.

**Alternatives considered**: Querying the LLM to explain its own decisions. Rejected (spec FR-002 explicitly prohibits new LLM calls for transparency purposes).

---

## FR-003 — Skip Reasons on Column Extraction (`0_index.R`)

**Current state**: Most skip reasons are already printed. `0_index.R` lines 1204–1249 cover: `[skipped: too large]`, `[skipped: GB limit reached]`, `[skipped: timed out]`, `[skipped: unreadable or empty]`, `[skipped: Qualtrics headers only]`.

**Decision**: No new skip reason tags needed — existing coverage is complete. The main gap is the **zero-columns-extracted case** (FR-006), addressed separately. One minor improvement: when `nrow(data_files) == 0` at line 1190, the message `── Extracting columns + statistics from 0 data file(s)` should explain *why* there are zero data files (see FR-006).

**Rationale**: Skip tags already exist and follow a consistent format. Adding more tags would duplicate coverage.

---

## FR-004 — Plain-Language psychDS Error Translation (`3_psychds_convert.R`)

**Current state**: `3_psychds_convert.R:1072` prints `✗  FAILED: <raw R error string>`. Known error patterns from the expert report include `replacement has N rows, data has M` (an internal R assignment error during data frame construction).

**Decision**: In the `tryCatch` error handler in `3_psychds_convert.R`, apply a translation table mapping known raw error patterns to plain-language messages before printing. Unknown patterns fall back to the raw message unchanged (safe default).

**Translation table** (known patterns from expert report):

| Raw pattern | Plain-language message |
|-------------|------------------------|
| `replacement has \d+ rows, data has \d+` | `column count mismatch when building study table (N input rows vs M in data)` |
| `no_data_files` | `no data files found for this study group` |

**Rationale**: Only two patterns are documented in the expert report. Exhaustive coverage of all possible R errors is explicitly out of scope (per spec Assumptions).

---

## FR-005 — Codebook Coverage as Percentage (`2_codebook_label.R` + `run_single.R`)

**Current state**: `run_single.R:105-111` prints the raw return from `run_codebook_label()`, including `label_status=ok labelled=N unlabelled=N`. The `coverage:` JSON format shown in the expert report (`coverage: {"unmatched_in_data":10,"matched":1}`) appears to come from direct `print()` of the return object in an earlier version. The return object from `2_codebook_label.R` contains: `n_matched_vars`, `n_codebook_vars`, `n_labelled`, `n_unlabelled`, `label_status`.

**Decision**: In `run_single.R`, replace the raw `label_status=ok labelled=N unlabelled=N` line with:
```
label_status=ok  labelled=N  unlabelled=N  coverage=matched/total (X%)
```
Where `matched = n_matched_vars`, `total = n_codebook_vars`. If `n_codebook_vars == 0` (no codebook), omit coverage field entirely — it is not meaningful.

**Rationale**: The percentage requires only arithmetic on fields already present in the return value. No changes to `2_codebook_label.R` internals needed.

---

## FR-006 — Zero Columns Extracted Explanation (`0_index.R` + `run_0_index_bulk.R`)

**Current state**: `0_index.R:1599` prints `── No columns extracted` with no explanation. `run_0_index_bulk.R:~330` prints `⚠  N paper(s) had data files but zero columns:` with paper IDs but no explanation.

**Decision**: At line 1599 in `0_index.R`, if data files were classified but column extraction yielded zero rows, print an explanatory note:  
`── No columns extracted — pipeline indexes combined-granularity files only; individual-granularity datasets will produce zero columns by design`

In `run_0_index_bulk.R`, append the same explanation to the `⚠` warning line.

**Rationale**: This is a known, expected pipeline behaviour (spec Assumptions). The explanation eliminates researcher confusion without adding any logic — it is a static string appended to an existing message.

---

## FR-007 — Terminology Legend (`0_index.R`)

**Current state**:
- `granularity` first printed at `0_index.R:994` with no definition
- File type categories first appear in the inventory table at `0_index.R:1129-1163` with no legend
- Group inference basis is never stated

**Decision**:

1. **Granularity legend**: Add one-line definition above the first granularity print (line 994):  
   `── granularity legend: individual = one file per participant; combined = multiple participants per file`  
   Print only once per run (use a flag variable).

2. **File type legend**: Add a header line above the inventory table (line 1129):  
   `── file types: data=participant data  code=analysis scripts  codebk=codebook  asset=media  suppl=supplemental  softw=software  output=generated output  other=unclassified`

3. **Group inference basis**: Add one line above the group column in the inventory table:  
   `── groups inferred from folder structure`

**Rationale**: All three are static strings added to existing print sites. No logic changes required.

---

## FR-008 — Retry and Fallback Reasons (`helper.R`)

**Current state**: 
- `helper.R:618` prints `── LLM [batch X/Y | chunk Z] retry N/3 ──` but does not include the reason for the retry.
- `helper.R:1039` prints `── parse_codebook: structured extraction failed for <src> — falling back to LLM` — this already includes a reason.

**Decision**: In `helper.R:618`, capture the error from the previous attempt (already available in the `tryCatch` context as `e$message`) and append a trimmed version to the retry line:  
`── LLM retry N/3 — <trimmed reason> ──`

Trim the reason to ≤60 characters to avoid wrapping.

**Rationale**: The error message is already captured in the retry handler — it just is not printed. One-line change.

---

## No-CLARIFICATION Summary

All NEEDS CLARIFICATION items were resolved. No unknown decisions remain.
