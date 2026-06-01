# rerun_llmerror_columns.R
# ─────────────────────────────────────────────────────────────────────────────
# Re-run ONLY columns.csv + codebook (labels.csv, codebook_coverage.csv) for the
# papers whose columns.csv contained col_type == "llm_error". No psychDS.
# Mirrors run_fullPipeline_120bJson.R globals/model pin, stages 0-2 only.
# ─────────────────────────────────────────────────────────────────────────────

source("runners/eval/eval_helpers.R")
source("pipeline/prompts.R")

FULL_RUN     <- TRUE
SKIP_COLUMNS <- FALSE
COLUMNS_ONLY <- TRUE

FROZEN_CELL  <- "gpt-oss-120b-low_json"
FROZEN_STEP2 <- file.path(EVAL_RESULTS_DIR, "outputs", "step2")

RUN_BASE        <- file.path(EVAL_RESULTS_DIR, "full_120b_json")
OUTPUT_DIR      <- file.path(RUN_BASE, "outputs")
PSYCHDS_OUT_DIR <- file.path(RUN_BASE, "psychds")

source("pipeline/0_index.R")
source("pipeline/2_codebook_label.R")

CFG <- list(model = "groq/openai/gpt-oss-120b", think = "low", temp = 0.3,
            prompt = "json", label = "gpt-oss-120b-low")

LLM_MODEL        <<- CFG$model
LLM_TEMPERATURE  <<- CFG$temp
LLM_THINK_LEVEL  <<- CFG$think
CAPTURE_THINKING <<- TRUE
llm_use(TRUE)
llm_model(LLM_MODEL)

SRC  <- "osf"
IDS  <- c("0956797616672268", "0956797618773095")

for (pid in IDS) {
  out_dir <- paper_path("outputs", SRC, pid)
  cat(sprintf("\n=== %s/%s ===\n", SRC, pid))

  THINKING_LOG_PATH <<- file.path(out_dir, "thinking_traces.csv")

  # Force regeneration: drop stale columns/codebook outputs (keep structure.csv seed).
  for (f in c("columns.csv", "labels.csv", "codebook_coverage.csv"))
    if (file.exists(file.path(out_dir, f))) unlink(file.path(out_dir, f))

  # Stage 1: columns.csv
  t0 <- proc.time()[["elapsed"]]
  s1 <- tryCatch(run_index(paper_id = pid, download = FALSE),
                 error = function(e) list(success = FALSE, error = conditionMessage(e)))
  el <- round(proc.time()[["elapsed"]] - t0, 1)
  if (isFALSE(s1$success)) {
    cat(sprintf("  stage1: FAILED (%.1fs) — %s\n", el, s1$error %||% "?")); next
  }
  cat(sprintf("  stage1: ok (%.1fs)  columns=%s\n", el, s1$n_columns %||% "NA"))

  # Stage 2: codebook labels + coverage
  t0 <- proc.time()[["elapsed"]]
  s2 <- tryCatch(run_codebook_label(paper_id = pid),
                 error = function(e) list(success = FALSE, error = conditionMessage(e)))
  el <- round(proc.time()[["elapsed"]] - t0, 1)
  if (isFALSE(s2$success))
    cat(sprintf("  stage2: FAILED (%.1fs) — %s\n", el, s2$error %||% "?"))
  else
    cat(sprintf("  stage2: ok (%.1fs)  labelled=%s unlabelled=%s\n",
                el, s2$n_labelled %||% "NA", s2$n_unlabelled %||% "NA"))
}

cat("\nDone.\n")
