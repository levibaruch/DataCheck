# Implementation Plan: Harvard Dataverse Source Support

**Branch**: `031-dataverse-source-support` | **Date**: 2026-04-08 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `specs/031-dataverse-source-support/spec.md`

## Summary

Extend the pipeline to process Harvard Dataverse deposits stored at `data_check/data/dataverse/<doi_slug>/`. The core change is source detection in `run_index()` — Dataverse IDs (prefix `doi_`) skip the download/XML stage and read from the `dataverse/` subdirectory. A new bulk runner iterates over all deposits. The `source` column is added to `bulk_summary.csv`. The psychDS converter's hardcoded `platform = "osf"` is made dynamic. The Validation GUI filters out Dataverse IDs.

## Technical Context

**Language/Version**: R (base R only — no new packages)  
**Primary Dependencies**: `metacheck` (`llm_batch()`), `haven`, `readxl`, `jsonlite`, `xml2` — all already installed  
**Storage**: CSV files on local filesystem; `data_check/data/dataverse/`, `data_check/outputs/`, `data_check/psychds/`  
**Testing**: `runners/run_tests.R` + `runners/report_tests.R`; manual smoke-test with one Dataverse deposit  
**Target Platform**: macOS local machine (same as existing pipeline)  
**Project Type**: CLI pipeline / batch processing scripts  
**Performance Goals**: No additional latency targets — same per-paper LLM/column budgets as OSF  
**Constraints**: No new packages; base R only; all existing Principles I–V apply  
**Scale/Scope**: 457 Dataverse deposits in initial corpus

## Constitution Check

| Principle | Status | Notes |
|---|---|---|
| I — Crash Resilience | ✅ Pass | New Dataverse bulk runner uses append-after-each-paper pattern; auto-resumes from `bulk_summary.csv` |
| II — Paper ID Preservation | ✅ Pass | DOI slugs stored as character throughout; all `read.csv()` calls preserve `colClasses = c(paper_id = "character")` |
| III — Resource Limits | ✅ Pass | No download stage for Dataverse; LLM call caps unchanged; `too_large` still enforced for path count |
| IV — Centralised Helpers | ✅ Pass | `is_dataverse_id()` added to `helper.R`; no new LLM prompts; no logic duplicated across scripts |
| V — Structured Error Codes | ✅ Pass | New code `dataverse_dir_missing` registered before merge; `empty_repo` reused for empty deposits |

## Project Structure

### Documentation (this feature)

```text
specs/031-dataverse-source-support/
├── plan.md              # This file
├── research.md          # Phase 0 — integration decisions
├── data-model.md        # Phase 1 — schema changes, constants, directory layout
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created here)
```

### Source Code (affected files)

```text
pipeline/
├── helper.R                    # ADD is_dataverse_id() helper
├── 0_index.R                   # MODIFY source routing, target_dir, return value, new error code
└── 3_psychds_convert.R         # MODIFY build_dataset_description() — dynamic platform/download_path

runners/
├── run_0_index_bulk.R          # MODIFY make_summary_row() — add source = "osf"
└── run_dataverse_bulk.R        # NEW — Dataverse bulk runner

tools/validation_gui/
└── gt_store.R                  # MODIFY discover_papers() — exclude doi_ prefixed IDs

docs/
├── output-schemas.md           # ADD source column, dataverse_dir_missing error code
└── pipeline.md                 # ADD Dataverse flow, DATAVERSE_DATA_DIR constant
```

## Implementation Tasks

### Task 1 — Add `is_dataverse_id()` helper to `helper.R`

**File**: `pipeline/helper.R`  
**Type**: Addition  
**Constitution**: Principle IV

Add after the existing paper_output_dir helper (around line 6):

```r
# Returns TRUE if paper_id is a Harvard Dataverse DOI slug.
# OSF paper IDs are always numeric strings; they never start with "doi_".
is_dataverse_id <- function(paper_id) {
  startsWith(as.character(paper_id), "doi_")
}
```

**Test**: `is_dataverse_id("doi_10.7910_DVN_0QEUU5")` → TRUE; `is_dataverse_id("0956797615569001")` → FALSE.

---

### Task 2 — Add `DATAVERSE_DATA_DIR` constant to `0_index.R`

**File**: `pipeline/0_index.R`  
**Type**: Addition (constants block)

Add after `DATA_DIR` (around line 23):

```r
DATAVERSE_DATA_DIR  <- file.path(DATA_DIR, "dataverse")
```

---

### Task 3 — Add Dataverse routing to `run_index()`

**File**: `pipeline/0_index.R`  
**Type**: Modify

**Where**: In `run_index()`, after `eff_dir` is resolved (around line 92) and before `target_dir` is set (line 93).

Replace:
```r
target_dir <- file.path(DATA_DIR, paper_id)
```

With:
```r
is_dv      <- is_dataverse_id(paper_id)
target_dir <- if (is_dv) file.path(DATAVERSE_DATA_DIR, paper_id)
              else       file.path(DATA_DIR, paper_id)
```

**Where**: In `run_index()`, at the top of the `else` branch (the non-COLUMNS_ONLY path, around line 112), add a Dataverse guard before the download block:

```r
  if (is_dv) {
    # ── Dataverse: skip download; verify directory exists ──────────────────
    if (!dir.exists(target_dir))
      stop("dataverse_dir_missing: no directory found at ", target_dir,
           " for deposit ", paper_id)
    t_download <- 0
    message("── Dataverse deposit: skipping download, reading from ", target_dir)
  } else {
    # existing OSF download block (lines 114–131) goes here unchanged
    t_download_start <- proc.time()[["elapsed"]]
    if (download) {
      ...
    }
    ...
  }
```

**Where**: In `run_index()` return list (around line 1103), add:

```r
source         = if (is_dv) "dataverse" else "osf",
```

---

### Task 4 — Add `source` to `make_summary_row()` in `run_0_index_bulk.R`

**File**: `runners/run_0_index_bulk.R`  
**Type**: Modify  
**Where**: `make_summary_row()` (line 134)

Add `source` field at end of `data.frame(...)`:

```r
source          = na_fallback(r$source, "osf"),
```

Also update the two inline failure-stub `list(...)` objects (lines ~224 and ~242) to include `source = "osf"`.

---

### Task 5 — Create `runners/run_dataverse_bulk.R`

**File**: `runners/run_dataverse_bulk.R`  
**Type**: New file  
**Constitution**: Principle I (crash-resilient), II (character paper_id), V (structured errors)

Structure mirrors `run_0_index_bulk.R`:

```r
# run_dataverse_bulk.R
# ─────────────────────────────────────────────────────────────────────────────
# Batch-index all Harvard Dataverse deposits in data_check/data/dataverse/.
# Crash-resilient: appends one row per deposit to results/bulk_summary.csv
# immediately after each paper. Auto-resumes on restart.
#
# Usage:
#   Rscript data_check/runners/run_dataverse_bulk.R
# ─────────────────────────────────────────────────────────────────────────────

source("data_check/pipeline/helper.R")
source("data_check/pipeline/0_index.R")

SUMMARY_CSV <- "./data_check/results/bulk_summary.csv"
if (!exists("RESUME"))   RESUME   <- TRUE
if (!exists("FULL_RUN")) FULL_RUN <- FALSE

# 1. Discover all deposit directories
dataverse_root <- DATAVERSE_DATA_DIR
if (!dir.exists(dataverse_root))
  stop("Dataverse data root not found: ", dataverse_root)

all_ids <- list.dirs(dataverse_root, full.names = FALSE, recursive = FALSE)
all_ids <- all_ids[nzchar(all_ids)]
if (length(all_ids) == 0) stop("No deposits found in ", dataverse_root)
message("Total Dataverse deposits: ", length(all_ids))

# 2. Auto-resume: skip IDs already in bulk_summary.csv
done_ids <- character(0)
if (RESUME && file.exists(SUMMARY_CSV)) {
  prior <- tryCatch(
    read.csv(SUMMARY_CSV, stringsAsFactors = FALSE,
             colClasses = c(paper_id = "character")),
    error = function(e) NULL
  )
  if (!is.null(prior) && "paper_id" %in% names(prior))
    done_ids <- unique(as.character(prior$paper_id))
  message("Already processed: ", length(intersect(all_ids, done_ids)), " — skipping")
}
remaining_ids <- setdiff(all_ids, done_ids)
message("Remaining: ", length(remaining_ids), " / ", length(all_ids))

if (length(remaining_ids) == 0) {
  message("All deposits already processed.")
  invisible(NULL)
}

# 3. Process each deposit
n_ok <- 0L; n_err <- 0L

for (i in seq_along(remaining_ids)) {
  pid <- remaining_ids[i]
  cat(sprintf("[%d/%d] %s ... ", i, length(remaining_ids), pid))

  r <- tryCatch(
    run_index(paper_id = pid, download = FALSE),
    error = function(e) {
      list(paper_id = pid, success = FALSE,
           error = conditionMessage(e),
           source = "dataverse",
           elapsed_sec = NA_real_, download_sec = 0,
           llm_sec = NA_real_, column_sec = NA_real_,
           n_files = NA_integer_, n_data_files = NA_integer_,
           n_tabular_files = NA_integer_, n_agg_dirs = NA_integer_,
           n_individual = NA_integer_, n_combined = NA_integer_,
           n_columns = NA_integer_, n_source_files = NA_integer_)
    }
  )

  # Write row immediately (Principle I)
  row <- data.frame(
    paper_id        = as.character(r$paper_id),
    run_at          = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    success         = isTRUE(r$success),
    error           = if (is.null(r$error)) NA_character_ else r$error,
    elapsed_ms      = round(if (is.null(r$elapsed_sec))  NA_real_ else r$elapsed_sec  * 1000),
    download_ms     = 0L,
    llm_ms          = round(if (is.null(r$llm_sec))      NA_real_ else r$llm_sec      * 1000),
    column_ms       = round(if (is.null(r$column_sec))   NA_real_ else r$column_sec   * 1000),
    n_files         = if (is.null(r$n_files))         NA_integer_ else r$n_files,
    n_data_files    = if (is.null(r$n_data_files))    NA_integer_ else r$n_data_files,
    n_tabular_files = if (is.null(r$n_tabular_files)) NA_integer_ else r$n_tabular_files,
    n_agg_dirs      = if (is.null(r$n_agg_dirs))      NA_integer_ else r$n_agg_dirs,
    n_individual    = if (is.null(r$n_individual))    NA_integer_ else r$n_individual,
    n_combined      = if (is.null(r$n_combined))      NA_integer_ else r$n_combined,
    n_columns       = if (is.null(r$n_columns))       NA_integer_ else r$n_columns,
    n_src_files     = if (is.null(r$n_source_files))  NA_integer_ else r$n_source_files,
    source          = "dataverse",
    stringsAsFactors = FALSE
  )
  write_header <- !file.exists(SUMMARY_CSV)
  write.table(row, SUMMARY_CSV, append = TRUE, sep = ",",
              row.names = FALSE, col.names = write_header,
              quote = TRUE)

  if (isTRUE(r$success)) {
    n_ok <- n_ok + 1L
    cat("OK\n")
  } else {
    n_err <- n_err + 1L
    cat(sprintf("FAILED: %s\n", r$error))
  }
}

message("─────────────────────────────────────────────────────")
message(sprintf("Dataverse bulk complete: %d OK, %d failed", n_ok, n_err))
message(sprintf("Results written to: %s", SUMMARY_CSV))
```

---

### Task 6 — Filter Dataverse IDs from Validation GUI

**File**: `tools/validation_gui/gt_store.R`  
**Type**: Modify  
**Where**: `discover_papers()`, after `dirs` is populated (line 55)

Add one line before the `has_structure` filter:

```r
dirs <- dirs[!startsWith(dirs, "doi_")]   # exclude Dataverse deposits
```

---

### Task 7 — Fix `build_dataset_description()` in `3_psychds_convert.R`

**File**: `pipeline/3_psychds_convert.R`  
**Type**: Modify

**Step 7a** — Add `source` parameter to `build_dataset_description()` (line 411):

```r
build_dataset_description <- function(paper_id, study_group, property_values,
                                      xml_meta, bulk_row,
                                      shared_files = NULL,
                                      source = "osf") {   # NEW param
```

**Step 7b** — Replace hardcoded `platform = "osf"` block (lines 487–490):

```r
desc[["metacheck:source_repository"]] <- list(
  platform      = source,
  download_path = if (source == "dataverse")
                    paste0("data/dataverse/", paper_id, "/")
                  else
                    paste0("data/", paper_id, "/")
)
```

**Step 7c** — In `convert_psychds()`, derive `source` before calling `convert_study()` (after line 1040):

```r
# Derive source — prefer bulk_summary.csv value, fallback to ID pattern
paper_source <- if (!is.null(paper_row) && "source" %in% names(paper_row) &&
                    !is.na(paper_row$source[1]))
                  paper_row$source[1]
                else if (is_dataverse_id(paper_id)) "dataverse"
                else "osf"
```

**Step 7d** — Pass `source = paper_source` through `convert_study()` → `build_dataset_description()` call chain. `convert_study()` signature gains `source = "osf"` parameter; it passes it to `build_dataset_description()`.

---

### Task 8 — Update docs

**Files**: `docs/output-schemas.md`, `docs/pipeline.md`

**output-schemas.md**:
- Add `source` column to `bulk_summary.csv` schema table (values: `"osf"`, `"dataverse"`)
- Add `dataverse_dir_missing` to error codes table

**pipeline.md**:
- Add `DATAVERSE_DATA_DIR` to constants table
- Add Dataverse flow note to the processing order section (step 1a: for Dataverse IDs, skip steps 1–3, read from `DATAVERSE_DATA_DIR`)
- Add `run_dataverse_bulk.R` to Entry Points table

---

## Testing Checklist

- [ ] `is_dataverse_id("doi_10.7910_DVN_0QEUU5")` returns TRUE
- [ ] `is_dataverse_id("0956797615569001")` returns FALSE
- [ ] `run_index(paper_id = "doi_10.7910_DVN_0QEUU5", download = FALSE)` produces `outputs/doi_10.7910_DVN_0QEUU5/structure.csv` and `columns.csv`
- [ ] `run_index()` for a valid OSF paper ID is unchanged in output and behavior
- [ ] `run_index()` with a missing Dataverse dir stops with error code `dataverse_dir_missing`
- [ ] `bulk_summary.csv` rows from OSF runner have `source = "osf"`
- [ ] `bulk_summary.csv` rows from Dataverse runner have `source = "dataverse"`
- [ ] Dataverse bulk runner auto-resumes correctly on restart (no duplicate rows)
- [ ] Validation GUI paper selector shows zero `doi_` prefixed IDs
- [ ] psychDS output for a Dataverse deposit has `"platform": "dataverse"` and `"download_path": "data/dataverse/doi_.../"`
- [ ] psychDS output for an OSF deposit is unchanged (`"platform": "osf"`)
- [ ] Existing OSF papers in `run_tests.R` all pass after changes
- [ ] `docs/output-schemas.md` documents `source` column and `dataverse_dir_missing`
