# Tasks: LLM Retry and Failure Logging

**Input**: Design documents from `/specs/027-llm-retry-logging/`
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅, quickstart.md ✅

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Define new constants and prepare the log directory entry point

- [x] T001 Add `LLM_RETRY_LIMIT <- 3L`, `LLM_ERROR_LOG <- "logs/llm_batch_errors.log"`, and `LLM_SENTINEL_VAL <- "llm_error"` constants alongside `LLM_BATCH_SIZE` in `pipeline/0_index.R`
- [x] T002 [P] Add `logs/` entry to `.gitignore` so runtime log files are never committed

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Extend the `llm_batch()` signature — required before any story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 Extend `llm_batch()` in `pipeline/helper.R` — add three optional parameters to the function signature: `sentinel_cols = NULL`, `paper_id = NULL`, `stage_name = NULL`

**Checkpoint**: `llm_batch()` accepts new parameters (with `NULL` defaults — existing call sites remain unbroken); user story work can begin

---

## Phase 3: User Story 1 — Review LLM Failures After a Bulk Run (Priority: P1) 🎯 MVP

**Goal**: Write a persistent, append-only log entry to disk whenever a batch chunk fails, containing timestamp, paper ID, stage name, chunk index, item count, and raw LLM response

**Independent Test**: Override `llm()` in the metacheck namespace to return malformed JSON, set `LLM_RETRY_LIMIT <- 0L`, run `llm_batch()` with `paper_id` and `stage_name`, then confirm an entry appears in `logs/llm_batch_errors.log` (see `quickstart.md` Smoke Test — Story 1)

### Implementation for User Story 1

- [x] T004 [US1] Implement log writer inside `llm_batch()` in `pipeline/helper.R`: on chunk failure call `dir.create(dirname(LLM_ERROR_LOG), recursive = TRUE, showWarnings = FALSE)`, then `cat()` a formatted block (`[ISO8601] paper_id=... stage=... chunk=... n_items=...\n--- raw response ---\n<raw>\n---\n\n`) to `LLM_ERROR_LOG` with `append = TRUE`
- [x] T005 [US1] Update all 4 `llm_batch()` call sites in `pipeline/0_index.R` to pass `paper_id` and `stage_name` arguments: `"file-type Phase 1"`, `"file-type Phase 2"`, `"col-type Batch 1"`, `"col-type Batch 2"`

**Checkpoint**: Run Smoke Test — Story 1 from `quickstart.md`; log entry must appear with correct fields. Zero-failure runs must produce no log output

---

## Phase 4: User Story 2 — Automatic Retry of Failed LLM Batches (Priority: P2)

**Goal**: Wrap each per-chunk `llm()` call in a retry loop; retry up to `LLM_RETRY_LIMIT` times on failure before accepting the chunk as irrecoverable; emit a `message()` per retry attempt

**Independent Test**: Inject a failure-then-success pattern (bad JSON on attempt 1, valid JSON on attempt 2), set `LLM_RETRY_LIMIT <- 3L`, confirm the item is correctly classified and no log entry is written (see `quickstart.md` Smoke Test — Story 2)

### Implementation for User Story 2

- [x] T006 [US2] Wrap the per-chunk `llm()` call in `pipeline/helper.R` in a retry loop: initialize `attempt <- 1L`; on parse failure, if `attempt <= LLM_RETRY_LIMIT` emit `message(sprintf("── LLM chunk %d retry %d/%d ──", i, attempt, LLM_RETRY_LIMIT))`, increment `attempt`, and re-try; break on success
- [x] T007 [US2] Move log write to trigger only after the final retry attempt fails in `pipeline/helper.R`; replace the per-failure `warning()` with a post-loop `warning()` that fires only when all retries are exhausted

**Checkpoint**: Run Smoke Test — Story 2 from `quickstart.md`; item must be classified correctly on retry with no log entry; run Smoke Test — Story 1 again to confirm logging still fires after `LLM_RETRY_LIMIT` failures

---

## Phase 5: User Story 3 — Sentinel Value for Unresolvable LLM Failures (Priority: P3)

**Goal**: After all retries are exhausted, items in the failed chunk receive `"llm_error"` in `sentinel_cols` rather than `fallback_vals`; `VALID_COL_TYPES` guard is updated so sentinel rows are never remapped; sentinel is documented in output schemas

**Independent Test**: Force a chunk to exhaust all retries; open the returned data frame and confirm `sentinel_cols` contain `"llm_error"` while non-sentinel `extra_cols` retain their `fallback_vals` (see `quickstart.md` Smoke Test — Story 3)

### Implementation for User Story 3

- [x] T008 [US3] On final retry failure in `pipeline/helper.R`, build an `error_fallback` row: for each column in `extra_cols`, use `LLM_SENTINEL_VAL` if the column is in `sentinel_cols`, otherwise use the corresponding value from `fallback_vals`; use `error_fallback` as the chunk result instead of the plain `fallback_vals` row
- [x] T009 [US3] Append `LLM_SENTINEL_VAL` to the `VALID_COL_TYPES` vector in `pipeline/0_index.R` (prevents the invalid-type guard from remapping sentinel rows to `"unknown"`)
- [x] T010 [P] [US3] Update all 4 `llm_batch()` call sites in `pipeline/0_index.R` to pass `sentinel_cols`: `"type"` for file-type call sites, `"col_type"` for col-type call sites
- [x] T011 [P] [US3] Add `llm_error` row to the File Types enum table and the Column Types enum table in `docs/output-schemas.md` per the schema updates specified in `specs/027-llm-retry-logging/data-model.md`

**Checkpoint**: Run Smoke Test — Story 3 from `quickstart.md`; all three stories should now be fully functional together

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Validation across all stories and regression check

- [x] T012 Run `source("runners/run_tests.R")` then `source("runners/report_tests.R")`; review `results/test_report_<date>.md` and confirm no regressions in existing papers
- [x] T013 [P] Verify `LLM_RETRY_LIMIT <- 0L` backward-compatibility case from `quickstart.md`: one attempt, sentinel/log on failure, identical to pre-feature behavior

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately; T001 and T002 are parallel
- **Foundational (Phase 2)**: Depends on T001 (constants must exist before signature extension); BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational (Phase 2)
- **User Story 2 (Phase 4)**: Depends on User Story 1 (logging must exist before retry moves it to final-failure path)
- **User Story 3 (Phase 5)**: Depends on User Story 2 (sentinel applied on retry exhaustion)
- **Polish (Phase 6)**: Depends on all user story phases

### User Story Dependencies

- **US1 (P1)**: Requires Foundational complete; no dependency on US2 or US3
- **US2 (P2)**: Requires US1 complete (log write is called inside the retry loop's failure branch)
- **US3 (P3)**: Requires US2 complete (sentinel is built after the retry loop exits)

### Within Each User Story

- T004 (log writer) before T005 (call sites that trigger it) — but both can be done in the same editing session
- T008 (sentinel row construction) before T009/T010 (guard + call sites that pass sentinel_cols)
- T010 and T011 are parallel (different files)

### Parallel Opportunities

- T001 and T002 (Phase 1) can run in parallel — different files
- T010 and T011 (Phase 5) can run in parallel — different files
- T012 and T013 (Phase 6) can run in parallel — independent validations

---

## Parallel Example: User Story 3

```
# These two tasks touch different files — run together:
T010: Update call sites in pipeline/0_index.R with sentinel_cols
T011: Add llm_error to docs/output-schemas.md
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001, T002)
2. Complete Phase 2: Foundational (T003)
3. Complete Phase 3: User Story 1 (T004, T005)
4. **STOP and VALIDATE**: Run Smoke Test — Story 1 from `quickstart.md`
5. Failures are now visible in the log — core value delivered

### Incremental Delivery

1. Setup + Foundational → constants defined, signature extended
2. Add US1 → failures logged → validate with quickstart smoke test
3. Add US2 → transient failures recovered silently → validate retry smoke test
4. Add US3 → sentinel in output CSVs → validate sentinel smoke test
5. Polish → confirm no regressions in existing test papers

---

## Notes

- [P] tasks = different files, no dependencies on in-progress tasks
- [Story] label maps task to specific user story for traceability
- All three stories modify `pipeline/helper.R` — implement sequentially in priority order
- `pipeline/0_index.R` is touched across multiple phases: constants (T001), call sites paper_id/stage (T005), VALID_COL_TYPES (T009), call sites sentinel (T010) — review the full diff before committing
- Retry loop does NOT increment the per-paper chunk-count cap — retries are within the same chunk slot (see plan.md Performance Goals)
