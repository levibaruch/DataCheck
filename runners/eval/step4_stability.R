# step4_stability.R
# Stability evaluation: 5 repeated runs per paper with identical config.
# For each paper x model: TARa@5 = proportion of files where all 5 runs
# agree on the type classification (Total Agreement Rate at N=5).
# Writes results/eval/step4_tara.csv      (one row per paper x model)
# Writes results/eval/step4_summary.csv   (one row per model)

source("runners/eval/eval_helpers.R")
source("pipeline/prompts.R")
source("pipeline/0_index.R")
SKIP_COLUMNS <<- TRUE   # eval only scores file-type classification; skip column extraction

STEP1_RESULTS_PATH  <- file.path(EVAL_RESULTS_DIR, "step1_results.csv")
STEP2_RESULTS_PATH  <- file.path(EVAL_RESULTS_DIR, "step2_results.csv")
STEP4_OUT_DIR       <- file.path(EVAL_RESULTS_DIR, "outputs", "step4")
STEP4_TARA_PATH     <- file.path(EVAL_RESULTS_DIR, "step4_tara.csv")
STEP4_SUMMARY_PATH  <- file.path(EVAL_RESULTS_DIR, "step4_summary.csv")
N_RUNS              <- 5

dir.create(STEP4_OUT_DIR, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(STEP1_RESULTS_PATH))
  stop("step1_results.csv not found. Run step1_tune.R first.")
if (!file.exists(STEP2_RESULTS_PATH))
  stop("step2_results.csv not found. Run step2_prompt.R first.")

step1 <- read.csv(STEP1_RESULTS_PATH, stringsAsFactors = FALSE)
step2 <- read.csv(STEP2_RESULTS_PATH, stringsAsFactors = FALSE)

best_step1 <- do.call(rbind, lapply(unique(step1$model), function(mdl) {
  rows <- step1[step1$model == mdl, ]
  rows[which.max(rows$macro_f1), ]
}))
best_step2 <- do.call(rbind, lapply(unique(step2$model), function(mdl) {
  rows <- step2[step2$model == mdl, ]
  rows[which.max(rows$macro_f1), ]
}))
final_configs <- merge(
  best_step1[, c("model", "model_label", "think", "temp")],
  best_step2[, c("model", "prompt_format")],
  by = "model", all.x = TRUE
)
final_configs$prompt_format[is.na(final_configs$prompt_format)] <- "md"

subset_path <- file.path(EVAL_RESULTS_DIR, "tuning_subset.csv")
if (!file.exists(subset_path))
  stop("tuning_subset.csv not found. Run build_tuning_subset.R first.")
papers_df <- read.csv(subset_path,
                      colClasses = c(id = "character", source = "character"),
                      stringsAsFactors = FALSE)

RUN_ID  <- format(Sys.time(), "%Y-%m-%d_%H-%M-%S")
divider <- paste0(rep("─", 72), collapse = "")

cat(sprintf("\n%s\n  STEP 4 — Stability (TARa@%d)  [%s]\n  %d papers × %d runs × %d models\n%s\n",
            divider, N_RUNS, RUN_ID, nrow(papers_df), N_RUNS, nrow(final_configs), divider))

# Compute TARa@N for a list of structure.csv paths (one per run)
compute_tara <- function(run_paths) {
  dfs <- lapply(run_paths, function(p) {
    tryCatch(read.csv(p, stringsAsFactors = FALSE), error = function(e) NULL)
  })
  dfs <- Filter(Negate(is.null), dfs)
  if (length(dfs) < 2) return(NA_real_)

  # Align on rel_path — only paths present in ALL runs
  all_paths <- Reduce(intersect, lapply(dfs, function(d) d$rel_path))
  if (length(all_paths) == 0) return(NA_real_)

  # For each file path, check if all runs give the same type
  agreed <- vapply(all_paths, function(rp) {
    types <- vapply(dfs, function(d) {
      d$type[d$rel_path == rp][1L] %||% NA_character_
    }, character(1))
    !any(is.na(types)) && length(unique(types)) == 1L
  }, logical(1))

  mean(agreed) * 100
}

for (i in seq_len(nrow(final_configs))) {
  cfg       <- final_configs[i, ]
  mdl_label <- cfg$model_label %||% cfg$model

  if (cell_done(STEP4_SUMMARY_PATH, cfg$model, cfg$think, as.numeric(cfg$temp),
                cfg$prompt_format)) {
    cat(sprintf("\n── Model: %s  [SKIP — already complete]\n", mdl_label))
    next
  }

  cat(sprintf("\n── Model: %s\n", mdl_label))

  LLM_MODEL        <<- cfg$model
  LLM_TEMPERATURE  <<- as.numeric(cfg$temp)
  LLM_THINK_LEVEL  <<- if (cfg$think == "FALSE") FALSE else
                       if (cfg$think == "TRUE")  TRUE  else cfg$think
  CAPTURE_THINKING <<- TRUE
  llm_model(LLM_MODEL)

  paper_taras <- numeric(0)

  for (j in seq_len(nrow(papers_df))) {
    pid <- papers_df$id[j]
    src <- papers_df$source[j] %||% "osf"
    cat(sprintf("  [%d/%d] %s\n", j, nrow(papers_df), pid))

    run_paths <- character(N_RUNS)
    for (run in seq_len(N_RUNS)) {
      out_dir <- file.path(STEP4_OUT_DIR, src, pid,
                           safe_label(mdl_label), sprintf("run%d", run))
      dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
      str_path <- file.path(out_dir, "structure.csv")
      run_paths[run] <- str_path

      if (file.exists(str_path)) {
        cat(sprintf("    run %d [SKIP]\n", run))
        next
      }

      cat(sprintf("    run %d ... ", run))
      THINKING_LOG_PATH <<- file.path(out_dir, "thinking_traces.csv")
      result <- tryCatch(
        run_index(paper_id = pid, download = FALSE,
                  output_dir = out_dir,
                  structure_prompt_version = cfg$prompt_format),
        error = function(e) { cat(sprintf("ERROR: %s\n", e$message)); NULL }
      )
      if (!is.null(result) && isTRUE(result$success)) {
        cat("ok\n")
      } else {
        cat("FAILED\n")
      }
    }

    # Compute TARa@5 for this paper
    tara <- compute_tara(run_paths)
    gt   <- read_gt(pid, src)
    n_files <- if (!is.null(gt)) nrow(gt) else NA_integer_

    cat(sprintf("    TARa@%d = %.1f%%  (%d files)\n", N_RUNS, tara %||% NA, n_files %||% NA))

    paper_taras <- c(paper_taras, tara %||% NA_real_)

    tara_row <- data.frame(
      run_id        = RUN_ID,
      model         = cfg$model,
      model_label   = mdl_label,
      think         = as.character(cfg$think),
      temp          = cfg$temp,
      prompt_format = cfg$prompt_format,
      paper_id      = pid,
      tara5         = tara,
      n_files       = n_files,
      stringsAsFactors = FALSE
    )
    append_csv(tara_row, STEP4_TARA_PATH)
  }

  mean_tara <- mean(paper_taras, na.rm = TRUE)
  sd_tara   <- sd(paper_taras,   na.rm = TRUE)
  worst_pid <- papers_df$id[which.min(paper_taras)]

  summary_row <- data.frame(
    run_id        = RUN_ID,
    model         = cfg$model,
    model_label   = mdl_label,
    think         = as.character(cfg$think),
    temp          = cfg$temp,
    prompt_format = cfg$prompt_format,
    n_papers      = sum(!is.na(paper_taras)),
    mean_tara5    = round(mean_tara, 2),
    sd_tara5      = round(sd_tara,   2),
    min_tara5     = round(min(paper_taras, na.rm = TRUE), 2),
    worst_paper   = worst_pid,
    stringsAsFactors = FALSE
  )
  append_csv(summary_row, STEP4_SUMMARY_PATH)
  cat(sprintf("  TARa@5: mean=%.1f%%  sd=%.1f%%  worst=%s (%.1f%%)\n",
              mean_tara, sd_tara, worst_pid, min(paper_taras, na.rm = TRUE)))
}

cat(sprintf("\n%s\n  Step 4 complete.\n  TARa: %s\n  Summary: %s\n%s\n",
            divider, STEP4_TARA_PATH, STEP4_SUMMARY_PATH, divider))
