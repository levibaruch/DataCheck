# Feature Specification: Data Format Sub-classification (Tabular vs Raw)

**Feature Branch**: `028-data-format-subtype`  
**Created**: 2026-04-01  
**Status**: Draft  
**Input**: User description: "read data_check/pipeline/prompt_error_analysis.log. there is a big problem in the current classification of data; collumn based data is seen as the same as raw mp4 like data. This needs to be refined. data can be both collumn actionable (the current assumption) or raw (not collumn actionable; a .mat that is not readable, a mp4). This needs to be rebased. It required changes in the prompt, but will also require a redo of many validation steps in the 100 already defined repositories. Both fix this bug, make sure downstream no problems occur but also create helpers that owuld programmatically allow for easy recall of curreny mislabelled files for relabelling."

---

## Background

The pipeline currently classifies all research measurement files under a single `type = "data"` value in `structure.csv`. However, `data` files span two fundamentally different sub-categories:

- **Tabular / column-actionable**: CSV, SAV, XLSX, DTA, etc. — `read_data_head()` can extract columns from these.
- **Raw / non-column-actionable**: MP4, AVI, WAV, MAT (binary), EDF, BDF, etc. — research recordings or signal matrices that cannot produce column output.

The current prompt's participant-naming rule (e.g. `participant_1_eyes_clip.mp4 → data`) is semantically correct but causes column extraction to be attempted on binary files that cannot be read. As documented in `prompt_error_analysis.log`, 1,550 `.mp4` eye-tracking recordings were classified as `data` and routed to column extraction, which silently fails or produces garbage for all of them.

This feature introduces a `data_format` sub-field on every `data`-typed row with exactly two values — `"tabular"` (column-actionable) or `"raw"` (not column-actionable). Column extraction is gated on `data_format = "tabular"`. Existing outputs for all ~100 already-processed papers are repaired, and tooling is provided to identify previously mislabelled files for re-labelling.

---

## Clarifications

### Session 2026-04-01

- Q: How many `data_format` values should the schema support? → A: Exactly two — `"tabular"` (column-based, actionable) and `"raw"` (not column-based). Simplicity over granularity.
- Q: Should `.rds`/`.rda`/`.rdata` be `"tabular"` or `"raw"`? → A: Deferred. R serialised objects will be handled in a future feature (analogous to how Excel files are currently "exploded"). For this feature they are excluded from the explicit lookup and fall to the `"tabular"` fallback, preserving current extraction behaviour.
- Q: Should the repair tooling strip garbage rows from `columns.csv`? → A: No — all papers will be fully rerun regardless. The priority for repair tooling is the ground truth files (`ground_truth/<paper_id>.csv`): these human-validated labels need `data_format` backfilled and any mislabelled raw-format entries flagged for re-review before the rerun.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — New Papers Produce Correct Column Extraction Gating (Priority: P1)

A researcher runs the pipeline on a new paper containing both `.csv` participant data files and `.mp4` eye-tracking recordings. Both file types are correctly classified as `type = "data"`. The `.csv` files receive `data_format = "tabular"` and columns are extracted normally. The `.mp4` files receive `data_format = "raw"` and are indexed in `structure.csv` but the column extraction stage skips them entirely — no error, no garbage output.

**Why this priority**: This is the core defect. Every new paper processed before this fix risks polluted column output for any lab storing raw recordings. This is the most direct harm to pipeline output quality.

**Independent Test**: Run the pipeline on a paper known to contain participant video recordings. Verify `structure.csv` has `data_format = "raw"` for `.mp4` rows and `data_format = "tabular"` for `.csv` rows. Verify `columns.csv` contains no rows sourced from `.mp4` files.

**Acceptance Scenarios**:

1. **Given** a paper with `.mp4` participant recordings, **When** the pipeline completes, **Then** all `.mp4` rows in `structure.csv` have `type = "data"` and `data_format = "raw"`, and `columns.csv` contains zero rows with those files as source.
2. **Given** a paper with `.csv` data files, **When** the pipeline completes, **Then** `.csv` rows have `data_format = "tabular"` and columns are extracted normally.
3. **Given** a paper with `.mat` participant-named files, **When** the pipeline completes, **Then** `.mat` rows have `data_format = "raw"` and column extraction is skipped.
4. **Given** a paper with `.edf`/`.bdf` signal files, **When** the pipeline completes, **Then** those rows have `data_format = "raw"` and column extraction is skipped.

---

### User Story 2 — Ground Truth Files Repaired Before Full Rerun (Priority: P2)

All ~100 papers will be fully rerun with the new pipeline. Before that rerun, the human-validated ground truth files (`ground_truth/<paper_id>.csv`) must be updated so the validation comparisons remain meaningful. A ground truth repair helper adds a `data_format` column to each ground truth file using the same extension lookup, and flags entries for raw-format files that may have been validated under incorrect assumptions (e.g. a researcher confirmed a `.mp4` file as `type = "data"` — that label is still correct, but the `data_format = "raw"` implication should be recorded and reviewed).

**Why this priority**: Ground truth files are the reference for measuring pipeline accuracy. If they do not reflect the new `data_format` field, the accuracy report after the rerun cannot be trusted.

**Independent Test**: Run the ground truth repair helper against a paper with known raw-format data entries. Verify `data_format` is added to the ground truth file, raw-format rows are flagged for review, and the file is otherwise unchanged.

**Acceptance Scenarios**:

1. **Given** a ground truth CSV without a `data_format` column, **When** the repair helper runs, **Then** the file is updated in-place with `data_format` populated using the extension lookup (same rules as `structure.csv`).
2. **Given** a ground truth CSV containing a `type = "data"` entry for a `.mp4` file, **When** the repair helper runs, **Then** that entry receives `data_format = "raw"` and is included in a flagged-for-review list.
3. **Given** all ground truth files processed, **When** the bulk repair runner completes, **Then** a summary CSV reports per-paper counts of raw-format entries flagged for re-review.

---

### User Story 3 — Audit Tooling Identifies Ground Truth Entries Needing Re-review (Priority: P2)

Before triggering the full pipeline rerun, a researcher wants a consolidated view of which ground truth entries cover raw-format files — these are the entries most likely to have been validated under the old (incorrect) assumption that all `data`-typed files are column-actionable. An audit helper scans all ground truth files and produces a prioritised re-review list.

**Why this priority**: The full rerun will regenerate `columns.csv` correctly for all papers. What cannot be regenerated automatically is the human validation signal. Identifying which prior validations were made under defective conditions lets the researcher decide which to re-validate.

**Independent Test**: Run the audit helper. Verify it lists all ground truth entries where the source file has a raw-format extension, grouped by paper and sorted by entry count.

**Acceptance Scenarios**:

1. **Given** ground truth files containing entries for `.mp4` or `.mat` data files, **When** the audit helper runs, **Then** a report lists those papers, affected file paths, extensions, and original validated `type` values.
2. **Given** ground truth files with no raw-format data entries, **When** the audit helper runs, **Then** those papers are absent from the report.
3. **Given** the audit report, **When** a researcher reviews it, **Then** each entry provides enough context (paper ID, file path, validated type, `data_format` assignment) to decide whether re-validation is needed.

---

### User Story 4 — `data_format` Flows Through to Downstream Consumers (Priority: P3)

PsychDS conversion correctly uses `data_format` when routing files: `"tabular"` files go through column conversion; `"raw"` files are copied to `data/raw/` without conversion. The validation GUI shows `data_format` as an informational badge on `data`-typed rows.

**Why this priority**: Downstream correctness depends on this field, but PsychDS conversion already has an extension-based fallback. Important for long-term correctness but does not block the core defect fix.

**Independent Test**: Run PsychDS conversion on a paper with both `"tabular"` and `"raw"` `data`-typed files. Verify tabular files appear in `data/` and raw files appear in `data/raw/`.

**Acceptance Scenarios**:

1. **Given** a `structure.csv` with `data_format = "raw"` rows, **When** PsychDS conversion runs, **Then** those files are copied to `data/raw/` without column conversion attempts.
2. **Given** the validation GUI loaded for a paper with mixed `data_format` values, **When** a `data`-typed row is displayed, **Then** the `data_format` value is shown alongside the type badge.

---

### Edge Cases

- A `.mat` file with a participant-named filename — receives `data_format = "raw"` even though the participant-naming rule fires for `type = "data"`. Semantics (`type`) and actionability (`data_format`) are independent.
- A `.txt` file that is participant data (e.g. `subject-2294_run1.txt`) — receives `data_format = "tabular"` since plain-text delimited files are parseable by `read_data_head()`.
- A `.wav` file that is a stimulus — classified as `type = "asset"`, so `data_format = NA` (not applicable to non-data files).
- A `.wav` file that is a participant voice recording — classified as `type = "data"`, `data_format = "raw"`.
- All papers will be fully rerun — `columns.csv` for all papers will be regenerated cleanly by the new gated pipeline. The repair priority before the rerun is the `ground_truth/` files, not `structure.csv` or `columns.csv`.
- An extension not in the lookup table — falls to `"tabular"` as a conservative default (attempt extraction rather than silently skip unknown types).
- A `structure.csv` where `data_format` was partially populated by a prior run — the repair helper preserves existing values and fills only missing ones.

---

## Requirements *(mandatory)*

### Functional Requirements

#### Schema & Extension Lookup

- **FR-001**: The `structure.csv` schema MUST include a new `data_format` column. For `type = "data"` rows, `data_format` MUST be either `"tabular"` or `"raw"`. For all other `type` values, `data_format` MUST be `NA`.
- **FR-002**: `data_format` MUST be assigned by a deterministic extension lookup table after LLM classification, not by the LLM. The assignment rules are: `"tabular"` = `.csv`, `.tsv`, `.txt`, `.dat`, `.xlsx`, `.xls`, `.sav`, `.dta`; `"raw"` = `.edf`, `.bdf`, `.acq`, `.mat`, `.mp4`, `.avi`, `.mov`, `.wav`, `.mp3`. Extensions not in any list (including `.rds`, `.rda`, `.rdata`) → `"tabular"` (conservative fallback — attempt extraction rather than silently skip). Note: `.rds`/`.rda`/`.rdata` handling is deferred to a future feature.
- **FR-003**: The LLM classification prompt MUST be updated to fix the media/signal hard cases identified in Cluster 0 (`.mp4` participant recordings) and Cluster 1 (`.mat` files) of the error log. The `type` vocabulary is unchanged; the prompt changes only refine the context-based priority rules for media and binary formats.

#### Column Extraction Gating

- **FR-004**: The column extraction stage MUST only process files where `data_format = "tabular"`. Files with `data_format = "raw"` MUST be skipped — no call to `read_data_head()`.
- **FR-005**: Skipped files MUST NOT produce rows in `columns.csv`. Their absence is expected, not an error.
- **FR-006**: A new `n_tabular_files` column MUST be added to `bulk_summary.csv` recording the count of `data_format = "tabular"` files per paper. The existing `n_data_files` column retains its current meaning (all `type = "data"` files, regardless of `data_format`).

#### Ground Truth Repair Tooling

- **FR-007**: A ground truth repair helper MUST accept a paper ID and add a `data_format` column to the corresponding `ground_truth/<paper_id>.csv` using the same extension lookup table as the pipeline — no LLM call, no re-download.
- **FR-008**: The repair helper MUST be idempotent: running it multiple times on the same file produces the same result as running it once. Existing `data_format` values are preserved.
- **FR-009**: A bulk ground truth repair runner MUST iterate over all `ground_truth/` files, apply the repair helper, and write a summary CSV with columns: `paper_id`, `n_data_rows`, `n_tabular`, `n_raw`, `n_flagged_for_review` (count of raw-format entries that warrant re-validation).

#### Audit Tooling

- **FR-010**: An audit helper MUST scan all `ground_truth/<paper_id>.csv` files and identify entries where `type = "data"` and the file has a raw-format extension (`.mp4`, `.avi`, `.mov`, `.wav`, `.mp3`, `.mat`, `.edf`, `.bdf`, `.acq`).
- **FR-011**: The audit helper MUST output a report CSV with columns: `paper_id`, `source_file`, `ext`, `validated_type`, `data_format_assigned` (`"raw"` for all flagged entries).
- **FR-012**: The audit report MUST be sorted by paper to allow a researcher to efficiently re-validate flagged entries before triggering the full pipeline rerun.

#### Downstream Consumers

- **FR-013**: PsychDS conversion MUST consult `data_format` when routing files: `"tabular"` files go through the column conversion path; `"raw"` files are copied to `data/raw/`.
- **FR-014**: The `docs/output-schemas.md` documentation MUST be updated to define `data_format` as a new column in `structure.csv` with both enum values, their meanings, and which extensions map to each.
- **FR-015**: The `docs/pipeline.md` documentation MUST be updated to reflect the column extraction gating logic and the new `n_tabular_files` bulk summary column.

### Key Entities

- **`data_format`**: A sub-classification applied to all `type = "data"` rows in `structure.csv`. Encodes whether the file's content is column-extractable by `read_data_head()`. Values: `"tabular"` (parseable row/column structure — column extraction runs), `"raw"` (any non-column-actionable data file — column extraction skipped). `NA` for all non-data files.
- **Ground truth repair helper**: A utility function that backfills `data_format` into existing `ground_truth/<paper_id>.csv` files using extension rules. Stateless, idempotent, requires no LLM or network access.
- **Audit report**: A CSV produced by scanning `ground_truth/` files to identify entries where `type = "data"` and the file is raw-format. Used by the researcher to re-validate affected entries before triggering the full pipeline rerun.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero rows in any newly-generated `columns.csv` are sourced from files with `data_format = "raw"`.
- **SC-002**: All ~100 existing paper `structure.csv` outputs have a populated `data_format` column after a single bulk repair run — no manual per-paper intervention required.
- **SC-003**: The audit report correctly identifies all ground truth entries where `type = "data"` and the file is raw-format. Results match manual inspection of a sample of 10 ground truth files.
- **SC-004**: The `data_format` extension lookup covers 100% of extensions currently observed in `type = "data"` rows across existing paper outputs (verified by checking that no paper produces an unexpected `data_format` value after repair).
- **SC-005**: Re-running `runners/report_tests.R` on test papers after the prompt fix shows non-negative change in overall classification accuracy (no regression introduced by the prompt changes).

---

## Assumptions

- `data_format` is determined by extension rule only — the LLM is not asked to predict it. This is consistent with how `type_source = "extension_rule"` already works for aggregate files.
- `.rds`/`.rda`/`.rdata` handling is deferred to a future feature (analogous to Excel "explosion"). For this feature they are not in the explicit `"raw"` list and fall to the `"tabular"` fallback, preserving current extraction behaviour.
- All ~100 papers will be fully rerun. The repair tooling targets `ground_truth/` files only — these are the only artefacts that cannot be regenerated automatically and contain human validation signal that must be preserved and updated before the rerun.
- Prompt changes in this feature are limited to the media/signal classification hard cases (Clusters 0 and 1 from the error log). Fixes for other clusters (`.spv`, `.log`, output CSVs, library detection) are deferred to keep scope bounded.
- The `data_format` column is appended as the last column in `structure.csv` to minimise schema disruption; downstream consumers that read by column name are unaffected.

---

## Dependencies

- `pipeline/prompts.R` — `STRUCTURE_PROMPT` updated for media/signal hard cases
- `pipeline/0_index.R` — `data_format` assignment after LLM; column extraction gated on `data_format`; `n_tabular_files` added to summary
- `runners/repair_ground_truth_data_format.R` — new: bulk ground truth repair helper (new file)
- `runners/audit_ground_truth_data_format.R` — new: audit report for ground truth entries needing re-review (new file)
- `tools/validation_gui/app.R` — `data_format` badge display
- PsychDS conversion runner — `data_format`-based file routing
- `docs/output-schemas.md` — `data_format` column documented
- `docs/pipeline.md` — gating logic and new summary column documented
