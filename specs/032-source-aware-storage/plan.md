# Implementation Plan: Source-Aware Storage Paths

**Branch**: `032-source-aware-storage` | **Date**: 2026-04-08 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/specs/032-source-aware-storage/spec.md`

## Summary

Refactor every storage path in the pipeline from flat `<layer>/<paper_id>/` to `<layer>/<source>/<paper_id>/`. A new centralized `paper_path(layer, source, paper_id, ...)` helper in `helper.R` becomes the single path-construction site, satisfying the futureproofing requirement (SC-003: new source requires changes in one place). Ground-truth is OSF-only; `test_papers.csv` gains an explicit `source` column; `psychds/conversion_summary.csv` stays unified. Twelve files require path-logic changes.

## Technical Context

**Language/Version**: R (base R only — no new packages per constitution)  
**Primary Dependencies**: `haven`, `readxl`, `jsonlite`, `xml2`, `metacheck` — all already installed  
**Storage**: Local filesystem; CSV files; directory trees under `data/`, `outputs/`, `psychds/`, `ground_truth/`  
**Testing**: `runners/run_tests.R` + `runners/report_tests.R`  
**Target Platform**: macOS / Linux local filesystem  
**Project Type**: Data pipeline (scripted R)  
**Performance Goals**: None new — this is a structural refactor  
**Constraints**: Must not break existing OSF pipeline; migration of existing data is out of scope  
**Scale/Scope**: ~400 OSF papers in `data/`; ~10 test papers; ~25 ground-truth files

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I — Crash Resilience | ✅ Pass | Refactor changes paths only; append-after-each-paper pattern preserved |
| II — Paper ID Preservation | ✅ Pass | `test_papers.csv` `id` column must keep `colClasses = c(id = "character")`; new `source` column read as character too |
| III — Resource Limits | ✅ Pass | No resource limit changes |
| IV — Centralised Helpers | ⚠️ Requires Action | New `paper_path()` and `sanitize_id()` helpers MUST go in `helper.R`. `GROUND_TRUTH_DIR` must be added as a shared constant. Constitution amendment (MINOR, 1.3.1 → 1.4.0) needed to register these additions. |
| V — Structured Error Codes | ✅ Pass | FR-012 (legacy path warning) uses `warning()`, not a new error code |

**Constitution Amendment Required**: Principle IV's helper list and Key Constants table must be updated in `constitution.md` (MINOR bump: 1.3.1 → 1.4.0) to register `paper_path()`, `sanitize_id()`, `list_downloaded_papers()`, and `GROUND_TRUTH_DIR`.

## Project Structure

### Documentation (this feature)

```text
specs/032-source-aware-storage/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (files changed)

```text
pipeline/
├── helper.R             # ADD: paper_path(), sanitize_id(), list_downloaded_papers()
│                        #      UPDATE: apply_ground_truth(source, paper_id)
│                        #      UPDATE: hardcoded outputs path at line 12
├── 0_index.R            # UPDATE: DATA_DIR/OUTPUT_DIR constants → source-aware paths
│                        #         ADD: GROUND_TRUTH_DIR constant
│                        #         UPDATE: target_dir construction
│                        #         UPDATE: output_dir per-paper
├── 2_codebook_label.R   # UPDATE: OUTPUT_DIR usage for per-paper paths
└── 3_psychds_convert.R  # UPDATE: PSYCHDS_OUT_DIR per-paper paths (lines 491-493, 1010, 1062, 1084)
                         #         UPDATE: apply_ground_truth call (add source arg)

runners/
├── run_0_index_bulk.R   # UPDATE: paper discovery (list_downloaded_papers() replaces list.dirs)
│                        #         UPDATE: GT_DIR → paper_path("ground_truth", ...)
│                        #         UPDATE: columns.csv path construction
├── run_single.R         # UPDATE: OUTPUT_DIR paths
├── run_psychds_bulk.R   # UPDATE: per-paper psychds path construction
├── run_dataverse_bulk.R # UPDATE: per-paper path construction
├── run_tests.R          # UPDATE: read source column from test_papers.csv
│                        #         UPDATE: gt_path construction
│                        #         UPDATE: PSYCHDS_OUT_DIR override pattern
├── run_test_validation_gui.R  # UPDATE: dc_gt_dir to osf-scoped path
└── download_all_osf.R   # UPDATE: DATA_DIR path → data/osf/

reports/
└── report_normal.R      # UPDATE: GT_DIR reference

tools/validation_gui/
├── app.R                # UPDATE: filter paper list to OSF-only (source == "osf")
│                        #         UPDATE: output CSV paths to outputs/osf/<id>/
└── gt_store.R           # UPDATE: ground_truth root to ground_truth/osf/

tests/
└── test_papers.csv      # ADD: source column (all existing rows → "osf")

ground_truth/
└── osf/                 # NEW subdirectory: existing *.csv files moved here

docs/
├── pipeline.md          # UPDATE: step 10 path in processing order; constants table
└── output-schemas.md    # UPDATE: any path references

.specify/memory/
└── constitution.md      # MINOR bump 1.3.1 → 1.4.0: add paper_path/sanitize_id/
                         # list_downloaded_papers to Principle IV; add GROUND_TRUTH_DIR
                         # to Key Constants table; update path in Processing Order step 10
```

**Structure Decision**: Single R project; no new packages; all new code added to existing files per Principle IV.

## Phase 0: Research

*See [research.md](research.md) for full findings.*

Key decisions resolved:

1. **DOI sanitization**: replace `:` → `-` and `/` → `_` in `sanitize_id()`. Applied only at path-construction time; original ID stored unmodified in all CSV output columns.
2. **Touchpoint inventory**: 12 files require changes (listed above in Project Structure).
3. **Bulk paper discovery**: `list_downloaded_papers()` replaces `list.dirs(DATA_DIR, ...)` in bulk runners — scans each registered `data/<source>/` subdirectory, returns a data frame with `source` and `paper_id` columns.
4. **`apply_ground_truth` signature**: `apply_ground_truth(structure_df, source, paper_id)` — adds `source` parameter; constructs GT path via `paper_path("ground_truth", source, paper_id)`.
5. **`GROUND_TRUTH_DIR` constant**: Added alongside `DATA_DIR`, `OUTPUT_DIR`, `PSYCHDS_OUT_DIR` in `0_index.R` as `"./data_check/ground_truth"`.
6. **`psychds/conversion_summary.csv`**: Stays unified (flat); per-paper artifacts namespaced under `psychds/<source>/<id>/`.
7. **`test_papers.csv` schema**: `id, source, label` — new `source` column, all existing rows get `source = "osf"`.
8. **Ground-truth migration**: Existing `ground_truth/*.csv` files moved to `ground_truth/osf/*.csv` as a one-time step in the implementation.
9. **Validation GUI scope**: OSF-only; filter paper list by `source == "osf"` when loading from bulk summary.

## Phase 1: Design & Contracts

*See [data-model.md](data-model.md) for full entity and path model.*

### Core abstraction: `paper_path()`

The single path-construction function added to `helper.R`:

```r
# Central path resolver.
# layer:    "data" | "outputs" | "psychds" | "ground_truth"
# source:   registered source identifier — "osf" | "dataverse"
# paper_id: source-specific identifier (sanitized for filesystem use)
# ...:      optional additional path components passed to file.path()
paper_path <- function(layer, source, paper_id, ...) {
  KNOWN_SOURCES <- c("osf", "dataverse")
  if (!source %in% KNOWN_SOURCES)
    stop(sprintf("paper_path: unknown source '%s'. Valid: %s",
                 source, paste(KNOWN_SOURCES, collapse = ", ")))
  root <- switch(layer,
    data         = DATA_DIR,
    outputs      = OUTPUT_DIR,
    psychds      = PSYCHDS_OUT_DIR,
    ground_truth = GROUND_TRUTH_DIR,
    stop(sprintf("paper_path: unknown layer '%s'", layer))
  )
  file.path(root, source, sanitize_id(paper_id), ...)
}

sanitize_id <- function(id) {
  # Make a source-specific ID safe for filesystem paths.
  # Converts DOIs like "doi:10.7910/DVN/ABC123" → "doi-10.7910_DVN_ABC123"
  gsub("/", "_", gsub(":", "-", as.character(id)))
}
```

### `list_downloaded_papers()` helper

Replaces ad-hoc `list.dirs(DATA_DIR, ...)` in bulk runners:

```r
# Returns a data.frame with columns: source (character), paper_id (character)
# by scanning data/<source>/ subdirectories for all registered sources.
list_downloaded_papers <- function() {
  KNOWN_SOURCES <- c("osf", "dataverse")
  rows <- lapply(KNOWN_SOURCES, function(src) {
    src_dir <- file.path(DATA_DIR, src)
    if (!dir.exists(src_dir)) return(NULL)
    ids <- list.dirs(src_dir, full.names = FALSE, recursive = FALSE)
    if (length(ids) == 0L) return(NULL)
    data.frame(source = src, paper_id = ids,
               stringsAsFactors = FALSE)
  })
  do.call(rbind, Filter(Negate(is.null), rows))
}
```

### Updated `apply_ground_truth` signature

```r
# Old: apply_ground_truth(structure_df, paper_id)
# New: apply_ground_truth(structure_df, source, paper_id)
apply_ground_truth <- function(structure_df, source, paper_id) {
  ...
  gt_path <- paper_path("ground_truth", source, paper_id)
  gt_path <- paste0(gt_path, ".csv")   # ground_truth/osf/<id>.csv
  ...
}
```

All callers (`3_psychds_convert.R:1032`) must pass `source`.

### Key constant additions in `0_index.R`

```r
DATA_DIR          <- "./data_check/data"
OUTPUT_DIR        <- "./data_check/outputs"
PSYCHDS_OUT_DIR   <- "./data_check/psychds"
GROUND_TRUTH_DIR  <- "./data_check/ground_truth"   # NEW
# DATAVERSE_DATA_DIR removed — subsumed by paper_path("data", "dataverse", id)
```

### Legacy-path warning (FR-012)

Added in `0_index.R` after `target_dir` is resolved:

```r
legacy_path <- file.path(DATA_DIR, paper_id)   # old flat path
if (!dir.exists(target_dir) && dir.exists(legacy_path)) {
  warning(sprintf(
    "Legacy data found at '%s' but expected source-aware path '%s' does not exist. ",
    legacy_path, target_dir
  ))
}
```

### Validation GUI changes (`app.R`)

After loading papers from bulk summary, filter to OSF-only:

```r
papers <- bulk[bulk$source == "osf", ]
```

Output CSVs and GT paths resolved via `paper_path()` rather than hardcoded `outputs/<id>/`.

### No external interface contracts

This feature has no public APIs, REST endpoints, or inter-system contracts. All interfaces are internal R function signatures.

## Implementation Order

Tasks must be completed in this order to avoid broken intermediate states:

1. **Add helpers to `helper.R`** — `paper_path()`, `sanitize_id()`, `list_downloaded_papers()`, updated `apply_ground_truth()` signature. All other changes depend on this.
2. **Update constants in `0_index.R`** — add `GROUND_TRUTH_DIR`, remove `DATAVERSE_DATA_DIR`, wire all per-paper paths through `paper_path()`.
3. **Update `pipeline/2_codebook_label.R`** — output paths via `paper_path()`.
4. **Update `pipeline/3_psychds_convert.R`** — psychds per-paper paths via `paper_path()`; update `apply_ground_truth` call.
5. **Update bulk runners** (`run_0_index_bulk.R`, `run_psychds_bulk.R`, `run_dataverse_bulk.R`, `run_single.R`, `download_all_osf.R`) — switch paper discovery to `list_downloaded_papers()`; use `paper_path()`.
6. **Update test infrastructure** (`test_papers.csv`, `run_tests.R`, `run_test_validation_gui.R`) — add `source` column; update GT paths.
7. **Migrate ground-truth files** — move `ground_truth/*.csv` → `ground_truth/osf/*.csv`.
8. **Update validation GUI** (`app.R`, `gt_store.R`) — OSF filter; source-aware paths.
9. **Update reporting** (`reports/report_normal.R`) — GT_DIR reference.
10. **Update docs** (`docs/pipeline.md`, `docs/output-schemas.md`) — path references in processing order and constants table.
11. **Update constitution** (`constitution.md`) — MINOR bump 1.3.1 → 1.4.0.
12. **Run tests** — `runners/run_tests.R` then `runners/report_tests.R`.
