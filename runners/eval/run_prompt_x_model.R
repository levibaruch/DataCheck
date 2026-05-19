# run_prompt_x_model.R
# Collapsed eval: 3 prompts × 3 fixed-config models on full ground truth.
# Replaces original step1→step4 chain for this pass.
#
# Cells:
#   groq/llama-3.1-8b-instant      think=FALSE  temp=0.3
#   groq/openai/gpt-oss-20b        think=low    temp=0.3
#   groq/openai/gpt-oss-120b       think=low    temp=0.3
# × prompts: md / plaintext / json   →  9 cells
#
# Outputs (schema-compatible with original step2_results.csv +
# step3_summary.csv so eval_report.R and a later step3/step4 can reuse them):
#   results/eval/prompt_model_summary.csv
#   results/eval/prompt_model_per_paper.csv
#   results/eval/outputs/step2/<src>/<id>/<cell_label>/structure.csv

source("runners/eval/eval_helpers.R")
source("pipeline/prompts.R")
source("pipeline/0_index.R")
SKIP_COLUMNS <<- TRUE   # file-type classification only

CONFIGS <- list(
  list(model = "groq/llama-3.1-8b-instant", think = FALSE, temp = 0.3,
       label = "llama3.1-8b"),
  list(model = "groq/openai/gpt-oss-20b",  think = "low", temp = 0.3,
       label = "gpt-oss-20b-low"),
  list(model = "groq/openai/gpt-oss-120b", think = "low", temp = 0.3,
       label = "gpt-oss-120b-low")
)

OUT_DIR      <- file.path(EVAL_RESULTS_DIR, "outputs", "step2")
SUMMARY_PATH <- file.path(EVAL_RESULTS_DIR, "prompt_model_summary.csv")
PAPER_PATH   <- file.path(EVAL_RESULTS_DIR, "prompt_model_per_paper.csv")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# Full GT corpus: every <src>/<id>.csv under tests/ground_truth/
gt_files <- list.files(GT_DIR, pattern = "\\.csv$", recursive = TRUE,
                       full.names = FALSE)
if (length(gt_files) == 0) stop("No ground truth files found in ", GT_DIR)
papers_df <- data.frame(
  source = dirname(gt_files),
  id     = tools::file_path_sans_ext(basename(gt_files)),
  stringsAsFactors = FALSE
)
papers_df <- papers_df[order(papers_df$source, papers_df$id), ]

RUN_ID  <- format(Sys.time(), "%Y-%m-%d_%H-%M-%S")
divider <- paste0(rep("─", 72), collapse = "")

cat(sprintf("%s\n  Prompt × Model eval  [%s]\n  %d papers × %d models × %d prompts = %d cells\n%s\n",
            divider, RUN_ID, nrow(papers_df), length(CONFIGS),
            length(EVAL_PROMPTS), length(CONFIGS) * length(EVAL_PROMPTS), divider))

for (cfg in CONFIGS) {
  for (p in EVAL_PROMPTS) {
    cell_label <- sprintf("%s_%s", safe_label(cfg$label), p$label)

    if (cell_done(SUMMARY_PATH, cfg$model, cfg$think, cfg$temp, p$label)) {
      cat(sprintf("\n── %s | prompt=%s  [SKIP — already complete]\n",
                  cfg$label, p$label))
      next
    }

    cat(sprintf("\n── %s | prompt=%s\n", cfg$label, p$label))

    LLM_MODEL        <<- cfg$model
    LLM_TEMPERATURE  <<- cfg$temp
    LLM_THINK_LEVEL  <<- cfg$think
    CAPTURE_THINKING <<- TRUE
    llm_model(LLM_MODEL)

    paper_results <- list()

    for (j in seq_len(nrow(papers_df))) {
      pid <- papers_df$id[j]
      src <- papers_df$source[j]
      out_dir <- file.path(OUT_DIR, src, pid, cell_label)
      dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

      cat(sprintf("  [%d/%d] %s/%s ... ", j, nrow(papers_df), src, pid))

      if (paper_done(out_dir)) {
        metrics <- eval_paper(pid, out_dir, src)
        if (!is.null(metrics)) {
          paper_results[[pid]] <- metrics
          cat(sprintf("[SKIP] macro_f1=%.1f%%\n", metrics$macro_f1 %||% NA))
        } else {
          cat("[SKIP] (no metrics)\n")
        }
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
        if (!is.null(metrics)) {
          paper_results[[pid]] <- metrics
          cat(sprintf("ok (%.1fs)  macro_f1=%.1f%%\n",
                      elapsed, metrics$macro_f1 %||% NA))
          pp_row <- as.data.frame(c(
            list(run_id = RUN_ID, model = cfg$model, model_label = cfg$label,
                 think = as.character(cfg$think), temp = cfg$temp,
                 prompt_format = p$label),
            metrics
          ), stringsAsFactors = FALSE)
          append_csv(pp_row, PAPER_PATH)
        } else {
          cat(sprintf("ok (%.1fs)  no metrics\n", elapsed))
        }
      } else {
        cat(sprintf("FAILED (%.1fs)\n", elapsed))
      }
    }

    summary_row <- aggregate_metrics(
      paper_results,
      model         = cfg$model,
      think         = cfg$think,
      temp          = cfg$temp,
      prompt_format = p$label,
      run_id        = RUN_ID
    )
    if (!is.null(summary_row)) {
      summary_row$model_label <- cfg$label
      append_csv(summary_row, SUMMARY_PATH)
      cat(sprintf("  Summary: macro_f1=%.1f%%  micro_f1=%.1f%%  kappa=%.3f  n=%d\n",
                  summary_row$macro_f1, summary_row$micro_f1,
                  summary_row$kappa, summary_row$n_papers))
    }
  }
}

cat(sprintf("\n%s\n  Done.\n  Summary:    %s\n  Per-paper:  %s\n  Raw outputs: %s\n%s\n",
            divider, SUMMARY_PATH, PAPER_PATH, OUT_DIR, divider))
