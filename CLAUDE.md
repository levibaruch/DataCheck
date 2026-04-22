# data_check Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-04-21

## Active Technologies
- R (base R only — no new packages; `haven`/`readxl`/`jsonlite` already present) + `llm_batch()`, `extract_json()` (existing helpers in `helper.R`); `jsonlite::fromJSON` (005-codebook-column-labelling)
- `structure/<paper_id>_labels.csv`, `structure/<paper_id>_codebook_coverage.csv` (new); reads existing `_structure.csv` and `_columns.csv` (005-codebook-column-labelling)
- R (base R only — no new packages) + `llm()` from `metacheck`; `jsonlite::fromJSON`, `extract_json()` — all already presen (006-llm-fuzzy-matching)
- Extends `structure/<paper_id>_labels.csv` with new `label_method` column; no new files (006-llm-fuzzy-matching)
- R (base R, no new packages) + `metacheck`, `haven`, `readxl`, `jsonlite` — all already presen (007-per-id-output-structure)
- CSV files on local filesystem; `outputs/<paper_id>/` directories (007-per-id-output-structure)
- R (base R, no new packages) + `metacheck`, `haven`, `readxl` — already present; `helper.R` (shared helpers) (008-bulk-label-runners)
- CSV files on local filesystem; `outputs/<paper_id>/` directories (from feature 007) (008-bulk-label-runners)
- R (base R + already-installed: `officer`, `pdftools`, `haven`, `readxl`) + `officer` (DOCX), `pdftools` (PDF) — both already installed (009-multi-format-codebooks)
- R (base R, no new packages) + `metacheck` (`llm()`), `jsonlite` (`fromJSON`, `extract_json`) — all already presen (010-fix-label-ambiguity)
- CSV files; `outputs/<paper_id>/labels.csv` (modified in-place by pipeline) (010-fix-label-ambiguity)
- CSV files; `outputs/<paper_id>/columns.csv` restored in-place (011-merge-columns-output)
- R (base R, no new packages) + `0_index.R`, `2_codebook_label.R`, `helper.R` — all already presen (012-single-dataset-runner)
- CSV files on local filesystem under `data_check/outputs/<paper_id>/` (012-single-dataset-runner)
- R (base R, no new packages) + `0_index.R`, `helper.R` — both already present; no external packages added (013-fix-r-file-misclassification)
- CSV files on local filesystem (`outputs/<paper_id>/`) (013-fix-r-file-misclassification)
- R (base R, no new packages) + `readxl` (already present), `haven` (already present) — `read_data_head()` in `helper.R` unchanged (014-fix-multilevel-csv-headers)
- CSV files on local filesystem — `outputs/<paper_id>/columns.csv`, `outputs/<paper_id>/structure.csv` (014-fix-multilevel-csv-headers)
- R (base R, no new packages) + `metacheck` (`llm()`), `jsonlite` — already presen (015-verbatim-codebook-labels)
- CSV files on local filesystem — `outputs/<paper_id>/labels.csv`, `outputs/<paper_id>/codebook_coverage.csv` (015-verbatim-codebook-labels)
- R (base R, no new packages) + `haven`, `readxl`, `jsonlite` — all already present; not needed for this feature (read-only CSV reporting) (016-pipeline-quality-report)
- CSV files on local filesystem — `bulk_summary.csv`, `codebook_summary.csv`, `outputs/<paper_id>/columns.csv`, `outputs/<paper_id>/codebook_coverage.csv` (016-pipeline-quality-report)
- R (base R, no new packages) + `metacheck` (`llm()`), `haven`, `readxl`, `jsonlite` — all already installed; `helper.R`, `0_index.R`, `2_codebook_label.R` sourced at runtime (017-llm-temperature-testing)
- CSV files on local filesystem under `sweep_results/<paper_id>/`; new `sweep_bulk_log.csv` at `sweep_results/sweep_bulk_log.csv` (017-llm-temperature-testing)
- R (base R, no new packages) + `haven`, `readxl`, `jsonlite` — all already installed; `helper.R` (shared helpers), `2_codebook_label.R` (coverage output) (018-fix-csv-codebook-parsing)
- CSV files on local filesystem — `outputs/<paper_id>/codebook_coverage.csv` (018-fix-csv-codebook-parsing)
- R (base R, no new packages) + `haven` (already installed) — source of labelled type; vctrs (transitively via haven) — source of precision error on rbind (019-fix-index-labelled-stats)
- CSV files — `outputs/<paper_id>/columns.csv`, `results/bulk_summary.csv` (019-fix-index-labelled-stats)
- R (base R + already-installed: `shiny`, `bslib`, `haven`) + `shiny` (UI + server), `bslib` (layout/theming), `haven`/`readxl` (020-validation-gui)
- Local CSV files; `ground_truth/<paper_id>.csv` per paper; no database (020-validation-gui)
- R 4.5 (base R, no new packages) + `haven`, `readxl`, `jsonlite`, `xml2`, `pdftools`, `officer` — all already installed (021-psychds-conversion)
- Local filesystem — `data_check/psychds/<paper_id>/` output roo (021-psychds-conversion)
- R (base R, no new packages) + `metacheck` (`llm_batch()`), `haven`, `readxl`, `jsonlite` — all already installed (022-file-type-taxonomy-refactor)
- CSV files on local filesystem — `outputs/<paper_id>/structure.csv` (schema change), `docs/output-schemas.md` (doc update) (022-file-type-taxonomy-refactor)
- R (base R, no new packages) + `metacheck` (`llm_batch()`), `haven`, `readxl`, `jsonlite` — all already installed (023-sentinel-aggregate-revamp)
- CSV files on local filesystem — `outputs/<paper_id>/structure.csv`, `ground_truth/<paper_id>.csv` (023-sentinel-aggregate-revamp)
- R (base R, no new packages) + `metacheck` (`llm_batch()`), `haven`, `readxl`, `jsonlite` — all already installed (026-add-output-file-type)
- R (base R, no new packages) + `pipeline/helper.R` (`llm_batch()`), `pipeline/0_index.R` (constants + fallback rules), `docs/output-schemas.md` (027-llm-retry-logging)
- Append-only plain-text log at `logs/llm_batch_errors.log` (relative to `data_check/` root); auto-created by pipeline if absen (027-llm-retry-logging)
- R (base R, no new packages) + `haven`, `readxl`, `jsonlite`, `tools` (base) — all already installed; `metacheck` (`llm_batch()`) (028-data-format-subtype)
- CSV files on local filesystem (`outputs/<paper_id>/structure.csv`, `ground_truth/<paper_id>.csv`, `results/bulk_summary.csv`) (028-data-format-subtype)
- R (base R, no new packages) + `metacheck` (`llm_batch()`), `shiny` + `bslib` (validation GUI) — all already installed (029-software-file-type)
- CSV files on local filesystem (`outputs/<paper_id>/structure.csv`, `ground_truth/<paper_id>.csv`) (029-software-file-type)
- R (base R, no new packages) + `metacheck` (`llm_batch()`), `haven`, `readxl`, `jsonlite`, `xml2` — all already installed (031-dataverse-source-support)
- CSV files on local filesystem; `data_check/data/dataverse/`, `data_check/outputs/`, `data_check/psychds/` (031-dataverse-source-support)
- R (base R, no new packages per constitution) + `haven`, `readxl`, `jsonlite`, `xml2`, `metacheck` — all already installed (032-source-aware-storage)
- Local filesystem; CSV files; directory trees under `data/`, `outputs/`, `psychds/`, `ground_truth/` (032-source-aware-storage)
- R (base R only) + None — prompt string edit only (033-llm-prompt-refinements)
- R (base R + already-installed: `readxl`, `haven`, `metacheck`) + `readxl` (xlsm), `system2` (unrar via shell), `haven` (codebook parsing) — all presen (034-classification-parsing-fixes)
- CSV files on local filesystem; `structure.csv`, `columns.csv`, `labels.csv`, `codebook_coverage.csv` (034-classification-parsing-fixes)
- R (base R only — no new packages) + `helper.R` (`llm_batch()`, `classify_by_rules()`), `0_index.R`, `3_psychds_convert.R`, `prompts.R` (`STRUCTURE_PROMPT_NEW`) (035-sentinel-aggregate-redesign)
- CSV files — `outputs/<source>/<id>/structure.csv` (modified), `docs/output-schemas.md` (updated) (035-sentinel-aggregate-redesign)
- R (base R, no new packages) + `helper.R` (`classify_col_type_rules()`), `0_index.R` (`COLUMN_TYPE_PROMPT`, `run_index()`) (004-reduce-unknown-coltypes)
- R 4.5 (base R only — no new packages per constitution.md Principle IV) + `helper.R` (`llm_batch()`, `is_participant_id()`), `prompts.R` (`GRANULARITY_PROMPT`), `0_index.R` (integration) (037-improve-granularity-detection)
- CSV files on local filesystem (`structure.csv`) (037-improve-granularity-detection)
- R 4.5 (base R, no new packages per constitution.md Principle IV) + `metacheck` (llm()), `jsonlite` (fromJSON, extract_json), existing helpers in `helper.R` (038-llm-fallback-retry)
- CSV files on local filesystem; append-only error logs (`llm_batch_errors.log`) (038-llm-fallback-retry)
- R 4.5 (base R only — no new packages) + `helper.R` (`classify_by_rules()`), `0_index.R` (constants, `run_index()`) (040-software-folder-detection)
- CSV files — `outputs/<source>/<id>/structure.csv` (existing schema, new `type_source` value) (040-software-folder-detection)

## Project Structure

```text
src/
tests/
```

## Commands

# Add commands for R (base R, no new packages)

## Code Style

R (base R, no new packages): Follow standard conventions

## Recent Changes
- 040-software-folder-detection: Added R 4.5 (base R only — no new packages) + `helper.R` (`classify_by_rules()`), `0_index.R` (constants, `run_index()`)
- 038-llm-fallback-retry: Added R 4.5 (base R, no new packages per constitution.md Principle IV) + `metacheck` (llm()), `jsonlite` (fromJSON, extract_json), existing helpers in `helper.R`
- 037-improve-granularity-detection: Added R 4.5 (base R only — no new packages per constitution.md Principle IV) + `helper.R` (`llm_batch()`, `is_participant_id()`), `prompts.R` (`GRANULARITY_PROMPT`), `0_index.R` (integration)


<!-- MANUAL ADDITIONS START -->

## Pipeline Documentation

`docs/` = canonical pipeline docs. **Keep in sync when workflow changes.**

| File | What it documents | Update when... |
|---|---|---|
| `docs/pipeline.md` | End-to-end flow from paper ID to CSV outputs, all constants, resource limits, retry behaviour, **test infrastructure** | Stage added/removed/reordered; constant changes; retry logic changes; new LLM prompt added; test paper added |
| `docs/output-schemas.md` | Column definitions for `_structure.csv`, `_columns.csv`, `bulk_summary.csv`; all type/group enum values | Column added/removed/renamed in any output CSV; new `col_type`, file `type`, `group`, or error code introduced |

### Update rules

- New pipeline stage → add step to flow diagram in `pipeline.md`
- Constant change (e.g. `N_DATA_READ`, `LLM_BATCH_SIZE`, resource limits) → update constants table in `pipeline.md`
- New `col_type` → add to Column Types table in `output-schemas.md`
- New file classification `type` or `group` → update File Types / Groups tables in `output-schemas.md`
- New error code → update Error Codes table in `output-schemas.md`
- New output CSV column → add to relevant schema table in `output-schemas.md`
- New feature or PR → add/update `progress.md`
- All PRs MUST target `dev`, not `main`
- New feature → run `runners/run_tests.R` then `runners/report_tests.R`; review quality report before merging (see **Testing** in `pipeline.md`)
- New edge case found → add to `data_check/tests/test_papers.csv` and test paper catalogue in `pipeline.md`


<!-- MANUAL ADDITIONS END -->
