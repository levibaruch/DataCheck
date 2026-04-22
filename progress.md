# Progress Log

## 2026-04-22

### Completed ✅

**Prompt iteration + test report overhaul** (branch: `dev`, commit `6bb5451d`)
- Add `STRUCTURE_PROMPT_MD_V2` to `prompts.R`: Markdown-structured prompt with explicit signal-priority rule (filename first, folder as context); per-file labelling enforced in thinking trace via `NON NEGOTIABLE` instruction; type→group ordering made explicit
- `run_tests.R` report expanded: add Cohen's κ, MCC, Macro/Micro F1, paper-averaged vs file-pooled executive summary; per-class P/R/F1/FPR/FNR table; paper-averaged per-class table with SD; both file-pooled and paper-averaged type confusion matrices; group/DG/data_format confusion matrices; extension-level error analysis; metric glossary
- Per-paper table in section 3.3 now includes κ, Macro F1, MCC, top error pair per paper
- Misclassification investigation: codebook FN traced to `*_annotation.txt` files (paper `0956797616685770`) and `.doc`/`.docx` naming confusion; HTML supplemental→codebook FP identified as dominant precision problem

---

**040** — software-folder-detection (branch: `040-software-folder-detection`, PR #44)
- Detect software package folders (`node_modules`, `renv`, `site-packages`, `venv`, `lib`, etc.) before LLM classification
- Folders matching a known basename pattern with ≥500 files (recursive) are bulk-labeled `type="software"`, `type_source="rule_folder"` without consuming any LLM calls
- Extension-majority safety gate: folders where >50% of files are data extensions pass through to normal LLM classification unchanged
- Validated on `doi_10.7910_DVN_4SYZHV` (dataverse, `renv`: 524 files detected correctly); no regression on baseline paper `0956797615620784`
- Docs updated: `rule_folder` added to `output-schemas.md` type_source table; step 4.5 + constants documented in `pipeline.md`

---

## 2026-04-17 – 2026-04-20

### In Progress / Unmerged 🔧

**Ollama thinking-trace infrastructure** (branch: `dev`, commits `4a405292`, `6581e0dc`, `eea77415`)
- Add `pipeline/ollama.R`: dedicated Ollama HTTP caller that captures the LLM thinking trace alongside the final response; enables per-call inspection of chain-of-thought for prompt debugging
- New `runners/test_llm_params.R`: sweeps temperature/think_level combinations on a single paper; outputs classification accuracy per config to aid prompt tuning
- New `runners/test_thinking_trace.R`: runs a paper with thinking enabled and prints the full trace for each batch; replaces ad-hoc debug sessions
- Updated `0_index.R` and `helper.R`: plumbing to accept ollama-mode caller in place of regular `llm()`; **WIP — not yet gated behind a clean config flag**
- Re-added extended prompt versions to `pipeline/prompts.R` (266 → 517 lines): multiple `STRUCTURE_PROMPT_V*` variants for AB testing

---

## 2026-04-15 – 2026-04-16

### Completed ✅

**039** — two-phase-aggregate-prompt-llm-config-consolidation (branch: `039-*`, PR #43)
- Consolidate `STRUCTURE_PROMPT_V0` / `V1`: each version now self-contained (header + body together); `run_index()` accepts `structure_body` string directly instead of a version integer
- Add `LLM_TEMPERATURE` and `LLM_THINK_LEVEL` constants to `0_index.R`; replace scattered `getOption("llm_temperature")` calls in `helper.R` and `2_codebook_label.R` with the new constants
- Enhanced `llm_batch()` logging: records temperature and think_level alongside paper_id/stage per call; `run_sweep.R` saves/restores `LLM_TEMPERATURE` global instead of R option
- Fix PDF paired-source detection: both the PDF and its companion source file (`.Rmd`/`.qmd`/`.tex`) now receive correct types via `rmd_pair_rule`
- `MAX_FILE_READ_SEC`: 5 min → 1 min (timeout efficiency for column extraction)
- Add detailed progress logging in `extract_column_info()`: file size and folder context emitted via `message()`
- Remove `is_sentinel` column from `structure.csv` output (sentinel concept eliminated in 035)
- `llm_batch()`: add `input_type` param supporting JSON descriptor mode (alternative to plain path list)
- Comprehensive `run_ab_test.R` refactor: supports multiple named prompt variants; structured per-variant accuracy comparison
- Remove `AGGREGATE_EXT_OVERRIDE` from `3_psychds_convert.R` (now handled upstream in indexing)
- Add `pipeline/ollama.R` (not yet wired into main pipeline path)

**038** — llm-fallback-retry-granularity-hardening (branch: `038-*`, PR #42)
- `llm_batch()` in `helper.R`: validate response count matches number of paths sent; incomplete responses (fewer objects than input) now trigger retry instead of silent fill; logs paper_id, stage, chunk, attempt to `LLM_ERROR_LOG`
- `detect_filename_pattern()`: raise minimum match threshold 2 → 8 files before inferring a participant pattern (reduces false positives on study-label sequences like `study1a`, `study2b`)
- `detect_filename_pattern()`: multiple-pattern case now returns all patterns with ≥8 matches instead of failing; enables per-aggregate multi-pattern granularity queries
- Granularity US3 fixes in `0_index.R`: folder-name heuristic bug fixed (was inverted — now correctly marks `individual` when >50% subdirs are participant-named); remove `MAX_GRANULARITY_LLM_CALLS` cap (chunking handled by `llm_batch()`); multiple-pattern aggregates build combined `user_prefix` and store one DB row per pattern; raw-sample fallback sends aggregates with no detected pattern to LLM with `(no clear pattern)` + examples
- `GRANULARITY_PROMPT` clarifications: rule for ANY consistent prefix+number pattern → individual; rule for `(multiple patterns)` case; strengthen default (10+ files, same ext, varying number → individual); add `IFFControl2C/11C/17C` example
- `report_normal.R` major overhaul: paper-avg vs file-pooled divergence column (Δ pa−fp) in per-class metrics; group classification computed across all file types (not data-only); per-group-accuracy-by-file-type table (§4a-ii); sections 7b (full per-paper table) and 8 (all misclassified files) moved to `appendix.md`; fix variable shadowing bug that broke fp_fn plot
- New report sections 4d–4g: accuracy by type_source (`aggregate_llm` vs `llm`), granularity accuracy by granularity_source, type accuracy by file type × method (paper-avg and file-pooled); heatmap plots 14–17 via shared `plot_type_method_heatmap()` helper
- New `docs/regression_analysis_2026-04-15.md`: full taxonomy of Apr 10→15 regressions, root causes, proposed aggregate prompt architecture, priority fix order
- Validation GUI (`tools/validation_gui/app.R`, `gt_store.R`): size and completeness filtering; semi-annotated file indicator
- `runners/run_0_index_bulk.R`: set `SKIP_COLUMNS=TRUE` (indexing-only mode); `runners/run_tests.R`: set `REPORT_ONLY=FALSE`

---

## 2026-04-15

### Completed ✅

**036** — sanitize-llm-outputs (branch: `035-sentinel-aggregate-redesign`)
- Add type validation to `llm_batch()` retry loop: invalid types trigger automatic retries (up to 4 attempts)
- `TYPO_MAP` constant in `helper.R`: 4 initial mappings (coden→code, Code→code, supplimental→supplemental, supp→supplemental); extensible empirically from error logs
- `validate_type()`, `is_valid_type()`, `is_valid_group()` helpers: apply mapping, check validity (closed set: 10 types), validate group pattern (ex/pilot + digits + optional suffix)
- Group validation: invalid groups set to "shared" (defensive, no retry); type validation triggers retry with simpleError("llm_validation: ...") prefix
- `LLM_RETRY_LIMIT` increased from 3 to 4 to accommodate validation failures alongside parsing errors
- Logging: validation failures logged via existing feature 027 infrastructure with "llm_validation:" prefix for grepping
- Verification script: `specs/036-sanitize-llm-outputs/verify_validation.R` tests all validation logic with known mistakes
- Test results: paper 0956797614535937 (known "coden" typo) produces valid "code"; pilot groups validated; 99-file aggregate handles correctly

**035** — sentinel-aggregate-redesign (branch: `035-sentinel-aggregate-redesign`)
- Eliminated Phase 2 LLM loop; replaced with Phase 1-only propagation for aggregate folder handling
- `group_aggregate_folder()` helper in `helper.R`: groups file paths by lowercase extension; returns sample paths (up to 5 per group) and `route_individually` flag (TRUE if <AGGREGATE_THRESHOLD)
- Routing: sample paths from large groups + individual small groups sent to Phase 1 LLM batch
- Propagation: Phase 1-only results applied to all member files with `type_source = "aggregate_llm"`
- Series detection restored: participant aggregates (folders with >50% numeric subdirs) marked `is_series = TRUE`, propagated to `data_granularity = "individual"` in structure.csv
- Removed `expand_sentinel_rows()` from `3_psychds_convert.R`; all output rows file-level (no sentinel rows in structure.csv)
- Accuracy improvement: aggregate_llm 89.7% (vs 62% sentinel_llm baseline, 74% extension_rule)
- AGGREGATE_THRESHOLD corrected from 50 → 20 throughout
- Constitution updated to v1.5.0 with SYNC IMPACT REPORT; Processing Order steps 4-5 updated for Phase 1-only design
- Updated `docs/output-schemas.md`: removed is_sentinel, replaced sentinel_llm with aggregate_llm in type_source enum

**034** — classification-parsing-fixes (branch: `034-classification-parsing-fixes`)
- Add `.xlsm` (macro-enabled Excel) support to `read_data_head()` via `readxl::read_excel()` (already handles .xlsm transparently)
- Fix `.rar` archive extraction: use `system2("unrar", c("e", rar_path, temp_dir))` instead of `untar()` (base untar cannot handle .rar format)
- Enhance codebook parsing robustness: retry with latin1 encoding when CSV read fails; add header-row detection for malformed CSVs with skipped/merged rows
- Add `parse_method` column to codebook outputs: tracks whether codebook was parsed via structured rules ("structured") or LLM fallback ("llm")

**033** — llm-prompt-refinements (branch: `033-llm-prompt-refinements`)
- Iterative refinement of `STRUCTURE_PROMPT` without code changes
- Tightened classification rules for image/audio/video files: never fallback to `other` for these media types
- Improved keyword detection for SPSS output files (`.spv` → supplemental, not other)
- Enhanced E-Prime log file detection (`.log` → output when participant ID in filename, supplemental otherwise)
- Clarified participant ID detection in aggregate folder context
- Aggregate threshold reduced from 50 to 20 files (tuned from prompt testing)
- Accuracy baseline: 74% (extension_rule), target 85%+ for Phase 1 redesign

**032** — source-aware-storage (branch: `032-source-aware-storage`)
- Implement `paper_path(source, id, layer)` in `helper.R`: centralised path resolver for all file I/O
- All pipeline artifacts stored under `<layer>/<source>/<id>/` scheme: data/osf/<id>/, data/dataverse/<id>/, outputs/osf/<id>/, etc.
- Updated `0_index.R`, `2_codebook_label.R`, `3_psychds_convert.R` to use `paper_path()` for all path construction
- Constitution Principle VI added: source-aware storage rules, ID sanitisation, `paper_path()` mandate
- Ground-truth annotation OSF-only: `ground_truth/osf/<id>.csv` (Dataverse papers excluded from validation GUI)
- `psychds/conversion_summary.csv` remains unified rollup (NOT split per-source)
- `tests/test_papers.csv` schema updated to `id, source, label`
- Constitution updated to v1.4.0 with Principle VI

**031** — dataverse-source-support (branch: `031-dataverse-source-support`)
- Add `resolve_dataverse_links()` to `helper.R`: fetches Dataverse dataset metadata via OAI-PMH XML API; extracts file download links
- Extend `0_index.R` to detect and download from Dataverse alongside OSF
- Add `paper_path()` resolver to support multiple sources (prerequisite for 032)
- XML metadata parsing for Dataverse datasets using `xml2` (already installed)
- New source identifier: `"dataverse"` (parallel to `"osf"`)

**030** — prompt-fixes-skip-columns-aggregate-threshold (branch: `030-prompt-fixes-skip-columns-aggregate-threshold`)
- Prompt refinement: image/audio/video files never classified as `other` (hard rules)
- Add `.spv` (SPSS Viewer) → supplemental rule; `.log` context-aware (participant ID = output, else supplemental)
- SKIP_COLUMNS mode: when true, skip column extraction entirely (files indexed only); used for high-volume aggregate repos
- AGGREGATE_THRESHOLD tuning: lowered from 50 to 20 files (better detection, reduced Phase 2 workload)
- Improved participant series detection: numeric-subdir heuristic captures per-participant data folders

**029** — software-file-type (branch: `029-software-file-type`)
- Clarify `code` type handling for software-specific formats: `.ipynb`, `.do` (Stata), `.sas` (SAS), `.sps` (SPSS syntax)
- `code` type no longer confused with `supplemental` for syntax/script files
- STRUCTURE_PROMPT updated with explicit code-type guidance
- Validation GUI: `code` type keyboard shortcut assigned (number key)

**028** — data-format-subtype (branch: `028-data-format-subtype`)
- Add `data_format` column to `structure.csv`: tracks data file subtype for files classified as `type = "data"`
- Subtypes: csv, tsv, txt, xlsx, xls, sav, dta, sas7bdat, rds, rda, rdata, dat, unknown
- Extracted via `tools::file_ext()` then validated against supported formats
- Enables downstream pipelines to route by format (e.g. SPSS → CSV conversion for reproducibility)
- Updated `docs/output-schemas.md` with `data_format` enum

---

## 2026-03-30

### Completed ✅

**027** — llm-retry-logging (branch: `027-llm-retry-logging`)
- Adds automatic retry loop to `llm_batch()` in `helper.R`: up to `LLM_RETRY_LIMIT` (default 3) retries per failing chunk, with a `message()` per attempt
- On retry exhaustion: appends a structured entry to `logs/llm_batch_errors.log` (timestamp, paper_id, stage, chunk, n_items, raw LLM response)
- Introduces `"llm_error"` sentinel value: written to `sentinel_cols` on irrecoverable failure instead of fallback; `VALID_COL_TYPES` updated so sentinel rows are never remapped
- New constants in `0_index.R`: `LLM_RETRY_LIMIT <- 3L`, `LLM_ERROR_LOG <- "logs/llm_batch_errors.log"`, `LLM_SENTINEL_VAL <- "llm_error"`
- All 4 `llm_batch()` call sites updated with `paper_id`, `stage_name`, and `sentinel_cols`
- `logs/` added to `.gitignore`; `llm_error` added to File Types and Column Types tables in `docs/output-schemas.md`

**026** — add-output-file-type (branch: `026-add-output-file-type`)
- Introduces `output` file type for script-generated artefacts (rendered notebooks `.html`/`.pdf`/`.docx`, figures, log files); narrows `supplemental` to human-authored documents only
- Updates `STRUCTURE_PROMPT` with `output` type definition and examples; `supplemental` definition explicitly excludes script-generated files
- `output` files excluded from column extraction (same as `supplemental`)
- Updates validation GUI: `output` added to TYPE_MAP, keyboard shortcut assigned
- Updates `docs/output-schemas.md`: `output` added to File Types table; `supplemental` definition narrowed
- Updates `docs/pipeline.md` to reflect new type

**025** — add-n-unique-stat (branch: `025-add-n-unique-stat`)
- Adds `n_unique` column to `columns.csv`: count of distinct non-NA values for every column, regardless of `col_type`
- `n_unique = 0` for all-NA columns; excludes NA values consistent with existing `n` (non-missing count)
- Column positioned after `n_missing` and before `mean` in `columns.csv`
- Updates `docs/output-schemas.md` with `n_unique` column definition

**test-infrastructure** — test runner and test paper catalogue
- Adds `runners/run_tests.R`: runs full pipeline (index → codebook label → PsychDS) on all papers in `tests/test_papers.csv`; outputs to `tests/outputs/<paper_id>/` and `tests/psychds/<paper_id>/`; appends per-paper timing and status to `tests/test_log.csv`; generates `results/test_report_<date>.md`
- Adds `runners/run_test_validation_gui.R`: launches validation GUI in test mode reading from `tests/outputs/` and writing to `tests/ground_truth/`; scoped to 13 test papers only
- Adds `tests/test_papers.csv`: catalogue of hard-dataset papers covering known edge cases (multilevel headers, aggregate repos, labelled columns, etc.)
- Removes unused `sample_size.R` / `token_difference.R` scripts

**026 (pt. 2)** — validation GUI enhancements
- Bulk labelling: Shift+click for range select, Cmd+click for toggle; single Save applies one label to all selected files; bulk banner shows selection count; "Select all unvalidated" button; Escape clears selection
- Paper completion tracking: dropdown prefixes complete papers with ✓; `paper_is_complete()` and `make_paper_choices()` helpers in `gt_store.R`
- "Open folder in Finder" button (📂) on file header
- Keyboard help updated with Shift+click, Cmd+click, Esc shortcuts
- `readme` type now matches any file *containing* `README` (not just files named exactly `README`)
- `label_status = "llm"` now counted as labelled in `2_codebook_label.R` and `run_tests.R`

---

## 2026-03-28

### Completed ✅

**024** — fix-col-type-detection (branch: `024-fix-col-type-detection`)
- Expanded ID column detection: name-pattern rule now covers `participant`, `subject`, `subj`, `sub`, `respondent`, `pp`, `ppt`, `pid`, `ResponseId`, `subjectNumber`, BIDS `sub-01`, and suffix patterns (`_id`, `_number`, `_nr`, etc.). Hard-classifies as `id` directly — no LLM routing, no whole-number guard.
- Added `constant` col_type for columns with exactly 1 unique non-NA value; fires after ID check and before binary rule.
- Narrowed binary rule from `≤2` to `==2` unique non-NA values so constants are no longer absorbed into `binary`.
- Narrowed `COLUMN_TYPE_PROMPT` to the 6 types the LLM actually resolves (`continuous`, `ordinal`, `categorical`, `binary`, `id`, `unknown`); removed types handled deterministically by rules; tightened `unknown` definition.
- Added dedicated second LLM batch (Batch 2) for character-ambiguous columns using new `CHAR_COLUMN_TYPE_PROMPT`; replaces hardcoded categorical/text rules 8–9 in `classify_col_type_rules()`; up to 20 sampled unique values (vs 10 for numeric); independent cap `MAX_CHAR_COL_TYPE_LLM_CALLS = 3`; `unknown`/invalid → `"text"` fallback. Both batch caps are bypassed when `FULL_RUN = TRUE`.
- Amended constitution to v1.3.0: added `MAX_CHAR_COL_TYPE_LLM_CALLS` to Principle III resource limits and constants table.
- Added log message for invalid LLM type remapping so `"other"` leakage is visible in pipeline logs.
- Updated `VALID_COL_TYPES` to include `constant`.
- Updated `docs/output-schemas.md`: added `constant` to Column Types table, updated `binary` and `id` descriptions, updated stats-suppression footnote.

## 2026-03-27

### Completed ✅

**022** — file-type-taxonomy-refactor (branch: `022-file-type-taxonomy-refactor`)
- Full pre-validation audit and refactor of the file taxonomy used in `STRUCTURE_PROMPT`
- Removed `doc` type entirely — merged into `supplemental`; text extraction in PsychDS now triggered by filename heuristic (`manuscript`, `preregistr`, `thesis`, etc.) rather than type field
- Removed `na` group entirely — all files now use `shared`, `ex<N>`, or `pilot<N>`; readme/asset/other files use `shared`
- Rewrote `STRUCTURE_PROMPT` from a rule-based extension catalogue to a semantic-focused classification guide: type definitions describe intent rather than enumerate extensions; explicit framing that extension alone is insufficient; "hard cases" section replaces disambiguation rules
- Added `.spv` → `supplemental` disambiguation (SPSS Viewer output ≠ SPSS syntax)
- Added `.do`, `.sas`, `.sps`, `.ipynb` to `code` type; removed `.sps` from `supplemental`
- Expanded `codebook` keyword list; restricted `"variables"` trigger to filename start/end only
- Previous rule-based prompt preserved as commented block for comparison
- Updated `TYPE_TO_SUBDIR` and `AGGREGATE_EXT_OVERRIDE` in `3_psychds_convert.R`: doc entries → supplemental; `na` group checks → `shared`
- Updated `fallback_vals` in `0_index.R`: `group = "na"` → `group = "shared"`
- Updated `resolve_shared_files()` in `3_psychds_convert.R`: group check updated from `c("na", "other")` → `"shared"`
- Removed `doc` type and `na` group from `tools/validation_gui/app.R`: TYPE_MAP renumbered (7 types), CSS rules removed, keyboard shortcuts updated
- Updated `docs/output-schemas.md`: removed `doc` from File Types, removed `na` from Groups, updated `supplemental` and `shared` descriptions, updated TXT extraction trigger description

---

## 2026-03-25

### Completed ✅

**021** — psychds-conversion (branch: `021-psychds-conversion`)
- Add `pipeline/3_psychds_convert.R` with `convert_psychds(paper_id)` — converts pipeline outputs to PsychDS-compliant directory structure; returns list of per-study result rows
- Produces `dataset_description.json` (Schema.org JSON-LD with `schema:variableMeasured` PropertyValues), `*_data.csv` (UTF-8, sanitised filenames), `*_data.json` sidecars, `provenance.json`
- Multi-study layout: `study-<group>/` subdirectories when multiple experiment groups detected; co-location heuristic assigns `group=na/other` files to a study or `shared/` directory
- Non-data file placement: `materials/`, `documentation/`, `code/`, `assets/` subdirectories by file type
- Binary format conversion: SPSS (`.sav`), Stata (`.dta`), SAS (`.sas7bdat`), Excel (`.xlsx`/`.xls`), R objects (`.rds`/`.rda`/`.rdata`) — reads via `haven`/`readxl`; strips labels with `haven::zap_labels()` while preserving value mappings in sidecar
- Oversized files (>500 MB): raw-copy to `data/raw/` only; skip-sidecar with `metacheck:conversion_skipped = TRUE`
- `row_id` uniqueness enforcement: column renamed to `original_row_id` if values not unique (FR-015b)
- Sentinel row expansion: aggregate placeholder rows replaced with individual file records using `AGGREGATE_EXT_OVERRIDE` extension classification
- Ground truth integration: `ground_truth/<paper_id>.csv` overrides `type`/`group`/`is_raw` for validated rows
- Paper metadata from GROBID TEI XML when present (`xml2`): title, authors, abstract, DOI, date, keywords
- Crash resilience: `append_conversion_summary()` appends to `psychds/conversion_summary.csv` immediately after each paper
- Add `apply_ground_truth()` and `sanitise_keyword_value()` helpers to `pipeline/helper.R`
- Add `runners/run_psychds_single.R` — dev/smoke-test entry point; accepts `paper_id` as CLI arg or pre-set variable; falls back to random paper from `results/bulk_summary.csv`
- Add `runners/run_psychds_bulk.R` — batch conversion of all successfully indexed papers; crash-resilient auto-resume via `psychds/conversion_summary.csv`
- Update `docs/pipeline.md` — add step 13 (PsychDS conversion), new entry points, new constants
- Update `docs/output-schemas.md` — add `psychds/conversion_summary.csv` schema and new error codes `pipeline_failed`/`no_data_files`

---

## 2026-03-23

### Completed ✅

**020** — validation-gui (branch: `020-validation-gui`)
- Local Shiny application for human ground-truth labelling of `structure.csv` outputs
- Keyboard-optimised: number keys `1`–`8` select file type, `R` toggles `is_raw`, `G` focuses group field, `⌘↩` saves, `Tab` skips, `⌘[` goes back, `⌘/` shows help overlay
- Type-appropriate file preview: raw text (CSV/script), structured preview via `read_data_head()`, R object summary, PDF/DOCX text extraction, inline image, archive member list
- Ground-truth saved to `ground_truth/<paper_id>.csv` immediately on each save; fully resumable across sessions
- Folder-tree view and sibling list give repo context per file
- `is_raw` toggle auto-disabled and forced `FALSE` for non-data file types
- Startup annotator name dialog; console session summary on exit
- New files: `tools/validation_gui/app.R`, `tools/validation_gui/gt_store.R`, `tools/validation_gui/preview.R`
- New directory: `ground_truth/` (version-controlled dataset, not pipeline output)

**019** — fix-index-labelled-stats (branch: `019-fix-index-labelled-stats`)
- Fix `Can't convert from 'value' <labelled<double>> to <labelled<double>> due to loss of precision` error: add `as.numeric()` coercion at `x_comp` assignment in `0_index.R` so haven-labelled type metadata is stripped before statistics computation — prevents vctrs rbind from encountering incompatible label mappings across columns
- Fix `arguments imply differing number of rows: 0, 1` error: cancel the sentinel mechanism when all files fall into aggregate folders — set `aggregate_df = NULL` and process all paths individually so `non_agg_relpaths` is never empty; the existing 10-call limit still guards runaway repos
- Remove 3 affected papers (`0956797618772822`, `09567976231158570`, `0956797618773095`) from `bulk_summary.csv` for reprocessing

**018** — fix-csv-codebook-parsing (branch: `018-fix-csv-codebook-parsing`)
- Extend `.find_codebook_cols()` in `helper.R` to recognise additional column-name variants: `variable_label`, `var_label`, `item` (variable column); `label_text`, `question`, `question_text`, `variable_description` (description column)
- Replace fixed-header CSV read in `parse_codebook()` with header-row lookahead: reads file without header, scans rows 1–`CODEBOOK_HEADER_LOOKAHEAD` (default 5) for a row matching the codebook-column patterns; handles multi-level / merged-header CSVs
- Add latin1 encoding fallback to CSV codebook reading (mirrors existing `read_data_head()` pattern); retries with `fileEncoding = "latin1"` when UTF-8 produces invalid bytes
- Update `sniff_delimiter()` to skip comment rows (lines starting with `#`) in addition to blank lines when probing for the delimiter
- Add `parse_method` column (`"structured"` or `"llm"`) to the data.frame returned by `parse_codebook()` and `.run_llm_chunk_loop()`; propagated to `codebook_coverage.csv` via `coverage_df` construction in `2_codebook_label.R`
- Add `CODEBOOK_HEADER_LOOKAHEAD <- 5L` constant to `2_codebook_label.R`
- Update `docs/output-schemas.md` with `parse_method` column definition

**refactor** — repo restructure (branch: `017-llm-temperature-testing`)
- Move all R source files from `data_check/` root into purpose-grouped subdirectories: `pipeline/` (core modules), `runners/` (entry-point scripts), `reports/` (report generators)
- Move generated summary CSVs (`bulk_summary.csv`, `codebook_summary.csv`) to `results/`
- Update all `source()` calls and path constants (`DATA_DIR`, `OUTPUT_DIR`, `SUMMARY_CSV`, `SWEEP_DIR`, `BULK_LOG`, `PROGRESS_CSV`) to resolve correctly when scripts are run from `data_check/` root
- Update `report_quality.R` to write `quality_report_*.md` to `results/` instead of root
- Update defaults in `report_quality.R` and `report_sweep_grand.R` to point at `results/` for input CSVs and output paths
- Archive `descriptive_statistics.R` to `_old/` (broken external deps, exploratory only)
- Delete scratch files: `0_result.txt`, `2_result.txt`, `quality_report_2026-03-19.md`
- All scripts still invoked from `data_check/` root (e.g. `Rscript runners/run_single.R`)

---

## 2026-03-19

### Completed ✅

**017** — llm-temperature-testing (branch: `017-llm-temperature-testing`)
- Add `run_sweep.R`: CLI tool to run a paper through the full pipeline N times at M temperatures, saving each (temperature, repeat) to an isolated output directory; crash-resilient via `sweep_log.csv` with resume support; exports `run_paper_sweep()` for use by bulk runner
- Add `run_sweep_bulk.R`: sequential bulk sweep across all papers in `XML_DIR`; paper-level crash-resilient log (`sweep_results/sweep_bulk_log.csv`); `N_PAPERS` cap; auto-resumes on restart; tracks `n_no_data` separately from `n_failed`
- Add `report_sweep.R`: reports pairwise col_type / label stability per temperature, quality proxies (known-type rate, codebook coverage, non-empty label rate), weighted recommendation, and always writes `sweep_report_YYYY-MM-DD.md`; exports `compute_stability()` / `compute_quality()` for grand report
- Add `report_sweep_grand.R`: grand flat CSV report across all swept papers; one row per (paper_id × temperature × pipeline stage); `no_data` temperatures emit NA metrics (not "failed"); no aggregation — post-processing friendly
- Modify `llm_batch()` in `helper.R` and three standalone `llm()` calls in `2_codebook_label.R`: read `getOption("llm_temperature")` and pass as `params = list(temperature = X)` when set
- Add `output_dir = NULL` param to `run_index()` in `0_index.R`: when non-NULL, writes outputs to specified path instead of `paper_output_dir(paper_id)`
- Add `output_dir = NULL` param to `run_codebook_label()` in `2_codebook_label.R`: same isolation pattern as `run_index()`
- Add `no_data` end state: `run_one()` detects when `columns.csv` is absent/empty after index; logs `status = "no_data"`, skips codebook stage, counts as completed for resume (not a failure)
- Add `data_check/sweep_results/` to `.gitignore`

**016** — pipeline-quality-report (branch: `016-pipeline-quality-report`)
- Add `report_quality.R`: single-script CLI report over `bulk_summary.csv`, `codebook_summary.csv`, per-paper `columns.csv`, and `codebook_coverage.csv`; four sections (bulk overview, col-type distribution, codebook coverage, timing); always writes `quality_report_YYYY-MM-DD.md`
- N/A for absent codebook file vs 0% for present-but-empty file
- Add `data_check/quality_report_*.md` to `.gitignore`

**015** — verbatim-codebook-labels (branch: `015-verbatim-codebook-labels`)
- Update `CODEBOOK_PARSE_PROMPT` in `2_codebook_label.R` to instruct the LLM to copy label text verbatim from the codebook source rather than paraphrasing or summarising it; add explicit no-rephrase rule and no-fabrication rule for variables without a description

## 2026-03-18

### Completed ✅

**fix** — increased LLM call count in codebooks
- Increased LLM call count in codebooks to fully parse PDFs

**fix** — latin1 encoding fallback in `read_data_head()` (branch: `dev`)
- `read_data_head()` in `helper.R`: after reading csv/tsv/txt/dat with default encoding, detect invalid UTF-8 bytes via `iconv(..., from="UTF-8", to="UTF-8")`; if any character column has invalid bytes, re-read the file with `fileEncoding="latin1"`
- Fixes crash `invalid multibyte string` when processing Windows-1252 encoded CSV files
- Updated `docs/pipeline.md` step 6 to document the encoding fallback behaviour

**014** — fix-multilevel-csv-headers (branch: `014-fix-multilevel-csv-headers`)
- Replace the blanket `>50% ...N` skip rule with a two-branch recovery strategy in `extract_column_info()` in `0_index.R`
- Branch 1 (sub-header found): scan first `MULTILEVEL_HEADER_LOOKAHEAD = 3` rows for a row with lower `...N` fraction AND non-numeric text labels; use its values as `column_name`; NA/empty sub-header cells fall back to the original `...N` placeholder; apply `make.unique()` for duplicate names
- Branch 2 (partial labels, no sub-header): proceed with original column names as-is; `col_header_group = NA`
- Skip only when header is entirely `...N` and no sub-header is found (genuinely headerless)
- Add `col_header_group` column to `columns.csv`: forward-filled condition/group label from row-1 name prefixes (e.g. `SHAM...3` → `SHAM`); `NA` for all non-multi-level files
- `column_name` is always the resolved raw variable name, enabling direct codebook matching with zero changes to `match_column_labels()`
- Add `MULTILEVEL_HEADER_LOOKAHEAD <- 3L` constant to the constants block
- Fix numeric-data-row false positive: sub-header candidate cells must contain non-numeric text (added `is.na(suppressWarnings(as.numeric(candidate)))` check)
- Recovers 4 previously-skipped files across 2 papers (`09567976221147259`, `09567976231151581`)
- Update `docs/output-schemas.md` — add `col_header_group` to `columns.csv` schema
- Update `docs/pipeline.md` — add `MULTILEVEL_HEADER_LOOKAHEAD` to Key Constants table

**013** — fix-r-file-misclassification (branch: `013-fix-r-file-misclassification`)
- Add `AGGREGATE_EXT_OVERRIDE` constant to `0_index.R`: named vector mapping 40 file extensions to their definitive type (`code`, `asset`, or `data`)
- Apply override after aggregate sentinel expansion in Step 7 of `run_index()`: files with unambiguous extensions (`.R`→code, `.jpeg`→asset, `.csv`→data, etc.) get the correct type regardless of what the LLM assigned to the sentinel
- Root cause: sentinel type was inherited verbatim by all files in a collapsed aggregate folder; for paper `09567976211040491` this caused 378 files (incl. `.R` scripts and `.jpeg` images) to reach column extraction; fixed to 340 true data files
- Fix `sniff_delimiter()` in `helper.R`: guard against `character(0)` returned by `readLines` on empty files — prevents "argument is of length zero" error on zero-byte CSVs (e.g. `PickupsBehavProf.csv`)
- Suppress "incomplete final line" cosmetic warning from `read.table` inside `read_data_head()` with `suppressWarnings()`
- Update `docs/pipeline.md` Step 5 and constants table
- Fix `sanitize_name()` in `0_index.R`: strip non-alphanumeric characters (`;`, `:`, `?`, etc.) from each word token after splitting on whitespace, so folder names like `I Hear My Voice; Therefore` → `I_Hear_My_Voice_Therefore` instead of `I_Hear_My_Voice;_Therefore`; also extend the trigger condition to fire for folders containing special characters even if they have no spaces
- Fix regex crash in sanitize loop: `sub(paste0("^", d, "/"), ...)` used the folder path as a regex pattern, causing "Missing ')'" errors when folder names contained parentheses (e.g. `Follow-up_2020-05a_(Constructs_related_to`); replaced with `startsWith` + `substr` string operations

## 2026-03-17

### Completed ✅

**012** — single-dataset-runner (branch: `012-single-dataset-runner`)
- Add `run_single.R` — single-command entry point that runs the full pipeline (index + codebook label) for one randomly selected paper
- Selects a random ID from `XML_DIR`, runs `run_index()` then `run_codebook_label()`, prints stage status and output path
- Graceful error handling for all known error codes; Stage 2 auto-skipped if `columns.csv` absent

**011** — merge-columns-output (branch: `011-merge-columns-output`)
- Delete `1_data_label.R` and `run_1_label_bulk.R` — stage 1 was overwriting stage 0's rich `columns.csv` (23 cols) with a thin 5-col version; stage 1 provided no unique value
- Recovery: re-run `run_index(paper_id, download=FALSE)` for all 47 papers whose `columns.csv` was thinned by stage 1
- Remove stale references to deleted files in `helper.R`, `2_codebook_label.R`, `run_2_codebook_bulk.R`
- Update `docs/pipeline.md` — remove stage-1 rows from scripts table and constants table

**010** — fix-label-ambiguity (branch: `010-fix-label-ambiguity`)
- Add `normalize_label()` to `helper.R` — strips possessives, punctuation, and pluralising "s" for label comparison
- Add two-tier conflict resolution in `match_column_labels()` (rule-based tier first, LLM merge tier second)
- Rule tier: normalise all candidate labels; if they collapse to one string, pick the longest original label; `label_method = "merged_rules"`
- LLM tier: batch remaining `conflicting_definition` columns into single call with `LABEL_MERGE_PROMPT`; equivalent labels merged with `label_method = "merged_llm"`; genuinely conflicting labels preserved as `conflicting_definition`
- New optional argument `label_merge_prompt = NULL` on `match_column_labels()` — fully backward-compatible
- Add `LABEL_MERGE_PROMPT` constant to `2_codebook_label.R`; wire up in `run_codebook_label()`
- Update `docs/output-schemas.md` — new `label_method` values `merged_rules`, `merged_llm`; note `labelled` status covers merged rows
- Update `docs/pipeline.md` — document conflict resolution sub-step in codebook labelling stage
- BIS misplaced-label (0956797617716929): investigated and confirmed correct per source codebook — no code change needed

### In Progress 🔧

**009** — multi-format-codebooks (branch: `009-multi-format-codebooks`)
- Extend `parse_codebook()` in `helper.R` to support DOCX, PDF, RTF, ODT, DOC codebook files
- Add `.extract_rich_text()` using `officer` (DOCX) and `pdftools` (PDF) — both already installed
- Add `.strip_rtf()` for regex-based RTF text extraction (no new packages)
- Add `.run_llm_chunk_loop()` shared helper to deduplicate LLM chunking logic
- Graceful `parse_failed` for unreadable files (image-only PDFs, binary DOC); pipeline never aborts
- No output schema changes; existing CSV/XLSX/SAV/DTA/plain-text behaviour unchanged

**008** — bulk-label-runners (branch: `008-bulk-label-runners`)
- Refactor `1_data_label.R` into `run_data_label(paper_id)` function (no top-level execution)
- Confirm `2_codebook_label.R` already clean; update header comment with correct paths
- Add `run_label_bulk.R` — crash-resilient bulk runner for data-label stage, auto-resumes via `label_summary.csv`
- Add `run_codebook_bulk.R` — crash-resilient bulk runner for codebook-label stage, auto-resumes via `codebook_summary.csv`

**007** — per-id-output-structure (branch: `007-per-id-output-structure`)
- Replace flat `structure/` output directory with `outputs/<paper_id>/` per-paper layout
- Add `paper_output_dir()` helper to `helper.R` (centralised path + auto-create)
- Update `0_index.R`, `1_data_label.R`, `2_codebook_label.R` to write to `outputs/<paper_id>/`
- Migrate 59 existing CSVs from `structure/` → `outputs/<paper_id>/` via `migrate_structure.R`
- Short filenames inside per-ID dirs (no paper-ID prefix): `structure.csv`, `columns.csv`, `labels.csv`, `codebook_coverage.csv`
- `bulk_summary.csv` and resume logic unchanged

## 2026-03-16

### PRs Merged ✅

**#1** — 002-column-type-classification → dev (2h ago)
- Initialize speckit framework for feature specifications
- Add col_type classification with controlled vocabulary (continuous, binary, categorical, ordinal, date, id, text, continuous_comma_decimal, continuous_outliers_excluded, empty, unknown)
- Track coerced values in n_coerced field for comma-decimal normalization
- Route ID columns to LLM for proper classification
- Output: col_type and n_coerced columns in *_columns.csv
- **+1,087 lines | -13 lines**

**#2** — 003-qualtrics-header-skip → 002-column-type-classification (2h ago)
- Detect and handle Qualtrics triple-header CSV exports
- Strip metadata rows (1-2) before column extraction
- Add is_qualtrics field to *_columns.csv
- Remove obsolete helpers.R and sample_size_stuff/ modules
- Depends on #1
- **+873 lines | -1,074 lines**

**#4** — 004-reduce-unknown-coltypes → dev (1h ago)
- Add Rule 6a: decimal numeric columns → continuous (no LLM needed)
- Add is_numeric flag with post-LLM fallback (unknown → continuous for confirmed-numeric)
- Strengthen COLUMN_TYPE_PROMPT with examples
- Add docs/pipeline.md and docs/output-schemas.md (canonical pipeline documentation)
- **+1,072 lines | -21 lines**

**#5** — 005-codebook-column-labelling → dev
- Implement labelling from codebook to data columns using rule-based structures
- LLM analyses codebook, transforms to dataframe, rule-based matching to variables

**#6** — 006-llm-fuzzy-matching → dev
- Add specs and docs for LLM fuzzy matching feature
- Updated pipeline documentation

### Summary
46PRs merged, 2 PRs created and ready for review. Features 002–006 now live in dev, providing col_type classification, Qualtrics handling, unknown-type reduction, codebook labelling and fuzzy codebook matching.
