# run_single.R
# ─────────────────────────────────────────────────────────────────────────────
# Run the full pipeline (index + codebook label) for one randomly selected
# paper.  Useful for smoke-testing the pipeline and inspecting outputs.
#
# Usage: Rscript run_single.R
#        or source("./run_single.R") from an interactive session
#
# Output: outputs/<paper_id>/
#           structure.csv, columns.csv   (from run_index)
#           labels.csv, codebook_coverage.csv  (from run_codebook_label)
# ─────────────────────────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

source("pipeline/0_index.R")
source("pipeline/2_codebook_label.R")
source("pipeline/3_psychds_convert.R")

# Change these to the models you are actually using! I can recommend gpt-oss:20b
CAPTURE_THINKING <- TRUE         # TRUE = write one row per LLM call to thinking_traces.csv

llm_use(TRUE)
llm_model("ollama/gpt-oss:20b-cloud")

PROCESS_DIR      <- "/Volumes/NINJAV/data/dataverse"  # directory containing folders to process (each treated as a "paper")
DATA_DIR         <- "/Volumes/NINJAV/data"
OUTPUT_DIR       <- "/Volumes/NINJAV/DataCheckOut/outputs"
PSYCHDS_OUT_DIR  <- "/Volumes/NINJAV/DataCheckOut/psychds"
GROUND_TRUTH_DIR <- "./ground_truth"

local({

  # ── Discover all folders ───────────────────────────────────────────────────
  all_folders <- list.dirs(PROCESS_DIR, full.names = FALSE, recursive = FALSE)

  if (length(all_folders) == 0) stop("No folders found in ", PROCESS_DIR)

  for (folder in all_folders) {
    cat("\n══════════════════════════════════════════════════════════════════════\n")
    cat(sprintf("  Processing Folder: %s\n", folder))
    cat("══════════════════════════════════════════════════════════════════════\n\n")

    # ── Stage 1: run_index ──────────────────────────────────────────────────
    print(folder)
    KNOWN_ERROR_CODES <- c("no_links", "download_failed", "empty_repo", "too_large")

    cat("── Stage 1: run_index ──────────────────────────────────────────────────\n")

    t1_start <- proc.time()[["elapsed"]]

    stage1 <- tryCatch(
      run_index(paper_id = folder, download = TRUE),
      error = function(e) list(success = FALSE, error = conditionMessage(e))
    )

    t1_elapsed <- proc.time()[["elapsed"]] - t1_start

    if (isFALSE(stage1$success)) {
      err  <- stage1$error
      code <- if (any(startsWith(err, KNOWN_ERROR_CODES))) sub(":.*$", "", err) else "error"
      cat(sprintf("  FAILED — %s\n  %s\n\n  (Stage 2 skipped)\n", code, err))
      next
    }

    cat(sprintf(
      "  success=TRUE  files=%s  data_files=%s  columns=%s  elapsed=%.1fs\n",
      stage1$n_files %||% "NA",
      stage1$n_data_files %||% "NA",
      stage1$n_columns %||% "NA",
      t1_elapsed
    ))

    # ── Stage 2: run_codebook_label ──────────────────────────────────────────

    cat("\n── Stage 2: run_codebook_label ─────────────────────────────────────────\n")

    src          <- if (is_dataverse_id(folder)) "dataverse" else "osf"
    columns_path <- paper_path("outputs", src, folder, "columns.csv")

    if (!file.exists(columns_path)) {
      cat("  Stage 2 skipped — no columns.csv\n")
      next
    }

    t2_start <- proc.time()[["elapsed"]]

    stage2 <- tryCatch(
      run_codebook_label(paper_id = folder),
      error = function(e) list(success = FALSE, error = conditionMessage(e))
    )

    t2_elapsed <- proc.time()[["elapsed"]] - t2_start

    if (isFALSE(stage2$success)) {
      cat(sprintf("  FAILED — %s\n", stage2$error))
      next
    }

    cat(sprintf(
      "  label_status=%s  labelled=%s  unlabelled=%s  elapsed=%.1fs\n",
      stage2$label_status %||% "NA",
      stage2$n_labelled %||% "NA",
      stage2$n_unlabelled %||% "NA",
      t2_elapsed
    ))

    # ── Stage 3: convert_psychds ─────────────────────────────────────────────

    cat("\n── Stage 3: convert_psychds ────────────────────────────────────────────\n")

    t3_start <- proc.time()[["elapsed"]]

    psychds_result <- tryCatch(
      convert_psychds(paper_id = folder),
      error = function(e) list(success = FALSE, error = conditionMessage(e))
    )

    t3_elapsed <- proc.time()[["elapsed"]] - t3_start

    if (isFALSE(psychds_result$success)) {
      cat(sprintf("  FAILED — %s\n", psychds_result$error))
      next
    }

    cat(sprintf(
      "  PsychDS conversion completed successfully. Elapsed time: %.1fs\n",
      t3_elapsed
    ))

    # ── Done ─────────────────────────────────────────────────────────────────

    cat(sprintf("\n── Outputs: %s\n\n", paper_path("outputs", src, folder)))
  }
})
