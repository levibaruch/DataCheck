# Tasks: Sentinel/Aggregate System Revamp

**Input**: Design documents from `/specs/023-sentinel-aggregate-revamp/`
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅

**Tests**: No test tasks generated — not requested in spec.

**Organization**: Tasks grouped by user story. US1 → US2 → US3 → US4 → US5. US2–US5 all depend on US1.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no blocking dependencies)
- **[Story]**: Maps to user story from spec.md (US1–US5)

---

## Phase 1: Setup

No new project structure needed — all changes are within existing files.

- [x] T001Read current sentinel implementation in `pipeline/0_index.R` (steps 5–7) and `pipeline/helper.R` to establish baseline before any changes

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Changes that must exist before any user story can be implemented

**⚠️ CRITICAL**: US1 and all downstream stories depend on T002 and T003.

- [x] T002 Remove `.txt` and `.dat` entries from `AGGREGATE_EXT_OVERRIDE` in `pipeline/0_index.R` (lines ~30–41) — these are ambiguous and must fall through to sentinel_llm inheritance [FR-010]
- [x] T003 Add `detect_series()` function to `pipeline/helper.R` — accepts a character vector of basenames, strips trailing `[-_][alphanumeric*digit*].*` suffix via `sub("[-_][A-Za-z0-9]*[0-9][A-Za-z0-9]*[-_]?.*$", "", x, perl=TRUE)`, groups by resulting prefix (min 2 chars), returns `list(sub_sentinels=data.frame(prefix, members, dominant_ext, samples), singletons=character[])` where singletons are files whose stripped prefix equals their full basename or whose prefix-group has only 1 member

**Checkpoint**: `detect_series()` exists in `helper.R` and `.txt`/`.dat` removed from override table — US1 can now begin.

---

## Phase 3: User Story 1 — Sub-group Series Detection (Priority: P1) 🎯 MVP

**Goal**: Aggregate folders are split into per-series sub-sentinels (or one fallback sentinel if no series found), each carrying its prefix and sample filenames into Phase 2 instead of a single opaque `[N_files.ext]` path.

**Independent Test**: Run `run_index()` on the IAT paper (folder with 329 files, ~20 task-condition prefixes). Confirm `structure.csv` contains ~20 distinct `aggregate_folder` rows with distinct series prefixes in the path. Run on a paper with a non-series folder (55 unique HTML files) and confirm it collapses to 1 sentinel.

- [x] T004 [US1] In `pipeline/0_index.R` step 5 (aggregate detection, ~line 299), replace the `agg_sentinels <- lapply(...)` block with a loop that calls `detect_series(members)` per aggregate folder, producing a list of sub-sentinels and appending any singletons to `non_agg_relpaths`
- [x] T005 [US1] In `pipeline/0_index.R`, build the sub-sentinel descriptor string for each sub-sentinel using the format: `"folder/[prefix: \"PREFIX\", N files, .EXT, samples: FILE1, FILE2, ...]"` (or `"folder/[mixed, N files, .EXT, samples: ...]"` for single-sentinel fallback when no series found) — store in `aggregate_df$rel_path`
- [x] T006 [US1] In `pipeline/0_index.R`, attach `is_series` logical column to `aggregate_df` (`TRUE` when a real series prefix was found, `FALSE` for single-sentinel fallback) — required for `data_granularity` derivation in US3
- [x] T007 [US1] In `pipeline/0_index.R`, update the `message()` call for aggregate detection (FR-011) to report: folder path, number of sub-sentinels produced, member count per sub-sentinel — emit after `detect_series()` completes per folder

**Checkpoint**: `run_index()` on IAT paper produces multiple sub-sentinels per aggregate folder. Single-sentinel fallback still works for non-series folders.

---

## Phase 4: User Story 2 — Context-Aware Phase 2 Classification (Priority: P2)

**Goal**: Sub-sentinels are classified in a dedicated Phase 2 `llm_batch()` call that receives the full Phase 1 experiment map as context, enabling group-consistent assignment across all sub-sentinels.

**Independent Test**: Run on a paper with a participant folder alongside a named merged data file. Confirm the participant folder's `group` in `structure.csv` matches the group assigned to the merged file in Phase 1.

- [x] T008 [US2] Add `SENTINEL_PROMPT` to `pipeline/prompts.R` — distinct from `STRUCTURE_PROMPT`; instructs the LLM it is classifying aggregate folder series descriptors (not individual paths); uses the same `type`/`group` enum; states that type may already be resolved by extension rule and only group assignment is needed in that case; expects `{"path": "<descriptor_string>", "type": "<type>", "group": "<group>"}` JSON array output
- [x] T009 [US2] In `pipeline/0_index.R`, before the Phase 2 batch, pre-resolve sub-sentinel types via `AGGREGATE_EXT_OVERRIDE` using the sub-sentinel's `dominant_ext` — store as `aggregate_df$type_resolved` (`NA` if ambiguous); these pre-resolved types will override the LLM's type output after Phase 2 (FR-005, FR-006)
- [x] T010 [US2] In `pipeline/0_index.R`, add a Phase 2 `llm_batch()` call after the Phase 1 loop — passes all sub-sentinel descriptor strings, uses `SENTINEL_PROMPT`, injects the fully-populated Phase 1 `experiment_map` as user prefix via `build_structure_summary(experiment_map)` (FR-003, FR-004)
- [x] T011 [US2] In `pipeline/0_index.R`, update `MAX_LLM_CALLS` / `n_llm_calls` guard (step 6, ~line 338) to account for Phase 2 calls: compute `n_phase2_calls <- ceiling(nrow(aggregate_df) / LLM_BATCH_SIZE)` and add to `n_llm_calls` before the `too_large` check (edge case: no non-aggregate files → skip two-phase split entirely, FR-012)
- [x] T012 [US2] In `pipeline/0_index.R` step 7 (sentinel expansion), merge Phase 2 results into `aggregate_df` by descriptor string (replacing the current merge from `structure_parsed`); apply `type_resolved` override: where `!is.na(aggregate_df$type_resolved)`, use pre-resolved type; elsewhere use Phase 2 LLM type; emit FR-011 post-Phase-2 diagnostic (folder, assigned type, assigned group)

**Checkpoint**: Phase 2 produces group-consistent labels. `type_source` for ambiguous-extension expanded files is `"sentinel_llm"`; for extension-resolved files it is `"extension_rule"`.

---

## Phase 5: User Story 3 — data_granularity Flag (Priority: P3)

**Goal**: Every data file in `structure.csv` carries `data_granularity`: `"individual"` (part of a detected series), `"combined"` (classified individually by Phase 1, including singletons inside aggregate folders), `NA` (non-data files).

**Independent Test**: Run on a paper with 200 numbered participant files AND one singleton merged summary file in the same aggregate folder. Sub-sentinel-expanded rows show `data_granularity = "individual"`, the singleton merged file shows `data_granularity = "combined"`, standalone files outside the folder also show `"combined"`.

- [x] T013 [US3] In `pipeline/0_index.R` expansion step 7, compute `data_granularity` per expanded file row: `ifelse(type == "data" & is_series_member, "individual", ifelse(type == "data", "combined", NA))` — where `is_series_member` is `TRUE` only when the sub-sentinel's `is_series == TRUE`; set `is_series_member = FALSE` for single-sentinel fallback expanded files
- [x] T014 [US3] In `pipeline/0_index.R`, set `data_granularity = ifelse(type == "data", "combined", NA)` for all Phase 1 (non-aggregate) rows in `non_agg_df`, including singletons that were routed from aggregate folders back to Phase 1
- [x] T015 [US3] In `pipeline/0_index.R`, ensure `data_granularity` column is included in the `structure.csv` write (step 8/10) — column must be present with correct values for all rows and must not be null for any row
- [x] T016 [P] [US3] Update `tools/validation_gui/app.R`: replace the `checkboxInput("is_raw_val", ...)` (line ~499) with a `selectInput("data_granularity_val", ...)` with choices `c("" = NA, "individual", "combined")`; update all reactive references from `rv$is_raw_val` → `rv$data_granularity_val`; update the custom JS message handler from `"set_is_raw_disabled"` to `"set_data_granularity_disabled"`; update the keyboard shortcut handler (currently `R` → toggle is_raw, ~line 670); update the save logic (~line 691) to write `data_granularity` instead of `is_raw`; update the structure.csv column read (~line 1102)
- [x] T017 [P] [US3] Update `tools/validation_gui/gt_store.R`: rename `is_raw_gt` column to `data_granularity_gt` (line ~8 schema definition, line ~18 empty data.frame, line ~44 coercion map, line ~58 merge coercion, ~line 62 non-data guard); change non-data correction guard from `df$is_raw_gt[non_data] <- FALSE` → `df$data_granularity_gt[non_data] <- NA`

**Checkpoint**: `structure.csv` has `data_granularity` column. Validation GUI shows tri-state selector. Ground truth file uses `data_granularity_gt`.

---

## Phase 6: User Story 4 — Per-File Accurate Type After Expansion (Priority: P4)

**Goal**: Every file expanded from an aggregate has its type individually resolved: unambiguous extensions use the override table; only truly ambiguous extensions inherit the sub-sentinel's LLM-assigned type. `.R` scripts inside data folders show `type = "code"`.

**Independent Test**: Run on a paper whose aggregate folder contains `.csv` participant files and stray `.R` scripts. Confirm `.R` files show `type = "code"`, `type_source = "extension_rule"` and `.csv` files show `type = "data"`, `type_source = "extension_rule"` (since csv is unambiguous).

- [x] T018 [US4] In `pipeline/0_index.R` expansion step 7, apply `AGGREGATE_EXT_OVERRIDE` per-file after expansion (this already exists in part — verify the logic uses the per-file extension, not the sub-sentinel's dominant_ext); where override matches → `type = AGGREGATE_EXT_OVERRIDE[ext]`, `type_source = "extension_rule"`; where no override → `type = sub_sentinel_llm_type`, `type_source = "sentinel_llm"` (not "llm" — renamed to distinguish Phase 2 sentinel from Phase 1)
- [x] T019 [US4] In `pipeline/0_index.R`, remove the old `type_source = ifelse(to_override, "rule", "llm")` line (~line 430) and replace with the new enum values `"extension_rule"` and `"sentinel_llm"` from T018

**Checkpoint**: Every expanded file has a non-null `type_source` from the correct enum. No `.R` file shows `type = "data"`.

---

## Phase 7: User Story 5 — Transparent Audit Trail (Priority: P5)

**Goal**: Every row in `structure.csv` has a non-null `type_source` from the defined enum and a populated `aggregate_folder` column (relative path for aggregate-expanded rows, `NA` otherwise).

**Independent Test**: Inspect `structure.csv` for the IAT paper. FlowerInsectCong files show `type_source = "sentinel_llm"`, `aggregate_folder = "ASD_CTL/RA_IATData"`, `data_granularity = "individual"`. Phase 1 files show `type_source = "llm"`, `aggregate_folder = NA`. No row has a null `type_source`.

- [x] T020 [US5] In `pipeline/0_index.R` expansion step 7, add `aggregate_folder` column to `agg_expanded_df` — set to the parent folder's relative path (e.g. `"ASD_CTL/RA_IATData"`) for all expanded files; set `aggregate_folder = NA` in `non_agg_df` (Phase 1 rows) [FR-008]
- [x] T021 [US5] In `pipeline/0_index.R` `non_agg_df` construction, explicitly set `type_source = "llm"` (already present at line ~443 — verify it is retained after all the new code is in place)
- [x] T022 [US5] In `pipeline/0_index.R`, remove `is_raw = NA` from both `non_agg_df` and `agg_expanded_df` data.frame constructors (lines ~416, ~436); remove the `is_raw` column from the `structure.csv` write

**Checkpoint**: All 5 user stories complete. Full audit trail visible in `structure.csv` for every row.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [x] T023 Update `pipeline/3_psychds_convert.R`: wherever `ground_truth/<paper_id>.csv` is read and `is_raw` is used as an override, switch column reference to `data_granularity`; map `data_granularity == "individual"` to the equivalent of `is_raw == TRUE` semantics
- [x] T024 [P] Update `docs/output-schemas.md`: add `type_source` enum update (`"extension_rule"` replaces `"rule"`, add `"sentinel_llm"`); add `aggregate_folder` and `data_granularity` column definitions; remove `is_raw` row; update `ground_truth` schema (rename `is_raw_gt` → `data_granularity_gt`)
- [x] T025 [P] Update `docs/pipeline.md`: revise step 4 flow description to describe two-phase classification and sub-grouping; add constants table entries if any new constants were added; ensure flow diagram reflects singletons routing back to Phase 1

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (T001)**: No dependencies — start immediately
- **Phase 2 (T002–T003)**: No dependencies — BLOCKS all user stories
- **Phase 3 US1 (T004–T007)**: Requires Phase 2 complete
- **Phase 4 US2 (T008–T012)**: Requires Phase 3 complete (needs sub-sentinel structure from US1)
- **Phase 5 US3 (T013–T017)**: Requires Phase 3 complete; T013–T015 require Phase 4 (need sub-sentinel `is_series` flag set by Phase 2 merge); T016–T017 can run in parallel with Phase 3–4
- **Phase 6 US4 (T018–T019)**: Requires Phase 4 complete (needs Phase 2 sentinel type to inherit)
- **Phase 7 US5 (T020–T022)**: Requires Phase 3–6 complete
- **Phase 8 (T023–T025)**: Requires all prior phases complete; T024–T025 can run in parallel

### User Story Dependencies

- **US1 (P1)**: Requires Phase 2 (foundational) only — independent of US2–US5
- **US2 (P2)**: Requires US1 — needs sub-sentinel descriptor strings and `is_series` flag
- **US3 (P3)**: Core logic requires US1 + US2 (for `is_series_member` from Phase 2 merge); GUI tasks T016–T017 can run after Phase 2 independently
- **US4 (P4)**: Requires US1 + US2 — needs Phase 2 sentinel type to assign as fallback
- **US5 (P5)**: Requires US1–US4 — audit trail validates correct output of all prior steps

### Within Each User Story

- Implement tasks in listed order (earlier tasks set up state used by later ones)
- T016 and T017 (GUI) can be worked in parallel within US3
- T024 and T025 (docs) can be worked in parallel

### Parallel Opportunities

- **T002 and T003** (Phase 2): Different changes — T002 edits `0_index.R` constants, T003 adds to `helper.R`
- **T008** (SENTINEL_PROMPT in `prompts.R`) can be drafted in parallel with T009–T010 (both in `0_index.R` but different sections)
- **T016** (app.R) and **T017** (gt_store.R): Different files — fully parallel
- **T024** (output-schemas.md) and **T025** (pipeline.md): Different files — fully parallel

---

## Parallel Example: Phase 2 (Foundational)

```text
Task T002: Remove .txt/.dat from AGGREGATE_EXT_OVERRIDE in pipeline/0_index.R
Task T003: Add detect_series() to pipeline/helper.R
```

## Parallel Example: US3 GUI tasks

```text
Task T016: Update tools/validation_gui/app.R (is_raw → data_granularity selector)
Task T017: Update tools/validation_gui/gt_store.R (is_raw_gt → data_granularity_gt)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (T001) + Phase 2 (T002–T003)
2. Complete Phase 3 US1 (T004–T007)
3. **STOP and VALIDATE**: Run `run_index()` on IAT paper — confirm ~20 sub-sentinels per aggregate folder, graceful fallback on non-series folder
4. Continue to US2 only after US1 validates

### Incremental Delivery

1. Phase 2 + US1 → Sub-sentinels in place; Phase 1 paths untouched
2. US2 → Phase 2 LLM classification with context; group consistency improves
3. US3 → `data_granularity` column appears; validation GUI updated
4. US4 → Per-file type accuracy confirmed; no .R files typed as data
5. US5 + Polish → Full audit trail + docs updated → PR ready

### Key Integration Point

After T012 (Phase 2 results merged into aggregate_df), the expansion in T013–T022 uses a single source of truth: `aggregate_df` with Phase 2 results + `type_resolved` pre-resolution + `is_series` flag. All downstream columns derive from this.

---

## Notes

- `is_raw` is retired everywhere — do not preserve it in any output or GUI element
- `type_source = "rule"` (old value) must be replaced with `"extension_rule"` — no backward-compat shim needed since the column is new in this feature
- The `too_large` guard in step 6 must account for Phase 2 calls before any LLM work begins (fail fast)
- FR-012 edge case (all files in aggregate folders → skip two-phase split): verify the existing cancel-sentinel fallback path still works after US1 changes
- After T004, the `llm_paths` vector no longer includes sentinel paths — Phase 2 paths are handled separately
