# step3_final.R
# Full GT evaluation: all models with their best config + best prompt.
# Runs on ALL papers that have both downloaded data and a GT file.
# Writes results/eval/step3_<model_label>.csv and step3_summary.csv.

source("runners/eval/eval_helpers.R")
source("pipeline/prompts.R")
source("pipeline/0_index.R")
SKIP_COLUMNS <<- TRUE   # eval only scores file-type classification; skip column extraction

STEP1_RESULTS_PATH <- file.path(EVAL_RESULTS_DIR, "step1_results.csv")
STEP2_RESULTS_PATH <- file.path(EVAL_RESULTS_DIR, "step2_results.csv")
STEP3_OUT_DIR      <- file.path(EVAL_RESULTS_DIR, "outputs", "step3")
STEP3_SUMMARY_PATH <- file.path(EVAL_RESULTS_DIR, "step3_summary.csv")

dir.create(STEP3_OUT_DIR, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(STEP1_RESULTS_PATH))
  stop("step1_results.csv not found. Run step1_tune.R first.")
if (!file.exists(STEP2_RESULTS_PATH))
  stop("step2_results.csv not found. Run step2_prompt.R first.")

step1 <- read.csv(STEP1_RESULTS_PATH, stringsAsFactors = FALSE)
step2 <- read.csv(STEP2_RESULTS_PATH, stringsAsFactors = FALSE)

# Best config per model from step1
best_step1 <- do.call(rbind, lapply(unique(step1$model), function(mdl) {
  rows <- step1[step1$model == mdl, ]
  rows[which.max(rows$macro_f1), ]
}))

# Best prompt per model from step2
best_step2 <- do.call(rbind, lapply(unique(step2$model), function(mdl) {
  rows <- step2[step2$model == mdl, ]
  rows[which.max(rows$macro_f1), ]
}))

# Merge: for each model use best think/temp from step1, best prompt from step2
final_configs <- merge(
  best_step1[, c("model", "model_label", "think", "temp")],
  best_step2[, c("model", "prompt_format")],
  by = "model", all.x = TRUE
)
final_configs$prompt_format[is.na(final_configs$prompt_format)] <- "current"

cat("Final configs for full GT eval:\n")
for (i in seq_len(nrow(final_configs))) {
  r <- final_configs[i, ]
  cat(sprintf("  %-30s think=%-8s temp=%s  prompt=%s\n",
              r$model_label %||% r$model, r$think, r$temp, r$prompt_format))
}
cat("\n")

# Discover all GT papers with downloaded data
gt_files   <- list.files(file.path(GT_DIR, "osf"), pattern = "\\.csv$", full.names = FALSE)
all_gt_ids <- tools::file_path_sans_ext(gt_files)
data_dirs  <- list.dirs("./data/osf", recursive = FALSE, full.names = FALSE)
run_papers <- intersect(all_gt_ids, data_dirs)
cat(sprintf("Full GT: %d papers with GT and data available.\n\n", length(run_papers)))

RUN_ID  <- format(Sys.time(), "%Y-%m-%d_%H-%M-%S")
divider <- paste0(rep("─", 72), collapse = "")

cat(sprintf("%s\n  STEP 3 — Full GT evaluation  [%s]\n%s\n", divider, RUN_ID, divider))

for (i in seq_len(nrow(final_configs))) {
  cfg       <- final_configs[i, ]
  mdl_label <- cfg$model_label %||% cfg$model
  out_path  <- file.path(EVAL_RESULTS_DIR,
                         sprintf("step3_%s.csv", safe_label(mdl_label)))

  if (cell_done(STEP3_SUMMARY_PATH, cfg$model, cfg$think, as.numeric(cfg$temp), cfg$prompt_format)) {
    cat(sprintf("\n══ Model: %s  [SKIP — already complete]\n", mdl_label))
    next
  }

  cat(sprintf("\n══ Model: %s  (%d papers)\n", mdl_label, length(run_papers)))

  LLM_MODEL        <<- cfg$model
  LLM_TEMPERATURE  <<- as.numeric(cfg$temp)
  LLM_THINK_LEVEL  <<- if (cfg$think == "FALSE") FALSE else
                       if (cfg$think == "TRUE")  TRUE  else cfg$think
  CAPTURE_THINKING <<- TRUE
  llm_model(LLM_MODEL)

  paper_results <- list()

  for (j in seq_along(run_papers)) {
    pid     <- run_papers[j]
    out_dir <- file.path(STEP3_OUT_DIR, "osf", pid, safe_label(mdl_label))
    dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

    cat(sprintf("  [%d/%d] %s ... ", j, length(run_papers), pid))

    if (paper_done(out_dir)) {
      metrics <- eval_paper(pid, out_dir, "osf")
      paper_results[[pid]] <- metrics
      cat(sprintf("[SKIP] macro_f1=%.1f%%\n", metrics$macro_f1 %||% NA))
      next
    }

    THINKING_LOG_PATH <<- file.path(out_dir, "thinking_traces.csv")
    t0 <- proc.time()[["elapsed"]]

    result <- tryCatch(
      run_index(paper_id = pid, download = FALSE,
                output_dir = out_dir,
                structure_prompt_version = cfg$prompt_format),
      error = function(e) { cat(sprintf("ERROR: %s\n", e$message)); NULL }
    )

    elapsed <- round(proc.time()[["elapsed"]] - t0, 1)

    if (!is.null(result) && isTRUE(result$success)) {
      metrics <- eval_paper(pid, out_dir, "osf")
      paper_results[[pid]] <- metrics

      pp_row <- as.data.frame(c(
        list(run_id = RUN_ID, model = cfg$model, model_label = mdl_label,
             think = cfg$think, temp = cfg$temp, prompt_format = cfg$prompt_format),
        metrics
      ), stringsAsFactors = FALSE)
      append_csv(pp_row, out_path)
      cat(sprintf("ok (%.1fs)  macro_f1=%.1f%%\n", elapsed, metrics$macro_f1 %||% NA))
    } else {
      cat(sprintf("FAILED (%.1fs)\n", elapsed))
    }
  }

  summary_row <- aggregate_metrics(
    paper_results,
    model         = cfg$model,
    think         = cfg$think,
    temp          = as.numeric(cfg$temp),
    prompt_format = cfg$prompt_format,
    run_id        = RUN_ID
  )
  if (!is.null(summary_row)) {
    summary_row$model_label <- mdl_label
    append_csv(summary_row, STEP3_SUMMARY_PATH)
    cat(sprintf("  Summary: macro_f1=%.1f%%  micro_f1=%.1f%%  kappa=%.3f  retry=%.1f%%\n",
                summary_row$macro_f1, summary_row$micro_f1,
                summary_row$kappa,   summary_row$retry_rate))
  }
}

cat(sprintf("\n%s\n  Step 3 complete.\n  Summary: %s\n%s\n",
            divider, STEP3_SUMMARY_PATH, divider))
