# Feature Specification: Add n_unique Column Statistic

**Feature Branch**: `025-add-n-unique-stat`
**Created**: 2026-03-30
**Status**: Draft
**Input**: User description: "Add n_unique to the column statistics in columns.csv for 0_index"

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Inspect column cardinality for any column type (Priority: P1)

A researcher reviewing `columns.csv` wants to know how many distinct values appear in a column — not just for numeric columns, but for categorical, ordinal, id, text, and binary columns too. Currently the file provides rich numeric statistics but no measure of cardinality, so the researcher must re-open the raw data file to count unique values manually.

**Why this priority**: Cardinality is one of the most universally useful column statistics. It is meaningful for every column type and is a prerequisite for many downstream quality checks (e.g. detecting near-constant categorical columns, verifying binary columns have exactly 2 levels).

**Independent Test**: Run the pipeline on a paper with known data files; open `columns.csv` and confirm a populated `n_unique` value appears for every row, regardless of `col_type`.

**Acceptance Scenarios**:

1. **Given** a data file with a numeric column containing 50 rows and 30 distinct values, **When** the pipeline produces `columns.csv`, **Then** that column's `n_unique` equals 30.
2. **Given** a binary column with values `0` and `1` (and some NAs), **When** the pipeline produces `columns.csv`, **Then** `n_unique` equals 2.
3. **Given** a constant column where every non-NA value is the same, **When** the pipeline produces `columns.csv`, **Then** `n_unique` equals 1.
4. **Given** an empty column (all NAs), **When** the pipeline produces `columns.csv`, **Then** `n_unique` equals 0.
5. **Given** a text column with free-form responses, **When** the pipeline produces `columns.csv`, **Then** `n_unique` is populated and reflects the actual number of distinct non-NA values.

---

### Edge Cases

- Empty columns (all `NA`): `n_unique` should be 0, not `NA`.
- Columns with mixed NA and non-NA values: count only non-NA unique values, consistent with how `n` (non-missing count) is computed.
- Very large columns (e.g. 100k+ rows): `n_unique` must be computed without truncation.
- Columns already classified as `binary` (exactly 2 unique non-NA values): `n_unique` must equal exactly 2 for these.
- Columns already classified as `constant` (exactly 1 unique non-NA value): `n_unique` must equal exactly 1 for these.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The pipeline MUST add a `n_unique` column to `columns.csv`, containing the count of distinct non-NA values in the source column.
- **FR-002**: `n_unique` MUST be populated for every column type — including `continuous`, `binary`, `constant`, `categorical`, `ordinal`, `date`, `id`, `text`, `empty`, and `unknown`.
- **FR-003**: For empty columns (all-NA), `n_unique` MUST be 0 (not `NA`).
- **FR-004**: The `n_unique` count MUST exclude `NA` values, consistent with how `n` (non-missing count) is computed elsewhere.
- **FR-005**: The `n_unique` column MUST appear in `columns.csv` after `n_missing` and before `mean` (after count-based columns, before numeric-only statistics).
- **FR-006**: The `output-schemas.md` documentation MUST be updated to include the `n_unique` column definition in the `columns.csv` schema table.

### Key Entities

- **Column row** (`columns.csv`): One row per column per data file; gains one new integer field `n_unique`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every row in `columns.csv` has a non-NA integer value for `n_unique`, regardless of `col_type`.
- **SC-002**: `n_unique` values for `binary` columns always equal 2; for `constant` columns always equal 1; for `empty` columns always equal 0.
- **SC-003**: `n_unique` never exceeds `n` (the non-missing count) for any row.
- **SC-004**: The `output-schemas.md` column table for `columns.csv` includes `n_unique` with an accurate description.

## Assumptions

- `n_unique` counts unique values among non-NA entries only.
- The statistic is an integer count (not a proportion).
- No new packages are needed.
- Column ordering in `columns.csv` follows the existing schema; `n_unique` is inserted logically after `n_missing` and before `mean`.
