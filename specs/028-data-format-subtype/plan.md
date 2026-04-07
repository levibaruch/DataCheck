# Implementation Plan: Data Format Sub-classification (Tabular vs Raw)

**Branch**: `028-data-format-subtype` | **Date**: 2026-04-01 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `specs/028-data-format-subtype/spec.md`

## Summary

Introduce a `data_format` field (`"tabular"` | `"raw"`) on every `type = "data"` row in `structure.csv`. Gate column extraction on `data_format == "tabular"` to stop the pipeline from attempting to extract columns from binary recordings (MP4, MAT, EDF, etc.). Backfill the new field into all 103 ground truth files before triggering a full bulk rerun. Add a `.mat` hard-case rule to `STRUCTURE_PROMPT`. The extension lookup lives in a new `classify_data_format()` helper in `helper.R` — the single source of truth for all callers.

---

## Technical Context

**Language/Version**: R (base R only — no new packages)  
**Primary Dependencies**: `haven`, `readxl`, `jsonlite`, `tools` (base) — all already installed; `metacheck` (`llm_batch()`)  
**Storage**: CSV files on local filesystem (`outputs/<paper_id>/structure.csv`, `ground_truth/<paper_id>.csv`, `results/bulk_summary.csv`)  
**Testing**: `runners/run_tests.R` + `runners/report_tests.R` (existing test paper suite)  
**Target Platform**: macOS / Linux local pipeline  
**Project Type**: CLI data pipeline (R scripts, no web service)  
**Performance Goals**: `classify_data_format()` is a vectorised lookup — negligible overhead. Repair runner processes 103 files, no LLM calls, expected runtime < 10 seconds.  
**Constraints**: No new packages; no LLM calls in repair/audit runners; idempotent repair; backward-compatible structure.csv (new column appended last)  
**Scale/Scope**: 103 existing ground truth files; ~100 papers for bulk rerun after repair

---

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I — Crash Resilience | ✅ PASS | Repair runner writes summary row per paper (append-after-each). Audit runner is read-only. |
| II — Paper ID Preservation | ✅ PASS | All `read.csv()` calls in repair/audit runners use `colClasses = c(paper_id = "character")`. |
| III — Resource Limits | ✅ PASS | No new LLM calls. No download I/O in repair/audit runners. All existing limits unchanged. |
| IV — Centralised Helpers | ✅ PASS | `classify_data_format()` goes in `helper.R`. Extension lookup NOT duplicated in pipeline scripts. |
| V — Structured Error Codes | ✅ PASS | No new failure modes introduced. Existing error codes unchanged. |

**Gate**: All principles pass. Proceed.

---

## Project Structure

### Documentation (this feature)

```text
specs/028-data-format-subtype/
├── plan.md              ← this file
├── spec.md
├── research.md          ← Phase 0 output
├── data-model.md        ← Phase 1 output
└── checklists/
    └── requirements.md
```

### Source Code Changes

```text
pipeline/
├── helper.R             ← ADD: TABULAR_EXTENSIONS, RAW_EXTENSIONS, classify_data_format()
├── prompts.R            ← MODIFY: STRUCTURE_PROMPT — .mat hard-case rule
└── 0_index.R            ← MODIFY: data_format assignment, extraction gate, structure.csv write,
                                    n_tabular_files in bulk summary

runners/
├── repair_ground_truth_data_format.R   ← NEW: backfill data_format_gt into ground_truth/ files
└── audit_ground_truth_data_format.R    ← NEW: report ground truth entries needing re-review

pipeline/3_psychds_convert.R            ← MODIFY: route data_format == "raw" to data/raw/ only
tools/validation_gui/app.R             ← MODIFY: data_format badge for data-typed rows

docs/
├── output-schemas.md    ← MODIFY: add data_format to structure.csv table; new runner output CSVs
└── pipeline.md          ← MODIFY: update step 6 (gating); n_tabular_files in bulk_summary table
```

---

## Implementation Steps

### Step 1 — `classify_data_format()` in `pipeline/helper.R`

Add immediately after the existing `classify_by_rules()` function.

```
TABULAR_EXTENSIONS <- c("csv", "tsv", "txt", "dat", "xlsx", "xls",
                         "sav", "dta", "sas7bdat")
RAW_EXTENSIONS     <- c("edf", "bdf", "acq", "mat",
                         "mp4", "avi", "mov", "wav", "mp3")

classify_data_format <- function(ext) {
  # ext: character vector of lowercase extensions (no leading dot)
  # Returns "tabular" or "raw" — never NA.
  # NA for non-data rows is applied by the caller, not here.
  ifelse(
    ext %in% RAW_EXTENSIONS, "raw", "tabular"   # conservative: anything unknown → tabular
  )
}
```

**Test**: Unit-level — call `classify_data_format(c("csv", "mp4", "mat", "xyz"))` and verify `c("tabular", "raw", "raw", "tabular")`.

---

### Step 2 — Assign `data_format` in `pipeline/0_index.R`

**Location**: After line 668 (`file_df$ext <- tolower(...)`).

```r
# Assign data_format — "tabular" or "raw" for data files, NA for all others
file_df$data_format <- ifelse(
  file_df$type == "data",
  classify_data_format(file_df$ext),
  NA_character_
)
```

This is vectorised, zero I/O, and uses the shared helper.

---

### Step 3 — Gate column extraction in `pipeline/0_index.R`

**Location**: Line 683 (the `data_files` filter).

**Current**:
```r
data_files <- file_df[file_df$type == "data" & !file_df$is_sentinel, ]
```

**New**:
```r
data_files <- file_df[
  file_df$type == "data" &
  !file_df$is_sentinel &
  !is.na(file_df$data_format) & file_df$data_format == "tabular",
]
```

The `!is.na()` guard handles any edge case where `data_format` was not assigned (defensive).

---

### Step 4 — Add `data_format` to structure.csv write in `pipeline/0_index.R`

**Location**: Lines 1029-1031 (the `write.csv` column vector).

Add `"data_format"` as the last element in the column selection vector.

---

### Step 5 — Add `n_tabular_files` to bulk summary in `pipeline/0_index.R`

Find where the bulk summary row is assembled (the list/data.frame that includes `n_data_files`). Add:

```r
n_tabular_files = sum(
  file_df$type == "data" & file_df$data_format == "tabular" & !file_df$is_sentinel,
  na.rm = TRUE
)
```

---

### Step 6 — Update `STRUCTURE_PROMPT` in `pipeline/prompts.R`

Add a `.mat` rule to the "Hard cases" section of `STRUCTURE_PROMPT`:

```
- .mat → data if participant/subject-named (e.g. "sub_01_data.mat", "participant3.mat");
         → output if filename contains "result", "output", "model", "fit", "figure", "plot";
         → data as default if context is ambiguous (false negative worse than false positive).
```

No change needed for `.mp4` — the participant-naming rule already produces the correct `type = "data"` outcome; `data_format = "raw"` is applied post-classification.

---

### Step 7 — Create `runners/repair_ground_truth_data_format.R`

New file. Structure:

```
source("pipeline/helper.R")   # for classify_data_format()

GT_DIR     <- "ground_truth"
SUMMARY_OUT <- "results/ground_truth_repair_summary.csv"

gt_files <- list.files(GT_DIR, pattern = "\\.csv$", full.names = TRUE)

for (f in gt_files) {
  gt <- read.csv(f, colClasses = c(paper_id = "character"),
                 stringsAsFactors = FALSE)
  
  n_already_present <- if ("data_format_gt" %in% names(gt))
    sum(!is.na(gt$data_format_gt)) else 0L
  
  # Backfill: only fill missing values (idempotent)
  ext_vec <- tolower(tools::file_ext(gt$rel_path))
  new_fmt  <- ifelse(gt$type_gt == "data", classify_data_format(ext_vec), NA_character_)
  
  if ("data_format_gt" %in% names(gt)) {
    gt$data_format_gt <- ifelse(is.na(gt$data_format_gt), new_fmt, gt$data_format_gt)
  } else {
    gt$data_format_gt <- new_fmt
  }
  
  write.csv(gt, f, row.names = FALSE)
  
  # Append summary row
  paper_id  <- unique(gt$paper_id)[1]
  data_rows <- gt[!is.na(gt$type_gt) & gt$type_gt == "data", ]
  summary_row <- data.frame(
    paper_id          = paper_id,
    n_data_rows       = nrow(data_rows),
    n_tabular         = sum(data_rows$data_format_gt == "tabular", na.rm = TRUE),
    n_raw             = sum(data_rows$data_format_gt == "raw",     na.rm = TRUE),
    n_already_present = n_already_present,
    stringsAsFactors  = FALSE
  )
  write.table(summary_row, SUMMARY_OUT,
              sep = ",", col.names = !file.exists(SUMMARY_OUT),
              row.names = FALSE, append = TRUE)
}
```

---

### Step 8 — Create `runners/audit_ground_truth_data_format.R`

New file. Scans all ground truth files and collects every `type_gt == "data"` entry with a raw-format extension.

```
source("pipeline/helper.R")

GT_DIR    <- "ground_truth"
AUDIT_OUT <- "results/ground_truth_audit_report.csv"

RAW_EXTS  <- RAW_EXTENSIONS   # from helper.R

gt_files <- list.files(GT_DIR, pattern = "\\.csv$", full.names = TRUE)
rows <- list()

for (f in gt_files) {
  gt  <- read.csv(f, colClasses = c(paper_id = "character"),
                  stringsAsFactors = FALSE)
  ext <- tolower(tools::file_ext(gt$rel_path))
  
  flagged <- gt[
    !is.na(gt$type_gt) & gt$type_gt == "data" & ext %in% RAW_EXTS,
  ]
  
  if (nrow(flagged) > 0) {
    flagged$ext              <- ext[!is.na(gt$type_gt) & gt$type_gt == "data" & ext %in% RAW_EXTS]
    flagged$data_format_gt   <- "raw"
    rows[[length(rows) + 1]] <- flagged[, c("paper_id","rel_path","ext","type_gt","data_format_gt")]
  }
}

report <- do.call(rbind, rows)
report <- report[order(report$paper_id, report$rel_path), ]
write.csv(report, AUDIT_OUT, row.names = FALSE)
message("Audit complete: ", nrow(report), " flagged entries across ",
        length(unique(report$paper_id)), " papers.")
```

---

### Step 9 — Update `pipeline/3_psychds_convert.R`

**Location**: Inside the data file processing loop, near line 663.

After the existing size check and before the column conversion logic, add a `data_format` routing guard:

```r
# Route raw-format data files to data/raw/ only — skip column conversion
is_raw <- !is.null(row$data_format) &&
          !is.na(row$data_format) &&
          row$data_format == "raw"

if (is_raw) {
  raw_dest <- file.path(out_dir, "data", "raw", filename)
  if (file.exists(src_path)) file.copy(src_path, raw_dest, overwrite = TRUE)
  n_raw_files <- n_raw_files + 1L
  next
}
```

The `!is.null(row$data_format)` guard ensures backward compatibility with old `structure.csv` files that lack the column — those files fall through to the existing conversion path.

---

### Step 10 — Update `tools/validation_gui/app.R`

**Badge display**: After the type badge render near line 1042, add a conditional `data_format` badge:

```r
if (!is.null(row$data_format) && !is.na(row$data_format) && row$type == "data")
  tags$span(
    class = paste0("tbadge-df-", row$data_format),
    row$data_format
  )
```

**CSS additions** (after existing `.tbadge-output` rules, light theme):
```css
.tbadge-df-tabular { background:#f1f8e9; color:#558b2f; font-size:0.76em; padding:1px 6px; }
.tbadge-df-raw     { background:#fff3e0; color:#e65100; font-size:0.76em; padding:1px 6px; }
```

**Dark theme**:
```css
[data-theme='dark'] .tbadge-df-tabular { background:rgba(139,195,74,0.18); color:#aed581; }
[data-theme='dark'] .tbadge-df-raw     { background:rgba(255,152,0,0.18);  color:#ffcc80; }
```

---

### Step 11 — Update documentation

**`docs/output-schemas.md`**:
- Add `data_format` row to the `structure.csv` schema table (after `is_sentinel`)
- Add `n_tabular_files` row to the `bulk_summary.csv` schema table (after `n_data_files`)
- Add `ground_truth_repair_summary.csv` and `ground_truth_audit_report.csv` as new sections

**`docs/pipeline.md`**:
- Update processing step 6 ("Read data heads…"): add note that only `data_format = "tabular"` files are processed
- Add `n_tabular_files` to the constants/columns table
- Add note about the pre-rerun ground truth repair workflow

---

## Implementation Order

The steps have the following dependency chain:

```
Step 1 (helper.R: classify_data_format)
  └─► Step 2 (0_index.R: assign data_format)
        └─► Step 3 (0_index.R: gate extraction)
        └─► Step 4 (0_index.R: structure.csv write)
        └─► Step 5 (0_index.R: n_tabular_files)
  └─► Step 7 (repair runner — needs classify_data_format)
  └─► Step 8 (audit runner  — needs RAW_EXTENSIONS from helper)
Step 6 (prompts.R) — independent
Step 9 (psychds)   — independent; reads data_format from structure.csv
Step 10 (GUI)      — independent; reads data_format from structure.csv
Step 11 (docs)     — last; documents final state
```

**Recommended execution order**: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11

---

## Testing Plan

1. **Unit test `classify_data_format()`**: call with known extensions, verify lookup and fallback.
2. **Run `run_tests.R`** after Steps 1-6: verify no regression in test paper classification accuracy; verify `.mat` hard-case rule improves or maintains accuracy.
3. **Smoke test repair runner** (Step 7): run on one ground truth file, verify `data_format_gt` column added, values correct, idempotent on second run.
4. **Smoke test audit runner** (Step 8): run on all ground truth files, verify report contains only raw-format `data`-typed entries.
5. **End-to-end test** (Steps 2-5): run `run_index()` on the eye-tracking paper from the error log, verify `columns.csv` contains zero rows sourced from `.mp4` files.
6. **Backward compat test** (Step 9): load a pre-fix `structure.csv` (lacking `data_format` column) into PsychDS conversion; verify no crash.

---

## Complexity Tracking

No constitution violations. No complexity justified beyond spec.
