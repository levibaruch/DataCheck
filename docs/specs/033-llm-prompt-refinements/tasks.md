# Tasks: LLM Prompt Refinements

**Branch**: `033-llm-prompt-refinements`
**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

Single file modified: `pipeline/prompts.R` — all tasks are sequential edits to `STRUCTURE_PROMPT`.

---

## Phase 1: Foundational

**Purpose**: Read and understand the current prompt before editing.

- [x] T001 Read `pipeline/prompts.R` in full — locate the "Hard cases" section of `STRUCTURE_PROMPT` and identify the exact insertion points for each new rule

---

## Phase 2: P1 Rules — Experiment log files + Intermediate results (US1, US2)

**Goal**: Fix the two highest-impact misclassifications — experiment `.log` files being labelled `output`, and intermediate result CSVs being labelled `output`.

**Independent Test**: Run pipeline on a paper with PsychoPy/E-Prime `.log` files in a `data/` folder and verify `type = "data"` in structure.csv. Run on a paper with `scores_cleaned.csv` and verify `type = "data"`.

- [x] T002 [US1] Extend the `.log/.out` hard case in `STRUCTURE_PROMPT` (`pipeline/prompts.R`) to also classify `.log` files as `data` when the file is inside a folder named `data`, `raw`, or the task name — even without a participant ID in the filename
- [x] T003 [US2] Add hard case to `STRUCTURE_PROMPT` (`pipeline/prompts.R`): tabular files (`.csv`, `.sav`, `.dta`, `.xlsx`, `.tsv`, `.dat`) whose names contain `scores`, `processed`, or `cleaned` → `data`, NOT `output`

**Checkpoint**: Re-run `runners/run_tests.R` — verify no regression on existing GT papers.

---

## Phase 3: P2 Rules — Pretest, borrowed data, placeholders (US3, US4, US5)

**Goal**: Fix three group/type misclassifications encountered repeatedly during GT annotation.

**Independent Test**: Run pipeline on a paper with a `pretest/` folder — verify `group != "pilot1"`. Run on a paper with `Smith2019_data.csv` — verify `type = "data"`.

- [x] T004 [US3] Add hard case to `STRUCTURE_PROMPT` (`pipeline/prompts.R`): `pretest` in folder or filename does NOT indicate a pilot — assign `ex<N>` if a study number is present, otherwise `shared`; never `pilot<N>`
- [x] T005 [US4] Add hard case to `STRUCTURE_PROMPT` (`pipeline/prompts.R`): tabular files whose name contains `prior`, `replication`, or a 4-digit year adjacent to a data extension → `data`, not `supplemental`
- [x] T006 [US5] Add hard case to `STRUCTURE_PROMPT` (`pipeline/prompts.R`): files whose name starts with or contains `example_`, `dummy`, or `placeholder` → `other`; include explicit carve-out for compound research-construct names (e.g. `implicit_association_test` — do not trigger on `test` as a standalone word)

**Checkpoint**: Re-run `runners/run_tests.R` — verify no regression.

---

## Phase 4: P3 Rules — Config files + SQL (US6, US7)

**Goal**: Fix config and SQL misclassification (lower priority — less frequent in corpus).

**Independent Test**: Run pipeline on a paper with `config.yaml` in a `task/` folder — verify `type = "software"`. Run on a paper with a `.sql` file — verify `type = "data"`.

- [x] T007 [US6] Add hard case to `STRUCTURE_PROMPT` (`pipeline/prompts.R`): `.yaml`, `.cfg`, `.ini`, `.toml` in an experiment-associated folder (`task/`, `paradigm/`, `experiment/`) → `software`; root-level tooling configs → `other`; config files with `analysis` or `model` in name → `code`
- [x] T008 [US7] Add hard case to `STRUCTURE_PROMPT` (`pipeline/prompts.R`): `.sql` files → `data` by default; exception: name contains `query`, `script`, or `procedure` → `code`

**Checkpoint**: Re-run `runners/run_tests.R` — verify no regression.

---

## Phase 5: Polish & Validation

- [x] T009 Run `runners/run_tests.R` on full GT paper set and confirm overall `type` accuracy does not decrease vs. pre-change baseline
- [x] T010 Run `reports/report_normal.R` and compare per-class metrics — flag any class whose precision or recall drops by more than 2 percentage points
- [x] T011 Update `docs/pipeline.md` to note the seven new hard-case rules under the LLM classification section

---

## Dependencies & Execution Order

- T001 → T002 → T003 → T004 → T005 → T006 → T007 → T008 (all sequential — same file)
- T009 and T010 depend on T008 (run after all rules are added)
- T011 can run after T008 in parallel with T009/T010

## Implementation Strategy

Complete all prompt edits (T001–T008) as a single commit, then validate (T009–T011). Do not commit partial rule sets — the checkpoint after each phase is a run-tests check, not a commit boundary.
