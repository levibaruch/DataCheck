# Pipeline Overview

The pipeline downloads psychology research data repositories from OSF, classifies their
contents using an LLM, and extracts column-level statistics into structured CSVs.

## Entry Points

| Script | Purpose |
|---|---|
| `run_single.R` | Run the full pipeline (index + codebook label) for one randomly selected paper. Dev/smoke-test entry point. |
| `runners/run_0_index_bulk.R` | Process all papers through the index stage. Crash-resilient, auto-resumes from `bulk_summary.csv`. |
| `run_codebook_bulk.R` | Run codebook-label stage across all papers with `columns.csv`. Auto-resumes from `codebook_summary.csv`. |
| `0_index.R` (`run_index()`) | Process a single paper by ID. Called by the index bulk runner. |
| `2_codebook_label.R` (`run_codebook_label()`) | Label columns against codebooks for a single paper. Called by the codebook bulk runner. |
| `run_sweep.R` | Temperature stability sweep for a single paper. Runs full pipeline at N temperatures × R repeats; crash-resilient via per-paper `sweep_log.csv`. |
| `run_sweep_bulk.R` | Bulk temperature sweep across all papers in `XML_DIR`. Paper-level resume via `sweep_results/sweep_bulk_log.csv`; calls `run_paper_sweep()`. |
| `report_sweep.R` | Single-paper sweep report: stability (pairwise col_type + label agreement), quality proxies, weighted recommendation. Writes `sweep_report_YYYY-MM-DD.md`. |
| `report_sweep_grand.R` | Grand cross-paper report: flat CSV with one row per (paper_id × temperature × pipeline stage). No aggregation — post-processing friendly. |
| `runners/run_psychds_single.R` | Convert one paper to PsychDS format. Dev/smoke-test entry point. Accepts `paper_id` as CLI arg or pre-set variable; falls back to random paper from `results/bulk_summary.csv`. |
| `runners/run_psychds_bulk.R` | Batch-convert all successfully indexed papers to PsychDS format. Crash-resilient, auto-resumes from `psychds/conversion_summary.csv`. |
| `runners/run_dataverse_bulk.R` | Batch-index all Harvard Dataverse deposits in `data_check/data/dataverse/`. Crash-resilient, auto-resumes from `bulk_summary.csv`. Writes `source = "dataverse"` rows. |
| `pipeline/3_psychds_convert.R` (`convert_psychds()`) | Convert a single paper by ID to PsychDS format. Returns list of per-study result rows. |
| `pipeline/4_report.R` (`run_report()`) | Render the per-paper user report (`report.html`) from existing CSV outputs. Read-only; no LLM. Stage 4 of `run_full_pipeline_bulk.R`. |
| `runners/reports/report_user.R` | Regenerate per-paper reports for one paper (`--paper-id`/`--source`) or every paper under `--outputs-dir`, without a pipeline run. |
| `runners/run_validation_gui.R` | Launch the Shiny validation GUI for manual ground-truth annotation of file type, group, and `is_raw`. Writes `ground_truth/<paper_id>.csv`. These override pipeline classifications in the PsychDS conversion step. |
| `runners/run_test_validation_gui.R` | Launch the validation GUI in test mode. Reads from `tests/outputs/osf/<paper_id>/`, writes to `tests/ground_truth/osf/<paper_id>.csv`, and shows only OSF papers in `tests/test_papers.csv`. |

---

## End-to-End Flow

```
Paper ID (character string)
      │
      ▼
┌─────────────────────┐
│  1. Resolve OSF     │  metacheck::osf_links(paper_id)
│     links           │  → list of downloadable file URLs
└──────────┬──────────┘
           │  fail → error: no_links
           ▼
┌─────────────────────┐
│  2. Download repo   │  Downloads to data_check/data/<paper_id>/
│                     │  Limit: 10 GB per paper
└──────────┬──────────┘
           │  fail → error: download_failed | too_large
           ▼
┌─────────────────────┐
│  3. Unpack          │  unpack_archive() in helper.R
│     archives        │  Handles: zip, tar, tgz, gz, bz2, xz
└──────────┬──────────┘
           │  empty after unpack → error: empty_repo (retried once)
           ▼
┌─────────────────────┐
│  4. Build file      │  Walk directory tree, collect all paths
│     tree            │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  4.5. Software      │  detect_software_folders(): two-tier name match. Tier A
│       folder        │  (SOFTWARE_FOLDER_PATTERNS_UNAMBIG: __pycache__, .git,
│       detection     │  renv, node_modules, site-packages, venv, .venv,
│                     │  .Rproj.user, packrat, .ipynb_checkpoints, …) claims
│                     │  any match regardless of size. Tier B (SOFTWARE_FOLDER_
│                     │  PATTERNS_AMBIG: lib, libs, src, build, dist, vendor)
│                     │  requires >= SOFTWARE_FOLDER_THRESHOLD_AMBIG (100) files
│                     │  AND extension-majority gate (skip if >50% files are
│                     │  tabular data extensions). Bulk-labels
│                     │  type="software", type_source="rule_folder".
│                     │  Claimed paths stripped from rel_paths before aggregate
│                     │  detection.
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  5. Aggregate +     │  Aggregate detection: folders with >50 direct files (flat) or >50
│     series detect   │  numeric subdirs (participant) → sub-grouped via detect_series().
│                     │  detect_series() strips trailing ID/date suffix to find common prefix;
│                     │  files sharing a prefix (≥2 chars) form a series → one sub-sentinel.
│                     │  Folders with no series → single fallback sentinel.
│                     │  Singleton files (unique names) routed back to Phase 1.
│                     │  Sub-sentinels carry: prefix, file_count, dominant_ext, 5 samples.
│                     │  Unambiguous-extension sub-sentinels pre-resolved by AGGREGATE_EXT_OVERRIDE.
└──────────┬──────────┘
           │  Phase 1 paths + Phase 2 sub-sentinels combined > 10 calls → error: too_large
           ▼
┌─────────────────────┐
│  5. Two-phase LLM   │  Phase 1: llm_batch(non-aggregate paths, STRUCTURE_PROMPT)
│     classification  │    Assigns type/group for all individual (non-aggregate) files.
│                     │    Batches 2+: user_prefix includes compact experiment-map summary
│                     │    for cross-batch group label consistency.
│                     │    Feature 038: Incomplete response validation — if LLM returns fewer
│                     │    objects than paths sent, system detects and retries (max 4 attempts).
│                     │    See quickstart.md for log monitoring and operator guidance.
│                     │    Key hard-case rules in STRUCTURE_PROMPT (feature 033):
│                     │      .log in data/raw/task folder → data (not output)
│                     │      tabular file with scores/processed/cleaned → data (not output)
│                     │      pretest folder/file → ex<N> or shared (never pilot<N>)
│                     │      prior/replication tabular files → data (not supplemental)
│                     │      example_/dummy/placeholder files → other
│                     │      .yaml/.cfg/.ini/.toml in experiment folder → software
│                     │      .sql → data (exception: query/script/procedure → code)
│                     │  Phase 2: llm_batch(sub-sentinel descriptors, SENTINEL_PROMPT)
│                     │    Runs after Phase 1; receives full Phase 1 experiment map as context.
│                     │    Assigns type/group per sub-sentinel series.
│                     │    type_resolved sub-sentinels (unambiguous ext): only group assigned.
│                     │  Expansion: each sub-sentinel → per-file rows.
│                     │    Per-file extension override (AGGREGATE_EXT_OVERRIDE) applied first.
│                     │    Fallback to sub-sentinel LLM type for ambiguous extensions.
│                     │  type_source: "llm" (Phase 1) | "extension_rule" (override) |
│                     │              "sentinel_llm" (Phase 2 inheritance)
│                     │  Valid types: data | codebook | code | output | supplemental |
│                     │              readme | asset | other
│                     │  aggregate_folder: relative path of aggregate parent (NA otherwise)
│                     │  data_granularity: "individual" (series member) | "combined" |  NA
│                     │  data_format: "tabular" | "raw" — assigned by classify_data_format()
│                     │    tabular: csv/tsv/txt/dat/xlsx/xls/sav/dta/sas7bdat + unknown (fallback)
│                     │    raw: edf/bdf/acq/mat/mp4/avi/mov/wav/mp3
└──────────┬──────────┘
           │  only files with type = "data" AND data_format = "tabular" continue
           │  (raw-format data files retained in structure.csv but skipped for column extraction)
           ▼
┌─────────────────────┐
│  6. Read data       │  read_data_head(path, n_rows = 5) in helper.R
│     heads           │  Formats: csv/tsv/txt/dat/xlsx/xls/sav/dta/sas7bdat/rds/rda/rdata
│                     │  Only data_format = "tabular" files reach this step.
│                     │  Limit: 500 MB per file; ggplot objects → NULL (skipped)
│                     │  Encoding: csv/tsv/txt/dat read with default encoding; if any
│                     │  character column contains invalid UTF-8 bytes, file is re-read
│                     │  with fileEncoding="latin1" (handles Windows-1252 encoded files)
│                     │  Header: detect_header() flags headerless files (first two
│                     │  non-comment rows both all-numeric → e.g. Mplus .dat, numeric
│                     │  matrices); read with header=FALSE + synthesized col_N names so
│                     │  the first data row is not eaten. Shared with read_full_data()
│                     │  (psychDS) so columns.csv and the converted CSV agree.
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│  7. Rule-based      │  classify_col_type_rules() in helper.R
│     column          │  Rules (in order):
│     classification  │    1. all-NA              → empty
│                     │    2. 1 unique non-NA      → constant
│                     │    3. 2 unique non-NA      → binary
│                     │    4. ID name pattern      → id  (hard-classify; no LLM)
│                     │    5. date-parseable       → date
│                     │    6. long strings         → text
│                     │    7a. any decimal         → continuous  ← no LLM needed
│                     │    7. integer, 3–20 unique → LLM Batch 1 (is_numeric=TRUE)
│                     │    7. integer, >20 unique  → continuous
│                     │    8. comma-decimal        → continuous_comma_decimal / _outliers_excluded
│                     │    9. remaining char cols  → LLM Batch 2 (is_char_ambiguous=TRUE)
└──────────┬──────────┘
           │  ambiguous columns (NA col_type) sent to LLM (two batches)
           ▼
┌─────────────────────┐
│  8. LLM column      │  Batch 1 — numeric ambiguous (integer, 3–20 unique values):
│     classification  │    llm_batch() with COLUMN_TYPE_PROMPT (prompts.R)
│                     │    Types: continuous / ordinal / categorical / binary / id / unknown
│                     │    Fallback: is_numeric=TRUE and LLM returns "unknown" → continuous
│                     │    Cap: MAX_COL_TYPE_LLM_CALLS (default 5) when !FULL_RUN
│                     │  Batch 2 — character ambiguous (rule 9 routing):
│                     │    llm_batch() with CHAR_COLUMN_TYPE_PROMPT (prompts.R)
│                     │    Types: categorical / ordinal / binary / text / id / unknown
│                     │    Fallback: invalid type or "unknown" → text
│                     │    Cap: MAX_CHAR_COL_TYPE_LLM_CALLS (default 3) when !FULL_RUN
│                     │    Sample: up to 20 unique non-NA values per column (vs 10 for Batch 1)
│                     │  VALID_COL_TYPES allowlist enforced after both batches; out-of-allowlist
│                     │  responses logged and replaced with fallback before writing output
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│  9. Compute stats   │  For numeric col_types: mean, sd, se, median, min, max,
│                     │  range, p25, p75, iqr, skewness, kurtosis
│                     │  Non-numeric: n and n_missing only
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│  10. Write outputs  │  outputs/<source>/<paper_id>/structure.csv  (one row per file)
│                     │  outputs/<source>/<paper_id>/columns.csv   (one row per column)
└──────────┬──────────┘
           │                    ┌─────────────────────────┐
           │   (optional,       │  [V] Validation GUI      │  runners/run_validation_gui.R
           ├──────────────────► │       (manual review)    │  Shiny app: annotator reviews
           │    any time        │                          │  type/group/data_granularity
           │    after step 10)  │                          │  per file; writes
           │                    │                          │  ground_truth/<paper_id>.csv
           │                    └─────────────────────────┘
           │                         │ overrides feed into step 13
           │                    ┌─────────────────────────┐
           │   (before bulk     │  [R] Ground truth repair │  runners/repair_ground_truth_data_format.R
           ├──────────────────► │       (pre-rerun step)   │  Backfills data_format_gt in all
           │    rerun only)     │                          │  ground_truth/<paper_id>.csv files.
           │                    │                          │  Idempotent. Run once before
           │                    │                          │  triggering a full pipeline rerun.
           │                    └─────────────────────────┘
           ▼
┌─────────────────────┐
│  11. Append to      │  bulk_summary.csv  (one row per paper, appended immediately)
│      bulk summary   │  Crash-safe: progress survives interruption
└──────────┬──────────┘
           │  (optional post-processing step)
           ▼
┌─────────────────────┐
│  12. Codebook       │  2_codebook_label.R  run_codebook_label(paper_id)
│      labelling      │  Reads: outputs/<source>/<paper_id>/structure.csv (codebook/readme files)
│                     │         outputs/<source>/<paper_id>/columns.csv   (data columns to label)
│                     │  Writes: outputs/<source>/<paper_id>/labels.csv        (one row per data column)
│                     │          outputs/<source>/<paper_id>/codebook_coverage.csv (one row per codebook var)
│                     │  Codebook formats: csv/tsv/xlsx/xls/sav/dta (rule-based)
│                     │                    docx (officer), pdf (pdftools), rtf (regex strip)
│                     │                    doc (textutil, macOS system binary — no install)
│                     │                    odt (unzip content.xml + XML tag strip, base R)
│                     │                    plain text (LLM chunking)
│                     │  Conflict resolution: multi-label columns resolved by rule-based
│                     │  normalisation first (normalize_label()), then LLM batch if still
│                     │  conflicting (LABEL_MERGE_PROMPT, 1 call/paper) — sets
│                     │  label_method = "merged_rules" or "merged_llm"
│                     │  Dependencies: officer (≥0.7.0), pdftools (≥3.0.0) — already installed
└──────────┬──────────┘
           │  (optional post-processing step)
           ▼
┌─────────────────────┐
│  13. PsychDS        │  pipeline/3_psychds_convert.R  convert_psychds(paper_id)
│      conversion     │  Reads: outputs/<source>/<paper_id>/structure.csv
│                     │         outputs/<source>/<paper_id>/columns.csv
│                     │         outputs/<source>/<paper_id>/labels.csv
│                     │         outputs/<source>/<paper_id>/codebook_coverage.csv
│                     │         ground_truth/<paper_id>.csv (optional)
│                     │         data_check/data/<paper_id>/grobid/*.xml (optional)
│                     │  Writes: psychds/<paper_id>/dataset_description.json
│                     │          psychds/<paper_id>/data/<name>_data.csv
│                     │          psychds/<paper_id>/data/<name>_data.json (sidecar)
│                     │          psychds/<paper_id>/data/raw/ (oversized/raw files)
│                     │          psychds/<paper_id>/materials/, documentation/, code/
│                     │          psychds/<paper_id>/documentation/txt/ (plaintext copies)
│                     │          psychds/<paper_id>/provenance.json
│                     │  Multi-study layout: psychds/<paper_id>/study-<group>/
│                     │  Oversized files (>500 MB): raw copy only, no CSV conversion
│                     │  Sentinel expansion: aggregate placeholder rows replaced with
│                     │  individual file records before conversion
│                     │  Ground truth: ground_truth/<paper_id>.csv overrides type/group/data_granularity
│                     │  Paper metadata: populated from GROBID TEI XML if present (xml2);
│                     │  authors read only from teiHeader analytic (not bibliography refs).
│                     │  Citation metadata (journal, publication year, volume, issue,
│                     │  pages, ISSN, publisher) resolved from CrossRef by DOI and cached
│                     │  to cache/crossref/; CrossRef is authoritative over GROBID for
│                     │  these fields. Emitted as schema.org isPartOf (Periodical),
│                     │  datePublished, and datacheck:publication_year/volume/issue/pagination.
│                     │  Plaintext extraction: doc/codebook files with .pdf/.docx/.rtf
│                     │  extension produce a .txt copy in documentation/txt/ via
│                     │  extract_plain_text() in helper.R (pdftools/officer/RTF strip);
│                     │  image-only PDFs and errors are flagged in provenance.json only
└─────────────────────┘
           │
           ▼
┌─────────────────────┐
│  14. User report    │  pipeline/4_report.R  run_report(paper_id, source)
│                     │  Reads: outputs/<source>/<paper_id>/structure.csv
│                     │         outputs/<source>/<paper_id>/columns.csv
│                     │         outputs/<source>/<paper_id>/labels.csv
│                     │         outputs/<source>/<paper_id>/codebook_coverage.csv
│                     │  Writes: outputs/<source>/<paper_id>/report.html
│                     │  READ-ONLY over existing CSVs — no LLM, no reclassification.
│                     │  Styled, self-contained HTML (the single export). Plain-
│                     │  language, end-user-facing. Sticky sidebar (key-number
│                     │  panel + section nav) + a numbered walkthrough that mirrors
│                     │  the pipeline: Overview → ① Files found (classification +
│                     │  type legend) → ② Columns & types (distribution + expandable
│                     │  per-variable overview: type + how decided, codebook label +
│                     │  how matched, granularity, samples, stats) → ③ Codebook
│                     │  matching (coverage + callouts) → ④ Data granularity
│                     │  (individual vs combined + how inferred) → Behind the scenes
│                     │  (rules-vs-LLM split) → Glossary. Each stage carries a "How
│                     │  this step works" <details>. Single brand colour; vivid
│                     │  colour only on type/decision badges + callouts.
│                     │  Standalone regen: runners/reports/report_user.R
└─────────────────────┘
```

---

## Key Constants (`0_index.R`)

| Constant | Value | Script | Purpose |
|---|---|---|---|
| `OUTPUT_DIR` | `./data_check/outputs` | `0_index.R`, `2_codebook_label.R` | Root for per-paper output subdirectories; per-paper path is `outputs/<source>/<paper_id>/` via `paper_path()` |
| `GROUND_TRUTH_DIR` | `./data_check/ground_truth` | `0_index.R`, `helper.R` | Root for ground-truth annotation CSVs (OSF only: `ground_truth/osf/<paper_id>.csv`) |
| `DATAVERSE_DATA_DIR` | `./data_check/data/dataverse` | `0_index.R` | Root for Harvard Dataverse deposit directories (`<doi_slug>/` subdirs) |
| `LLM_BATCH_SIZE` | 30 | `0_index.R`, `2_codebook_label.R` | Paths per LLM call (file classification); 30 improves cross-batch group consistency |
| `N_DATA_READ` | 5 | `0_index.R` | Rows sampled per data file |
| `MAX_COL_TYPE_LLM_CALLS` | 5 | `0_index.R` | Max LLM calls for numeric-ambiguous column classification (= 100 columns max) when `!FULL_RUN` |
| `MAX_CHAR_COL_TYPE_LLM_CALLS` | 3 | `0_index.R` | Max LLM calls for character-ambiguous column classification (Batch 2, = 60 columns max) when `!FULL_RUN` |
| `MAX_DATA_FILES` | `Inf` | `0_index.R` | Max tabular data files to column-extract per paper; `Inf` = no cap. Set to a finite integer (e.g. `30L`) in the bulk runner as a temporary guard when `combined`/`individual` misclassification inflates N. |
| `AGGREGATE_THRESHOLD` | 50 | `0_index.R` | Files per folder above which a sentinel row replaces individual paths |
| `SOFTWARE_FOLDER_THRESHOLD_AMBIG` | 100 | `0_index.R` | Min recursive file count for a **Tier B** (ambiguous-name) folder to trigger bulk `"software"` labelling (step 4.5). Tier A folders have no threshold. |
| `SOFTWARE_FOLDER_PATTERNS_UNAMBIG` | character vector | `0_index.R` | **Tier A** folder basenames unique to language tooling (`__pycache__`, `.git`, `renv`, `node_modules`, `site-packages`, `venv`, `.venv`, `.Rproj.user`, `packrat`, `.ipynb_checkpoints`, `bower_components`, `jspm_packages`, `__pypackages__`, `.pytest_cache`, `.mypy_cache`). Match alone is sufficient. |
| `SOFTWARE_FOLDER_PATTERNS_AMBIG` | character vector | `0_index.R` | **Tier B** ambiguous folder basenames (`lib`, `libs`, `src`, `build`, `dist`, `vendor`). Match requires threshold + extension-majority gate. `target` deliberately excluded (collides with psychology stimulus folders). |
| `AGGREGATE_EXT_OVERRIDE` | named vector | `0_index.R` | Extension → type map applied after sentinel expansion to correct inherited types |
| `MAX_DIR_WORDS` | 5 | `0_index.R` | Directory name word limit before truncation |
| `MAX_CODEBOOK_LLM_CALLS` | 3 | `2_codebook_label.R` | Max LLM calls per paper for codebook text parsing |
| `MAX_CODEBOOK_FILE_MB` | 100 | `2_codebook_label.R` | Codebook files larger than this (MB) are skipped |
| `MULTILEVEL_HEADER_LOOKAHEAD` | 3L | `0_index.R` | Max rows to scan below row 1 for a usable sub-header row in multi-level CSV files |
| `PSYCHDS_OUT_DIR` | `./data_check/psychds` | `3_psychds_convert.R` | Root directory for PsychDS output directories |
| `DATA_SIZE_LIMIT_MB` | 500 | `3_psychds_convert.R` | Max data file size (MB) for CSV conversion; oversized files are raw-copied only |
| `PSYCHDS_CROSSREF` | `TRUE` | `3_psychds_convert.R` | Enable CrossRef DOI lookup to fill citation metadata (journal/year/volume/issue/pages/ISSN/publisher) |
| `CROSSREF_CACHE_DIR` | `./cache/crossref` | `3_psychds_convert.R` | On-disk JSON cache of CrossRef responses (one file per DOI) |
| `CROSSREF_MAILTO` | `levi12373@gmail.com` | `3_psychds_convert.R` | Contact for CrossRef "polite pool" User-Agent |
| `CROSSREF_TIMEOUT_SEC` | 15L | `3_psychds_convert.R` | Per-request network timeout for CrossRef calls |

## Resource Limits

| Limit | Value | Error code on breach |
|---|---|---|
| Download size per paper | 10 GB | `too_large` |
| Data file size | 500 MB | file skipped silently |
| LLM calls per paper | 10 (= 200 file paths) | `too_large` |

## Bulk Runner Config (`runners/run_0_index_bulk.R`)

Flags set at the top of the bulk runner script. All override the same-named constants in `0_index.R` when present.

| Flag | Default | Purpose |
|---|---|---|
| `FULL_RUN` | `TRUE` | Bypass all LLM call caps (`MAX_COL_TYPE_LLM_CALLS`, `MAX_CHAR_COL_TYPE_LLM_CALLS`). **Must be `TRUE` for production runs.** The `!FULL_RUN` guard is mandatory on every truncation line in `0_index.R`. |
| `SKIP_COLUMNS` | `FALSE` | Skip column extraction entirely — produces `structure.csv` only. Useful for rapid file-type indexing passes. |
| `RERUN_COLUMNS` | `TRUE` | Re-run column extraction for papers that succeeded but have no `columns.csv` on disk. Forces `SKIP_COLUMNS = FALSE`, `COLUMNS_ONLY = TRUE`, `FROM_LOCAL = TRUE`, `DOWNLOAD = FALSE`. Updates existing rows in `bulk_summary.csv` rather than appending. |
| `FROM_LOCAL` | `TRUE` | Skip downloading; discover paper IDs from existing `data/<paper_id>/` subdirectories instead of XML files. Forces `DOWNLOAD = FALSE`. |
| `DOWNLOAD` | `TRUE` | Whether to attempt OSF downloads. Automatically set to `FALSE` when `FROM_LOCAL = TRUE`. |
| `RESUME` | `TRUE` | Skip papers already present in `bulk_summary.csv`. Set `FALSE` to re-run all papers (e.g. after a pipeline change). |
| `PRIORITISE_GT` | `TRUE` | Move papers that have a `ground_truth/<paper_id>.csv` to the front of the queue. Within each group, `SHUFFLE`/`SEED` ordering still applies. |
| `GT_DIR` | `./data_check/ground_truth` | Directory scanned to identify ground-truth papers when `PRIORITISE_GT = TRUE`. |
| `N_RUNS` | `Inf` | Cap on papers to process in this run. `Inf` = all remaining papers. |
| `SHUFFLE` | `TRUE` | Randomise paper order before processing. |
| `SEED` | `NULL` | RNG seed for reproducible shuffle. `NULL` = non-deterministic. |
| `MAX_DATA_FILES` | `30L` | Cap on tabular data files to column-extract per paper. Temporary guard against N explosion from `combined`/`individual` misclassification; set to `Inf` once that is fixed. |
| `MAX_COL_TYPE_LLM_CALLS` | `5L` | Overrides the `0_index.R` constant for this run. |

---

## LLM Model

All LLM calls use `ollama/gpt-oss:20b-cloud` via `llm_batch()` in `helper.R`.
Batch size is `LLM_BATCH_SIZE = 30` for file classification.

---

## Retry Behaviour

The bulk runner (`run_index_bulk.R`) retries once if the error is `empty_repo`
(deletes the empty downloaded folder and re-runs). All other errors are written
to `bulk_summary.csv` without retry.

---

## Testing

### Test runner

`runners/run_tests.R` runs the full pipeline (index → codebook label → psychds)
against a fixed set of 13 hard-dataset papers, then generates `results/test_report_<date>.md`.
Set `REPORT_ONLY <- TRUE` at the top to regenerate the report from the last run
without re-running the pipeline. There are **no automated assertions** — all
output is for manual inspection.

All papers must already be downloaded to `data_check/data/<paper_id>/`.

**Usage**

```r
source("data_check/runners/run_tests.R")   # interactive
Rscript data_check/runners/run_tests.R     # CLI
```

### Test outputs

| Path | Contents |
|---|---|
| `tests/outputs/<source>/<paper_id>/` | Per-stage CSVs written by index + codebook label stages |
| `tests/psychds/<paper_id>/` | PsychDS output written by the psychds stage |
| `tests/test_log.csv` | One row per paper per run; appended each run |

`convert_psychds()` reads from the production path `./data_check/outputs/<source>/<paper_id>/` via `paper_path()`.
The test runner bridges this via a temporary symlink when the production path does
not exist, then removes it after the stage completes.

### Test log columns

| Column | Description |
|---|---|
| `run_id` | Timestamp of the run (`YYYY-MM-DD_HH-MM-SS`) |
| `paper_id` | Paper identifier (character string) |
| `label` | Human-readable test case description |
| `index_success` / `index_error` | Stage 1 pass/fail and error message |
| `codebook_success` / `codebook_error` | Stage 2 pass/fail and error message |
| `psychds_success` / `psychds_error` | Stage 3 pass/fail and error message |
| `n_files`, `n_data_files`, `n_tabular_files`, `n_columns`, `n_agg_dirs` | Index-stage file counts (`n_data_files` = all data rows; `n_tabular_files` = tabular-format subset sent to column extraction) |
| `file_types`, `data_groups`, `col_types` | JSON count maps from index stage |
| `index_elapsed_sec` | Wall-clock seconds for index stage |
| `label_status`, `n_labelled`, `n_unlabelled`, `coverage` | Codebook label results |
| `codebook_elapsed_sec` | Wall-clock seconds for codebook label stage |
| `psychds_studies`, `psychds_vars`, `psychds_labelled` | PsychDS stage summary |
| `psychds_elapsed_sec` | Wall-clock seconds for psychds stage |

### Test paper catalogue

| Paper ID | Label / Scenario |
|---|---|
| `0956797615620784` | Baseline — 1 CSV + RTF codebook + R script |
| `0956797614523297` | Baseline — 2 clean CSVs, ex1/ex2 groups, no codebook |
| `0956797614559543` | Baseline — readme.txt codebook, all-continuous columns |
| `0956797614536738` | Column type: numeric ID columns (risk of `unknown` instead of `id`) |
| `0956797614557867` | Column type: alphanumeric IDs + 2 codebook files |
| `0956797614533802` | Multilevel headers + comma decimals + parentheses in filenames |
| `0956797614534695` | Comma decimals + multi-experiment CSV |
| `0956797614524581` | Multi-study (ex1/ex2/ex3) + CSV+SAV mix + DOCX codebook |
| `0956797614553121` | Multi-format: 10 data files + 6 codebook files across populations |
| `0956797614543801` | Codebook: 5 codebook files + 7 data files + LIWC output columns |
| `0956797614559730` | Codebook: CSV codebook in same folder as data (misclassification risk) |
| `0956797614547916` | Per-participant: 142 `.dat` files across 8 experiment groups |
| `0956797614561045` | Large repo: 99 data files + 1 codebook (near `too_large` limit) |
| `0956797615571018` | Software: E-Prime task files (`.ebs2/.es2/.wndpos`) + pilot1 study group |
| `0956797614535937` | Software: Python online task scripts — code vs software boundary |
| `0956797620965536` | Pilot: multi-pilot (pilot1+pilot2) + output plots not classified as asset |
| `0956797617739368` | Output: 25 output files (`.pdf/.spv/R markdown`) across 4 clean experiments |
| `0956797617746749` | Output: 41 outputs including CSV as output (p-curve results) — data boundary |
| `0956797617706706` | Complex groups: pilot6a + ex4b–ex4g letter suffixes + sharedex4b edge case |
| `0956797616685770` | Balanced: software (`.pyw`) + output (figures) + 7 experiment groups with letter suffixes |
| `0956797615624491` | Haven simple: `.sav` only (43/43 embedded labels, no codebook file) — tests haven-only label path |
| `0956797616669086` | Haven complex: `.sav` (48/48 embedded labels) + `Variable_Codebook.csv` — tests haven priority over file-based codebook |

### Adding new test papers

When a new edge case is found that a new implementation must handle:
1. Add the paper to `tests/test_papers.csv` with a descriptive `label`.
2. Ensure the paper's data is downloaded to `data_check/data/<paper_id>/`.
3. Update this table.

### Update rules

- When a new pipeline stage is added → verify it runs correctly against all 22 test papers before merging.
- When a new `col_type`, file `type`, or `group` is introduced → check the test log `file_types`, `data_groups`, `col_types` columns to confirm the new value appears where expected.
- When a new test paper is added → add it to the catalogue table above.
