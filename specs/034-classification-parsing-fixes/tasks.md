# Tasks: Classification and Parsing Fixes (034+035+036)

**Input**: Design documents from `specs/034-classification-parsing-fixes/`  
**Branch**: `034-classification-parsing-fixes`  
**Date**: 2026-04-14

---

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel with other [P] tasks (no shared edit site)
- **[Story]**: Which user story this task belongs to
- All paths relative to `data_check/`

---

## Phase 1: User Story 1 — Extension Classification (Priority: P1) 🎯 MVP

**Goal**: `.xlsm` files are exploded into sheets; `.inp`/`.ebs`/`.es` files are classified as code; `.rar` archives are extracted like `.zip` files.

**Independent Test**: Run `run_index()` on a paper containing a `.xlsm`, `.inp`/`.ebs`/`.es` files, and a `.rar` archive. Verify `structure.csv` and `columns.csv` reflect correct types and that `.xlsm` columns are present.

- [x] T001 [P] [US1] Add `"rar"` to `ARCHIVE_EXTS` at `pipeline/0_index.R:27` and add a `rar` branch to `unpack_archive()` at `pipeline/helper.R:142` — call `system2("unrar", c("x", "-y", path, dest))`; return `NULL` on failure (file is silently dropped, no stub rows)
- [x] T002 [P] [US1] Add `inp = "code"`, `ebs = "code"`, `es = "code"` to `AGGREGATE_EXT_OVERRIDE` at `pipeline/0_index.R:32`
- [x] T003 [P] [US1] Add `"xlsm"` to the Excel explosion filter at `pipeline/0_index.R:219` — change `c("xlsx", "xls")` to `c("xlsx", "xls", "xlsm")`

**Checkpoint**: Run on paper `619869505` (RAR paper). Verify extracted contents appear in `structure.csv`. Run on paper `617753562` (xlsm paper). Verify columns appear for the xlsm file.

---

## Phase 2: User Story 3 — Qualtrics Header Stripping (Priority: P1)

**Goal**: Qualtrics CSV exports have ImportId rows stripped before column type detection.

**Independent Test**: Run `run_index()` on a known Qualtrics CSV paper. Verify `columns.csv` shows Qualtrics variable names (not `{"ImportId":...}` strings) as column names.

- [x] T004 [P] [US3] Add Qualtrics ImportId detection inside `extract_column_info()` at `pipeline/0_index.R`, after the `is.null(df)` early-return (~line 829) and before the `auto_named` line (~line 835) — scan first 3 data rows for `^\{.*ImportId` pattern; strip that row and all rows above it

**Checkpoint**: Run on paper `622119391` (Qualtrics paper). Verify no `{"ImportId":...}` values appear in `columns.csv` sample values.

---

## Phase 3: User Story 2 — PDF Classification (Priority: P2)

**Goal**: PDFs never get `data_format = "tabular"`; PDFs co-located with same-stem `.Rmd`/`.qmd`/`.tex` files are labelled `type = "output"`.

**Independent Test**: Run `run_index()` on paper `617730892` (PDF tabular bug) and paper `619831964` (PDF-from-Rmd). Verify no `tabular` format for PDFs; Rmd-paired PDF shows `type = "output"`.

- [x] T005 [P] [US2] Add `"pdf"` to `RAW_EXTENSIONS` at `pipeline/helper.R:229` — so `classify_data_format("pdf")` returns `"raw"` instead of `"tabular"`
- [x] T006 [P] [US2] Add PDF-from-Rmd post-classification fallback at `pipeline/0_index.R`, immediately after `file_df$data_format` is assigned (~line 757) — for each PDF row, check if same `rel_path` stem has a `.rmd`/`.qmd`/`.tex` companion in `file_df`; if so, set `type = "output"`, `type_source = "rmd_pair_rule"`, `data_format = NA`

**Checkpoint**: Inspect `structure.csv` for any `data_format == "tabular"` rows where `ext == "pdf"` — there should be none after T005.

---

## Phase 4: User Story 4 — V\d+ Header Detection (Priority: P2)

**Goal**: Headerless CSVs whose columns base R named `V1`/`V2`/`V3` recover their real column names from row 2.

**Independent Test**: Supply a headerless CSV. Run `run_index()`. Verify `columns.csv` shows real column names, not `V1`, `V2`, `V3`.

- [x] T007 [P] [US4] Add `V\d+` header detection block inside `extract_column_info()` at `pipeline/0_index.R`, immediately after the closing `}` of the existing `if (mean(auto_named) > 0.5)` block (~line 898) — check `mean(grepl("^V\\d+$", names(df))) > 0.5`; apply same sub-header lookahead as the `...N` path using `MULTILEVEL_HEADER_LOOKAHEAD`, but without prefix extraction

**Checkpoint**: Run on paper `615595607` (V1/V2/V3 paper). Verify real column names appear in `columns.csv`.

---

## Phase 5: User Story 5 — Wide Codebook Transpose (Priority: P2)

**Goal**: Wide-format CSV codebooks (variables as columns, stats as rows) are transposed before label extraction.

**Independent Test**: Run `run_codebook_label()` on paper `61984421` (wide codebook paper). Verify `codebook_coverage.csv` shows non-zero coverage.

- [x] T008 [P] [US5] Add wide-format detection + transpose block inside `parse_codebook()` CSV branch at `pipeline/helper.R`, after encoding fallback (~line 785) and before the header-scan loop (~line 789) — check if ≥50% of trimmed lowercased first-column values are in `c("mean", "sd", "se", "min", "max", "median", "label", "type", "note", "n")`; if so, transpose `raw` and prepend a `variable` column from the original row-1 values

**Checkpoint**: Run on paper `61984421`. Verify `codebook_coverage.csv` has `coverage_pct > 0`.

---

## Phase 6: User Story 6 — Range Variable Expansion (Priority: P2)

**Goal**: Codebook entries using `V1–V10` range notation are expanded to individual variable rows before label matching.

**Independent Test**: Run `run_codebook_label()` on paper `620941840` (range variable paper). Verify all variables in the range appear in `labels.csv` with non-NA labels.

- [x] T009 [P] [US6] Add range expansion block inside `match_column_labels()` at `pipeline/helper.R`, after `norm_var <- normalize_varname(codebook_vars_df$codebook_variable)` (~line 938) — match `^([A-Za-z]*)\s*(\d+)\s*[-–]\s*(\d+)$`; expand matching rows to individual variable entries; recompute `norm_var` after expansion

**Checkpoint**: Run on paper `620941840`. Verify `labels.csv` contains label assignments for individual range variables (e.g., `V1`, `V2`, …, `V10`).

---

## Phase 7: Polish & Docs

**Purpose**: Schema documentation and final pipeline validation.

- [x] T010 [P] Update `docs/output-schemas.md` — add `rmd_pair_rule` to the `type_source` enum table
- [ ] T011 Run `runners/run_tests.R` then `runners/report_tests.R`; review the quality report; confirm no regressions across all test papers in `tests/test_papers.csv`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phases 1–6**: All independent of each other — can be worked in any order or in parallel
- **Phase 7**: Depends on all prior phases complete

### Parallel Opportunities

All tasks T001–T009 touch distinct line ranges across two files and can be worked in parallel within a single session. T010 is docs-only. T011 is the final gate.

### User Story Independence

Each story's checkpoint uses a different paper ID. No story depends on another being done first.

---

## Notes

- [P] tasks have no shared edit sites and can be implemented in any order
- T011 is the gate before PR creation — do not open a PR without passing the test suite
- RAR extraction: if `unrar` is unavailable, the file is silently dropped (no stub rows, no new enum values)
