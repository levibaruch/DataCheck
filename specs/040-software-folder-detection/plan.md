# Implementation Plan: Software Folder Bulk Detection

**Branch**: `040-software-folder-detection` | **Date**: 2026-04-21 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/040-software-folder-detection/spec.md`

## Summary

Add a rule-based pre-classification gate in `0_index.R` that detects folders whose basename matches a known software package directory name (e.g. `node_modules`, `site-packages`, `renv`) AND contains ≥ 500 files recursively. All files under detected folders are bulk-labeled as `type = "software"` with `type_source = "rule_folder"` — no LLM calls made. A safety gate skips folders where the majority of files have recognized data extensions (CSV, SAV, etc.), preventing false positives.

## Technical Context

**Language/Version**: R 4.5 (base R only — no new packages)
**Primary Dependencies**: `helper.R` (`classify_by_rules()`), `0_index.R` (constants, `run_index()`)
**Storage**: CSV files — `outputs/<source>/<id>/structure.csv` (existing schema, new `type_source` value)
**Testing**: `runners/run_tests.R` + `runners/report_tests.R`; manual spot-check on psychopy paper (74kqe)
**Target Platform**: Local filesystem (macOS/Linux)
**Project Type**: Pipeline library (internal R scripts)
**Performance Goals**: Zero LLM calls for software-folder files; detection overhead negligible vs. download time
**Constraints**: Base R only; no new packages; new constants follow existing naming convention
**Scale/Scope**: Single-paper and bulk-runner contexts

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Crash Resilience | ✅ Pass | No change to output-writing logic |
| II. Paper ID Preservation | ✅ Pass | No change to paper_id handling |
| III. Resource Limits | ✅ Pass | Feature reduces LLM calls; no limits bypassed |
| IV. Centralised Helpers | ✅ Pass | New `detect_software_folders()` → `helper.R`; new constants → `0_index.R`; no prompts (rule-based) |
| V. Structured Error Classification | ✅ Pass | No new error modes; existing `too_large` still fires if clean_rel_paths still exceeds cap |
| VI. Source-Aware Storage | ✅ Pass | No new paths; outputs still written via `paper_path()` |

## Project Structure

### Documentation (this feature)

```text
specs/040-software-folder-detection/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (modified files only)

```text
pipeline/
├── 0_index.R            # Add constants + step 4.5 (detect_software_folders call)
└── helper.R             # Add detect_software_folders() function

docs/
├── output-schemas.md    # Add "rule_folder" to type_source vocabulary
└── pipeline.md          # Update processing order diagram (add step 4.5)
```

## Implementation Phases

### Phase A — Helper Function (`helper.R`)

Add `detect_software_folders(rel_paths, target_dir, threshold, patterns)` to `helper.R`.

**Logic**:
1. Extract all unique directory segments from `rel_paths` (split each path by `/`, collect all but final component)
2. Find candidate folders: unique dir segments whose `tolower(basename())` exactly matches any pattern
3. Sort candidates by path depth ascending (fewest `/` = outermost first)
4. For each candidate (greedy outermost-wins):
   - Collect unclaimed rel_paths where the folder prefix matches
   - If count < threshold: skip
   - Extension majority check: if >50% of unclaimed collected files have data extensions → skip
   - Claim: add to software map, remove from unclaimed pool
5. Return `list(software_rel_paths, software_folder_map, clean_rel_paths)`

**Data extensions for majority check** (case-insensitive):
`csv`, `tsv`, `txt`, `dat`, `xlsx`, `xls`, `sav`, `dta`, `sas7bdat`, `rds`, `rda`, `rdata`

**Logging**: Print detected software folders and file counts using the existing `col_cyan`/`col_dim` pattern, matching the aggregate detection log style.

---

### Phase B — Constants and Integration (`0_index.R`)

**Add constants** (alongside `AGGREGATE_THRESHOLD`):

```r
SOFTWARE_FOLDER_THRESHOLD <- 500L
SOFTWARE_FOLDER_PATTERNS  <- c(
  "node_modules", "vendor", "renv", "site-packages",
  "__pycache__", "venv", ".venv", "libs", "lib", "dist", "build"
)
```

**Add step 4.5** between step 4 (build rel_paths) and step 5 (aggregate detection):

```r
# ── 4.5. Detect software package folders ────────────────────────────────────
sw <- detect_software_folders(rel_paths, target_dir,
                              SOFTWARE_FOLDER_THRESHOLD,
                              SOFTWARE_FOLDER_PATTERNS)
rel_paths <- sw$clean_rel_paths   # software paths removed before aggregate detection
```

**Build software_rows_df** when constructing `file_df` (before the existing aggregate + LLM row construction):
- One row per path in `sw$software_rel_paths`
- Columns: paper_id, path, rel_path, filename, ext, type="software", type_source="rule_folder", group=NA, aggregate_folder=sw$software_folder_map[rel_path], data_granularity=NA, granularity_source=NA, prompt_nr=NA, data_format=NA

**rbind into file_df** alongside existing aggregate and LLM rows.

---

### Phase C — Documentation

- `docs/output-schemas.md`: Add `"rule_folder"` to the `type_source` vocabulary table
- `docs/pipeline.md`: Add step 4.5 to the processing order description; add `SOFTWARE_FOLDER_THRESHOLD` and `SOFTWARE_FOLDER_PATTERNS` to the constants table

---

### Phase D — Testing

- Run `runners/run_tests.R` (existing test suite)
- Manual spot-check: run on the psychopy paper (`74kqe`) — confirm `site-packages` subtree is labeled `software` / `rule_folder` and paper completes without `too_large`
- Verify a paper with no software folders produces identical results to pre-feature baseline

## Complexity Tracking

No constitution violations. No complexity justification required.
