# Tasks: File Type & Group Taxonomy Refactor (022)

**Input**: Design documents from `/specs/022-file-type-taxonomy-refactor/`
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, contracts/ ✓

**Tests**: Not requested — validation is manual via GUI + ground truth CSVs per spec SC-001.

**Organization**: Tasks grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to
- No project setup needed — all changes are modifications to existing files

---

## Phase 1: Foundational (Blocking Prerequisites)

**Purpose**: Core classifier changes that ALL user stories depend on. Must complete before any story work begins.

**⚠️ CRITICAL**: Both tasks edit `pipeline/0_index.R` — run sequentially.

- [x] T001 Fix `.sps` entry in `AGGREGATE_EXT_OVERRIDE` in `pipeline/0_index.R` — change `sps = "code"` to `sps = "supplemental"` (line ~31)
- [x] T002 Rewrite `STRUCTURE_PROMPT` in `pipeline/0_index.R` (lines 62–111) — replace all 8 type definitions with litmus-test language (per plan.md Step 2) AND rename group `"other"` → `"shared"` AND add explicit `"na"` restriction (only for `readme`/`asset`/`other` types)

**Checkpoint**: Core LLM classifier updated — all user story work can now begin.

---

## Phase 2: User Story 1 — Unambiguous File Type Assignment (Priority: P1) 🎯 MVP

**Goal**: Every file classified into exactly one type with no ambiguity; `type_source` transparency column added to `structure.csv`.

**Independent Test**: Run pipeline on 5 known repos; verify every file has a type matching the new definitions with no "which bucket?" ambiguity (spec US1 acceptance scenarios).

- [x] T003 [US1] Add `type_source` column to `agg_expanded_df` and `non_agg_df` in `pipeline/0_index.R` — `ifelse(to_override, "rule", "llm")` for expanded sentinels; `"llm"` for non-aggregate files (plan.md Step 3, ~lines 457–475)
- [x] T004 [P] [US1] Update `docs/output-schemas.md` — add `type_source` row to `structure.csv` schema table; update all 8 File Types descriptions to match sharpened definitions (plan.md Step 5, partial)

**Checkpoint**: US1 complete — `type_source` in output, all 8 type definitions sharpened in prompt.

---

## Phase 3: User Story 2 — Unambiguous Group Assignment (Priority: P1)

**Goal**: Zero files use group `"other"` in new outputs; `"shared"` and `"na"` are never interchangeable; validation GUI reflects new values.

**Independent Test**: Pick a repo with experiment-specific files, shared files, and readmes. Verify `"na"` appears only on `readme`/`asset`/`other` type files; `"shared"` on cross-experiment research files (spec US2 acceptance scenarios).

- [x] T005 [US2] Update `docs/output-schemas.md` — Groups table: rename `other` → `shared`; update `shared` description; update `na` row to note restriction to `readme`/`asset`/`other` types only (plan.md Step 5, remainder)
- [x] T006 [P] [US2] Update validation GUI group placeholder and hint text in `tools/validation_gui/app.R` — line ~501: placeholder `"ex1, other, na …"` → `"ex1, shared, na …"`; any other references to group `"other"` in help text
- [ ] T007 [US2] Review and re-label `ground_truth/` CSVs (manual) — change `group_gt = "other"` → `"shared"` or `"na"` as appropriate; change `type_gt = "asset"` for result figures → `"supplemental"` (spec FR-009b; depends on T002 being merged first so definitions are clear)

**Checkpoint**: US2 complete — no legacy `"other"` group in any new output; GUI updated; ground truth aligned.

---

## Phase 4: User Story 3 — Consistent Experiment Numbering Across Large Repos (Priority: P2)

**Goal**: Files from the same experiment always receive the same group label regardless of which LLM batch they appeared in.

**Independent Test**: Run pipeline on a repo with 60+ files spanning 3 experiments. Verify group labels are consistent — no experiment's files split between `ex2` and `shared` (spec US3 acceptance scenarios).

- [x] T008 [US3] Change `LLM_BATCH_SIZE` default from `20` to `30` in `pipeline/0_index.R` (line ~41: `if (!exists("LLM_BATCH_SIZE")) LLM_BATCH_SIZE <- 30`)
- [x] T009 [US3] Replace single `llm_batch()` call with chunk loop in `run_index()` in `pipeline/0_index.R` — implement `build_structure_summary()` and `update_experiment_map()` as inline helpers; pass incremental experiment-map header as `user_prefix` for batches 2+ (plan.md Step 4b, ~lines 408–423)

**Checkpoint**: US3 complete — large repos classified with cross-batch context; batch size 30.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and constitution updates that reflect completed changes across all stories.

- [x] T010 [P] Update `docs/pipeline.md` — `LLM_BATCH_SIZE` constant table entry `20` → `30`; update step 5 in Processing Order to note incremental structure summary for batches 2+ (plan.md Step 6)
- [x] T011 [P] Update `.specify/memory/constitution.md` — `LLM_BATCH_SIZE` constant table `20` → `30`; Principle III parenthetical `"200 paths at batch size 20"` → `"300 paths at batch size 30"`; version bump `1.1.0` → `1.1.1` (plan.md Step 8)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 1)**: No dependencies — start immediately
- **US1 (Phase 2)**: Depends on Phase 1 completion (T001, T002 must be done)
- **US2 (Phase 3)**: Depends on Phase 1 completion (T002 defines group `shared`/`na`)
- **US3 (Phase 4)**: Independent of US1/US2 — can start after Phase 1 (only touches batch loop logic)
- **Polish (Phase 5)**: Depends on all story phases complete

### User Story Dependencies

- **US1 and US2**: Both depend on T002 (STRUCTURE_PROMPT rewrite); US1 and US2 work can proceed in parallel after T002
- **US3**: Only depends on T001/T002 being done; T008 and T009 are independent of US1/US2 tasks

### Within Each Phase

- T001 → T002 (sequential, same file)
- T003 → T004 can run in parallel (different files: `0_index.R` vs `output-schemas.md`)
- T005 → T006 can run in parallel (different files: `output-schemas.md` vs `app.R`)
- T007 depends on T002 being merged (needs new definitions to be clear)
- T008 → T009 sequential (same file: `0_index.R`)
- T010, T011 fully parallel (different files)

---

## Parallel Opportunities

```bash
# After Phase 1 completes (T001, T002 done):
# US1, US2, US3 can all start in parallel:

US1: T003 (0_index.R) → T004 (output-schemas.md)
US2: T005 (output-schemas.md) then T006 (app.R), T007 (ground_truth/)
US3: T008 (0_index.R) → T009 (0_index.R)

# NOTE: T003 and T008/T009 both touch 0_index.R — run sequentially if solo
# T004 and T005 both touch output-schemas.md — run sequentially
```

---

## Implementation Strategy

### MVP (US1 + US2 only — both P1)

1. Complete Phase 1: Foundational (T001, T002)
2. Complete Phase 2: US1 (T003, T004)
3. Complete Phase 3: US2 (T005, T006, T007)
4. **STOP and VALIDATE**: Run pipeline on known repos; check type/group assignments against acceptance scenarios
5. Merge to `dev` branch

### Full Delivery

1. MVP above
2. Complete Phase 4: US3 (T008, T009)
3. Validate: run on 60+ file repo, check cross-batch group consistency
4. Complete Phase 5: Polish (T010, T011)
5. PR to `dev`

---

## Notes

- All changes are to existing files — no new files created except possibly in `ground_truth/`
- T002 is the largest single task (full STRUCTURE_PROMPT rewrite) — refer to plan.md Step 2 for the exact wording of all 8 type definitions
- T009 is the most complex task — refer to plan.md Step 4b for the pseudocode and helper function specs
- T007 is manual — run after T002 is written so the new definitions are clear
- PRs MUST target `dev`, not `main`
