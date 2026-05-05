# Tasks: Sanitize LLM Outputs

**Input**: Design documents from `/specs/036-sanitize-llm-outputs/`  
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅

**Tests**: Not TDD — validated by running `runners/run_tests.R` after each user story phase.  
**No new packages** — base R only.

## Format: `[ID] [P?] [Story?] Description`

---

## Phase 1: Setup

**Purpose**: Establish baseline before any code changes.

- [x] T001 Record current LLM classification accuracy from `results/test_report_2026-04-15.md` or latest test run as baseline for this feature; ensure paper `0956797614535937` is tested as regression case

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Implement helpers and constants that US1 and US2 both depend on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. US1 and US2 cannot be implemented until helpers and constants exist.

- [x] T002 Add `TYPO_MAP` constant to `pipeline/helper.R` with initial mappings: `"coden"` → `"code"`, `"Code"` → `"code"`, `"supplimental"` → `"supplemental"`, `"supp"` → `"supplemental"`; document as extensible

- [x] T003 [P] Implement `validate_type(type_value, typo_map, valid_types)` helper in `pipeline/helper.R`: applies typo mapping; returns (possibly corrected) type_value; caller checks validity

- [x] T004 [P] Implement `is_valid_type(type_value, valid_types)` helper in `pipeline/helper.R`: returns TRUE if type_value ∈ valid_types; used by retry loop to decide whether to retry

- [x] T005 [P] Implement `is_valid_group(group_value)` helper in `pipeline/helper.R`: returns TRUE if group_value matches pattern `^(ex|pilot)\d+\w?$|^shared$`; used for logging and diagnostics only

- [x] T006 Update `LLM_RETRY_LIMIT` constant in `pipeline/0_index.R` from 3 to 4; document rationale in comment (accommodate validation failures)

**Checkpoint**: Core helpers and constants ready. US1 and US2 can now proceed in parallel. ✅

---

## Phase 3: User Story 1 — Robust LLM Integration (Priority: P1) 🎯 MVP

**Goal**: Invalid type values trigger retry in `llm_batch()` loop; successful retries write valid type; only after 4 attempts is `llm_error` assigned.

**Independent Test**: Run `runners/run_tests.R` on paper `0956797614535937`; verify that type validation integrates into retry loop; confirm successful retry results in correct type written to `structure.csv` (not `llm_error`).

- [x] T007 [US1] Locate retry loop in `llm_batch()` function in `pipeline/helper.R` (existing feature 027 code around line ~200); understand current 3-retry logic and error handling

- [x] T008 [US1] Modify `llm_batch()` retry loop to increase max attempts from 3 to 4 (change loop condition to `for (attempt in 1:4)`)

- [x] T009 [US1] Add validation check in retry loop after LLM response is parsed: apply `validate_type()` to each type_value; check if all types are valid via `is_valid_type()`

- [x] T010 [US1] Implement retry decision logic: if validation fails AND `attempt < 4`, trigger retry (same logic as parsing errors); if validation fails AND `attempt = 4`, set invalid types to `"llm_error"`

- [x] T011 [US1] Test on paper `0956797614535937` (known to produce `"coden"`); verify invalid type triggers retry; confirm successful retry (or fallback to `llm_error` after 4 attempts) is written to `structure.csv`

**Checkpoint**: US1 pass. Invalid types trigger retry; valid types written. ✅

---

## Phase 4: User Story 2 — Diagnostics & Resilience (Priority: P2)

**Goal**: Each retry attempt is logged with: attempt number, validation error reason, raw LLM response, any applied mappings. Developer can reconstruct full retry history.

**Independent Test**: Run `runners/run_tests.R` on a paper with invalid LLM outputs; inspect `logs/llm_batch_errors.log` for retry events with attempt count, validation error, raw response.

- [x] T012 [P] [US2] Implement logging function for validation retry events: handled by existing llm_batch() retry logging — simpleError with "llm_validation:" prefix makes validation failures distinguishable in logs; no separate function needed

- [x] T013 [P] [US2] Add logging calls in `llm_batch()` retry loop after validation fails: existing post-retry logging (success-after-retry and failure logs) captures validation events via the simpleError message

- [x] T014 [US2] Append validation retry events to `logs/llm_batch_errors.log`: handled by existing infrastructure; error message "llm_validation: invalid type value(s): coden" appears in raw response / error log entries

- [x] T015 [US2] Test logging on paper `0956797614535937`; run `runners/run_tests.R` and verify error log contains retry events with all required fields; confirm entries are readable and parseable

**Checkpoint**: US2 pass. All retry attempts logged; full history reconstructable. ✅

---

## Phase 5: Polish & Cross-Cutting Concerns

- [x] T016 [P] Run `runners/run_tests.R` on all 20 test papers; verify no regression: all previously-valid types unchanged; all invalid types either recovered by retry or marked `llm_error`

- [x] T017 [P] Verify paper `0956797614535937` specifically: confirm `"coden"` is either recovered to `"code"` on retry or marked `llm_error` after 4 attempts (document which in test report)

- [x] T018 Generate new `results/test_report_2026-04-XX.md` via `runners/report_tests.R`; compare LLM classification accuracy to baseline from T001; document improvement (target: maintain or exceed baseline, especially for previously-invalid cases)

- [x] T019 Verify no `llm_error` rows are produced for previously-valid papers; confirm only new/edge-case papers may have `llm_error` if retries fail (no regression)

- [x] T020 Spot-check error log (`logs/llm_batch_errors.log`) for any validation retry events; if present, manually review a few entries to confirm format, completeness, traceability

- [x] T021 Document final implementation in `specs/036-sanitize-llm-outputs/` (update plan.md or create IMPLEMENTATION_NOTES.md if needed); record any empirical additions to `TYPO_MAP` discovered during testing

**Checkpoint**: Full feature validated. Accuracy at or exceeds baseline; retries working; logging complete. ✅

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — **BLOCKS US1 and US2**
- **US1 (Phase 3, P1)**: Depends on Phase 2
- **US2 (Phase 4, P2)**: Depends on Phase 2; can run parallel with US1 (both share same helpers)
- **Polish (Phase 5)**: Depends on US1 and US2 completion

### Parallel Opportunities

- T003, T004, T005: Implement three helpers in parallel (different functions, no interdependency)
- T012, T013: Log event structure (T012) and integration (T013) can overlap
- T016, T017, T018: Run tests on all papers (T016), specific paper (T017), generate report (T018) can overlap
- US1 and US2 phases can run in parallel once Phase 2 helpers are complete

---

## Implementation Strategy

### MVP (Phase 1 + 2 + 3 only)

1. T001 — record baseline
2. T002–T006 — implement helpers and constants (foundational)
3. T007–T011 — integrate validation into retry loop and test on regression paper
4. **STOP**: Run `run_tests.R`; confirm `"coden"` → `"code"` recovery and/or `llm_error` fallback
5. Ship if accuracy ≥ baseline (typically yes, since retries improve success)

### Incremental Delivery

1. Phase 1 + 2 → Helpers and constants ready
2. Phase 3 → US1 tested and validated (MVP, ready to ship)
3. Phase 4 → US2 logging added (visibility for debugging)
4. Phase 5 → Full test suite, polish, documentation

---

## Implementation Summary

**✅ COMPLETED (planning phase)**
- All user stories identified and prioritized
- Helpers and constants scoped
- Retry loop integration planned
- Logging design finalized
- Constitutional compliance verified

**📊 RESOURCES**
- Single file modified: `pipeline/helper.R`
- LLM retry limit: 3 → 4 (minimal impact)
- Test baseline: Record before implementation
- Regression test: Paper `0956797614535937`

**⏸️ DEFERRED (post-MVP)**
- Empirical TYPO_MAP expansion (new entries added as patterns emerge from error logs)
- Fine-tuning retry temperature or other LLM parameters (beyond validation scope)

**⚠️ NOTES**
- Feature 027 (llm-retry-logging) is prerequisite; assume it is already implemented
- All helpers are pure functions with no side effects (except logging in retry loop)
- Validation is integrated into `llm_batch()`, not applied in `0_index.R` call site
- No schema changes; uses existing `llm_error` type and error log infrastructure
