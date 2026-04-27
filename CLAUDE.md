# data_check Development Guidelines

Auto-generated from all feature plans. Last updated: 2026-04-23

## Active Technologies

- **Language:** R 4.5, base R only — no new packages
- **Installed packages:** `metacheck`, `haven`, `readxl`, `jsonlite`, `xml2`, `pdftools`, `officer`, `shiny`, `bslib`
- **LLM interface:** `llm_batch()` calls `llm_ollama()` in `pipeline/ollama.R` → Ollama `/api/chat` directly via `httr2` (bypasses `metacheck`/ellmer to support the `think` parameter)
- **Key helpers:** `pipeline/helper.R` (`llm_batch`, `classify_by_rules`, `read_data_head`, `extract_json`), `pipeline/prompts.R`, `pipeline/0_index.R`
- **Storage:** CSV files on local filesystem — no database
- **Shell deps:** `system2` for `.rar` unpacking (macOS unrar binary)
- **Known pitfall:** `vctrs` (loaded transitively via `haven`) is the source of a precision error on `rbind` — surfaced in feature 019

## Project Structure

```text
data_check/
├── pipeline/               # Core pipeline scripts
│   ├── 0_index.R           # Main run_index() — download, classify, extract
│   ├── 2_codebook_label.R  # Codebook matching and label output
│   ├── 3_psychds_convert.R # PsychDS conversion
│   ├── helper.R            # Shared helpers (read_data_head, llm_batch, etc.)
│   ├── prompts.R           # All LLM prompt strings
│   └── ollama.R            # Ollama interface
├── runners/                # Entry-point scripts (not sourced by pipeline)
│   ├── run_single.R        # Run one paper
│   ├── run_0_index_bulk.R  # Bulk indexing runner
│   ├── run_full_pipeline_bulk.R
│   ├── run_tests.R         # Run test suite
│   ├── run_sweep.R / run_sweep_bulk.R
│   ├── run_validation_gui.R
│   └── ...
├── outputs/                # Per-paper pipeline outputs (large, gitignored)
│   └── <source>/<id>/      # structure.csv, columns.csv, labels.csv, etc.
├── results/                # Aggregate outputs and reports
│   ├── bulk_summary.csv
│   ├── codebook_summary.csv
│   └── normal_report_<date>/
├── tests/                  # Test infrastructure
│   ├── test_papers.csv     # Registered test paper catalogue
│   ├── test_log.csv        # Test run history
│   └── outputs/            # Test paper outputs
├── ground_truth/           # Human-validated labels per paper
│   └── osf/<id>.csv
├── specs/                  # Feature specs (NNN-feature-name/)
├── docs/                   # Canonical documentation
│   ├── pipeline.md         # End-to-end flow, constants, retry logic
│   ├── output-schemas.md   # CSV column definitions, enum values
│   └── diary.txt
├── reports/                # Report scripts
│   ├── report_normal.R
│   ├── report_quality.R
│   └── report_sweep.R
├── ab_test/                # A/B prompt test harness and logs
├── tools/                  # Standalone utility scripts
│   └── validation_gui/     # Shiny validation GUI
├── logs/                   # Append-only error logs
│   ├── llm_batch_errors.log
│   └── codebook_parse_failures.log
├── data/                   # Downloaded raw repos (large, gitignored)
└── psychds/                # PsychDS conversion outputs
```

## Commands

# Add commands for R (base R, no new packages)

## Code Style

R (base R, no new packages): Follow standard conventions

## Recent Changes
- 041-pipeline-output-transparency: Added R 4.5 (base R only — no new packages) + `helper.R` (`classify_by_rules()`, `llm_batch()`), `prompts.R` — both already present; no additions
- 040-software-folder-detection: Added R 4.5 (base R only — no new packages) + `helper.R` (`classify_by_rules()`), `0_index.R` (constants, `run_index()`)
- 038-llm-fallback-retry: Added R 4.5 (base R, no new packages per constitution.md Principle IV) + `metacheck` (llm()), `jsonlite` (fromJSON, extract_json), existing helpers in `helper.R`


<!-- MANUAL ADDITIONS START -->

## Pipeline Documentation

`docs/` = canonical pipeline docs. **Keep in sync when workflow changes.**

| File | What it documents | Update when... |
|---|---|---|
| `docs/pipeline.md` | Entry points table; end-to-end flow diagram; key constants; resource limits; bulk runner config flags; LLM model; retry behaviour; **test infrastructure** (runner, test log columns, test paper catalogue) | Stage added/removed/reordered; new entry point added; constant or resource limit changes; new bulk runner flag; retry logic changes; new LLM prompt added; test paper added |
| `docs/output-schemas.md` | Column definitions for all 8 output CSVs (`structure.csv`, `columns.csv`, `bulk_summary.csv`, `codebook_summary.csv`, `labels.csv`, `codebook_coverage.csv`, `psychds/conversion_summary.csv`, `label_summary.csv`); all type/group/`type_source`/`granularity_source`/`label_status` enum values; error codes | Column added/removed/renamed in any output CSV; new `col_type`, file `type`, `group`, `type_source`, `granularity_source`, `label_status`, or error code introduced; new output CSV added |

### Update rules

- New pipeline stage → add step to flow diagram in `pipeline.md`
- New entry point script → add row to Entry Points table in `pipeline.md`
- Constant change (e.g. `N_DATA_READ`, `LLM_BATCH_SIZE`, resource limits) → update constants / resource limits tables in `pipeline.md`
- New bulk runner flag → add row to Bulk Runner Config table in `pipeline.md`
- New `col_type` → add to Column Types table in `output-schemas.md`
- New file classification `type` or `group` → update File Types / Groups tables in `output-schemas.md`
- New `type_source` value → update Type Source Values table in `output-schemas.md`
- New `granularity_source` value → update `structure.csv` schema table in `output-schemas.md`
- New error code → update Error Codes table in `output-schemas.md`
- New output CSV column → add to relevant schema table in `output-schemas.md`
- New output CSV file → add full schema table in `output-schemas.md`
- New feature or PR → add/update `progress.md`
- All PRs MUST target `dev`, not `main`
- New feature → run `runners/run_tests.R`; review test log before merging (see **Testing** in `pipeline.md`)
- New edge case found → add to `data_check/tests/test_papers.csv` and test paper catalogue in `pipeline.md`


## Permission & Safety Rules
- NEVER run `rm -rf` or other destructive shell commands without explicit user confirmation, even if implied by context
- NEVER use `git reset --hard` on a repo with uncommitted changes; prefer stash, branch, or PR workflows
- NEVER stage large test data folders or build artifacts; check `.gitignore` and file sizes before `git add`

## Debugging Practices
- Investigate root cause before patching. Do NOT add ad-hoc rules, hardcoded thresholds, or benchmark-hack workarounds
- If a fix involves tuning a number/threshold, ask the user for the target before guessing
- After applying a fix, re-run the original failing test/output and confirm it is resolved before declaring done

## Workflow Conventions
- Before committing, confirm with the user; do not auto-commit while a task is still in progress (e.g., progress.md not updated, fix not verified)
- When adding new functionality, determine whether it belongs upstream (e.g., `0_index.R`) vs. in a single runner before writing code
- For path resolution in R scripts, use script-relative paths rather than the working directory

<!-- MANUAL ADDITIONS END -->
