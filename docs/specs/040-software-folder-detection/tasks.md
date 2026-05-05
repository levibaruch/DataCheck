# Tasks: Software Folder Bulk Detection (040)

**Input**: Design documents from `/specs/040-software-folder-detection/`
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅

**Organization**: Tasks grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to

---

## Phase 1: Setup (Shared Constants)

**Purpose**: Add new named constants to `0_index.R` — required before any user story work.

- [x] T001 Add `SOFTWARE_FOLDER_THRESHOLD <- 500L` and `SOFTWARE_FOLDER_PATTERNS` character vector to `pipeline/0_index.R`, placed alongside the existing `AGGREGATE_THRESHOLD` constant block. Pattern list: `c("node_modules", "vendor", "renv", "site-packages", "__pycache__", "venv", ".venv", "libs", "lib", "dist", "build")`

**Checkpoint**: Constants exist in `0_index.R` — US1 and US2 work can begin.

---

## Phase 2: User Story 1 — Bloated Repo Completes Instead of Failing (Priority: P1) 🎯 MVP

**Goal**: Software package folders (≥500 files, matching pattern name) are detected before LLM runs, all files bulk-labeled `software`/`rule_folder`, paper completes without `too_large`.

**Independent Test**: Run the psychopy paper `74kqe` (known to contain `site-packages` subtree). Verify: (1) paper completes without error, (2) `structure.csv` has `type="software"` and `type_source="rule_folder"` for the affected files, (3) no LLM calls consumed for those files.

### Implementation for User Story 1

- [x] T002 [P] [US1] Implement `detect_software_folders(rel_paths, target_dir, threshold, patterns)` in `pipeline/helper.R`. Logic: (1) extract unique directory segments from rel_paths; (2) find candidates whose `tolower(basename())` exactly matches a pattern; (3) sort by depth ascending (outermost first); (4) for each candidate count recursively covered unclaimed rel_paths using `startsWith(rel_path, paste0(candidate, "/"))`; (5) if count ≥ threshold, claim those paths and record matched folder in map; (6) return `list(software_rel_paths, software_folder_map, clean_rel_paths)`. No safety gate yet (added in US2).

- [x] T003 [US1] Wire step 4.5 into `pipeline/0_index.R` immediately after step 4 (build rel_paths) and before step 5 (aggregate detection): call `detect_software_folders(rel_paths, target_dir, SOFTWARE_FOLDER_THRESHOLD, SOFTWARE_FOLDER_PATTERNS)`, then reassign `rel_paths <- sw$clean_rel_paths` so aggregate detection and LLM classification only see non-software paths.

- [x] T004 [US1] In `pipeline/0_index.R`, build `software_rows_df` from `sw$software_rel_paths`. One row per path with columns: `paper_id`, `path` (absolute), `rel_path`, `filename` (basename), `ext` (tolower file_ext), `type="software"`, `type_source="rule_folder"`, `group=NA_character_`, `aggregate_folder=sw$software_folder_map[rel_path]`, `data_granularity=NA_character_`, `granularity_source=NA_character_`, `prompt_nr=NA_integer_`, `data_format=NA_character_`. Build immediately after the `sw <- detect_software_folders(...)` call. Only build if `length(sw$software_rel_paths) > 0`.

- [x] T005 [US1] In `pipeline/0_index.R`, rbind `software_rows_df` into `file_df` alongside the existing aggregate-expanded and LLM-classified rows. Ensure column order matches the existing `write.csv()` call at step 10 (`paper_id`, `path`, `rel_path`, `filename`, `ext`, `type`, `type_source`, `group`, `aggregate_folder`, `data_granularity`, `granularity_source`, `prompt_nr`, `data_format`).

- [x] T006 [US1] Add console logging in `pipeline/0_index.R` step 4.5 for detected software folders. Use the existing `col_cyan`/`col_dim` pattern matching the aggregate detection log style. Print: folder name, file count claimed. Print nothing if no software folders detected.

**Checkpoint**: User Story 1 complete. Run psychopy paper `74kqe` — should complete cleanly with software-folder files labeled `software`/`rule_folder`.

---

## Phase 3: User Story 2 — Legitimate Data Files Not Caught (Priority: P2)

**Goal**: Folders matching a pattern but containing a majority of data-extension files (CSV, SAV, XLSX, etc.) are excluded from bulk labeling and sent through normal LLM classification.

**Independent Test**: Manually construct a test scenario where a folder named `lib` contains ≥500 CSV files. Verify `detect_software_folders()` returns those paths in `clean_rel_paths` (not `software_rel_paths`).

### Implementation for User Story 2

- [x] T007 [US2] Add extension-majority safety gate inside `detect_software_folders()` in `pipeline/helper.R`. After the file count threshold check passes for a candidate folder, compute the fraction of collected files whose `tolower(tools::file_ext())` is in: `c("csv","tsv","txt","dat","xlsx","xls","sav","dta","sas7bdat","rds","rda","rdata")`. If this fraction > 0.5, skip (do not claim) the folder. Otherwise proceed to claim.

**Checkpoint**: User Story 2 complete. Data folders named `lib`/`dist`/etc. with majority data-extension files pass through to normal LLM classification.

---

## Phase 4: User Story 3 — Bulk-Labeled Files Are Auditable (Priority: P3)

**Goal**: `rule_folder` is documented as a recognized `type_source` value; processing order diagram updated; constants documented.

**Independent Test**: Open `docs/output-schemas.md` — confirm `rule_folder` appears in the `type_source` vocabulary table with correct description.

### Implementation for User Story 3

- [x] T008 [P] [US3] Add `"rule_folder"` to the `type_source` vocabulary table in `docs/output-schemas.md`. Description: "File classified as `software` by the software folder detection rule (folder name match + file count threshold) without an LLM call."

- [x] T009 [P] [US3] Update the processing order section in `docs/pipeline.md`: insert step 4.5 between step 4 (build rel_paths) and step 5 (aggregate detection). Description: "Detect software package folders via `detect_software_folders()` — any folder whose basename matches `SOFTWARE_FOLDER_PATTERNS` and contains ≥ `SOFTWARE_FOLDER_THRESHOLD` files (recursive) is bulk-labeled `software`/`rule_folder`; its files are removed from `rel_paths` before aggregate detection runs."

- [x] T010 [P] [US3] Add `SOFTWARE_FOLDER_THRESHOLD` (500, pipeline/0_index.R) and `SOFTWARE_FOLDER_PATTERNS` (character vector of folder name patterns, pipeline/0_index.R) to the constants table in `docs/pipeline.md`.

**Checkpoint**: All three user stories complete. Documentation reflects the new behavior.

---

## Phase 5: Polish & Validation

**Purpose**: Verify no regressions; confirm feature works on real data.

- [x] T011 [P] Run `runners/run_tests.R` then `runners/report_tests.R`; confirm all existing test papers pass with no regressions.

- [ ] T012 [P] Manual spot-check: run `run_index()` on psychopy paper `74kqe`. Confirm `site-packages` subtree files appear in `structure.csv` with `type="software"`, `type_source="rule_folder"`, and `aggregate_folder` set to the matched folder path. Confirm paper completes without `too_large` error.

- [ ] T013 [P] Regression check: run `run_index()` on a test paper known to have no software-named folders. Confirm `structure.csv` output is identical (same rows, same type/type_source values) to a pre-feature baseline run.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (US1)**: T001 must complete before T003/T004/T005/T006. T002 can start in parallel with T001 (different file). T003 → T004 → T005 (sequential within `0_index.R`). T006 can be done alongside T003.
- **Phase 3 (US2)**: T002 must be complete (modifies same function). T007 can start after T002.
- **Phase 4 (US3)**: Independent of Phase 2/3 — can start any time after T001 (constants are being documented).
- **Phase 5 (Polish)**: All phases complete before validation.

### User Story Dependencies

- **US1 (P1)**: Depends on T001 (constants). T002 parallel with T001.
- **US2 (P2)**: Depends on T002 (extends same function). No dependency on US1 integration tasks (T003–T006).
- **US3 (P3)**: Independent — only requires docs access.

### Parallel Opportunities

- T001 and T002 in parallel (different files: `0_index.R` and `helper.R`)
- T008, T009, T010 all in parallel (different doc sections)
- T011, T012, T013 all in parallel (independent validation runs)
- T006 alongside T003 (both in `0_index.R` but non-conflicting sections)

---

## Parallel Example: User Story 1

```
# Start in parallel:
T001 — Add constants to pipeline/0_index.R
T002 — Implement detect_software_folders() in pipeline/helper.R

# After both complete:
T003 — Wire step 4.5 into pipeline/0_index.R
T004 — Build software_rows_df in pipeline/0_index.R
T005 — rbind software_rows_df into file_df
T006 — Add console logging
```

---

## Implementation Strategy

### MVP (User Story 1 Only)

1. Complete Phase 1: T001
2. Complete Phase 2: T002–T006
3. **Validate**: Run psychopy paper `74kqe` — paper should complete without `too_large`
4. Ship US1 if validation passes

### Incremental Delivery

1. US1 → paper `74kqe` completes cleanly (core value delivered)
2. US2 → safety gate prevents data-folder false positives
3. US3 → documentation complete, ready to merge
4. Phase 5 → full test suite green, merge to `dev`

---

## Notes

- No new files created — all changes are in existing `helper.R`, `0_index.R`, and docs
- `[P]` tasks operate on different files or non-conflicting sections
- `aggregate_folder` column reused for software folder audit trail — no schema change required
- `type="software"` already exists from feature 029 — no new type introduced
- Commit after each Phase checkpoint
