# Feature Specification: Classification and Parsing Fixes (034+035+036)

**Feature Branch**: `034-classification-parsing-fixes`  
**Created**: 2026-04-14  
**Status**: Draft  
**Input**: Combined fixes from three planned features — extension/format classification (034), header detection (035), codebook parser improvements (036).

---

## Overview

This feature consolidates three groups of fixes that share the same pipeline files and have no inter-dependencies. Most are deterministic rule additions; User Story 6 extends the existing LLM-based codebook labelling path.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Correct File Type Classification for Known Extensions (Priority: P1)

A researcher downloads a psychology data repository that contains `.xlsm` macro-enabled Excel files, Mplus `.inp` script files, E-Prime `.ebs`/`.es` script files, and `.rar` archives. Without this fix, these files are either misclassified or silently ignored. With the fix, each file is assigned the correct type by deterministic rule before the LLM is consulted, and `.rar` archives are extracted so their contents are indexed.

**Why this priority**: Misclassification of known extension types is the highest-frequency source of incorrect pipeline output. These are deterministic rules with zero ambiguity — no LLM judgement required.

**Independent Test**: Run the pipeline on a paper containing at least one of each file type listed above and verify `structure.csv` output reflects correct `type` assignments and that `.rar` contents appear as indexed files.

**Acceptance Scenarios**:

1. **Given** a repo containing a `.xlsm` file, **When** the pipeline indexes the repo, **Then** the `.xlsm` file is exploded into sheets exactly as `.xlsx` files are.
2. **Given** a repo containing `.inp`, `.ebs`, or `.es` files, **When** the pipeline classifies them, **Then** `type = "code"` for each.
3. **Given** a repo containing a `.rar` archive, **When** the pipeline processes the repo, **Then** the archive is extracted and its contents are indexed in `structure.csv` like any other unpacked archive; if `unrar` is unavailable, the file is silently dropped from the index.

---

### User Story 2 — PDF-from-Rmd Fallback Labelling (Priority: P2)

A researcher's repository contains a PDF that shares its stem name with an `.Rmd` source file — it was compiled from that source. After the LLM assigns this PDF a type (likely `"supplemental"` or `"data"`), a post-classification fallback checks whether a same-stem `.Rmd`, `.qmd`, or `.tex` file exists in the same directory. If so, the PDF's type is overridden to `"output"`. This runs after group assignment so the group context is already available.

**Why this priority**: This is a clean deterministic signal requiring no LLM. The post-classification placement is intentional: group must already be resolved before the fallback fires, so the override is contextually correct.

**Independent Test**: Run the pipeline on a paper where a PDF shares its stem with an `.Rmd` file. Verify the PDF is assigned `type = "output"` in `structure.csv`.

**Acceptance Scenarios**:

1. **Given** a directory containing both `analysis.Rmd` and `analysis.pdf`, **When** the post-classification fallback runs after group assignment, **Then** `analysis.pdf` has its type overridden to `"output"`.
2. **Given** a PDF with no matching source file in the same directory, **When** the fallback runs, **Then** the PDF's type is unchanged.

---

### User Story 3 — Correct Column Extraction for Qualtrics CSV Exports (Priority: P1)

A researcher downloads a paper whose data was collected in Qualtrics and exported as CSV. The Qualtrics export format contains three header rows: variable names, question text labels, and an `ImportId` row (`{"ImportId":"QID1_TEXT"}`). The existing Qualtrics parsing code is extended to cover this stripping for CSV exports — without it, column type detection reads `ImportId` JSON strings as sample values, producing corrupt `col_type` assignments.

**Why this priority**: Qualtrics is among the most common data collection tools in psychology. Corrupt column type detection for Qualtrics files affects a large fraction of the corpus.

**Independent Test**: Run the pipeline on a known Qualtrics CSV export. Verify that `columns.csv` contains the correct variable names (row 1 of the file) and that no `ImportId` strings appear as sample values in the output.

**Acceptance Scenarios**:

1. **Given** a CSV where any value in the first 3 rows matches `^\{.*ImportId`, **When** the pipeline extracts columns, **Then** rows 2 and 3 are dropped and row 1 is used as column names.
2. **Given** a non-Qualtrics CSV, **When** the pipeline checks for the ImportId pattern, **Then** no rows are stripped and extraction proceeds normally.
3. **Given** a Qualtrics CSV where the ImportId string is not in the first 3 rows, **When** the pipeline checks, **Then** no stripping occurs (conservative: only strip when confident).

---

### User Story 4 — V1/V2/V3 Auto-Header Detection (Priority: P2)

A researcher stores data as a CSV with no column headers (or with the true headers in row 2). Base R's `read.csv` names the columns `V1`, `V2`, `V3`, etc. The pipeline's existing multi-level header recovery detects `...N` patterns (from `readxl`) but misses the `V\d+` pattern from base R CSV reading, so row 2 (the real headers) is treated as the first data row. With this fix, the same lookahead logic fires for `V\d+` patterns.

**Why this priority**: This is an extension of existing logic (the `...N` detection already works); `V\d+` is the direct analogue for CSV files read with base R.

**Independent Test**: Supply a headerless CSV file. Verify that `columns.csv` reflects the real column names from row 2, not `V1`, `V2`, `V3`.

**Acceptance Scenarios**:

1. **Given** a CSV where all column names match `^V\d+$`, **When** column extraction runs, **Then** the pipeline applies the sub-header lookahead logic to recover real column names from row 2.
2. **Given** a CSV with legitimate columns named `V1`, `V2` (a real variable naming convention), **When** classified, **Then** the lookahead logic correctly identifies that row 2 does not represent better headers and does not strip the header row.

---

### User Story 5 — Wide-Format Codebook Parsing (Priority: P2)

A researcher's codebook CSV is in wide format: columns are variables, rows are statistics (e.g., `mean`, `sd`, `label`). The current codebook parser assumes long/tidy format and fails to extract labels from this structure. With the fix, the parser detects wide format by checking whether the first column contains known statistic names and, if so, transposes before label extraction.

**Why this priority**: Wide-format codebooks are a documented failure mode that produces 0% coverage for affected papers. The detection heuristic is simple and low-risk.

**Independent Test**: Run the codebook labelling pipeline on a paper with a known wide-format codebook. Verify that `codebook_coverage.csv` shows non-zero coverage and that `labels.csv` contains correct label assignments.

**Acceptance Scenarios**:

1. **Given** a CSV codebook where the first column contains values like `mean`, `sd`, `label`, `min`, `max`, **When** the codebook parser runs, **Then** the data is transposed before label extraction.
2. **Given** a long-format codebook, **When** the first-column heuristic fires, **Then** it correctly identifies non-wide format and does not transpose.

---

### User Story 6 — Range Variable Reference Expansion in Codebook LLM Labelling (Priority: P2)

A psychology codebook describes a battery of items using range notation (e.g., "V1–V10 means agreement with statement"). The codebook LLM labelling step does exact string matching on variable names against the data columns; range entries never match any individual column. With this fix, range patterns are expanded to individual variable names before the LLM labelling match step, so the shared label is applied to each column in the range.

**Why this priority**: Range descriptions are common in multi-item scale batteries, a core construct in psychology data. Without this fix, codebook coverage is artificially low for such papers.

**Independent Test**: Run codebook labelling on a paper whose codebook uses `V1–V10` range notation. Verify that all ten columns receive label assignments in `labels.csv`.

**Acceptance Scenarios**:

1. **Given** a codebook entry with variable name matching `[A-Za-z]*\d+\s*[-–]\s*\d+`, **When** the LLM labelling step processes it, **Then** the entry is expanded to individual variable entries (V1, V2, … V10) before matching against columns.
2. **Given** a codebook with no range references, **When** the expansion check runs, **Then** no behaviour changes.

---

### Edge Cases

- A PDF that shares its stem with an `.Rmd` file but lives in a different directory — the pairing fallback must only match within the same directory.
- A Qualtrics file where row 3 is absent (two-row header variant) — the `ImportId` check should still fire on row 2 and strip only the rows that exist.
- A wide codebook with a first column named `variable` — must not be mistakenly transposed; detection requires known statistic names only (`mean`, `sd`, `label`, `min`, `max`, `type`, `note`).
- A range pattern like `Item1–Item10` (non-`V` prefix) — out of scope; only `V\d+` ranges are handled in this feature.
- A `.rar` file where the `unrar` system binary is not available — extraction fails; the file is silently dropped from the index, consistent with how other archive failures are handled.

---

## Requirements *(mandatory)*

### Functional Requirements

**Extension and Format Classification (034)**

- **FR-001**: The pipeline MUST include `"xlsm"` in the Excel explosion step so that macro-enabled Excel files are unpacked into sheets like `.xlsx` files.
- **FR-002**: The pipeline MUST classify `.inp`, `.ebs`, and `.es` files as `type = "code"` via the extension override table, without consulting the LLM.
- **FR-003**: The pipeline MUST add `"rar"` to the archive extraction list so that `.rar` files are unpacked and their contents indexed; if extraction fails (binary unavailable), the file is silently dropped, consistent with existing archive failure behaviour.
- **FR-004**: After classification and group assignment, a fallback pass MUST detect PDF files that share a stem with a `.Rmd`, `.qmd`, or `.tex` file in the same directory and override their type to `"output"`.

**Header Detection (035)**

- **FR-005**: The existing Qualtrics parsing MUST be extended so that after `read_data_head()` returns a data frame from a CSV, the pipeline checks whether any value in the first 3 rows matches `^\{.*ImportId`; if so, rows 2 and 3 are dropped and column names are re-applied from row 1.
- **FR-006**: The multi-level header detection logic MUST be extended to match `^V\d+$` column name patterns, applying the same sub-header lookahead already used for `...N` columns.

**Codebook Parser (036)**

- **FR-007**: The codebook parser MUST detect wide-format CSV codebooks by checking whether the first column contains values matching a set of known statistic names (`mean`, `sd`, `label`, `min`, `max`, `type`, `note`); if detected, MUST transpose before extraction.
- **FR-008**: Before the LLM labelling match step, the codebook parser MUST detect variable name entries matching `[A-Za-z]*\d+\s*[-–]\s*\d+` (range notation) and expand them to individual variable entries before matching against columns.

### Key Entities

- **`structure.csv`**: Per-paper file classification output. Affected by FR-001–004.
- **`columns.csv`**: Per-paper column extraction output. Affected by FR-005–006.
- **`labels.csv`**: Per-paper codebook label assignments. Affected by FR-007–008.
- **`codebook_coverage.csv`**: Per-paper codebook coverage scores. Affected by FR-007–008.
- **Extension override table** (`AGGREGATE_EXT_OVERRIDE`): The lookup table in `0_index.R` that maps file extensions to classification outcomes. FR-001 through FR-003 add or modify entries here.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Papers containing `.xlsm` files produce column data in `columns.csv` for those files, where previously no columns were extracted.
- **SC-002**: `.inp`, `.ebs`, `.es` files in test papers are classified as `type = "code"` without LLM calls for those files.
- **SC-003**: `.rar` archives are extracted and their contents appear as indexed rows in `structure.csv` (same behaviour as `.zip`).
- **SC-004**: PDF files co-located with same-stem `.Rmd` files are assigned `type = "output"` in `structure.csv`.
- **SC-005**: Qualtrics CSV exports produce `columns.csv` entries where column names are the Qualtrics variable names (row 1), not `ImportId` JSON strings.
- **SC-006**: Headerless CSV files (base R `V1/V2/V3` pattern) produce `columns.csv` entries with the real column names from row 2.
- **SC-007**: Papers with wide-format codebooks produce non-zero `coverage_pct` in `codebook_coverage.csv`, where previously coverage was 0%.
- **SC-008**: Papers with range variable references (`V1–V10`) in codebooks produce label assignments for all variables in the range in `labels.csv`.

---

## Assumptions

- The Qualtrics ImportId pattern (`^\{.*ImportId`) is treated as a sufficient detection signal; false positives are considered acceptable given their rarity in psychology repos.
- V\d+ auto-header recovery uses the same existing lookahead depth constant (`MULTILEVEL_HEADER_LOOKAHEAD`) already defined for the `...N` case.
- Wide codebook detection uses first-column value matching only; no schema inference or ML is used.
- Range notation expansion is scoped to patterns of the form `[prefix][start]–[end]` only; free-text range descriptions (e.g., "items 1 through 10") are out of scope.
- `.mat` read support is deferred to feature 037. RAR extraction uses `unrar` via system call; if the binary is unavailable the file is silently dropped (no fallback stub rows or new data_format values).
