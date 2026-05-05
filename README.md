# DataCheck

A pipeline for auditing open psychology datasets. Downloads research data repositories from OSF and Harvard Dataverse, classifies every file using a local LLM, extracts column-level statistics, matches columns against codebooks, and converts to [PsychDS](https://psychds-docs.readthedocs.io/) format.

---

## What it does

Given a paper ID, DataCheck:

1. **Downloads** the data repository from OSF or Harvard Dataverse (up to 10 GB)
2. **Unpacks** archives (zip, tar, rar, gz, bz2, xz)
3. **Classifies** every file by type (`data`, `codebook`, `code`, `output`, `supplemental`, `software`, `asset`, `readme`, `other`) and experiment group (`ex1`, `ex2`, `shared`, …) using a two-phase LLM strategy
4. **Detects** aggregate folders (per-participant series, large flat dirs) and routes them efficiently without exploding the LLM call count
5. **Extracts** column names, types, and statistics from all tabular data files (CSV, SPSS, Stata, Excel, R objects)
6. **Labels** columns by fuzzy-matching against codebook variables — supports CSV, XLSX, DOCX, PDF, RTF, ODT, and plain text codebooks
7. **Converts** to PsychDS format: JSON-LD `dataset_description.json`, per-study subdirectories, sidecar metadata, provenance log
8. **Reports** quality metrics, codebook coverage, and classification accuracy across a bulk run

All outputs are written as CSVs under `outputs/<source>/<paper_id>/`.

---

## Pipeline at a glance

```
Paper ID
  → resolve links (OSF / Dataverse)
  → download + unpack
  → detect software folders (rule-based, no LLM)
  → two-phase LLM file classification
      Phase 1: individual files → type + group
      Phase 2: aggregate series → type propagated to all members
  → read data heads (5 rows per file)
  → rule-based column type classification
  → LLM column type classification (ambiguous columns only)
  → compute statistics (mean, sd, median, IQR, skewness, …)
  → write structure.csv + columns.csv
  → [optional] codebook labelling → labels.csv + codebook_coverage.csv
  → [optional] PsychDS conversion → psychds/<paper_id>/
```

---

## Requirements

- **R 4.5** — base R only, no additional packages beyond those listed
- **R packages:** `haven`, `readxl`, `jsonlite`, `xml2`, `pdftools`, `officer`, `shiny`, `bslib`
- **[Ollama](https://ollama.com/)** running locally (default model: `gpt-oss:20b`)
- **`unrar`** binary on macOS (for `.rar` archives)

---

## Quick start

Run the full pipeline on one randomly selected paper (smoke test / dev entry point):

```r
Rscript runners/pipeline/run_single.R
```

Bulk index all papers:

```r
Rscript runners/pipeline/run_0_index_bulk.R
```

Run the codebook labelling stage across all indexed papers:

```r
Rscript runners/pipeline/run_2_codebook_bulk.R
```

Convert all indexed papers to PsychDS:

```r
Rscript runners/psychds/run_psychds_bulk.R
```

Run the test suite against the 13 registered hard-dataset papers:

```r
Rscript tests/run_tests.R
```

All scripts are invoked from the **repo root**.

---

## Outputs

Per paper, under `outputs/<source>/<paper_id>/`:

| File | Contents |
|---|---|
| `structure.csv` | One row per file — type, group, aggregate folder, data granularity, data format |
| `columns.csv` | One row per column — name, type, statistics (mean, sd, median, IQR, skewness, …) |
| `labels.csv` | One row per column — matched codebook label, label method, label status |
| `codebook_coverage.csv` | One row per codebook variable — match status, parse method |

Aggregate summaries in `results/`:

| File | Contents |
|---|---|
| `bulk_summary.csv` | One row per paper — success/error, timing, file counts |
| `codebook_summary.csv` | One row per paper — label counts, coverage |

### File types

| Type | Meaning |
|---|---|
| `data` | Research measurements — tabular (CSV, SAV, XLSX, …) or raw (EEG, MATLAB, video) |
| `codebook` | Variable dictionary / data dictionary |
| `code` | Executable source: R, Python, MATLAB, Stata, notebooks |
| `software` | Experiment software package — stimuli delivery tools, binaries, installers |
| `output` | Script-generated artefacts — rendered notebooks, figures, log files |
| `supplemental` | Human-authored research material — manuscripts, preregistrations, consent forms |
| `readme` | Files named `README.*`, `LICENSE.*`, `CONTRIBUTING.*` |
| `asset` | Participant-facing stimuli — images, audio, video |
| `other` | OS metadata, lock files, no research content |

### Column types

`continuous`, `ordinal`, `categorical`, `binary`, `id`, `date`, `text`, `constant`, `empty`, `unknown`, `continuous_comma_decimal`, `continuous_outliers_excluded`

---

## Key constants

Set at the top of `pipeline/0_index.R` and overridable in bulk runners:

| Constant | Default | Meaning |
|---|---|---|
| `LLM_BATCH_SIZE` | 30 | File paths per LLM call |
| `N_DATA_READ` | 5 | Rows sampled per data file |
| `AGGREGATE_THRESHOLD` | 20 | Files per folder before aggregate routing kicks in |
| `SOFTWARE_FOLDER_THRESHOLD` | 500 | Min files for software-folder bulk labelling |
| `MAX_COL_TYPE_LLM_CALLS` | 5 | Max LLM batches for numeric-ambiguous columns |
| `MAX_CHAR_COL_TYPE_LLM_CALLS` | 3 | Max LLM batches for character-ambiguous columns |

---

## Repo structure

```
DataCheck/
├── pipeline/               # Core modules — sourced by runners, never run directly
│   ├── 0_index.R           # File classification + structure extraction
│   ├── 2_codebook_label.R  # Column–codebook matching
│   ├── 3_psychds_convert.R # PsychDS conversion
│   ├── helper.R            # Shared helpers: llm_batch, read_data_head, paper_path, …
│   ├── ollama.R            # Ollama HTTP interface (captures thinking traces)
│   └── prompts.R           # All LLM prompt strings
│
├── runners/
│   ├── pipeline/           # run_single, run_folder, run_*_bulk
│   ├── psychds/            # run_psychds_single, run_psychds_bulk
│   ├── reports/            # report_normal, report_quality, report_sweep, report_sweep_grand
│   ├── experiments/        # run_sweep, run_sweep_bulk, ab_test, test_thinking_trace, test_llm_params
│   └── tools/              # download_all_osf, find_csv_codebooks, reset_csv_codebooks, …
│
├── tests/
│   ├── run_tests.R         # Full pipeline test suite (13 hard-dataset papers)
│   ├── test_papers.csv     # Registered test papers with edge-case labels
│   ├── test_log.csv        # Test run history
│   ├── ground_truth/       # Human-validated file labels (used as classification targets)
│   └── validation_gui/     # Shiny app for manual ground-truth annotation
│
├── docs/
│   ├── pipeline.md         # Full end-to-end flow, constants, retry logic, test catalogue
│   ├── output-schemas.md   # Column definitions for all output CSVs, enum values, error codes
│   ├── diary.txt           # Development notes
│   └── specs/              # Feature specs (one folder per feature, NNN-name/)
│
├── outputs/                # Per-paper pipeline outputs (gitignored)
├── data/                   # Downloaded raw repositories (gitignored)
├── results/                # Aggregate summaries and reports (gitignored)
├── psychds/                # PsychDS conversion outputs (gitignored)
└── logs/                   # LLM error logs (gitignored)
```

---

## Testing

The test suite runs the full pipeline (index → codebook label → PsychDS) against 13 hard-dataset papers covering known edge cases: multilevel CSV headers, per-participant aggregate repos, comma decimal separators, mixed codebook formats, near-`too_large` repos, and more.

```r
Rscript tests/run_tests.R        # run pipeline + generate report
```

Set `REPORT_ONLY <- TRUE` to regenerate the report from the last run without re-running the pipeline. There are no automated assertions — all output is for manual inspection.

Test papers must be pre-downloaded to `data/<source>/<paper_id>/`.

---

## Validation GUI

A keyboard-optimised Shiny app for manually annotating file classifications. Used to build the ground-truth dataset that drives test accuracy metrics.

```r
Rscript runners/tools/run_validation_gui.R       # production papers
Rscript runners/tools/run_test_validation_gui.R  # test papers only
```

Keyboard shortcuts: `1`–`8` select file type, `R` toggles `is_raw`, `G` focuses group, `⌘↩` saves, `Tab` advances.

---

## LLM interface

All classification calls go through `llm_batch()` in `pipeline/helper.R`, which calls Ollama via `pipeline/ollama.R`. Failed batches are retried up to 4 times; on exhaustion the error is logged to `logs/llm_batch_errors.log` and the affected rows receive `type = "llm_error"`. A fallback model can be configured for retry.

Thinking traces (chain-of-thought) are captured alongside each response and written to the output for prompt debugging.

---

## Documentation

- [`docs/pipeline.md`](docs/pipeline.md) — complete flow diagram, all constants, retry logic, bulk runner flags, test infrastructure
- [`docs/output-schemas.md`](docs/output-schemas.md) — schema for every output CSV, all enum values, error codes
- [`docs/diary.txt`](docs/diary.txt) — development notes
