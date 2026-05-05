# Tasks: Software File Type (029)

**Input**: Design documents from `specs/029-software-file-type/`  
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅

**Organization**: Tasks grouped by user story. No tests requested — implementation tasks only.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: User story this task belongs to (US1, US2, US3)
- Exact file paths included in all descriptions

---

## Phase 1: Setup

No setup required — this feature modifies existing files in an established project structure.

---

## Phase 2: Foundational (Blocking Prerequisite)

**Purpose**: Establish the `software` type definition in the canonical schema documentation before any implementation begins. All other tasks depend on this definition being locked.

**⚠️ CRITICAL**: Complete before any user story work begins.

- [x] T001 Update `docs/output-schemas.md`: add `software` row to the File Types table (after `code` row); add `software` to the Consumer registry "Current consumers" section; colour: amber/experiment-delivery tone. Definition: programs whose purpose is to run the experiment — stimulus delivery, task presentation, data collection, compiled binaries (`.exe`, `.app`, `.jar`, `.msi`, `.dmg`), installers. Distinct from `code` (analysis scripts). Notebooks always `code`.

**Checkpoint**: Schema definition locked — implementation can now begin.

---

## Phase 3: User Story 1 — Automatic Classification (Priority: P1) 🎯 MVP

**Goal**: Pipeline automatically assigns `type = "software"` to compiled binaries in aggregate folders and provides the LLM with a `software` type definition for non-aggregate classification.

**Independent Test**: Run the pipeline on a paper containing `.exe` or `.app` files; verify `structure.csv` shows `type = "software"` for those files and `type = "code"` for analysis scripts.

- [x] T002 [US1] Add `software` definition to `STRUCTURE_PROMPT` TYPE block in `pipeline/prompts.R`: insert after the `code` entry — "software : program or application whose purpose is to run the experiment — stimulus delivery, task presentation, data collection tools. Compiled binaries (.exe, .app, .jar, .msi, .dmg) → always software. Notebooks (.ipynb, .Rmd, .qmd) → always code, never software." Also add `"software"` to the JSON schema enum array (currently ends at `"other"`).
- [x] T003 [P] [US1] Add compiled-binary and installer extensions to `AGGREGATE_EXT_OVERRIDE` in `pipeline/0_index.R` (constants block, lines 30–41): add `exe = "software", app = "software", jar = "software", msi = "software", dmg = "software"` as a new named group in the vector. (Parallel with T002 — different file.)
- [x] T004 [US1] Add `software` entry to `SENTINEL_PROMPT` TYPE block in `pipeline/prompts.R` (after the `code` line, ~line 307): "software : series of experiment programs, compiled binaries, or task tools". (Sequential after T002 — same file.)

**Checkpoint**: Pipeline classifies compiled binaries as `software` in aggregates; LLM has `software` as a valid type choice for non-aggregate files.

---

## Phase 4: User Story 2 — LLM Prompt Precision (Priority: P2)

**Goal**: LLM reliably distinguishes `software` from `code` for ambiguous source-language files by using full path context (folder + filename) as the purpose signal.

**Independent Test**: Manually submit filenames like `experiment/run_task.py`, `analysis/clean_data.R`, and `ExperimentTask.exe` to the LLM using the updated prompt; verify correct type returned for each.

- [x] T005 [US2] Add purpose-based hard-case disambiguation rules to `STRUCTURE_PROMPT` in `pipeline/prompts.R` (hard-cases section, after existing `.html`/`.mat` rules): "- code vs software: purpose is the primary signal. Use the full path for context. Analysis/modelling/cleaning scripts → code. Experiment task runners, stimulus apps, compiled programs → software. When the path contains experiment/, task/, paradigm/, or stimulus/ folder AND the file runs something (not a data/codebook/readme/asset), prefer software. Analysis/, results/, scripts/ folder context → code. Notebooks (.ipynb, .Rmd, .qmd) → always code regardless of folder." (Sequential after T004 — same file.)

**Checkpoint**: LLM correctly classifies source-language files using path context; compiled binaries always `software`.

---

## Phase 5: User Story 3 — Validation GUI (Priority: P3)

**Goal**: Annotators can view, assign, and filter by `software` type in the validation GUI with keyboard shortcut `9`, consistent badge styling in light and dark mode.

**Independent Test**: Open the validation GUI; verify a `software` button appears, press `9` to assign it, confirm ground truth CSV updates, and verify amber/brown badge renders in both themes.

*Note: All tasks below modify `tools/validation_gui/app.R` and must run sequentially.*

- [x] T006 [US3] Add `"9" = "software"` to `TYPE_MAP` in `tools/validation_gui/app.R` (line ~28): `TYPE_MAP <- c("1" = "data", ..., "8" = "other", "9" = "software")`. `VALID_TYPES` derives from `TYPE_MAP` automatically — filter panel gains `software` for free.
- [x] T007 [US3] Add `software = "sfw"` to `TYPE_ABBREV` in `tools/validation_gui/app.R` (line ~33): append to the named character vector.
- [x] T008 [US3] Add CSS badge and active-button rules for `software` in `tools/validation_gui/app.R`. Light mode (after `.tbadge-output` line ~318): `.tbadge-software { background:#fff3e0; color:#e65100; }` and `.tbtn-software.tbtn-active { border-color:#e65100 !important; background:rgba(230,101,0,0.1) !important; color:#bf360c !important; box-shadow:0 0 8px rgba(230,101,0,0.2) !important; }`. Dark mode (after `[data-theme='dark'] .tbadge-output` line ~425): `[data-theme='dark'] .tbadge-software { background:rgba(255,183,77,0.22); color:#ffcc80; }` and `[data-theme='dark'] .tbtn-software.tbtn-active { border-color:#ffb300 !important; background:rgba(255,179,0,0.22) !important; color:#ffe082 !important; box-shadow:0 0 10px rgba(255,179,0,0.25) !important; }`.
- [x] T009 [US3] Add `"9"` case to `observeEvent(input$key_press)` handler in `tools/validation_gui/app.R` (after the `"8"` case, ~line 805): `"9" = { rv$selected_type <- "software" },`.
- [x] T010 [US3] Add `"9"` to the JavaScript key allowlist in `tools/validation_gui/app.R` (line ~225): change `["1","2","3","4","5","6","7","8","i","c","g"]` to `["1","2","3","4","5","6","7","8","9","i","c","g"]`.

**Checkpoint**: `software` button visible and functional in GUI; keyboard shortcut `9` works; badge renders correctly in both themes; filter panel lists `software`.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T011a Add `software = "materials"` to `TYPE_TO_SUBDIR` in `pipeline/3_psychds_convert.R` (PsychDS converter subdirectory map); add `.exe`, `.app`, `.jar`, `.msi`, `.dmg` → `"software"` to `AGGREGATE_EXT_OVERRIDE` in `pipeline/3_psychds_convert.R`; update `docs/output-schemas.md` Consumer registry to include both PsychDS entries.
- [ ] T011 Run `runners/run_tests.R` then `runners/report_tests.R`; review quality report; fix any regressions — particularly verify no existing `code` or `other` files in test papers changed type.
- [ ] T012 Review `docs/pipeline.md` step 5 (classify file paths) and update if the workflow description needs to mention the new `software` type.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 2)**: No dependencies — start immediately
- **US1 (Phase 3)**: Depends on Phase 2 (T001 must complete first)
- **US2 (Phase 4)**: Depends on Phase 3 (T002, T004 must complete — same file, sequential)
- **US3 (Phase 5)**: Independent of US1/US2 — can start after Phase 2
- **Polish (Phase 6)**: Depends on all user story phases complete

### User Story Dependencies

- **US1 (P1)**: Depends only on Foundational (T001)
- **US2 (P2)**: Depends on US1 T002 and T004 (same file; must follow)
- **US3 (P3)**: Independent of US1/US2 — can run in parallel with Phase 3+4

### Within Each Phase

- T002 and T003 are parallel (different files: `prompts.R` vs `0_index.R`)
- T004 follows T002 (same file: `prompts.R`)
- T005 follows T004 (same file: `prompts.R`)
- T006 through T010 are sequential (same file: `app.R`)

---

## Parallel Example: US1 + US3 in Parallel

```
# Stream A — prompts + override map (US1/US2):
T001 → T002 → T004 → T005
         ↑ parallel ↑
T003 (0_index.R, can overlap with T002)

# Stream B — validation GUI (US3, independent):
T001 → T006 → T007 → T008 → T009 → T010
```

---

## Implementation Strategy

### MVP First (US1 Only)

1. Complete T001 (schema doc)
2. Complete T002, T003, T004 (basic classification wiring)
3. **STOP and VALIDATE**: run pipeline on a paper with `.exe`/`.app` files; check `structure.csv`
4. Proceed to US2 (prompt precision) then US3 (GUI)

### Incremental Delivery

1. T001 → foundation locked
2. T002 + T003 (parallel) → T004 → compiled binaries classified, LLM has the type
3. T005 → LLM distinguishes purpose for source files  
4. T006–T010 → GUI complete
5. T011–T012 → validated and documented

---

## Notes

- [P] tasks operate on different files and have no incomplete task dependencies
- All `prompts.R` tasks (T002, T004, T005) are sequential — same file
- All `app.R` tasks (T006–T010) are sequential — same file
- `0_index.R` task (T003) is parallel with `prompts.R` tasks
- US3 (GUI) is fully independent of US1/US2 and can be worked on simultaneously
- Commit after each user story phase completes (not after each individual task)
