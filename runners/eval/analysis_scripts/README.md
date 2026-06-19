# Thesis results reproduction

`reproduction_thesis_results.R` regenerates every figure and table in the
thesis evaluation chapter from saved run artifacts. One script, run from the
repo root:

```sh
Rscript runners/eval/analysis_scripts/reproduction_thesis_results.R
```

Make sure to download the representative files from OSF: https://osf.io/huw39

Outputs land under `COMP_DIR` (`results/eval/reproduction_thesis/`): `*.tex`
tables, `*.csv` data, and `plots/*.png`. Each stage runs in its own scope and is
independent once the inputs exist.

## What it produces

| Stage | Thesis section | Artifacts |
|---|---|---|
| 1–3 | Classification eval | Fig 8–15, Tables 15–19 (macro/micro-F1, per-class F1, confusion, format effect, sub-classification, method usage, size quartiles) |
| 4 | Unevaluated modules | Fig 16 (variable count), Fig 17 (codebook provenance), Table 20 (col_type) + coverage / haven-label summaries |
| 5 | PsychDS conversion  | conversion-reason + error-key CSVs; prints the processed → converted → valid funnel |

## Inputs — three different sources

The stages **do not all read the same place**:

- **Stages 1–3** read the step2 config comparison: `results/eval/outputs/step2/osf/<paper>/<config>/structure.csv` + ground truth `tests/ground_truth/osf/`.
- **Stage 4** reads the frozen gpt-oss-120b + JSON full run: `results/eval/full_120b_json/outputs/<id>/{columns,labels,codebook_coverage}.csv`. The step2 comparison does not carry these.
- **Stage 5** reads `results/eval/full_120b_json/{conversion_summary,validation_summary}.csv`.

Stages 4 and 5 **skip cleanly** (with a message) if their source is missing, so
you can run the classification half on its own.

## PsychDS is report-only — and the data is destructive to regenerate

Stage 5 **computes nothing about the datasets**; it only reads the two summary
CSVs. The actual work happened earlier, in two layers:

1. **Conversion** — `pipeline/3_psychds_convert.R`, unit = one *study group*
   (multi-study papers contribute several). Appends a row to
   `conversion_summary.csv`. A `success=FALSE` here is a DataCheck-side
   parse/convert failure (e.g. `no_data_files`, non-UTF-8 input), *before* spec
   validation can start.
2. **Validation** — the npm `psychds-validator` CLI, run inside the full-run
   pipeline (`runners/eval/evaluation_runners/run_fullPipeline_120bJson.R`,
   Stage 3.5). It validates each converted dir, records validity + error keys to
   `validation_summary.csv`, then **deletes the psychDS dir to save disk**. 

**If you only have the summaries** (the normal case): just run the script —
Stage 5 reproduces the numbers directly from `conversion_summary.csv` +
`validation_summary.csv`. Nothing else needed.

**If you want to reproduce the validation itself** (regenerate the summaries
from scratch): the psychDS reconstructions are transient — they were deleted
after validation — so you must **re-run the conversion + validation pipeline**.
That requires:

- the npm `psychds-validator` CLI on `PATH` (`npm i -g psychds-validator`), and
- the raw data downloaded at `data/<src>/<id>/`,

then `Rscript runners/eval/evaluation_runners/run_fullPipeline_120bJson.R` (or the
standalone `runners/eval/evaluation_runners/validate_psychds.R` if conversion
artifacts still exist). Both rewrite the two summary CSVs that Stage 5 consumes.

## Full reproduction from scratch (download OSF → run models → analyse)

If you do not want to trust *any* saved artifact and want to regenerate the
entire evaluation — re-download the repositories, re-run the models, rebuild
every input the analysis reads — the chain is three runners, then the analysis.

**Prerequisites**

- The ground-truth corpus at `tests/ground_truth/<src>/<id>.csv` — this defines
  which OSF repositories are in scope and holds the hand-labelled file types.
- LLM access for the model cells. The configurations call `groq/llama-3.1-8b-instant`,
  `groq/openai/gpt-oss-20b` and `groq/openai/gpt-oss-120b` through `metacheck`'s
  `llm_batch()`, so set the provider key it expects before running.
- The npm `psychds-validator` CLI on `PATH` (`npm i -g psychds-validator`) for the
  PsychDS stage.
- R with the project deps (`haven`, `readxl`, `jsonlite`, `metacheck`, …).

**Step 1 — file-type classification grid (feeds analysis stages 1–3)**

```sh
Rscript runners/eval/evaluation_runners/run_DataCheck_Validation.R
```

Walks every ground-truth paper, **downloads the OSF data** as it goes, and runs
the 3 models × 3 prompts = 9 cells. Writes
`results/eval/outputs/step2/<src>/<id>/<cell>/structure.csv` (plus summary CSVs).
This is the step2 comparison the classification stages read.

**Step 2 — columns + codebook + PsychDS for the best cell (feeds stages 4–5)**

```sh
Rscript runners/eval/evaluation_runners/run_fullPipeline_120bJson.R
```

Seeds the frozen `gpt-oss-120b-low_json` structure.csv from step 1 (it does **not**
re-classify), then runs column extraction → codebook labelling → PsychDS
conversion → validation (npm validator) → **deletes** each reconstruction.
Produces `results/eval/full_120b_json/outputs/...` plus `conversion_summary.csv`
and `validation_summary.csv`. Needs the data on disk at `data/<src>/<id>/` (from
step 1) and the validator CLI. *(The standalone
`run_DataCheck_Validation.R`-side validation can also be re-run later via
`validate_psychds.R` if the conversion artifacts still exist.)*

**Step 3 — regenerate the figures and tables**

```sh
Rscript runners/eval/analysis_scripts/reproduction_thesis_results.R
```

Now every stage has its freshly-built source and reproduces the full thesis
evaluation chapter end to end.

> Cost/time note: step 1 re-downloads the whole corpus and issues ~9 × N_papers
> batches of LLM calls — it is the expensive part. Steps 2–3 are cheap by
> comparison. If you only doubt the *analysis*, not the model outputs, skip
> steps 1–2 and just run step 3 against the saved artifacts.