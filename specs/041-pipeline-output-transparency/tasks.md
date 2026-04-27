# Tasks: Pipeline Output Transparency

**Input**: Design documents from `/specs/041-pipeline-output-transparency/`  
**Architecture**: All changes inside pipeline functions only. No runner changes.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Parallelizable — different files, no incomplete dependencies
- **[Story]**: User story from spec.md

---

## Phase 1: Setup

- [ ] T001 Confirm already-complete pipeline changes in `0_index.R` (method labels, legends, zero-col explanation) and `helper.R` (retry reason) and `3_psychds_convert.R` (error translation) still apply cleanly

---

## Phase 2: User Story 1 — Stage Verdict inside `run_codebook_label()` (Priority: P1) 🎯 MVP

**Goal**: `run_codebook_label()` prints its own final outcome line so any caller — any runner — sees a clear verdict without needing to format the return value.

**Why here**: `run_codebook_label()` already knows `overall_status`, `n_labelled`, `n_unlabelled` before returning. One print line here benefits all runners universally.

**Independent Test**: Run any runner that calls `run_codebook_label()`; verify a summary line like `── Codebook label: status=ok  labelled=42  unlabelled=37` appears at the end of Stage 2 output, printed by the function itself.

### Implementation

- [ ] T002 [US1] In `pipeline/2_codebook_label.R`, in section `── 8. Return LabellingResult` (just before the final `list(...)` return), add a `cat()` that prints the stage outcome: `── Codebook label: status=<status>  labelled=N  unlabelled=N`; status values `ok` / `no_match` / `no_codebook` are already computed in `overall_status`

**Checkpoint**: Every `run_codebook_label()` call ends with a readable summary line regardless of which runner called it.

---

## Phase 3: User Story 4 — Coverage Percentage inside `run_codebook_label()` (Priority: P3)

**Goal**: Replace `coverage: {"unmatched_in_data":9}` (printed by callers from raw return value) with a human-readable `coverage=matched/total (X%)` printed by the function itself.

**Independent Test**: Run any pipeline that calls `run_codebook_label()` on a paper with a codebook; verify `coverage=N/M (X%)` appears in the output, printed during Stage 2, not formatted by the runner.

### Implementation

- [ ] T003 [US4] In `pipeline/2_codebook_label.R`, extend the T002 print line to include coverage when a codebook was present: `── Codebook label: status=<status>  labelled=N  unlabelled=N  coverage=matched/total (X%)`; omit coverage when `n_codebook_vars == 0` (no codebook)

**Checkpoint**: Coverage always shown as a percentage from inside the function. Raw JSON no longer needed by runners.

---

## Phase 4: Verify Already-Complete Changes (Priority: P2/P3)

These changes were implemented in the previous pass and are already in the codebase. This phase confirms they are correct and complete.

**US2 — Classification method labels** (`0_index.R`):

- [ ] T004 [P] [US2] Verify `pipeline/0_index.R` aggregate classification print (~line 759) shows `[LLM]` suffix and `[rules]` on `individual [rules]` gran_label — confirm via a test run output

**US3 — Retry reason + error translation**:

- [ ] T005 [P] [US3] Verify `pipeline/helper.R` retry separator includes reason (e.g. `── LLM batch 1/2 retry 1/3 — llm_validation: invalid type... ──`) — check `logs/llm_batch_errors.log` for a paper that retried
- [ ] T006 [P] [US3] Verify `pipeline/3_psychds_convert.R` `translate_psychds_error()` function exists and is called at both tryCatch error handlers (~lines 1060 and 1129 in the modified file)

**US4 — Zero-col explanation** (`0_index.R`):

- [ ] T007 [P] [US4] Verify `pipeline/0_index.R` "No columns extracted" message includes combined-only explanation when individual files present — read the modified section at ~line 1599

**US5 — Terminology legends** (`0_index.R`):

- [ ] T008 [P] [US5] Verify `pipeline/0_index.R` prints file type legend and groups note before the File inventory table — confirm in a test run output (already visible in user-provided output)
- [ ] T009 [P] [US5] Verify `pipeline/0_index.R` prints granularity legend once before first granularity inference — confirm flag `granularity_legend_printed` is initialised and checked

---

## Phase 5: Polish

- [ ] T010 Run `runners/run_tests.R` then `runners/report_tests.R`; verify no regressions against test papers
- [ ] T011 [P] Review `docs/pipeline.md` for any documented output format that changed; update if needed

---

## Dependencies & Execution Order

- T002 → T003 (same function, same section — T003 extends T002's print line)
- T004–T009 are independent verifications — all parallel
- T010 depends on T002–T009 complete

## Key Constraint

`pipeline/2_codebook_label.R` is the only file that still needs new code (T002/T003). All other pipeline changes are already in place. Runners are not modified.

## Implementation Strategy

**MVP (2 tasks)**: T002 + T003 — one print line added to `run_codebook_label()`. Delivers US1 + US4 for all runners immediately.
