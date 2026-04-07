# Tasks: Data Format Sub-classification (Tabular vs Raw)

**Input**: Design documents from `specs/028-data-format-subtype/`  
**Branch**: `028-data-format-subtype`

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel with other [P] tasks (no shared file dependencies)
- **[USN]**: Which user story this task belongs to
- No test tasks generated — none requested in spec

---

## Phase 1: Setup

**Purpose**: No external setup required. Base R, no new packages, no new directories.  
This project uses existing `pipeline/`, `runners/`, `tools/`, `docs/` directories.

- [ ] T001 Confirm `pipeline/helper.R` loads cleanly and locate the `classify_by_rules()` function (end of helpers block) — identify the exact line for inserting `classify_data_format()` in `pipeline/helper.R`

---

## Phase 2: Foundational (Blocking Prerequisite)

**Purpose**: `classify_data_format()` and its extension constants must exist in `helper.R` before any user story task can be coded. All four phases depend on this function.

**⚠️ CRITICAL**: No user story work can begin until T002 is complete.

- [ ] T002 Add `TABULAR_EXTENSIONS`, `RAW_EXTENSIONS` character vector constants and `classify_data_format(ext)` vectorised lookup function to `pipeline/helper.R` immediately after `classify_by_rules()`. Values: tabular = csv/tsv/txt/dat/xlsx/xls/sav/dta/sas7bdat; raw = edf/bdf/acq/mat/mp4/avi/mov/wav/mp3; conservative fallback → `"tabular"`. Function takes a character vector of lowercase extensions (no dot), returns `"tabular"` or `"raw"`, never `NA`.

**Checkpoint**: Source `pipeline/helper.R` in an R session and call `classify_data_format(c("csv","mp4","mat","xyz"))` — must return `c("tabular","raw","raw","tabular")`.

---

## Phase 3: User Story 1 — New Papers Produce Correct Column Extraction Gating (Priority: P1) 🎯 MVP

**Goal**: Running `run_index()` on any paper with binary data files (MP4, MAT, EDF…) produces a `structure.csv` with `data_format` populated, and `columns.csv` contains zero rows sourced from raw-format files.

**Independent Test**: Run `run_index()` on the eye-tracking paper referenced in `pipeline/prompt_error_analysis.log`. Verify `structure.csv` has `data_format = "raw"` for all `.mp4` rows and `data_format = "tabular"` for all `.csv` rows. Verify `columns.csv` contains no row where `source_file` ends in `.mp4`.

### Implementation for User Story 1

- [ ] T003 [US1] Assign `data_format` column in `pipeline/0_index.R` immediately after the line that computes `file_df$ext` (line ~668): `file_df$data_format <- ifelse(file_df$type == "data", classify_data_format(file_df$ext), NA_character_)`. Requires `pipeline/helper.R` is already sourced (it is, at top of script).

- [ ] T004 [US1] Gate column extraction in `pipeline/0_index.R` at the `data_files` filter (line ~683). Change: `data_files <- file_df[file_df$type == "data" & !file_df$is_sentinel, ]` → add `& !is.na(file_df$data_format) & file_df$data_format == "tabular"` to the filter condition.

- [ ] T005 [US1] Add `"data_format"` as the last element in the column selection vector passed to `write.csv()` for `structure.csv` in `pipeline/0_index.R` (lines ~1029-1031).

- [ ] T006 [US1] Add `n_tabular_files` to the bulk summary row assembled in `pipeline/0_index.R`. Value: `sum(file_df$type == "data" & file_df$data_format == "tabular" & !file_df$is_sentinel, na.rm = TRUE)`. Insert after `n_data_files` in the summary list/data.frame.

- [ ] T007 [P] [US1] Add `.mat` hard-case rule to `STRUCTURE_PROMPT` in `pipeline/prompts.R` (Hard cases section). Rule: participant/subject-named `.mat` → `data`; filename contains result/output/model/fit/figure/plot → `output`; ambiguous default → `data`. No change to `.mp4` rule — existing participant-naming rule already produces the correct `type = "data"` outcome.

**Checkpoint**: After T003–T007, run `runners/run_tests.R` then `runners/report_tests.R`. Verify: (a) no regression in classification accuracy, (b) a fresh `run_index()` on a paper with `.mp4` files produces `data_format = "raw"` in `structure.csv` and zero `.mp4` rows in `columns.csv`.

---

## Phase 4: User Story 2 — Ground Truth Files Repaired Before Full Rerun (Priority: P2)

**Goal**: Running `runners/repair_ground_truth_data_format.R` adds `data_format_gt` to all 103 `ground_truth/<paper_id>.csv` files in a single idempotent pass, writing a summary CSV to `results/ground_truth_repair_summary.csv`.

**Independent Test**: Run the repair runner. Open any ground truth file that contained `.mp4` or `.mat` entries — verify `data_format_gt = "raw"` for those rows, `data_format_gt = "tabular"` for `.csv` rows, `NA` for non-data rows. Run the runner a second time — verify no values change (idempotency). Check `results/ground_truth_repair_summary.csv` has 103 rows.

### Implementation for User Story 2

- [ ] T008 [US2] Create `runners/repair_ground_truth_data_format.R`. Script must: source `pipeline/helper.R`; iterate over all `ground_truth/*.csv` files; for each file, read with `colClasses = c(paper_id = "character")`; compute `data_format_gt` from `tools::file_ext(rel_path)` via `classify_data_format()` for rows where `type_gt == "data"`, `NA` otherwise; preserve existing non-NA values (idempotent); write file back in-place; append one summary row to `results/ground_truth_repair_summary.csv` with columns `paper_id`, `n_data_rows`, `n_tabular`, `n_raw`, `n_already_present`. Summary CSV auto-created on first run (write header), appended on subsequent runs (skip header).

**Checkpoint**: After T008, run `runners/repair_ground_truth_data_format.R`. Inspect `results/ground_truth_repair_summary.csv` — must have 103 rows. Spot-check 3 ground truth files with known raw-format entries and confirm values.

---

## Phase 5: User Story 3 — Audit Tooling Identifies Ground Truth Entries Needing Re-review (Priority: P2)

**Goal**: Running `runners/audit_ground_truth_data_format.R` produces `results/ground_truth_audit_report.csv` listing every ground truth entry where `type_gt == "data"` and the file extension is raw-format — the entries most likely to have been validated under incorrect assumptions.

**Independent Test**: Run the audit runner. Verify the report contains only rows where the `ext` column is in the raw extensions list. Verify papers with no raw-format data entries are absent. Open a ground truth file containing `.mat` data entries and confirm those entries appear in the report.

### Implementation for User Story 3

- [ ] T009 [US3] Create `runners/audit_ground_truth_data_format.R`. Script must: source `pipeline/helper.R` (for `RAW_EXTENSIONS`); iterate over all `ground_truth/*.csv` files; read each with `colClasses = c(paper_id = "character")`; compute extension from `rel_path`; collect rows where `type_gt == "data"` and `ext %in% RAW_EXTENSIONS`; assemble output data.frame with columns `paper_id`, `rel_path`, `ext`, `type_gt`, `data_format_gt` (value `"raw"` for all rows); sort by `paper_id` then `rel_path`; write to `results/ground_truth_audit_report.csv`; print summary message: count of flagged entries and count of affected papers.

**Checkpoint**: Run `runners/audit_ground_truth_data_format.R`. Report must exist. Open it and confirm all `ext` values are in the raw extensions list. Confirm the count matches a manual count of `.mp4`/`.mat`/`.edf` etc. entries across spot-checked ground truth files.

---

## Phase 6: User Story 4 — `data_format` Flows Through to Downstream Consumers (Priority: P3)

**Goal**: PsychDS conversion routes `data_format = "raw"` files to `data/raw/` without column conversion. Validation GUI shows a `data_format` badge on `data`-typed rows.

**Independent Test**: (a) Run PsychDS conversion on a paper with both tabular and raw `data`-typed files — verify raw files appear in `data/raw/` and tabular files go through conversion. (b) Open the validation GUI on that same paper — verify a small secondary badge shows `"tabular"` or `"raw"` next to the type badge for data rows.

### Implementation for User Story 4

- [ ] T010 [P] [US4] Update `pipeline/3_psychds_convert.R`: inside the data file processing loop (near line 663), add a routing guard after the existing size check. If `!is.null(row$data_format) && !is.na(row$data_format) && row$data_format == "raw"`: copy file to `data/raw/`, increment `n_raw_files`, `next`. The `!is.null` guard preserves backward compatibility with pre-fix `structure.csv` files that lack the `data_format` column.

- [ ] T011 [P] [US4] Update `tools/validation_gui/app.R`: (a) add CSS rules for `.tbadge-df-tabular` (light green-grey, label "tab") and `.tbadge-df-raw` (light amber, label "raw") in both light and dark theme blocks; (b) after the type badge render (~line 1042), add a conditional secondary badge: when `row$type == "data"` and `!is.na(row$data_format)`, render `tags$span(class = paste0("tbadge-df-", row$data_format), row$data_format)`.

**Checkpoint**: Load the validation GUI on a paper with mixed `data_format` values. Confirm data rows show the secondary badge. Confirm no crash on papers with old `structure.csv` that lack the `data_format` column.

---

## Phase 7: Polish & Documentation

**Purpose**: Sync all documentation to reflect the schema and logic changes.

- [ ] T012 [P] Update `docs/output-schemas.md`: (a) add `data_format` row to the `structure.csv` schema table (after `is_sentinel`), documenting both values, applicable rows, and extension mapping; (b) add `n_tabular_files` row to `bulk_summary.csv` schema table (after `n_data_files`); (c) add `ground_truth_repair_summary.csv` and `ground_truth_audit_report.csv` as new sections with column definitions.

- [ ] T013 [P] Update `docs/pipeline.md`: (a) update processing step 6 ("Read data heads") to state that only `data_format = "tabular"` files are processed; (b) add `n_tabular_files` to the constants/columns table; (c) add a note in the pipeline workflow describing the pre-rerun ground truth repair step.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (Foundational)**: Depends on Phase 1 — **BLOCKS all user story phases**
- **Phase 3 (US1 — P1)**: Depends on Phase 2 — core pipeline fix; should complete before US2/US3 since ground truth repair runs before the rerun
- **Phase 4 (US2 — P2)**: Depends on Phase 2 (needs `classify_data_format()`); US1 should be complete before triggering the full rerun that follows
- **Phase 5 (US3 — P2)**: Depends on Phase 2 only — fully independent of US2
- **Phase 6 (US4 — P3)**: Depends on Phase 2 only — independent of US1/US2/US3
- **Phase 7 (Polish)**: Depends on all phases complete

### User Story Dependencies

- **US1 (P1)**: Can start after Foundational — no story dependencies
- **US2 (P2)**: Can start after Foundational — logically after US1 completes (run repair, then rerun pipeline)
- **US3 (P2)**: Can start after Foundational — independent of US1 and US2
- **US4 (P3)**: Can start after Foundational — independent of all other stories

### Within Each Phase

- T003 → T004 (must assign `data_format` before gating on it)
- T003 → T005 (must assign before writing to CSV)
- T003 → T006 (must assign before counting tabular files)
- T007 is independent of T003–T006 (different file: `prompts.R`)
- T010 and T011 are fully parallel (different files)
- T012 and T013 are fully parallel (different files)

### Parallel Opportunities

```
Phase 2: T002 (solo — foundational gate)

Phase 3: T003 → T004, T005, T006 (sequentially)
          T007 in parallel with T003-T006

Phase 4: T008 (solo)

Phase 5: T009 (solo)

Phase 6: T010 ‖ T011 (parallel — different files)

Phase 7: T012 ‖ T013 (parallel — different files)
```

---

## Implementation Strategy

### MVP (User Story 1 Only)

1. Complete Phase 1 (T001)
2. Complete Phase 2 (T002) — foundational gate
3. Complete Phase 3 (T003–T007) — pipeline fix
4. **STOP and VALIDATE**: run `run_index()` on a paper with `.mp4` files; confirm no raw-format rows in `columns.csv`; run `run_tests.R` for regression check
5. Repair is now active for all future papers

### Full Delivery Order

1. T001 → T002 → T003 → T004 → T005 → T006 (core pipeline fix, sequential)
2. T007 in parallel with T003–T006 (prompt fix, independent file)
3. T008 (ground truth repair runner)
4. T009 (audit runner) — can run in parallel with T008
5. T010 ‖ T011 (PsychDS + GUI, in parallel)
6. T012 ‖ T013 (docs, in parallel)

---

## Notes

- No new packages — base R only
- All `read.csv()` calls on ground truth files MUST use `colClasses = c(paper_id = "character")` (Constitution Principle II)
- `classify_data_format()` is the single source of truth — never inline the extension lists in pipeline scripts
- Run `runners/run_tests.R` after T003–T007 before proceeding to US2/US3/US4
- Trigger the full bulk rerun only after T008 (ground truth repair) is confirmed correct
