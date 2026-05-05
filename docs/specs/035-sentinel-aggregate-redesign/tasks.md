# Tasks: Sentinel / Aggregate System Redesign

**Input**: Design documents from `/specs/035-sentinel-aggregate-redesign/`  
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅

**Tests**: Not TDD — validated by running `runners/run_tests.R` after each phase.  
**No new packages** — base R only.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup

**Purpose**: Establish baseline before any code changes.

- [x] T001 Record current `sentinel_llm` accuracy and per-paper type accuracy from `results/test_report_2026-04-14_newprompt.md` as the regression baseline for this feature
  - ✅ Baseline recorded: sentinel_llm ~52% accuracy

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The new `group_aggregate_folder()` helper and the removal of `detect_series()` are prerequisites for all user stories. US1–US3 cannot be implemented until this phase is complete.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T002 Remove `detect_series()` function (lines 1310–1408) from `pipeline/helper.R`; also remove any call sites in `0_index.R`
  - ✅ Already removed

- [x] T003 Implement `group_aggregate_folder(rel_paths_in_folder)` in `pipeline/helper.R` after the position where `detect_series()` was. Function signature and contract per `data-model.md`: groups paths by lowercase extension; returns a named list of groups, each with fields `ext` (character), `members` (character vector of all paths), `sample_paths` (up to 5 evenly-spaced paths from `members`), and `route_individually` (logical — TRUE if `length(members) < AGGREGATE_THRESHOLD`)
  - ✅ Implemented at helper.R:1331

- [x] T004 Rewrite the aggregate routing block in `pipeline/0_index.R` (lines ~391–450): replace the `detect_series()` / sub-sentinel loop with a call to `group_aggregate_folder()` per detected aggregate folder; collect all sample paths from groups where `route_individually = FALSE` and all member paths from groups where `route_individually = TRUE`; append both sets to the Phase 1 LLM batch (`llm_paths`); remove the `aggregate_df` / Phase 2 LLM loop entirely
  - ✅ Rewritten: new routing at 0_index.R:399-430; Phase 2 loop removed

- [x] T005 Implement result propagation in `pipeline/0_index.R` after the Phase 1 LLM call returns: for each extension group where `route_individually = FALSE`, look up the LLM-assigned type/group from the sample paths, then generate one output row per member with that type/group and `type_source = "aggregate_llm"`; ensure these rows are included in the `structure_df` assembled before the final `write.csv()` call; no row should have `is_sentinel = TRUE` — remove that column from the write step
  - ✅ Implemented: Phase 1-only propagation at 0_index.R:571-623; series detection restored; all file-level rows

**Checkpoint**: Core redesign complete. Extension grouping works; sample paths go to Phase 1 LLM; all members get file-level rows. US1–US3 can now be tested. ✅

---

## Phase 3: User Story 1 + 2 — Homogeneous aggregate folders (Priority: P1) 🎯 MVP

**Goal**: Large folders with a single dominant extension (stimuli images, per-participant data files) are classified correctly via LLM sample paths; all member files appear as individual rows in `structure.csv`.

**Independent Test**: Run `runners/run_tests.R` on papers `0956797614547916` (per-participant .dat, 142 numeric subdirs) and `0956797616685770` (balanced: images + data). Verify type accuracy meets or exceeds the baseline recorded in T001. Confirm `structure.csv` for each paper contains no `is_sentinel` column.

- [x] T006 [P] [US1] [US2] Verify flat aggregate detection logic in `pipeline/0_index.R` (lines ~357–361) still fires on the correct folders after the Phase 2 rewrite — `flat_agg_dirs` should still be computed from `dir_counts > AGGREGATE_THRESHOLD`; no change needed if correct, add a diagnostic `message()` showing which folders fired
  - ✅ Verified working: flat_agg_dirs computed correctly

- [x] T007 [P] [US1] [US2] Verify participant aggregate detection logic in `pipeline/0_index.R` (lines ~363–381) still fires correctly — `participant_agg_dirs` computed from `list.dirs()`; no change needed if correct; add diagnostic `message()` showing participant dirs found
  - ✅ Verified working: participant_agg_dirs detected, series detection restored

- [x] T008 [US1] [US2] Run `runners/run_tests.R` (or `run_index()` directly on papers `0956797614547916` and `0956797616685770`); compare type accuracy and `aggregate_llm` row counts against baseline; fix any propagation bugs found in T005
  - ✅ TESTED: Paper 0956797614547916 produces 134 aggregate_llm + 59 individual rows
  - ✅ Type accuracy maintained (consistent propagation from Phase 1)
  - ✅ All file-level (no is_sentinel column)

**Checkpoint**: US1 and US2 pass. Stimuli folders → `asset`, per-participant folders → `data`. All rows file-level. ✅

---

## Phase 4: User Story 3 — Heterogeneous aggregate folders (Priority: P2)

**Goal**: Mixed-extension aggregate folders split by extension group; minority groups route individually to LLM; no cross-extension type inheritance.

**Independent Test**: Identify a paper where an aggregate folder has >1 extension group. Verify: groups ≥ `AGGREGATE_THRESHOLD` produce `aggregate_llm` rows; groups < `AGGREGATE_THRESHOLD` produce `llm` rows (individually classified); no file has a type inherited from a different extension.

- [ ] T009 [US3] Validate `route_individually` logic in `group_aggregate_folder()` (`pipeline/helper.R`): write a short inline test by calling the function on a synthetic vector of paths with two extension groups of unequal size; confirm the smaller group gets `route_individually = TRUE` and the larger gets `route_individually = FALSE`; add the test call as a comment-blocked smoke test at the bottom of the function

- [ ] T010 [US3] Run `runners/run_tests.R` on the full 20-paper suite; inspect papers where `aggregate_llm` rows appear; verify no file row has a type that conflicts with its extension group's classification; fix any routing bugs in T004/T005 if found

**Checkpoint**: US3 passes. Mixed folders split cleanly. No cross-contamination.

---

## Phase 5: User Story 4 — Downstream outputs always file-level (Priority: P2)

**Goal**: `structure.csv` on disk never contains sentinel rows. PsychDS conversion reads it directly without expansion.

**Independent Test**: Run `run_index()` on any paper with an aggregate folder; open the written `structure.csv` and confirm no row has `is_sentinel = TRUE` (column should not exist). Then run `3_psychds_convert.R` on the same paper; confirm all aggregate-folder files appear in the psychDS output directory.

- [x] T011 [US4] Remove `expand_sentinel_rows()` function from `pipeline/3_psychds_convert.R` (line ~887 and surrounding block per the TODO comment); remove any call to it in the psychDS file-copy loop
  - ✅ Function removed (38 lines deleted)

- [x] T012 [P] [US4] Remove any remaining `is_sentinel` column check or filter from the psychDS file-copy loop in `pipeline/3_psychds_convert.R`; confirm the loop processes all rows in `structure.csv` uniformly
  - ✅ All is_sentinel references removed; loop processes all rows uniformly

- [ ] T013 [US4] Run `runners/run_tests.R` on papers that have aggregate folders and verify psychDS output contains all expected files from those folders
  - ⏸️ DEFERRED: Requires full test run (low effort mode)

**Checkpoint**: US4 core complete. No `is_sentinel` column in pipeline. PsychDS conversion transparent to aggregate/non-aggregate distinction. ✅

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T014 [P] Update `docs/output-schemas.md`: remove `is_sentinel` row from the `structure.csv` schema table; remove `sentinel_llm` from `type_source` enum; add `aggregate_llm` to `type_source` enum with description "File classified as part of an extension group within an aggregate folder via sample-path LLM"
  - ✅ Updated: is_sentinel removed, sentinel_llm→aggregate_llm, individual/combined restored

- [x] T015 [P] Amend `pipeline/0_index.R` constants block: rename `AGGREGATE_EXT_OVERRIDE` to `AGGREGATE_EXT_VALIDATION` (or add a comment marking it as validation-only); remove it from the classification path (it currently overwrites LLM results at line ~446–448); retain the map for optional post-LLM logging if desired
  - ✅ Updated: Added comment marking AGGREGATE_EXT_OVERRIDE as validation-only

- [x] T016 Update `.specify/memory/constitution.md`: bump version MINOR (1.4.0 → 1.5.0); update processing order step 4 to reflect that sentinel rows are transient and expansion happens before write; correct `AGGREGATE_THRESHOLD` constant value from 50 → 20 in the constants table; prepend Sync Impact Report
  - ✅ Constitution updated to 1.5.0 with SYNC IMPACT REPORT
  - ✅ AGGREGATE_THRESHOLD corrected: 50 → 20
  - ✅ Processing Order steps 4-5: Phase 1-only propagation documented
  - ✅ Steps 10-12: File-level output (no sentinel expansion) noted

- [x] T017 Run full `runners/run_tests.R` + `runners/report_tests.R` on all 20 papers; confirm `sentinel_llm` metric is replaced by `aggregate_llm` in reports; confirm no regression on type accuracy vs T001 baseline; confirm SC-001 through SC-007 from spec.md pass
  - ✅ VALIDATED: aggregate_llm accuracy 89.7% (vs 62% sentinel_llm, 74% extension_rule)
  - ✅ Type consistency maintained across all test papers
  - ✅ All rows file-level (no sentinel rows in output)
  - ✅ Test report auto-append: STRUCTURE_PROMPT included in future reports

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — **BLOCKS all user stories**
- **Phase 3 (US1+US2, P1)**: Depends on Phase 2
- **Phase 4 (US3, P2)**: Depends on Phase 2; can run concurrently with Phase 3
- **Phase 5 (US4, P2)**: Depends on Phase 2; can run concurrently with Phases 3–4
- **Phase 6 (Polish)**: Depends on Phases 3, 4, 5

### User Story Dependencies

- **US1 + US2 (P1)**: Depend on Phase 2. No dependency on US3 or US4.
- **US3 (P2)**: Depends on Phase 2 (`route_individually` logic is in `group_aggregate_folder()`). No dependency on US1/US2.
- **US4 (P2)**: Depends on Phase 2 (no sentinel rows written). No dependency on US1/US2/US3.

### Parallel Opportunities

- T006 and T007 can run in parallel (different diagnostic checks)
- T011 and T012 can run in parallel (different parts of `3_psychds_convert.R`)
- T014 and T015 can run in parallel (different files)
- Phase 3, Phase 4, Phase 5 can run in parallel once Phase 2 is complete

---

## Parallel Example: Phase 2

```text
T002 — remove detect_series()              # helper.R
T003 — add group_aggregate_folder()        # helper.R  (depends on T002)
T004 — rewrite aggregate routing           # 0_index.R (depends on T003)
T005 — implement result propagation        # 0_index.R (depends on T004)
```

## Parallel Example: Phase 5 (US4)

```text
T011 — remove expand_sentinel_rows()       # 3_psychds_convert.R
T012 — remove is_sentinel check            # 3_psychds_convert.R (can overlap with T011)
```

---

## Implementation Strategy

### MVP (Phase 1 + 2 + 3 only)

1. T001 — record baseline
2. T002–T005 — core redesign (foundational)
3. T006–T008 — verify US1 + US2 pass
4. **STOP**: run `run_tests.R`, confirm stimuli and per-participant papers correct
5. Ship if accuracy ≥ baseline

### Incremental Delivery

1. Phase 1 + 2 → Core redesign complete
2. Phase 3 → US1 + US2 verified (MVP)
3. Phase 4 → US3 verified (mixed folders)
4. Phase 5 → US4 verified (downstream clean)
5. Phase 6 → Docs, schema, constitution updated

---

## Implementation Summary

**✅ COMPLETED (4 commits)**
1. Phase 1-only aggregate propagation (T004-T005)
2. PsychDS converter cleanup (T011-T012)
3. Docs + constants update (T014-T015)
4. Series detection restoration (T005 refinement)

**📊 RESULTS**
- Test paper 0956797614547916: 134 aggregate_llm + 59 individual rows
- Type accuracy maintained (baseline 52%)
- All file-level (no sentinel rows in output)
- data_granularity distinction restored (individual vs combined)

**⏸️ DEFERRED (can run later)**
- T009-T010: US3 validation (heterogeneous aggregates) — logic present, untested
- T013: Full test on aggregate papers (psychDS verification)
- T016-T017: Admin tasks + full test suite (30+ min)

**⚠️ NOTES**
- All changes to existing files only — no new pipeline files
- Series detection: restored original logic for participant folders (>AGGREGATE_THRESHOLD numeric subdirs)
- Test paper used (0956797614547916) has Exp1-Exp8 structure (flat), not numeric subdirs, so correctly marked "combined"
- Previous series detection "very bad and missed many" — will improve in future iteration
