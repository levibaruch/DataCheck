# Output Schemas

Five CSV files are produced per paper run (three from `0_index.R`, two from `2_codebook_label.R`).

---

## `outputs/<paper_id>/structure.csv`

One row per file discovered in the paper's OSF repository.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier (leading zeros preserved) |
| `path` | character | Absolute local path to the file |
| `rel_path` | character | Path relative to the paper's download directory |
| `filename` | character | Basename of the file |
| `ext` | character | File extension (lowercase) |
| `type` | character | File type — see [File Types](#file-types) |
| `type_source` | character | How `type` was determined — see [Type Source Values](#type-source-values) |
| `group` | character | Experiment/study group — see [Groups](#groups) |
| `aggregate_folder` | character \| NA | Relative path of the aggregate folder this file was expanded from; `NA` for non-aggregate files |
| `data_granularity` | character \| NA | `"individual"` (one row per participant; detected via folder structure, filename heuristic, or LLM), `"combined"` (all participants merged; default for non-signalling files), or `NA` (non-data file). |
| `granularity_source` | character \| NA | Detection method for `data_granularity`: `"folder_heuristic"` (aggregate participant subdirs), `"filename_heuristic"` (per-participant filename pattern), `"llm"` (column names), `"default_combined"` (no signal), or `NA` (non-data file). Provides traceability for validation. |
| `prompt_nr` | integer \| NA | LLM prompt batch index used to classify this file; `NA` for rule-classified files |
| `data_format` | character \| NA | Sub-classification for `type = "data"` rows: `"tabular"` (column-extractable) or `"raw"` (binary recordings, matrices, media); `NA` for all non-data rows. Determined by file extension via `classify_data_format()` — never set by the LLM. Unknown extensions fall back to `"tabular"`. |

### Type Source Values

| Value | Meaning |
|---|---|
| `"llm"` | Type assigned by Phase 1 LLM classification of an individual (non-aggregate) file |
| `"aggregate_llm"` | Type assigned by Phase 1 LLM classification of a sample file from an extension group in an aggregate folder; propagated to all member files in that group |
| `"rule_folder"` | Type assigned by the software folder detection rule (step 4.5). Either: (a) folder basename matched `SOFTWARE_FOLDER_PATTERNS_UNAMBIG` (Tier A — e.g. `__pycache__`, `.git`, `renv`, `node_modules`), or (b) basename matched `SOFTWARE_FOLDER_PATTERNS_AMBIG` (Tier B — e.g. `lib`, `src`, `build`) AND folder contained ≥ `SOFTWARE_FOLDER_THRESHOLD_AMBIG` files AND ≤50% were tabular data extensions. No LLM call made. `aggregate_folder` column records the matched folder path. |
| `"extension_rule"` | Type assigned by `AGGREGATE_EXT_OVERRIDE` lookup (validation only; not applied to results) |
| `"rmd_pair_rule"` | Type overridden to `"output"` because the PDF shares its stem with a `.Rmd`/`.qmd`/`.tex` source file in the same directory (post-classification fallback) |
| `"fixed_ext_rule"` | Type overridden by a deterministic extension lookup applied after the LLM (formats whose purpose is fixed by file format). Code: `.R`, `.qmd`, `.ipynb`, `.do`, `.sps`, `.sas`. Software: `.exe`, `.dmg`, `.app`, `.jar`, `.msi`, `.deb`, `.rpm`, `.sh`, `.bash`, `.zsh`, `.bat`, `.cmd`, `.ps1`, `.dll`, `.so`, `.dylib`, `.lib`, `.lua`, `.psyexp`, `.osexp`, `.opensesame`. Output: `.spv`, `.fig`. Only set when the LLM's label differed from the rule. |
| `"fixed_filename_rule"` | Type overridden to `"readme"` because the filename matches `^readme(\.|$)` (case-insensitive). Only set when the LLM's label differed. |

### File Types

| Value | Meaning |
|---|---|
| `data` | Any file containing research measurements for analysis — tabular (CSV, SAV, XLSX, RDS, DTA, etc.) or non-tabular (EEG/physiological recordings `.edf`/`.acq`/`.bdf`, MATLAB matrices `.mat`, nested JSON survey exports). Column extraction skips non-parseable formats; file remains `data`. |
| `codebook` | File whose primary purpose is describing what variables mean — variable dictionary, data dictionary, coding key. Determined by semantic inference from filename. |
| `code` | Executable source file: R, Python, MATLAB, Julia, SQL, shell scripts, `.Rmd`/`.qmd` notebooks (always `code` regardless of narrative content). Purpose: generating analyses or research outputs. |
| `software` | Program, application, or any file that is part of the experiment software package — stimulus delivery tools, task presentation programs, data collection applications, compiled binaries (`.exe`, `.app`, `.jar`, `.msi`, `.dmg`), installers, configuration files, build files, and anything else belonging to the experiment software. Distinct from `code` (which generates analyses/outputs). The whole package counts: if a file belongs to the experiment software, it is `software` regardless of extension. |
| `output` | File produced by executing a script — rendered notebooks (`.html`, `.pdf`, `.docx` output from `.Rmd`/`.qmd`/`.ipynb`), script-generated figures and graphs, log files, and other computational byproducts. Not column-extracted. When provenance is ambiguous, `supplemental` is the fallback. |
| `supplemental` | Human-authored research material that is not data, code, or a codebook — manuscripts, articles, reports, proposals, theses, preregistrations, registered reports, survey instruments, consent forms, SPSS `.spv` syntax, supporting appendices. Script-generated artefacts (figures, rendered notebooks, log files) → `output`. Fallback for ambiguous provenance. |
| `readme` | Files named `README.*`, `LICENSE.*`, or `CONTRIBUTING.*` only. Classified by filename. |
| `asset` | Participant-facing sensory material presented to participants during the study — stimulus images, audio clips, video stimuli. |
| `other` | No research content: OS metadata (`.DS_Store`, `Thumbs.db`), lock files, environment config, executables, installers. Not a catch-all. |
| `llm_error` | LLM batch chunk failed on all retry attempts — classification could not be determined. Indicates a process error; rows should be reviewed manually. |

### File Type Consumers

Any component that enumerates or displays file types must be updated whenever a type is added, removed, or renamed. Current consumers:

| Consumer | Location | What to update |
|---|---|---|
| LLM classification prompt | `pipeline/prompts.R` — `STRUCTURE_PROMPT` | Add type to `TYPE —` block and relevant hard-case rules |
| Sentinel classification prompt | `pipeline/prompts.R` — `SENTINEL_PROMPT` | Add type to `TYPE —` block and key signals |
| Validation GUI type buttons | `tools/validation_gui/app.R` — `TYPE_MAP`, `TYPE_ABBREV` | Add entry; assign next available keyboard shortcut (1–9) |
| Validation GUI CSS | `tools/validation_gui/app.R` — `APP_CSS` | Add `.tbadge-<type>` and `.tbtn-<type>.tbtn-active` for light and dark mode |
| Validation GUI keyboard handler | `tools/validation_gui/app.R` — `observeEvent(input$key_press)` | Add `"N" = { rv$selected_type <- "<type>" }` |
| Validation GUI JS key allowlist | `tools/validation_gui/app.R` — `KB_JS` | Add key character to the allowlist array |
| PsychDS converter subdirectory map | `pipeline/3_psychds_convert.R` — `TYPE_TO_SUBDIR` | Add type → subdirectory mapping |
| PsychDS converter aggregate override | `pipeline/3_psychds_convert.R` — `AGGREGATE_EXT_OVERRIDE` | Add extensions → type mapping |

### Groups

| Value | Meaning |
|---|---|
| `ex<N>` | Main numbered experiment/study (e.g. `ex1`, `ex2`, `ex4a`). Letter suffixes preserved exactly. |
| `pilot<N>` | Pilot study (e.g. `pilot1`, `pilot1a`). Alphanumeric suffixes preserved exactly (`pilot1a` ≠ `pilot1`). Unnumbered pilots use `pilot1`. |
| `shared` | All files not tied to a specific numbered experiment or pilot — combined datasets, project-wide scripts, cross-experiment files, archive folders, and all `readme`, `asset`, and `other` files regardless of location. |

---

## `outputs/<paper_id>/columns.csv`

One row per column in each data file classified as `type = "data"`.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier |
| `source_file` | character | Relative path to the source data file |
| `filename` | character | Basename of the source file |
| `group` | character | Experiment group inherited from `structure.csv` |
| `col_header_group` | character (nullable) | Condition/group label from the first header row, forward-filled across the span it covers. `NA` for files without multi-level headers or for columns preceding the first group label. |
| `column_name` | character | Column name as it appears in the data file (sub-header row value for resolved multi-level files; original name otherwise) |
| `sample_values` | character | First up to 5 non-NA values, pipe-separated (`\|`) |
| `col_type` | character | Classified column type — see [Column Types](#column-types) |
| `n_coerced` | integer | Values excluded during comma-decimal normalisation; `NA` when not applicable |
| `n` | integer | Count of non-missing values |
| `n_missing` | integer | Count of missing (`NA`) values |
| `n_unique` | integer | Count of distinct non-NA values; 0 for all-NA columns; populated for all `col_type` values |
| `mean` | numeric | Arithmetic mean (numeric types only; `NA` otherwise) |
| `sd` | numeric | Standard deviation |
| `se` | numeric | Standard error of the mean |
| `median` | numeric | Median |
| `min` | numeric | Minimum |
| `max` | numeric | Maximum |
| `range` | numeric | `max - min` |
| `p25` | numeric | 25th percentile |
| `p75` | numeric | 75th percentile |
| `iqr` | numeric | Interquartile range (`p75 - p25`) |
| `skewness` | numeric | Pearson moment skewness |
| `kurtosis` | numeric | Excess kurtosis (normal distribution = 0) |

`n_unique` is populated for **all** column types. The 12 numeric statistics (`mean` through
`kurtosis`) are populated only for numeric column types (`continuous`,
`continuous_comma_decimal`, `continuous_outliers_excluded`). All other types —
including `binary`, `constant`, `categorical`, `ordinal`, `date`, `id`, `text`,
`empty`, and `unknown` — have `NA` for those 12 columns.

### Column Types

| Value | Assigned by | Meaning |
|---|---|---|
| `continuous` | Rule 7a / Rule 7 / LLM / fallback | Numeric measurement (decimal or integer with >20 unique values, or LLM-confirmed) |
| `ordinal` | LLM | Ordered integer scale with few levels (Likert, rating) |
| `binary` | Rule 4 | Exactly two unique non-NA values |
| `constant` | Rule 3 | Exactly one unique non-NA value (degenerate or placeholder column) |
| `categorical` | LLM Batch 2 | Unordered group or category label — condition names, gender codes, language labels |
| `date` | Rule 5 | Date-parseable values |
| `id` | Rule 2 | Participant or row identifier — classified by column name pattern (participant, subject, ResponseId, sub-01, pid, etc.); value type is not a factor |
| `text` | Rule 6 / LLM Batch 2 / fallback | Free-text or long string values; also fallback for character columns where LLM returns `unknown` |
| `continuous_comma_decimal` | Rule 8 | Numeric with comma as decimal separator (≥95% convertible) |
| `continuous_outliers_excluded` | Rule 8 | Numeric with comma separator but some non-convertible values (80–95%) |
| `empty` | Rule 1 | All values are `NA` |
| `unknown` | LLM / fallback | Cannot be determined (genuinely uninformative name and values) |
| `llm_error` | `llm_batch()` (on retry exhaustion) | LLM batch chunk failed on all retry attempts — column type could not be determined. Indicates a process error; not remapped by any fallback rule. |

---

## `bulk_summary.csv`

One row per paper, appended immediately after each paper completes. Used by the bulk
runner to resume after a crash.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier |
| `success` | logical | `TRUE` if the paper completed without error |
| `error` | character | Error code or message if `success = FALSE`; `NA` otherwise |
| `elapsed_ms` | integer | Total wall-clock time in milliseconds |
| `download_ms` | integer | Time spent downloading in milliseconds |
| `llm_ms` | integer | Time spent on all LLM calls in milliseconds |
| `column_ms` | integer | Time spent on column extraction in milliseconds |
| `n_files` | integer | Total files discovered in the repository |
| `n_data_files` | integer | Files classified as `type = "data"` (all formats, excluding sentinels) |
| `n_tabular_files` | integer | Data files with `data_format = "tabular"` — the subset actually sent to column extraction |
| `n_agg_dirs` | integer | Aggregate folders detected and sub-grouped |
| `n_individual` | integer | Data files with `data_granularity = "individual"` (part of a detected series) |
| `n_combined` | integer | Data files with `data_granularity = "combined"` (classified individually) |
| `n_columns` | integer | Total columns extracted across all data files |
| `n_src_files` | integer | Source data files from which columns were extracted |
| `source` | character | Repository source: `"osf"` or `"dataverse"`. `NA` on rows written before this column was added — treat as `"osf"`. |

### Error Codes

| Code | Cause |
|---|---|
| `no_links` | OSF repository has no downloadable file links |
| `download_failed` | Network or OSF API error during download |
| `empty_repo` | Downloaded repository contains no usable files after unpacking (retried once) |
| `too_large` | Exceeded download size limit (10 GB) or file path count limit (200 paths) |
| `dataverse_dir_missing` | Dataverse deposit: `data_check/data/dataverse/<doi_slug>/` directory does not exist |
| `pipeline_failed` | Paper's `structure.csv` is absent or `success` column indicates an earlier pipeline stage failed |
| `no_data_files` | `structure.csv` exists and pipeline succeeded, but no files with `type = "data"` were found |

---

## `psychds/conversion_summary.csv`

One row per study group per paper, appended immediately after each paper completes. Used by the bulk PsychDS runner to auto-resume after a crash.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier (leading zeros preserved) |
| `study_group` | character | Study/experiment group label (e.g. `ex1`, `ex2`); `"single"` for single-study papers |
| `success` | logical | `TRUE` if the study group converted without error |
| `error` | character | Error code or message if `success = FALSE`; `NA` otherwise |
| `n_data_files` | integer | Data files converted to PsychDS CSV format |
| `n_raw_files` | integer | Files copied to `data/raw/` only (oversized, raw-flagged, or non-convertible) |
| `n_variables` | integer | Total variables written to `variableMeasured` in `dataset_description.json` |
| `n_labelled` | integer | Variables with a matched codebook label |
| `has_paper_metadata` | logical | `TRUE` if GROBID TEI XML was found and metadata was extracted |
| `has_ground_truth` | logical | `TRUE` if `ground_truth/<paper_id>.csv` was applied |
| `output_path` | character | Absolute path to the output directory for this study group |

### TXT extraction fields in `provenance.json`

Present only on entries where TXT extraction was attempted (i.e., files with `pipeline_type` of `"codebook"`, or `"supplemental"` files whose filename matches a narrative-document pattern — manuscript, preregistration, thesis, report, etc. — with extension `.pdf`, `.docx`, or `.rtf`):

| Field | Type | Description |
|---|---|---|
| `txt_extraction_attempted` | boolean | `true` when `extract_plain_text()` was called for this file |
| `txt_extraction_skipped` | boolean | `true` if no `.txt` file was written (empty result or error) |
| `txt_skip_reason` | string | `"no_extractable_text"` (empty result, e.g. image-only PDF) or `"extraction_error"` (exception during extraction); absent when not skipped |
| `txt_psychds_path` | string | Relative path of the written `.txt` file (e.g. `"documentation/txt/codebook.txt"`); absent when skipped |

---

## `label_summary.csv`

One row per paper processed by `run_label_bulk.R`. Appended immediately after each paper. Used to auto-resume after a crash.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier (leading zeros preserved) |
| `success` | logical | `TRUE` if `columns.csv` was written successfully |
| `error` | character | Error message if `success = FALSE`; `NA` otherwise |
| `elapsed_ms` | integer | Wall-clock time in milliseconds |
| `n_data_files` | integer | Data files found in `structure.csv` |
| `n_columns` | integer | Columns written to `columns.csv` |

---

## `codebook_summary.csv`

One row per paper processed by `run_codebook_bulk.R`. Appended immediately after each paper. Used to auto-resume after a crash.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier (leading zeros preserved) |
| `success` | logical | `TRUE` if `labels.csv` and `codebook_coverage.csv` were written |
| `error` | character | Error message if `success = FALSE`; `NA` otherwise |
| `elapsed_ms` | integer | Wall-clock time in milliseconds |
| `n_labelled` | integer | Columns with `label_status = "labelled"` |
| `n_unlabelled` | integer | Columns with `label_status = "unlabelled"` or `"no_codebook"` |
| `n_codebook_vars` | integer | Total variables extracted from codebooks |
| `n_matched_vars` | integer | Codebook variables matched to at least one data column |
| `label_status` | character | Overall paper outcome: `"ok"`, `"no_match"`, or `"no_codebook"` |

---

## `report_summary.csv`

One row per paper processed by Stage 4 (`4_report.R`) of `run_full_pipeline_bulk.R`. Appended immediately after each paper. Used to auto-resume after a crash. The report itself is written per paper as a single self-contained `outputs/<source>/<paper_id>/report.html` — a styled, end-user-facing document (not a CSV) with a sticky sidebar (key-number panel + section nav) and a numbered walkthrough that follows the pipeline: Overview (tiles + roadmap) → ① Files found (classification + file-type legend) → ② Columns & their types (distribution + expandable per-variable overview: type + how decided, codebook label + how matched, granularity, sample values, stats) → ③ Codebook matching (coverage + recommendation callouts) → ④ Data granularity (individual vs combined + how inferred) → Behind the scenes (rules-vs-LLM split) → Glossary. Each numbered stage carries a "How this step works" disclosure. Single brand colour for cards; vivid colour reserved for type/decision badges and callouts.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier (leading zeros preserved) |
| `success` | logical | `TRUE` if `report.html` was written |
| `error` | character | Error code (`no_structure`) or message if `success = FALSE`; `NA` otherwise |
| `elapsed_ms` | integer | Wall-clock time in milliseconds |
| `n_files` | integer | Files in `structure.csv` |
| `n_columns` | integer | Columns in `columns.csv` |
| `n_labelled` | integer | Data columns with `label_status` in {`labelled`, `llm`} |
| `n_codebook_vars` | integer | Variables in `codebook_coverage.csv` |

---

## `outputs/<paper_id>/labels.csv`

One row per column in each data file (parallel to `columns.csv`). Produced by `2_codebook_label.R`.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier (leading zeros preserved) |
| `source_file` | character | Relative path to the source data file (join key to `columns.csv`) |
| `column_name` | character | Column name as it appears in the data file |
| `group` | character | Experiment group inherited from `_columns.csv` |
| `label` | character | Human-readable label/description from the matched codebook variable; `NA` if unlabelled |
| `codebook_variable` | character | Variable name as written in the codebook; `NA` if unlabelled; pipe-separated if multiple candidates |
| `label_source` | character | Basename of the codebook file that provided the label; `NA` if unlabelled; pipe-separated if multiple sources |
| `label_status` | character | Labelling outcome — see [Label Status Values](#label-status-values) |
| `label_method` | character | How the label was determined: `"rules"` = normalized string match; `"llm"` = secondary LLM pass; `"merged_rules"` = multiple candidate labels collapsed by rule-based normalization; `"merged_llm"` = multiple candidate labels confirmed equivalent by LLM; `NA` = column is unlabelled |

### Label Status Values

| Value | Meaning |
|---|---|
| `labelled` | Column matched exactly one codebook variable with no conflicts; also used when multiple candidate labels were determined to be semantically equivalent and merged (see `label_method`) |
| `unlabelled` | Column has no matching codebook variable |
| `conflicting_definition` | Column matched a variable present in multiple codebooks with different definitions; all candidates pipe-concatenated in `label` |
| `ambiguous_experiment` | Column name exists only in a different experiment group's codebook; candidates pipe-concatenated |
| `no_codebook` | Paper has no codebook or readme files; entire paper is unlabelled |
| `llm` | Matched by secondary LLM pass after rule-based matching found no match |

### Codebook Parse Status (per-file, console warnings only — not in output CSVs)

| Status | Meaning |
|---|---|
| `parse_failed` | File could not be read or yielded no extractable text (< 10 chars); emitted as a `warning()` and the file is skipped; other codebook files for the same paper are still attempted |

---

## `outputs/<paper_id>/codebook_coverage.csv`

One row per variable extracted from any codebook/readme file. Produced by `2_codebook_label.R`.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier |
| `codebook_variable` | character | Variable name as written in the codebook |
| `label` | character | Human-readable label/description |
| `codebook_source` | character | Basename of the codebook file |
| `group` | character | Experiment group scope inferred from codebook context; `NA` if no scope detected (applicable to all groups) |
| `parse_method` | character | How the codebook was parsed: `structured` — rule-based header/column detection; `llm` — LLM chunk parsing fallback; `haven` — embedded variable labels extracted directly from SPSS/Stata/SAS data file |
| `match_status` | character | `matched` — variable found in at least one data column; `unmatched_in_data` — not found in any data column |


---

## `results/ground_truth_repair_summary.csv`

One row per ground truth file processed by `runners/repair_ground_truth_data_format.R`. Written in a single pass over all 103 ground truth files (overwritten on each run).

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier (leading zeros preserved) |
| `n_data_rows` | integer | Rows in the ground truth file where `type_gt == "data"` |
| `n_tabular` | integer | Data rows assigned `data_format_gt = "tabular"` |
| `n_raw` | integer | Data rows assigned `data_format_gt = "raw"` |
| `n_already_present` | integer | Data rows where `data_format_gt` was non-NA before the repair run (idempotency count) |

---

## `results/ground_truth_audit_report.csv`

One row per ground truth entry where `type_gt == "data"` and the file extension is a raw format. Written by `runners/audit_ground_truth_data_format.R`. Sorted by `paper_id` then `rel_path`.

These rows identify entries that were validated under potentially incorrect assumptions — column extraction was previously attempted on raw binary files (EEG recordings, MATLAB matrices, video files) that cannot be parsed by `read_data_head()`.

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier |
| `rel_path` | character | Relative path of the flagged file |
| `ext` | character | File extension (lowercase, no dot) |
| `type_gt` | character | Validated type — always `"data"` for rows in this report |
| `data_format_gt` | character | Assigned format — always `"raw"` for rows in this report |
