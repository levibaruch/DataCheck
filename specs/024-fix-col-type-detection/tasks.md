# Tasks: Fix Column Type Detection

**Feature**: `024-fix-col-type-detection`
**Input**: `specs/024-fix-col-type-detection/` (spec.md, plan.md, data-model.md, research.md)

> Previously completed tasks (T001–T009) implemented US1–US4 and the rule-based char fallback.
> This task list supersedes the previous one. T001–T009 are re-listed as complete; T010+ cover
> the new character LLM routing work (FR-005 rewrite, FR-010–FR-012).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no blocking dependency)
- **[Story]**: User story this task belongs to
- All paths relative to `data_check/`

---

## Phase 1: Setup

No project initialization required.

---

## Phase 2: Foundational (Already Complete)

- [x] T001 Add `"constant"` to `VALID_COL_TYPES` in `pipeline/0_index.R`

---

## Phase 3: User Story 1 — ID Columns Reliably Detected (P1) ✅

- [x] T002 [US1] Rewrite ID rule in `classify_col_type_rules()` in `pipeline/helper.R` — expanded regex, hard-classify as `id`, no LLM routing, no whole-number guard

---

## Phase 4: User Story 2 — Unknown Rate Reduced (P1) — Numeric Batch ✅

- [x] T003 [P] [US2] Narrow `COLUMN_TYPE_PROMPT` to 6 types in `pipeline/prompts.R`
- [x] T004 [P] [US2] ~~Rule-based char unknown fallback~~ — superseded by T011/T012 (character LLM batch)

---

## Phase 5: User Story 3 — Constant Columns Separated (P2) ✅

- [x] T005 [US3] Add constant rule (`n_unique == 1`) in `pipeline/helper.R`
- [x] T006 [US3] Narrow binary rule from `n_unique <= 2` to `n_unique == 2` in `pipeline/helper.R`

---

## Phase 6: User Story 4 — "other" Eliminated (P2) ✅

- [x] T007 [US4] Add invalid-type logging in `pipeline/0_index.R`

---

## Phase 7: Polish (Batch 1) ✅

- [x] T008 [P] Update `docs/output-schemas.md` — constant row, binary/id descriptions, stats footnote
- [x] T009 [P] Update `progress.md` with feature 024 entry

---

## Phase 8: User Story 2 (continued) — Character Column LLM Routing (P1) 🔄 NEW

**Goal**: Character columns that rules can't deterministically classify are sent to a dedicated second LLM batch using `CHAR_COLUMN_TYPE_PROMPT`, with up to 20 sampled unique values and an independent resource cap.

**Independent Test**: Run a paper with string-value columns (e.g., condition labels, rating labels). Check `outputs/<paper_id>/columns.csv` — columns with string values like `"low"/"medium"/"high"` should receive `ordinal` or `categorical`, not the old hardcoded `categorical`/`text`. Check no `unknown` in character columns.

- [x] T010 Add `MAX_CHAR_COL_TYPE_LLM_CALLS <- 3L` constant to `pipeline/0_index.R` alongside the other LLM call constants (~line 49)

- [x] T011 Rewrite Rule 9 in `classify_col_type_rules()` in `pipeline/helper.R`: replace the former `categorical` rule and text fallback with a single char-ambiguous routing return: `return(list(col_type = NA_character_, ambiguous = TRUE, numeric_values = NULL, n_coerced = NA_integer_, is_numeric = FALSE))`. Remove the old text fallback (Rule 10) — all remaining character columns now route to the LLM.

- [x] T012 [P] Add `CHAR_COLUMN_TYPE_PROMPT` to `pipeline/prompts.R` — types: `categorical`, `ordinal`, `binary`, `text`, `id`, `unknown` (no `continuous`); include string-value examples; tighten `unknown` definition

- [x] T013 Update `sample_values_unique` computation in `pipeline/0_index.R` (inside `extract_column_info`): increase unique-value cap from 10 to 20 for char-ambiguous columns. Use `cap <- if (isTRUE(is_numeric_vec[i])) 10L else 20L` when building `sample_vals_unique`.

- [x] T014 Split the single LLM batch block in `pipeline/0_index.R` into two sequential batches:
  - **Batch 1** (existing, ~line 888): filter `ambig_rows` to `is_numeric == TRUE` only; use `COLUMN_TYPE_PROMPT`; keep existing numeric `unknown → continuous` fallback
  - **Batch 2** (new): `char_ambig_rows <- which(is.na(columns_df$col_type) & !columns_df$is_numeric)`; truncate to `MAX_CHAR_COL_TYPE_LLM_CALLS * LLM_BATCH_SIZE` only when `!FULL_RUN` (same pattern as Batch 1 — full run bypasses the cap); use `CHAR_COLUMN_TYPE_PROMPT`; invalid types and `"unknown"` → `"text"`; emit `message()` for both remappings

**Checkpoint**: After T010–T014, string-value columns route to Batch 2 and receive LLM-assigned types. `pipeline/0_index.R` runs two `llm_batch()` calls per paper (when both column types are present).

---

## Phase 9: Constitution Amendment

**Purpose**: Document `MAX_CHAR_COL_TYPE_LLM_CALLS` per Principle III governance requirements.

- [x] T015 Update `.specify/memory/constitution.md`: add `MAX_CHAR_COL_TYPE_LLM_CALLS` (default 3) to the Principle III resource limits list; add a row to the constants table; bump version 1.2.0 → 1.3.0; update the Sync Impact Report comment

**Checkpoint**: Constitution version is 1.3.0; new constant is documented.

---

## Phase 10: Polish

- [x] T016 [P] Update `docs/output-schemas.md` pipeline workflow section to note the two-batch column classification step (Batch 1: numeric; Batch 2: character)
- [x] T017 [P] Update `progress.md` with a note about the character LLM routing addition

---

## Dependency Graph

```
[T001–T009 complete]

T010 (new constant)
  └─► T014 (split batches) ← also depends on T011 (char routing in helper.R)

T011 (helper.R char routing)
  └─► T014

T012 (CHAR_COLUMN_TYPE_PROMPT) ─────────► T014
T013 (20-sample cap) ───────────────────► T014

T015 (constitution) — independent, any time
T016, T017 — independent, after T014
```

**Parallel opportunities**: T012 ∥ T013 (different files); T015 ∥ T010–T014; T016 ∥ T017.

---

## Implementation Strategy

**Remaining MVP** (T010–T014): Core character LLM routing — 5 tasks across 3 files.

**Constitution + polish** (T015–T017): Governance and docs — can be done in parallel.

**Suggested PR scope**: T010–T017 as a single PR (second half of feature 024). All existing T001–T009 changes stay in place.
