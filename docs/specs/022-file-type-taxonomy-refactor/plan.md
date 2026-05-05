# Implementation Plan: File Type & Group Taxonomy Refactor

**Branch**: `022-file-type-taxonomy-refactor` | **Date**: 2026-03-26 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/022-file-type-taxonomy-refactor/spec.md`

## Summary

Sharpen all 8 file type definitions and all group definitions in the LLM classification prompt. Key changes: tighten `doc`/`supplemental`/`other`/`asset`/`readme`/`codebook`/`code`/`data` boundaries with litmus-test language; rename group `"other"` → `"shared"`; restrict `"na"` to `readme`/`asset`/`other` types only; increase batch size (20 → 30) with incremental cross-batch experiment context; fix `.sps` override from `code` to `supplemental`; add `type_source` column to `structure.csv`; broaden `data` to include non-tabular measurement formats.

## Technical Context

**Language/Version**: R (base R, no new packages)
**Primary Dependencies**: `metacheck` (`llm_batch()`), `haven`, `readxl`, `jsonlite` — all already installed
**Storage**: CSV files on local filesystem — `outputs/<paper_id>/structure.csv` (schema change)
**Testing**: Manual validation using validation GUI + ground truth CSVs (updated as part of this feature)
**Target Platform**: Local macOS R environment
**Project Type**: Data pipeline (R scripts)
**Performance Goals**: Batch size increase reduces total LLM calls per large repo; improves group label consistency
**Constraints**: No new packages; max 10 LLM calls per paper preserved; `LLM_BATCH_SIZE = 30` raises effective path cap 200 → 300
**Scale/Scope**: Affects every paper run through the index pipeline; all existing outputs invalidated (re-run required)

## Constitution Check

| Principle | Status | Notes |
|---|---|---|
| I — Crash Resilience | ✅ PASS | Incremental summary is in-memory per paper; bulk runner's paper-level append is unaffected |
| II — Data Integrity (paper_id) | ✅ PASS | No changes to paper_id handling |
| III — Resource Limits | ⚠️ PATCH NEEDED | `LLM_BATCH_SIZE` 20 → 30; effective path cap 200 → 300; 10-call limit preserved. Constitution constants table + `pipeline.md` must be updated |
| IV — Centralised Helpers | ✅ PASS | `classify_by_rules()` is dead code (untouched); active override is `AGGREGATE_EXT_OVERRIDE`. Incremental summary helpers stay in `0_index.R` |
| V — Structured Errors | ✅ PASS | No new error codes |

**Constitution PATCH**: Update `LLM_BATCH_SIZE` value from `20` to `30`; update parenthetical in Principle III from "(i.e., 200 paths at batch size 20)" to "(i.e., 300 paths at batch size 30)"; bump version 1.1.0 → 1.1.1.

## Project Structure

### Documentation (this feature)

```text
specs/022-file-type-taxonomy-refactor/
├── spec.md
├── plan.md              ← this file
├── research.md          ← Phase 0 output
├── data-model.md        ← Phase 1 output
├── contracts/
│   └── structure-csv.md ← Phase 1 output
└── tasks.md             ← Phase 2 output (/speckit.tasks)
```

### Source Code (modified files)

```text
data_check/pipeline/
├── 0_index.R            ← STRUCTURE_PROMPT (all 8 types sharpened), AGGREGATE_EXT_OVERRIDE
│                           (.sps fix), LLM_BATCH_SIZE (20→30), type_source column,
│                           incremental batch context loop
└── helper.R             ← No changes (classify_by_rules is dead code; not touched)

data_check/docs/
├── output-schemas.md    ← type_source column; group other→shared; updated type/group
│                           descriptions; data now includes non-tabular formats
└── pipeline.md          ← LLM_BATCH_SIZE constant; step 5 incremental summary

data_check/tools/
└── validation_gui/      ← group dropdown: other→shared

data_check/.specify/memory/
└── constitution.md      ← PATCH: LLM_BATCH_SIZE constant table; version 1.1.0→1.1.1
```

## Implementation Steps

### Step 1 — Fix `AGGREGATE_EXT_OVERRIDE`: `.sps` → `supplemental`

**File**: `pipeline/0_index.R` lines 29–40

Change:
```r
do = "code", sps = "code", jl = "code",
```
To:
```r
do = "code", sps = "supplemental", jl = "code",
```

Image/audio/video entries stay as `"asset"` — the override applies only to sentinel-expanded files (>50-file folders), which are almost certainly stimulus sets, not results folders.

---

### Step 2 — Rewrite `STRUCTURE_PROMPT` with all 8 sharpened type definitions

**File**: `pipeline/0_index.R` lines 62–111

Replace the entire `STRUCTURE_PROMPT` value. All 8 types get thorough definitions with litmus-test language:

**`data`** (broadened to include non-tabular):
```
data : any file containing research measurements intended for analysis —
       tabular (CSV, SAV, XLSX, RDS, DTA, etc.) OR non-tabular
       (EEG/physiological recordings .edf/.acq/.bdf, MATLAB matrices .mat,
       nested JSON survey exports).
       Column extraction skips non-parseable formats; the file is still data.
       Litmus test: "Does this contain measurements collected from participants
       or instruments for the purpose of analysis?"
```

**`codebook`** (primary-purpose inference):
```
codebook : file whose PRIMARY purpose is describing what variables mean —
           variable dictionary, data dictionary, coding key.
           Use semantic inference from the filename/path: "variables.xlsx"
           or "codebook.pdf" → codebook; "methods.pdf" that mentions variables
           incidentally → doc or supplemental.
           When in doubt, default to doc or supplemental.
```

**`code`** (`.Rmd`/`.qmd` always code):
```
code : executable source file that can be run or sourced —
       R (.R), Python (.py), MATLAB (.m), Julia (.jl), SQL (.sql),
       shell (.sh/.bash), and notebooks (.Rmd/.qmd).
       .Rmd and .qmd are ALWAYS code regardless of narrative content;
       their knitted output (HTML/PDF) is doc or supplemental.
       Litmus test: "Can this file be run or sourced?"
```

**`supplemental`** (result figures explicitly included):
```
supplemental : materials that SUPPORT or DOCUMENT the research process but do
               NOT report conclusions — survey instruments (.qsf, PDFs),
               consent forms, preregistrations, SPSS .sps syntax files,
               HTML result output files, saved plot objects (.Rdata/.rda with
               ggplot), result figures and output graphs saved as image files,
               and supporting appendices.
               Key question: "Does this support/document the research process?"
               (supplemental) vs. "Does it report the conclusions?" (doc)
```

**`doc`**:
```
doc : narrative document FOR HUMAN READERS reporting research conclusions —
      manuscript, journal article, report of findings, project proposal,
      general prose notes, lab notebook entries, research decision logs.
      Litmus test: "Would a journal reviewer read this to understand the findings?"
```

**`readme`** (name-based only):
```
readme : files named README.* or LICENSE.* or CONTRIBUTING.* only.
         Classify by filename — if the filename is not one of these, it is
         not readme.
```

**`asset`** (participant-facing stimuli only):
```
asset : participant-facing sensory material presented TO participants during
        the study — stimulus images, audio clips played in trials, video
        stimuli, rating-scale images.
        Result figures, output plots, and graphs documenting outcomes
        → supplemental, NOT asset.
        Litmus test: "Would a participant see or hear this file during the study?"
```

**`other`** (not a catch-all):
```
other : NO research content — OS metadata (.DS_Store, Thumbs.db), package
        lock files, environment config files, binary executables, installers.
        MUST NOT be used as a catch-all for ambiguous research files.
```

**Group changes**:
- `"other"` → `"shared"`: not tied to a specific experiment — combined datasets, project-wide scripts, meta-analyses, proposals
- `"na"` restricted: ONLY for type `readme`, `asset`, or `other`; data/codebook/code/supplemental/doc MUST use `shared`/`ex<N>`/`pilot<N>`

---

### Step 3 — Add `type_source` column to `file_df`

**File**: `pipeline/0_index.R` — sentinel expansion block (~lines 440–480)

```r
# agg_expanded_df: after computing `to_override`
agg_expanded_df$type_source <- ifelse(to_override, "rule", "llm")

# non_agg_df (all LLM-assigned)
non_agg_df$type_source <- "llm"
```

`type_source` is written to `structure.csv` automatically via the existing `write.csv()` call.

---

### Step 4 — Increase `LLM_BATCH_SIZE` and add incremental cross-batch context

**File**: `pipeline/0_index.R`

4a. Change default:
```r
if (!exists("LLM_BATCH_SIZE")) LLM_BATCH_SIZE <- 30
```

4b. Replace the single `llm_batch()` call with a chunk loop:

```r
chunks           <- split(llm_paths, ceiling(seq_along(llm_paths) / LLM_BATCH_SIZE))
experiment_map   <- list()   # group → character vector of path tokens
structure_parsed <- NULL

for (i in seq_along(chunks)) {
  prefix <- if (i == 1) {
    "Classify this repository tree:"
  } else {
    build_structure_summary(experiment_map)
  }
  batch_result     <- llm_batch(
    paths         = chunks[[i]],
    system_prompt = STRUCTURE_PROMPT,
    user_prefix   = prefix,
    key_col       = "path",
    extra_cols    = c("type", "group"),
    fallback_vals = list(type = "other", group = "na")
  )
  structure_parsed <- rbind(structure_parsed, batch_result)
  experiment_map   <- update_experiment_map(experiment_map, batch_result)
}
```

`build_structure_summary(map)` formats the map as a bullet-list header (see research.md R5).
`update_experiment_map(map, batch)` collects paths by `ex<N>`/`pilot<N>` group; keeps shortest unique token per group. Both are small inline functions within `run_index()` scope.

---

### Step 5 — Update `docs/output-schemas.md`

- Add `type_source` row to `structure.csv` schema table (`"rule"` or `"llm"`).
- Groups table: rename `other` → `shared`; update description.
- Groups table: update `na` row — restricted to `readme`, `asset`, `other` only.
- Update `pilot<N>` note: alphanumeric suffixes permitted.
- File Types table: update all 8 type descriptions to match sharpened definitions.

---

### Step 6 — Update `docs/pipeline.md`

- Update `LLM_BATCH_SIZE` constant table entry: `20` → `30`.
- Update step 5 in Processing Order to note incremental structure summary for batches 2+.

---

### Step 7 — Update Validation GUI allowed values

Update group column dropdown to include `"shared"` and exclude `"other"`.

---

### Step 8 — Update constitution constants table

**File**: `.specify/memory/constitution.md`

- `LLM_BATCH_SIZE` entry: `20` → `30`
- Principle III parenthetical: "(i.e., 200 paths at batch size 20)" → "(i.e., 300 paths at batch size 30)"
- Version: 1.1.0 → 1.1.1

---

### Step 9 — Review and update ground truth CSVs (manual)

Review `ground_truth/` files for:
- `group_gt = "other"` → change to `"shared"` or `"na"` as appropriate
- `type_gt = "asset"` rows that are result figures → change to `"supplemental"`
- Any `type_gt` assignments affected by broadened `data` definition (non-tabular files)

---

## Complexity Tracking

No constitution violations requiring justification.

## Post-Design Constitution Re-check

All five principles satisfied:
- Crash resilience: batch loop is in-memory within a single paper call; bulk runner's append unchanged.
- Paper ID integrity: unaffected.
- Resource limits: 10-call cap preserved; path cap increase 200 → 300 documented as PATCH.
- Centralised helpers: `build_structure_summary()` / `update_experiment_map()` local to `run_index()`.
- Error classification: no new error codes.
