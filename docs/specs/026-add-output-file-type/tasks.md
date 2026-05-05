# Tasks: Add Output File Type

**Input**: Design documents from `specs/026-add-output-file-type/`
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅

**Organization**: Tasks grouped by user story. US1 (distinguish script outputs from supplemental) drives all implementation. US2 (filter outputs from data-quality analysis) is automatically satisfied once US1 is done.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: User story label (US1, US2)

---

## Phase 1: Foundational — LLM Prompt Changes

**Purpose**: Update the two LLM prompts in `pipeline/prompts.R` to recognise `output` as a valid file type. This is the core of the feature — all classification behaviour flows from here.

**⚠️ CRITICAL**: Both prompt changes must be complete before documentation can be finalised.

- [x] T001 [US1] Update `STRUCTURE_PROMPT` in `pipeline/prompts.R` — add `output` type definition between `code` and `supplemental`; update `supplemental` definition to exclude script-generated artefacts and add "When provenance is ambiguous, prefer supplemental"; update image hard-case rule to add `output` branch for script-generated figures (filename contains "figure", "fig", "plot", "graph", "results", or "output" and not in stimuli context); update `.rds`/`.rdata`/`.rda` hard-case rule to change destination from `supplemental` to `output` for plot/figure/graph-named files; add new `.html` hard-case rule (rendered notebook sharing basename with or co-located with `.Rmd`/`.qmd`/`.ipynb` → `output`, otherwise `supplemental`)

- [x] T002 [US1] Update `SENTINEL_PROMPT` in `pipeline/prompts.R` — add `output` type definition between `code` and `supplemental`; update `supplemental` definition to human-authored only; add key-signals rule "Figure/graph/plot series named files (.jpg, .png, .svg) outside stimuli folder → output"

**Checkpoint**: At this point US1 is fully implemented — pipeline will classify rendered notebooks, script-generated figures, and log files as `output`. Run `run_single.R` on a paper with known script outputs to validate.

---

## Phase 2: User Story 1 — Documentation Sync

**Goal**: All documentation reflects the new `output` type and narrowed `supplemental` definition.

**Independent Test**: Read `docs/output-schemas.md` File Types table — `output` present, `supplemental` no longer lists "result figures" or "output graphs".

- [x] T003 [P] [US1] Update `docs/output-schemas.md` — add `output` row to the File Types table (between `code` and `supplemental`); update `supplemental` row to remove "result figures and output graphs" and add explicit note that script-generated artefacts belong to `output` and that `supplemental` is the fallback for ambiguous provenance

- [x] T004 [P] [US1] Update `docs/pipeline.md` — add `output` to the file type list/enum wherever `supplemental`, `data`, `code`, `codebook` are listed (search for "supplemental" to locate all relevant sections)

**Checkpoint**: US1 documentation complete. All type references in docs are consistent.

---

## Phase 3: User Story 2 — Validate Separation in Output

**Goal**: Confirm that `output`-typed files do not appear in `columns.csv` and are excluded from `supplemental` counts.

**Independent Test**: After running the pipeline on a paper with known script outputs, verify `columns.csv` contains no rows sourced from `output`-typed files, and `structure.csv` rows with `type = "output"` are disjoint from `type = "supplemental"` rows.

- [x] T005 [US2] Verify no `columns.csv` rows exist for `output`-typed files — read `pipeline/0_index.R` and confirm that the `type == "data"` gate at the column-extraction step (search for `data_files <- file_df[file_df$type == "data"`) naturally excludes `output` files; add a comment if none exists explaining that `output` files are excluded by this gate

**Checkpoint**: US2 confirmed — `output` files are structurally excluded from column extraction with no code change required.

---

## Phase 4: Polish & Cross-Cutting Concerns

**Purpose**: Constitution amendment and final consistency check.

- [x] T006 [P] Amend `constitution.md` — update Technical Standards "ggplot / plot objects" note from "LLM MUST classify them as `supplemental`" to "LLM MUST classify them as `output`" for plot/figure/graph-named files; bump version from `1.3.0` to `1.3.1`; prepend Sync Impact Report HTML comment documenting the PATCH change

- [x] T007 [P] Review `prompts.R` — ensure the commented-out old `STRUCTURE_PROMPT` block (lines 10–89) also has its "result figures and output graphs → supplemental" notes updated to `output`, or add a `# DEPRECATED` marker so future readers are not confused by the old wording

**Checkpoint**: All files consistent. Ready for PR.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Foundational)**: No dependencies — start immediately; T001 and T002 are in the same file and must be sequential
- **Phase 2 (US1 Docs)**: Can start after Phase 1 is complete; T003 and T004 are in different files — run in parallel
- **Phase 3 (US2 Validation)**: Can start after Phase 1; T005 is a read + comment-add, independent of docs
- **Phase 4 (Polish)**: Can start after Phase 2; T006 and T007 are in different files — run in parallel

### User Story Dependencies

- **US1 (P1)**: Phases 1 + 2 — no dependencies on US2
- **US2 (P2)**: Phase 3 — depends on Phase 1 completion; automatically satisfied by existing routing code

### Parallel Opportunities

- T003 + T004 (both Phase 2): different files, fully parallel
- T003/T004 + T005 (Phase 2 + Phase 3): different files, can overlap
- T006 + T007 (Phase 4): different files, fully parallel

---

## Parallel Example: Phase 2 + Phase 3

```bash
# All of these can run simultaneously after Phase 1 completes:
Task T003: Update docs/output-schemas.md
Task T004: Update docs/pipeline.md
Task T005: Verify 0_index.R column-extraction gate
```

---

## Implementation Strategy

### MVP (US1 Only)

1. Complete Phase 1: Update both prompts (T001, T002)
2. **STOP and VALIDATE**: Run `run_single.R` on a paper with a rendered HTML report and a stimulus folder — confirm HTML → `output`, stimulus images → `asset`
3. Complete Phase 2: Sync documentation (T003, T004)
4. Deploy/merge MVP

### Full Delivery

1. MVP (above)
2. Phase 3: Validate US2 column-extraction exclusion (T005)
3. Phase 4: Constitution amendment + old-prompt cleanup (T006, T007)
4. PR to `dev`

---

## Notes

- T001 touches multiple sections of `STRUCTURE_PROMPT` — read the full prompt before editing to avoid missing the commented-out legacy block (lines 10–89)
- T002 touches `SENTINEL_PROMPT` only — shorter edit, but verify the key signals section is complete
- No new R packages, no new constants, no new CSV columns — this is a prompt-only + docs change
- Retroactive reclassification happens automatically on next `run_index()` call per paper; no backfill script needed
