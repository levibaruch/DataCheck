# step1_tune.R
# Hyperparameter grid search: temperature x thinking level, per model.
# Runs run_index() on the tuning subset for each grid cell.
# Writes results/eval/step1_results.csv (one row per grid cell).
# Writes results/eval/step1_per_paper.csv (one row per paper per cell).

source("runners/eval/eval_helpers.R")
source("pipeline/prompts.R")
source("pipeline/0_index.R")
SKIP_COLUMNS <<- TRUE   # eval only scores file-type classification; skip column extraction

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

n_cells <- length(EVAL_MODELS) * length(EVAL_TEMPS)
cat(sprintf("\n%s\n  STEP 1 — Hyperparameter grid  [%s]\n  %d papers x %d cells\n%s\n",
            divider, RUN_ID, nrow(papers_df), n_cells, divider))

# Loop paper-first so all models/temps for one paper are sent before moving on.
# This minimises Groq TPM gaps — a single paper uses ~3k tokens across all
# non-Groq models (Ollama), then one Groq call, then the next paper.
for (i in seq_len(nrow(papers_df))) {
  pid <- papers_df$id[i]
  src <- papers_df$source[i] %||% "osf"
  cat(sprintf("\n══ Paper [%d/%d]: %s\n", i, nrow(papers_df), pid))

  # Groq models last — Ollama calls act as natural spacing between Groq calls
  is_groq        <- vapply(EVAL_MODELS, function(m) grepl("^groq/", m$model), logical(1))
  models_ordered <- c(EVAL_MODELS[!is_groq], EVAL_MODELS[is_groq])

  for (temp in EVAL_TEMPS) {
    for (m in models_ordered) {
      cell_label <- sprintf("%s_think%s_temp%s",
                            m$label, safe_label(m$think), safe_label(temp))
      out_dir <- file.path(STEP1_OUT_DIR, src, pid, cell_label)
      dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

      cat(sprintf("  ── %s ... ", cell_label))

      if (paper_done(out_dir)) {
        metrics <- eval_paper(pid, out_dir, src)
        cat(sprintf("[SKIP] macro_f1=%.1f%%\n", metrics$macro_f1 %||% NA))
        next
      }

      LLM_MODEL         <<- m$model
      LLM_TEMPERATURE   <<- temp
      LLM_THINK_LEVEL   <<- m$think
      CAPTURE_THINKING  <<- TRUE
      THINKING_LOG_PATH <<- file.path(out_dir, "thinking_traces.csv")
      llm_model(LLM_MODEL)

      result <- tryCatch(
        run_index(paper_id = pid, download = FALSE, output_dir = out_dir),
        error = function(e) { cat(sprintf("ERROR: %s\n", e$message)); NULL }
      )

      if (!is.null(result) && isTRUE(result$success)) {
        metrics <- eval_paper(pid, out_dir, src)
        cat(sprintf("ok  macro_f1=%.1f%%  kappa=%.3f\n",
                    metrics$macro_f1 %||% NA, metrics$kappa %||% NA))
        pp_row <- as.data.frame(c(
          list(run_id = RUN_ID, model = m$model, model_label = m$label,
               think = as.character(m$think), temp = temp,
               prompt_format = "current"),
          metrics
        ), stringsAsFactors = FALSE)
        append_csv(pp_row, STEP1_PAPER_PATH)
      } else {
        cat("FAILED\n")
      }
    }
  }
}

# ── Cell summaries: aggregate from per-paper CSV once all papers are done ────
cat(sprintf("\n%s\n  Computing cell summaries...\n", divider))

if (file.exists(STEP1_PAPER_PATH)) {
  per_paper <- read.csv(STEP1_PAPER_PATH, stringsAsFactors = FALSE)

  for (m in EVAL_MODELS) {
    for (temp in EVAL_TEMPS) {
      if (cell_done(STEP1_RESULTS_PATH, m$model, m$think, temp)) next

      cell_rows <- per_paper[
        per_paper$model == m$model &
        as.character(per_paper$think) == as.character(m$think) &
        abs(as.numeric(per_paper$temp) - temp) < 1e-9, ]

      if (nrow(cell_rows) == 0) next

      paper_results <- lapply(seq_len(nrow(cell_rows)), function(j) {
        as.list(cell_rows[j, intersect(
          c("paper_id","n_files","macro_f1","micro_f1","kappa","mcc","accuracy","retry_rate"),
          names(cell_rows))])
      })

      summary_row <- aggregate_metrics(
        paper_results, model = m$model, think = m$think,
        temp = temp, prompt_format = "current", run_id = RUN_ID)

      if (!is.null(summary_row)) {
        summary_row$model_label <- m$label
        append_csv(summary_row, STEP1_RESULTS_PATH)
        cat(sprintf("  %s_think%s_temp%s  macro_f1=%.1f%%  kappa=%.3f\n",
                    m$label, safe_label(m$think), safe_label(temp),
                    summary_row$macro_f1, summary_row$kappa))
      }
    }
  }
}

cat(sprintf("\n%s\n  Step 1 complete.\n  Results: %s\n%s\n",
            divider, STEP1_RESULTS_PATH, divider))
