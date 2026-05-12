# step1_tune.R
# Hyperparameter grid search: temperature x thinking level, per model.
# Runs run_index() on the tuning subset for each grid cell.
# Writes results/eval/step1_results.csv (one row per grid cell).
# Writes results/eval/step1_per_paper.csv (one row per paper per cell).

source("runners/eval/eval_helpers.R")
source("pipeline/prompts.R")
source("pipeline/0_index.R")

STEP1_OUT_DIR        <- file.path(EVAL_RESULTS_DIR, "outputs", "step1")
STEP1_RESULTS_PATH   <- file.path(EVAL_RESULTS_DIR, "step1_results.csv")
STEP1_PAPER_PATH     <- file.path(EVAL_RESULTS_DIR, "step1_per_paper.csv")

dir.create(STEP1_OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# Load tuning subset
subset_path <- file.path(EVAL_RESULTS_DIR, "tuning_subset.csv")
if (!file.exists(subset_path))
  stop("tuning_subset.csv not found. Run build_tuning_subset.R first.")
papers_df <- read.csv(subset_path,
                      colClasses = c(id = "character", source = "character"),
                      stringsAsFactors = FALSE)

RUN_ID    <- format(Sys.time(), "%Y-%m-%d_%H-%M-%S")
divider   <- paste0(rep("─", 72), collapse = "")

cat(sprintf("\n%s\n  STEP 1 — Hyperparameter grid  [%s]\n  %d papers\n%s\n",
            divider, RUN_ID, nrow(papers_df), divider))

for (m in EVAL_MODELS) {
  for (temp in EVAL_TEMPS) {
    cell_label <- sprintf("%s_think%s_temp%s",
                          m$label, safe_label(m$think), safe_label(temp))

    if (cell_done(STEP1_RESULTS_PATH, m$model, m$think, temp)) {
      cat(sprintf("\n── Cell: %s  [SKIP — already complete]\n", cell_label))
      next
    }

    cat(sprintf("\n── Cell: %s\n", cell_label))

    LLM_MODEL       <<- m$model
    LLM_TEMPERATURE <<- temp
    LLM_THINK_LEVEL <<- m$think
    llm_model(LLM_MODEL)

    paper_results <- list()

    for (i in seq_len(nrow(papers_df))) {
      pid <- papers_df$id[i]
      src <- papers_df$source[i] %||% "osf"
      out_dir <- file.path(STEP1_OUT_DIR, cell_label, src, pid)
      dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

      cat(sprintf("  [%d/%d] %s ... ", i, nrow(papers_df), pid))

      if (paper_done(out_dir)) {
        metrics <- eval_paper(pid, out_dir, src)
        paper_results[[pid]] <- metrics
        cat(sprintf("[SKIP] macro_f1=%.1f%%\n", metrics$macro_f1 %||% NA))
        next
      }

      t0 <- proc.time()[["elapsed"]]

      result <- tryCatch(
        run_index(paper_id = pid, download = FALSE, output_dir = out_dir),
        error = function(e) { cat(sprintf("ERROR: %s\n", e$message)); NULL }
      )

      elapsed <- round(proc.time()[["elapsed"]] - t0, 1)

      if (!is.null(result) && isTRUE(result$success)) {
        metrics <- eval_paper(pid, out_dir, src)
        paper_results[[pid]] <- metrics
        cat(sprintf("ok (%.1fs)  macro_f1=%.1f%%  kappa=%.3f\n",
                    elapsed,
                    metrics$macro_f1 %||% NA,
                    metrics$kappa    %||% NA))

        # Write per-paper row
        pp_row <- as.data.frame(c(
          list(run_id = RUN_ID, model = m$model, model_label = m$label,
               think = as.character(m$think), temp = temp,
               prompt_format = "current"),
          metrics
        ), stringsAsFactors = FALSE)
        append_csv(pp_row, STEP1_PAPER_PATH)
      } else {
        cat(sprintf("FAILED (%.1fs)\n", elapsed))
        paper_results[[pid]] <- NULL
      }
    }

    # Aggregate summary row
    summary_row <- aggregate_metrics(
      paper_results,
      model         = m$model,
      think         = m$think,
      temp          = temp,
      prompt_format = "current",
      run_id        = RUN_ID
    )
    if (!is.null(summary_row)) {
      summary_row$model_label <- m$label
      append_csv(summary_row, STEP1_RESULTS_PATH)
      cat(sprintf("  Summary: macro_f1=%.1f%%  micro_f1=%.1f%%  kappa=%.3f  retry_rate=%.1f%%\n",
                  summary_row$macro_f1, summary_row$micro_f1,
                  summary_row$kappa,   summary_row$retry_rate))
    }
  }
}

cat(sprintf("\n%s\n  Step 1 complete.\n  Results: %s\n%s\n",
            divider, STEP1_RESULTS_PATH, divider))
