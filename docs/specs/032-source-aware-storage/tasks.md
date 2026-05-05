# Tasks: Source-Aware Storage Paths (032)

**Input**: Design documents from `/specs/032-source-aware-storage/`  
**Prerequisites**: plan.md ✅ | spec.md ✅ | research.md ✅ | data-model.md ✅

---

## Phase 2: Foundational — Central Path Helpers

**Purpose**: Add `paper_path()` and supporting helpers to `pipeline/helper.R`. Every user story depends on these being in place first.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T001 Add `paper_path(layer, source, paper_id, ...)` and `sanitize_id(id)` to `pipeline/helper.R` — new functions appended after existing helpers; see data-model.md for exact signatures
- [ ] T002 Add `list_downloaded_papers()` to `pipeline/helper.R` — scans `data/<source>/` for each registered source; returns `data.frame(source, paper_id)` (depends on T001 for `DATA_DIR` reference pattern)
- [ ] T003 Update `apply_ground_truth()` signature in `pipeline/helper.R` — from `(structure_df, paper_id)` to `(structure_df, source, paper_id)`; replace hardcoded `file.path("./data_check/ground_truth", ...)` path with `paper_path("ground_truth", source, paper_id)` + `.csv`
- [ ] T004 [P] Add `GROUND_TRUTH_DIR <- "./data_check/ground_truth"` constant to `pipeline/0_index.R` (alongside `DATA_DIR`, `OUTPUT_DIR`, `PSYCHDS_OUT_DIR`); remove `DATAVERSE_DATA_DIR` (subsumed by `paper_path("data", "dataverse", id)`)
- [ ] T005 Fix hardcoded `"./data_check/outputs"` at `pipeline/helper.R:12` — replace with `paper_path("outputs", source, paper_id)` (requires threading `source` through that caller's context; identify the enclosing function first)

**Checkpoint**: `paper_path()`, `sanitize_id()`, `list_downloaded_papers()`, updated `apply_ground_truth()` all in `helper.R`; `GROUND_TRUTH_DIR` constant in `0_index.R`. All user story phases may now begin.

---

## Phase 3: User Story 1 — OSF Pipeline (Priority: P1) 🎯 MVP

**Goal**: Full OSF pipeline (download → index → columns → codebook) writes artifacts to `data/osf/<id>/`, `outputs/osf/<id>/`, `psychds/osf/<id>/`.

**Independent Test**: Run `runners/run_single.R` for any known OSF paper; verify directory tree shows `data/osf/<id>/` and `outputs/osf/<id>/`.

### Implementation for User Story 1

- [ ] T006 [US1] Update `run_index()` in `pipeline/0_index.R` — replace `target_dir` construction at lines 94–96 with `paper_path("data", source, paper_id)`; replace output dir with `paper_path("outputs", source, paper_id)`; add legacy-path warning (FR-012) checking `file.path(DATA_DIR, paper_id)` (depends on T001, T004)
- [ ] T007 [US1][P] Update `pipeline/2_codebook_label.R` — replace `file.path(OUTPUT_DIR, paper_id, ...)` calls with `paper_path("outputs", source, paper_id, ...)` (depends on T001)
- [ ] T008 [US1][P] Update `runners/run_single.R` — replace `file.path(OUTPUT_DIR, pid, ...)` at lines 75 and 106 with `paper_path("outputs", "osf", pid, ...)` (depends on T001)
- [ ] T009 [US1][P] Update `runners/download_all_osf.R` — replace `file.path(DATA_DIR, pid)` at line 101 with `paper_path("data", "osf", pid)`; update `DATA_DIR` usage at line 11 if needed (depends on T001)

**Checkpoint**: OSF paper can be processed end-to-end with artifacts at source-aware paths. Run `runners/run_single.R` to verify.

---

## Phase 4: User Story 2 — Dataverse Pipeline (Priority: P1)

**Goal**: Dataverse papers write artifacts to `data/dataverse/<doi>/`, `outputs/dataverse/<doi>/`, `psychds/dataverse/<doi>/`.

**Independent Test**: Run `runners/run_dataverse_bulk.R` for a known Dataverse paper; verify all three storage layers contain source-namespaced paths.

### Implementation for User Story 2

- [ ] T010 [US2] Update `pipeline/3_psychds_convert.R`:
  - Fix hardcoded `"./data_check/outputs"` at line 1010 → `paper_path("outputs", source, paper_id)`
  - Update data source path construction at lines 491–493 → `paper_path("data", source, paper_id)` (removes the `if (is_dv)` branch)
  - Update `out_dir` at line 1062 → `paper_path("psychds", source, paper_id)`
  - Update `paper_root` at line 1084 → `paper_path("psychds", source, paper_id)`
  - Update `apply_ground_truth()` call at line 1032 to pass `source` as second argument
  (depends on T001, T003)
- [ ] T011 [US2] Update `runners/run_0_index_bulk.R`:
  - Replace `list.dirs(DATA_DIR, ...)` at line 54 with `list_downloaded_papers()` to get `(source, paper_id)` pairs
  - Update GT_DIR usage at line 40 (now derived via `paper_path()`)
  - Update `file.path("./data_check/outputs", succeeded$paper_id, "columns.csv")` at line 84 → `paper_path("outputs", succeeded$source, succeeded$paper_id, "columns.csv")`
  - Update `empty_dir` cleanup at line 216 → `paper_path("data", source, pid)`
  (depends on T001, T002, T004)
- [ ] T012 [US2][P] Update `runners/run_psychds_bulk.R` — replace per-paper psychds path construction with `paper_path("psychds", source, paper_id)`; ensure `source` field is read from input summary and passed through (depends on T001)
- [ ] T013 [US2][P] Update `runners/run_dataverse_bulk.R` — replace per-paper path construction with `paper_path("data"/"outputs"/"psychds", "dataverse", doi)`; verify `source = "dataverse"` is written to output CSV (depends on T001)

**Checkpoint**: Dataverse paper processed end-to-end with artifacts at `data/dataverse/`, `outputs/dataverse/`, `psychds/dataverse/`. Verify via `run_dataverse_bulk.R` on a known paper.

---

## Phase 5: User Story 3 — Validation GUI (Priority: P2)

**Goal**: GUI loads OSF papers only (filtered from bulk summary); reads from `outputs/osf/<id>/`; saves GT to `ground_truth/osf/<id>.csv`.

**Independent Test**: Launch `runners/run_validation_gui.R` with a mixed-source bulk summary; confirm only OSF papers appear; select one and verify data loads correctly.

### Implementation for User Story 3

- [ ] T014 [US3] Migrate existing ground-truth files — move all `ground_truth/*.csv` to `ground_truth/osf/` (create `ground_truth/osf/` directory; move each file; verify `tests/ground_truth/*.csv` also moved to `tests/ground_truth/osf/` if applicable)
- [ ] T015 [US3] Update `tools/validation_gui/gt_store.R` — replace ground_truth root path at line 19 with OSF-scoped path; ensure GT reads/writes target `ground_truth/osf/<id>.csv` (depends on T014)
- [ ] T016 [US3] Update `tools/validation_gui/app.R` — add `source == "osf"` filter when loading papers from bulk summary; update all `file.path(...outputs..., paper_id, ...)` constructions to use `paper_path("outputs", "osf", paper_id, ...)`; note: the `source` field must be available from bulk summary (depends on T001, T014, T015)

**Checkpoint**: Launch GUI; confirm OSF papers load from correct paths; save an annotation and verify file appears at `ground_truth/osf/<id>.csv`.

---

## Phase 6: User Story 4 — Test Suite (Priority: P2)

**Goal**: `run_tests.R` passes for all existing OSF test papers using new source-aware paths; `test_papers.csv` has a `source` column.

**Independent Test**: Run `runners/run_tests.R`; zero path errors; test log shows `source` column populated.

### Implementation for User Story 4

- [ ] T017 [US4] Update `tests/test_papers.csv` — add `source` column as second column; set `source = "osf"` for all existing rows; keep `id` read with `colClasses = c(id = "character")`
- [ ] T018 [US4] Update `runners/run_tests.R`:
  - Read `source` column from `test_papers.csv` (preserve `colClasses = c(id = "character", source = "character")`)
  - Update `gt_path` at line 103 → `paper_path("ground_truth", source, pid)` + `.csv` (or equivalent)
  - Update `TEST_OUTPUT_DIR` per-paper construction at line 621 to include source namespace
  - Update `PSYCHDS_OUT_DIR` override at lines 634–635 to use source-namespaced paths within the test psychds dir
  (depends on T001, T004, T017)
- [ ] T019 [US4][P] Update `runners/run_test_validation_gui.R` — update `dc_gt_dir` at line 26 to `ground_truth/osf/` path (depends on T014)
- [ ] T020 [US4] Add at least one Dataverse paper entry to `tests/test_papers.csv` with `source = "dataverse"` and an appropriate label; confirm `run_tests.R` processes it without path errors (depends on T017, T018)

**Checkpoint**: Run `runners/run_tests.R`; all existing OSF papers pass; Dataverse test paper is processed and reported.

---

## Phase 7: User Story 5 — Futureproof Extensibility (Priority: P3)

**Goal**: `paper_path()` raises an informative error for unregistered sources; adding a new source requires only editing `KNOWN_SOURCES` in `helper.R`.

**Independent Test**: Call `paper_path("data", "researchbox", "test123")` and confirm it stops with `"Unknown source 'researchbox'"`.

### Implementation for User Story 5

- [ ] T021 [US5] Verify `paper_path()` error behavior for unknown sources (already implemented in T001); add a short inline comment in `helper.R` at the `KNOWN_SOURCES` vector noting it as the sole registration site for new sources

**Checkpoint**: US5 complete — the abstraction is in place; no additional code required to satisfy P3 scope.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Docs, reporting, constitution, and final test run.

- [ ] T022 [P] Update `reports/report_normal.R` — replace `GT_DIR` local constant at line 29 with `GROUND_TRUTH_DIR` (or derive OSF GT path via `paper_path()` where needed)
- [ ] T023 [P] Update `docs/pipeline.md` — change step 10 in Processing Order from `outputs/<paper_id>/` to `outputs/<source>/<paper_id>/`; update Key Constants table (add `GROUND_TRUTH_DIR`; note that layer-root constants are now prefixed with `<source>/<id>` at use time)
- [ ] T024 [P] Update `docs/output-schemas.md` — update any path references to reflect source-namespaced paths
- [ ] T025 Amend `constitution.md` — MINOR version bump 1.3.1 → 1.4.0; add `paper_path()`, `sanitize_id()`, `list_downloaded_papers()` to Principle IV helper list; add `GROUND_TRUTH_DIR` to Key Constants table; update Processing Order step 10 path
- [ ] T026 Run `runners/run_tests.R` then `runners/report_tests.R`; confirm all test papers pass with zero path errors; review quality report before merge

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 2)**: No external dependencies — start immediately. BLOCKS all phases.
- **US1 (Phase 3)**: Depends on Phase 2. Can run in parallel with US2 after Phase 2 completes.
- **US2 (Phase 4)**: Depends on Phase 2. Can run in parallel with US1 after Phase 2 completes.
- **US3 (Phase 5)**: Depends on Phase 2. T014 (file migration) should precede T015/T016.
- **US4 (Phase 6)**: Depends on Phase 2 + Phase 3 (tests use the same pipeline). T017 before T018/T020.
- **US5 (Phase 7)**: Depends on Phase 2 (T001 already implements the behavior).
- **Polish (Phase 8)**: T022–T024 can run in parallel with any phase. T025 (constitution) after Phase 2. T026 (tests) after all phases.

### Parallel Opportunities

Within Phase 2: T001 → T002, T003 (sequential, same file); T004 independent (different file).  
Within Phase 3: T007, T008, T009 can run in parallel after T001 (different files); T006 after T001 + T004.  
Within Phase 4: T012, T013 in parallel after T001; T010 after T001 + T003; T011 after T001 + T002 + T004.  
Within Phase 5: T014 first, then T015 + T016 (T015 and T016 can be parallel).  
Within Phase 6: T017 first, then T018 + T019 in parallel; T020 after T017 + T018.

---

## Notes

- `[P]` = parallelisable (different files, no shared dependencies)
- `[USn]` = maps to User Story n for independent deliverability
- Always verify `paper_id` is read as character (Principle II) when updating CSV-reading code
- The `KNOWN_SOURCES` vector in `paper_path()` is the **only** place to register a new source
- `psychds/conversion_summary.csv` is the **one exception** to source-namespacing — it stays at `PSYCHDS_OUT_DIR` root
- Ground-truth is **OSF-only** — `paper_path("ground_truth", "dataverse", ...)` is callable but no pipeline code should invoke it
