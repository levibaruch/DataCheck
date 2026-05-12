# step2_prompt.R
# Prompt format sweep: markdown (current) vs plain text vs structured.
# Uses per-model best config from step1_results.csv.
# Writes results/eval/step2_results.csv and step2_per_paper.csv.

source("runners/eval/eval_helpers.R")
source("pipeline/prompts.R")
source("pipeline/0_index.R")
SKIP_COLUMNS <<- TRUE   # eval only scores file-type classification; skip column extraction

STEP1_RESULTS_PATH <- file.path(EVAL_RESULTS_DIR, "step1_results.csv")
STEP2_OUT_DIR      <- file.path(EVAL_RESULTS_DIR, "outputs", "step2")
STEP2_RESULTS_PATH <- file.path(EVAL_RESULTS_DIR, "step2_results.csv")
STEP2_PAPER_PATH   <- file.path(EVAL_RESULTS_DIR, "step2_per_paper.csv")

dir.create(STEP2_OUT_DIR, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(STEP1_RESULTS_PATH))
  stop("step1_results.csv not found. Run step1_tune.R first.")

step1 <- read.csv(STEP1_RESULTS_PATH, stringsAsFactors = FALSE)

# Best config per model: highest macro_f1
best_configs <- do.call(rbind, lapply(unique(step1$model), function(mdl) {
  rows <- step1[step1$model == mdl, ]
  rows[which.max(rows$macro_f1), ]
}))

cat(sprintf("Best configs loaded for %d models.\n\n", nrow(best_configs)))
for (i in seq_len(nrow(best_configs))) {
  r <- best_configs[i, ]
  cat(sprintf("  %s: think=%s  temp=%s  macro_f1=%.1f%%\n",
              r$model_label %||% r$model, r$think, r$temp, r$macro_f1))
}
cat("\n")

subset_path <- file.path(EVAL_RESULTS_DIR, "tuning_subset.csv")
if (!file.exists(subset_path))
  stop("tuning_subset.csv not found. Run build_tuning_subset.R first.")
papers_df <- read.csv(subset_path,
                      colClasses = c(id = "character", source = "character"),
                      stringsAsFactors = FALSE)

RUN_ID  <- format(Sys.time(), "%Y-%m-%d_%H-%M-%S")
divider <- paste0(rep("─", 72), collapse = "")

cat(sprintf("%s\n  STEP 2 — Prompt format sweep  [%s]\n%s\n", divider, RUN_ID, divider))

for (i in seq_len(nrow(best_configs))) {
  cfg <- best_configs[i, ]
  mdl_label <- cfg$model_label %||% cfg$model

  for (p in EVAL_PROMPTS) {
    cell_label <- sprintf("%s_%s", safe_label(mdl_label), p$label)

    if (cell_done(STEP2_RESULTS_PATH, cfg$model, cfg$think, as.numeric(cfg$temp), p$label)) {
      cat(sprintf("\n── %s | prompt=%s  [SKIP — already complete]\n", mdl_label, p$label))
      next
    }

    cat(sprintf("\n── %s | prompt=%s\n", mdl_label, p$label))

    LLM_MODEL        <<- cfg$model
    LLM_TEMPERATURE  <<- as.numeric(cfg$temp)
    LLM_THINK_LEVEL  <<- if (cfg$think == "FALSE") FALSE else
                         if (cfg$think == "TRUE")  TRUE  else cfg$think
    CAPTURE_THINKING <<- TRUE
    llm_model(LLM_MODEL)

    paper_results <- list()

    for (j in seq_len(nrow(papers_df))) {
      pid <- papers_df$id[j]
      src <- papers_df$source[j] %||% "osf"
      out_dir <- file.path(STEP2_OUT_DIR, src, pid, cell_label)
      dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

      cat(sprintf("  [%d/%d] %s ... ", j, nrow(papers_df), pid))

      if (paper_done(out_dir)) {
        metrics <- eval_paper(pid, out_dir, src)
        paper_results[[pid]] <- metrics
        cat(sprintf("[SKIP] macro_f1=%.1f%%\n", metrics$macro_f1 %||% NA))
        next
      }

      THINKING_LOG_PATH <<- file.path(out_dir, "thinking_traces.csv")
      t0 <- proc.time()[["elapsed"]]

      result <- tryCatch(
        run_index(paper_id = pid, download = FALSE,
                  output_dir = out_dir,
                  structure_prompt_version = p$version),
        error = function(e) { cat(sprintf("ERROR: %s\n", e$message)); NULL }
      )

      elapsed <- round(proc.time()[["elapsed"]] - t0, 1)

      if (!is.null(result) && isTRUE(result$success)) {
        metrics <- eval_paper(pid, out_dir, src)
        paper_results[[pid]] <- metrics
        cat(sprintf("ok (%.1fs)  macro_f1=%.1f%%\n", elapsed, metrics$macro_f1 %||% NA))

        pp_row <- as.data.frame(c(
          list(run_id = RUN_ID, model = cfg$model, model_label = mdl_label,
               think = cfg$think, temp = cfg$temp, prompt_format = p$label),
          metrics
        ), stringsAsFactors = FALSE)
        append_csv(pp_row, STEP2_PAPER_PATH)
      } else {
        cat(sprintf("FAILED (%.1fs)\n", elapsed))
      }
    }

    summary_row <- aggregate_metrics(
      paper_results,
      model         = cfg$model,
      think         = cfg$think,
      temp          = as.numeric(cfg$temp),
      prompt_format = p$label,
      run_id        = RUN_ID
    )
    if (!is.null(summary_row)) {
      summary_row$model_label <- mdl_label
      append_csv(summary_row, STEP2_RESULTS_PATH)
      cat(sprintf("  Summary: macro_f1=%.1f%%  micro_f1=%.1f%%  kappa=%.3f\n",
                  summary_row$macro_f1, summary_row$micro_f1, summary_row$kappa))
    }
  }
}

cat(sprintf("\n%s\n  Step 2 complete.\n  Results: %s\n%s\n",
            divider, STEP2_RESULTS_PATH, divider))
