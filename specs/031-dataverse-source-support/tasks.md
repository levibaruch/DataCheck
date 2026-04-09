# Tasks: Harvard Dataverse Source Support

**Input**: Design documents from `specs/031-dataverse-source-support/`  
**Branch**: `031-dataverse-source-support`  
**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Data Model**: [data-model.md](data-model.md)

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)

---

## Phase 1: Setup

**Purpose**: Prepare the Dataverse data directory on disk.

- [x] T001 Create `data_check/data/dataverse/` directory and move/copy Dataverse deposits from `/Users/levibaruch/dev/dataverse_scrape/downloads/` into it, one subfolder per DOI slug

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core helpers and constants that all user stories depend on.

**⚠️ CRITICAL**: No user story implementation can begin until this phase is complete.

- [x] T002 [P] Add `is_dataverse_id()` helper function to `pipeline/helper.R` (after `paper_output_dir` definition): `is_dataverse_id <- function(paper_id) startsWith(as.character(paper_id), "doi_")`
- [x] T003 [P] Add `DATAVERSE_DATA_DIR <- file.path(DATA_DIR, "dataverse")` constant to the constants block in `pipeline/0_index.R` (after `DATA_DIR` on line 23)
- [x] T004 Add `source` field to the `run_index()` return list in `pipeline/0_index.R`: `source = if (is_dv) "dataverse" else "osf"` — requires `is_dv` to be in scope (see T005)

**Checkpoint**: `is_dataverse_id()`, `DATAVERSE_DATA_DIR`, and `source` in the return list are available. US1 can now begin.

---

## Phase 3: User Story 1 — Single Dataverse deposit pipeline (Priority: P1) 🎯 MVP

**Goal**: `run_index(paper_id = "doi_10.7910_DVN_0QEUU5", download = FALSE)` reads files from `data_check/data/dataverse/doi_10.7910_DVN_0QEUU5/` and produces `outputs/doi_10.7910_DVN_0QEUU5/structure.csv` and `columns.csv`.

**Independent Test**: Call `run_index()` on one deposit; verify both output CSVs exist with correct schema and non-zero row counts. Verify an OSF paper ID still processes unchanged.

- [x] T005 [US1] Add Dataverse source detection and `target_dir` routing to `run_index()` in `pipeline/0_index.R`: set `is_dv <- is_dataverse_id(paper_id)` immediately after `eff_dir` is resolved (around line 92); replace `target_dir <- file.path(DATA_DIR, paper_id)` with conditional: `target_dir <- if (is_dv) file.path(DATAVERSE_DATA_DIR, paper_id) else file.path(DATA_DIR, paper_id)`
- [x] T006 [US1] Add Dataverse download-skip block to `run_index()` in `pipeline/0_index.R`: in the non-`COLUMNS_ONLY` branch, wrap the existing OSF download block (`if (download) { xml_path <- ... }`) in an `else` branch that runs only when `!is_dv`; add the Dataverse guard as the `if (is_dv)` branch: check `dir.exists(target_dir)` and stop with `"dataverse_dir_missing: no directory found at <path> for deposit <paper_id>"` if missing; set `t_download <- 0` and log a message
- [x] T007 [US1] Smoke-test: manually run `run_index(paper_id = "doi_10.7910_DVN_0QEUU5", download = FALSE)` (or similar deposit) and verify `outputs/doi_10.7910_DVN_0QEUU5/structure.csv` and `columns.csv` are produced with correct content and no errors

**Checkpoint**: A single Dataverse deposit can be fully indexed end-to-end. US2 and US3 can now begin.

---

## Phase 4: User Story 2 — Bulk-process all Dataverse deposits (Priority: P2)

**Goal**: `run_dataverse_bulk.R` iterates over all deposits in `data_check/data/dataverse/`, writes results incrementally to `results/bulk_summary.csv`, and resumes correctly after interruption.

**Independent Test**: Run bulk runner on a subset of 5 deposits; interrupt and restart; verify no duplicate rows in `bulk_summary.csv` and all 5 deposits appear with `source = "dataverse"`.

- [x] T008 [P] [US2] Add `source = na_fallback(r$source, "osf")` to `make_summary_row()` in `runners/run_0_index_bulk.R` (inside the `data.frame(...)` call, after `n_src_files`); also add `source = "osf"` to the two inline failure-stub `list(...)` objects in the same file (around lines 224 and 242)
- [x] T009 [P] [US2] Create `runners/run_dataverse_bulk.R` — new bulk runner following the structure from plan.md Task 5: discovers deposits in `DATAVERSE_DATA_DIR`, auto-resumes from `bulk_summary.csv`, calls `run_index(paper_id = pid, download = FALSE)` for each, writes rows with `source = "dataverse"` immediately after each deposit (Principle I), records structured errors without aborting

**Checkpoint**: All 457 deposits can be bulk-processed. `bulk_summary.csv` has a `source` column with `"dataverse"` for Dataverse rows and `"osf"` for OSF rows.

---

## Phase 5: User Story 3 — Source identity recorded and queryable (Priority: P3)

**Goal**: `source` column is present and correct in `bulk_summary.csv`; Validation GUI shows only OSF papers; psychDS output has correct `platform` and `download_path` for Dataverse deposits.

**Independent Test**: (1) Inspect `bulk_summary.csv` after running both runners — every row has a non-null `source`. (2) Open Validation GUI — zero `doi_` entries in paper selector. (3) Run `convert_psychds()` on one Dataverse deposit — `metacheck:source_repository.platform` equals `"dataverse"`.

- [x] T010 [P] [US3] Filter Dataverse IDs from `discover_papers()` in `tools/validation_gui/gt_store.R`: add `dirs <- dirs[!startsWith(dirs, "doi_")]` after the `list.dirs()` / filter block (around line 55), before the `has_structure` filter
- [x] T011 [P] [US3] Add `source` parameter (default `"osf"`) to `build_dataset_description()` signature in `pipeline/3_psychds_convert.R` (line 411); replace the hardcoded `platform = "osf"` block (lines 487–490) with: `platform = source, download_path = if (source == "dataverse") paste0("data/dataverse/", paper_id, "/") else paste0("data/", paper_id, "/")`
- [x] T012 [US3] Thread `source` through the `convert_study()` call chain in `pipeline/3_psychds_convert.R`: add `source = "osf"` parameter to `convert_study()` signature; pass it through to `build_dataset_description()` call inside `convert_study()`
- [x] T013 [US3] Derive `paper_source` in `convert_psychds()` in `pipeline/3_psychds_convert.R` (after the `parse_grobid_xml` call, around line 1040): read `source` from `paper_row` in `bulk_summary.csv` if present, fall back to `is_dataverse_id(paper_id)`; pass `paper_source` to both `convert_study()` calls (single-study and multi-study paths)

**Checkpoint**: All three user stories are complete and independently verifiable. Full pipeline — index → bulk → psychDS — works for Dataverse deposits.

---

## Phase 6: Polish & Docs

**Purpose**: Documentation sync and final validation.

- [x] T014 [P] Update `docs/output-schemas.md`: add `source` column to `bulk_summary.csv` schema table (type: character, values: `"osf"` / `"dataverse"`, note: `NA` on pre-existing rows should be treated as `"osf"`); add `dataverse_dir_missing` to the error codes table
- [x] T015 [P] Update `docs/pipeline.md`: add `DATAVERSE_DATA_DIR` to the constants table; add a Dataverse note to the processing order section (step 1a: Dataverse IDs skip steps 1–3, read from `DATAVERSE_DATA_DIR`); add `run_dataverse_bulk.R` to the Entry Points table
- [ ] T016 Run existing test suite: `Rscript data_check/runners/run_tests.R` then `Rscript data_check/runners/report_tests.R` — all existing OSF test papers must still pass

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 (data directory must exist) — **blocks all user stories**
- **US1 (Phase 3)**: Depends on Foundational completion
- **US2 (Phase 4)**: Depends on US1 completion (needs `run_index()` working for Dataverse)
- **US3 (Phase 5)**: Depends on US1 completion; T008 can run in parallel with US1 work; T010–T013 depend on Foundational only
- **Polish (Phase 6)**: Depends on all user stories

### User Story Dependencies

- **US1 (P1)**: Requires Foundational (T002–T004)
- **US2 (P2)**: Requires US1 (T005–T006); T008 and T009 can run in parallel with each other
- **US3 (P3)**: Requires US1; T010, T011 can run in parallel with each other and with US2

### Parallel Opportunities

```text
Phase 2:
  T002 (helper.R) ─┐
                   ├─> T004 (0_index.R return value, needs T003)
  T003 (0_index.R) ┘

Phase 3: T005 → T006 → T007  (sequential, all in 0_index.R or smoke-test)

Phase 4:
  T008 (run_0_index_bulk.R) ─┐  both after US1 complete
  T009 (run_dataverse_bulk.R) ┘

Phase 5:
  T010 (gt_store.R)           ─┐
  T011 (3_psychds_convert.R)   ├─> T012 → T013  (sequential within psychDS file)
                               ┘

Phase 6:
  T014 (output-schemas.md) ─┐  both after all stories
  T015 (pipeline.md)        ┘
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. Phase 1: Move Dataverse data into `data/dataverse/`
2. Phase 2: Add `is_dataverse_id()`, `DATAVERSE_DATA_DIR`, `source` return field (T002–T004)
3. Phase 3: Add routing + skip-download to `run_index()` (T005–T006)
4. **STOP AND VALIDATE**: Run one deposit, confirm output CSVs produced

### Incremental Delivery

1. MVP → Dataverse indexing works for single deposits
2. + Phase 4 → Bulk processing works across all 457 deposits
3. + Phase 5 → Source tracking, GUI exclusion, psychDS provenance correct
4. + Phase 6 → Docs in sync, existing tests still pass

---

## Notes

- [P] tasks = different files or truly independent, safe to execute concurrently
- T005 and T006 are both edits to `pipeline/0_index.R` — run sequentially
- T011, T012, T013 are all edits to `pipeline/3_psychds_convert.R` — run sequentially
- The existing `download = FALSE` parameter already exists in `run_index()` — the Dataverse runner passes it explicitly as a safety measure, but the source-detection guard in T006 makes it redundant for Dataverse IDs
- Backward compatibility: all existing OSF behavior must be unchanged — verify with T016
