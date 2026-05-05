# DataCheck Restructure Plan (2026-05-05)

## Problem

20+ items at repo root. Source code split across 6+ dirs (pipeline, runners, reports,
tools, ab_test, loose root scripts). Docs split across 3 dirs (docs, specs, psych_ds_docs).
Tests split across 2 dirs (tests, ground_truth).

## Proposed: 4 source dirs

```
DataCheck/
│
├── pipeline/           # Core modules — sourced by runners, never run directly
│   ├── 0_index.R
│   ├── 2_codebook_label.R
│   ├── 3_psychds_convert.R
│   ├── helper.R
│   ├── ollama.R
│   └── prompts.R
│
├── runners/
│   ├── pipeline/           # Run the pipeline on papers
│   │   ├── run_single.R
│   │   ├── run_folder.R
│   │   ├── run_0_index_bulk.R
│   │   ├── run_2_codebook_bulk.R
│   │   └── run_full_pipeline_bulk.R
│   │
│   ├── psychds/            # PsychDS conversion
│   │   ├── run_psychds_single.R
│   │   └── run_psychds_bulk.R
│   │
│   ├── reports/            # Report generators
│   │   ├── report_normal.R         ← reports/ moved here
│   │   ├── report_quality.R        ← reports/ moved here
│   │   ├── report_sweep.R          ← reports/ moved here
│   │   └── report_sweep_grand.R    ← reports/ moved here
│   │
│   ├── experiments/        # Sweeps, A/B tests, LLM param exploration
│   │   ├── run_sweep.R
│   │   ├── run_sweep_bulk.R
│   │   ├── ab_test.R               ← ab_test/run_ab_test.R
│   │   ├── test_thinking_trace.R
│   │   └── test_llm_params.R
│   │
│   └── tools/              # Standalone utilities
│       ├── download_all_osf.R
│       ├── find_rdata_papers.R
│       ├── find_csv_codebooks.R    ← root script
│       ├── reset_csv_codebooks.R   ← root script
│       ├── plot_file_counts.R      ← tools/
│       ├── run_validation_gui.R
│       └── run_test_validation_gui.R
│
├── tests/              # Test infra + validation data
│   ├── run_tests.R             ← runners/run_tests.R moved here
│   ├── test_papers.csv
│   ├── test_log.csv
│   ├── ground_truth/           ← ground_truth/ moved here
│   │   └── osf/
│   └── validation_gui/         ← tools/validation_gui/ moved here
│
├── docs/               # All documentation + specs
│   ├── pipeline.md
│   ├── output-schemas.md
│   ├── diary.txt
│   ├── hard-datasets.md
│   ├── detected_granularity_patterns.csv
│   ├── psychds/                ← psych_ds_docs/ moved here
│   │   └── spec.md
│   └── specs/                  ← specs/ moved here
│       └── NNN-feature-name/
│
│   (gitignored — data, not code)
├── data/
├── outputs/
├── psychds/
├── results/
├── logs/
├── user_tests/
│
├── CLAUDE.md
├── progress.md
└── TODO.txt
```

## What collapses

| Old location | New location | Reason |
|---|---|---|
| `reports/*.R` | `runners/reports/` | Reports are entry points like any runner |
| `tools/plot_file_counts.R` | `runners/tools/` | Utility runner |
| `tools/validation_gui/` | `tests/validation_gui/` | GUI is a testing/validation tool |
| `ab_test/run_ab_test.R` | `runners/experiments/ab_test.R` | Experiment entry point |
| `ab_test/results/` | gitignored | Data, not code |
| `runners/run_sweep.R` | `runners/experiments/` | Experiment entry point |
| `runners/run_sweep_bulk.R` | `runners/experiments/` | Experiment entry point |
| `runners/test_thinking_trace.R` | `runners/experiments/` | LLM exploration |
| `runners/test_llm_params.R` | `runners/experiments/` | LLM exploration |
| `runners/run_psychds_*.R` | `runners/psychds/` | PsychDS group |
| `runners/run_validation_gui.R` | `runners/tools/` | Utility |
| `runners/run_test_validation_gui.R` | `runners/tools/` | Utility |
| `runners/run_tests.R` | `tests/run_tests.R` | Belongs with test infra |
| `find_csv_codebooks.R` (root) | `runners/tools/` | Utility runner |
| `reset_csv_codebook_papers.R` (root) | `runners/tools/` | Utility runner |
| `ground_truth/` | `tests/ground_truth/` | Validation data belongs with tests |
| `specs/` | `docs/specs/` | Specs are documentation |
| `psych_ds_docs/` | `docs/psychds/` | External spec docs |
| `_old/` | Keep gitignored | Archive |

## Result: root goes from 20+ items to ~10

```
pipeline/
runners/pipeline/  runners/psychds/  runners/reports/  runners/experiments/  runners/tools/
tests/
docs/specs/  docs/psychds/
data/  outputs/  psychds/  results/  logs/  user_tests/
CLAUDE.md  progress.md  TODO.txt
```


## Source path changes needed

Most moves are free — all scripts run from repo root, so `source("pipeline/helper.R")`
and `"./outputs"` etc. are unaffected by which subfolder the script lives in.

Only **2 functional source() breaks** and **1 path constant change**:

### Functional source() breaks

| File | Current | Fix |
|---|---|---|
| `runners/run_sweep_bulk.R` | `source("runners/run_sweep.R")` | `source("runners/experiments/run_sweep.R")` |
| `reports/report_sweep_grand.R` | `source("reports/report_sweep.R")` | `source("runners/reports/report_sweep.R")` |

### ground_truth/ → tests/ground_truth/

All these set or use `GROUND_TRUTH_DIR` / `GT_DIR` / hardcoded `"./ground_truth"`:

| File | Change |
|---|---|
| `pipeline/0_index.R` | `"./ground_truth"` → `"./tests/ground_truth"` |
| `pipeline/2_codebook_label.R` | `"./ground_truth"` → `"./tests/ground_truth"` |
| `pipeline/3_psychds_convert.R` | `"./ground_truth"` → `"./tests/ground_truth"` |
| `reports/report_normal.R` | `GT_DIR <- "./ground_truth"` → `"./tests/ground_truth"` |
| `runners/run_folder.R` | `GROUND_TRUTH_DIR <- "./ground_truth"` → `"./tests/ground_truth"` |
| `runners/run_0_index_bulk.R` | `GT_DIR <- "./ground_truth"` → `"./tests/ground_truth"` |
| `runners/run_full_pipeline_bulk.R` | `GT_DIR <- "./ground_truth"` → `"./tests/ground_truth"` |
| `runners/run_tests.R` | `GT_DIR <- "./ground_truth"` → `"./tests/ground_truth"` |
| `ab_test/run_ab_test.R` | `file.path(TEST_DIR, "ground_truth/osf")` — already correct if `TEST_DIR <- "./tests"` |
| `tools/validation_gui/app.R` | `file.path(root, "ground_truth")` → `file.path(root, "tests/ground_truth")` |
| `tools/validation_gui/gt_store.R` | `file.path(..., "ground_truth")` → `file.path(..., "tests/ground_truth")` |
| `runners/run_test_validation_gui.R` | already uses `file.path(dc_root, "tests", "ground_truth", "osf")` — no change |

### Comment-only updates (no functional impact)

All `# Usage: source("runners/run_sweep.R")` etc. in moved files — update to new paths.

---

## Implementation steps

Do in this order to keep the repo runnable throughout:

1. **Create new dirs**
   ```
   mkdir -p runners/pipeline runners/psychds runners/reports runners/experiments runners/tools
   mkdir -p tests/ground_truth
   mkdir -p docs/specs docs/psychds
   ```

3. **Move docs** (no code deps)
   ```
   git mv specs/* docs/specs/
   git mv psych_ds_docs/spec.md docs/psychds/spec.md
   git mv psych_ds_docs/docs_copied.txt docs/psychds/docs_copied.txt
   git mv docs/validation-gui-spec.md docs/specs/validation-gui-spec.md
   git mv restructure.md docs/restructure.md
   ```

4. **Move ground_truth** and update all path constants (grep list above)
   ```
   git mv ground_truth/osf tests/ground_truth/osf
   ```
   Then update all 10 files listed above.

5. **Move runners into subfolders**
   ```
   git mv runners/run_single.R runners/pipeline/run_single.R
   git mv runners/run_folder.R runners/pipeline/run_folder.R
   git mv runners/run_0_index_bulk.R runners/pipeline/run_0_index_bulk.R
   git mv runners/run_2_codebook_bulk.R runners/pipeline/run_2_codebook_bulk.R
   git mv runners/run_full_pipeline_bulk.R runners/pipeline/run_full_pipeline_bulk.R

   git mv runners/run_psychds_single.R runners/psychds/run_psychds_single.R
   git mv runners/run_psychds_bulk.R runners/psychds/run_psychds_bulk.R

   git mv reports/report_normal.R runners/reports/report_normal.R
   git mv reports/report_quality.R runners/reports/report_quality.R
   git mv reports/report_sweep.R runners/reports/report_sweep.R
   git mv reports/report_sweep_grand.R runners/reports/report_sweep_grand.R

   git mv runners/run_sweep.R runners/experiments/run_sweep.R
   git mv runners/run_sweep_bulk.R runners/experiments/run_sweep_bulk.R
   git mv runners/test_thinking_trace.R runners/experiments/test_thinking_trace.R
   git mv runners/test_llm_params.R runners/experiments/test_llm_params.R
   git mv ab_test/run_ab_test.R runners/experiments/ab_test.R

   git mv runners/download_all_osf.R runners/tools/download_all_osf.R
   git mv runners/find_rdata_papers.R runners/tools/find_rdata_papers.R
   git mv runners/run_validation_gui.R runners/tools/run_validation_gui.R
   git mv runners/run_test_validation_gui.R runners/tools/run_test_validation_gui.R
   git mv find_csv_codebooks.R runners/tools/find_csv_codebooks.R
   git mv reset_csv_codebook_papers.R runners/tools/reset_csv_codebook_papers.R
   git mv tools/plot_file_counts.R runners/tools/plot_file_counts.R
   ```

6. **Fix the 2 functional source() breaks** (step 5 breaks these)
   - `runners/experiments/run_sweep_bulk.R`: update source path
   - `runners/reports/report_sweep_grand.R`: update source path

7. **Move tests**
   ```
   git mv runners/run_tests.R tests/run_tests.R
   git mv tools/validation_gui tests/validation_gui
   ```
   Update source paths in `tests/run_tests.R` if needed.

8. **Smoke test** — run `Rscript tests/run_tests.R` and verify.

9. **Update CLAUDE.md** project structure section.
   Update `docs/pipeline.md` entry points table.
