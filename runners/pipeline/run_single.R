# run_single.R
# ─────────────────────────────────────────────────────────────────────────────
# Run the full pipeline (index + codebook label + psychds) for one paper.
# Useful for smoke-testing the pipeline and inspecting outputs.
#
# Usage: Rscript run_single.R
#        or source("./run_single.R") from an interactive session
#
# Output: outputs/<paper_id>/
#           structure.csv, columns.csv   (from run_index)
#           labels.csv, codebook_coverage.csv  (from run_codebook_label)
#         psychds/<source>/<paper_id>/   (from convert_psychds)
# ─────────────────────────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

source("pipeline/0_index.R")
source("pipeline/2_codebook_label.R")
source("pipeline/3_psychds_convert.R")
source("pipeline/4_report.R")

FULL_RUN       <- TRUE
DATA_DIR       <- "data"
#OUTPUT_DIR     <- "/Volumes/NINJAV/DataCheckOut/outputs"
#PSYCHDS_OUT_DIR <- "/Volumes/NINJAV/DataCheckOut/psychds"
LLM_TEMPERATURE <- 0.3
LLM_THINK_LEVEL <- "low" # "none", "low", "medium", "high"
CAPTURE_THINKING <- TRUE   # write one row per prompt call to thinking_traces.csv



# Change these to the models you are actually using! I can recommend gpt-oss:20b
llm_use(TRUE)
llm_model("ollama/gpt-oss:20b-cloud")

local({

  # ── Discover all papers ─────────────────────────────────────────────────────
  # XML_DIR is defined in 0_index.R

  # Paper XMLs (GROBID metadata) are optional here — only needed when sampling a
  # random paper. Discovery is best-effort; a missing/empty XML_DIR is fine.
  all_ids <- if (dir.exists(XML_DIR))
    tools::file_path_sans_ext(list.files(XML_DIR, pattern = "\\.xml$", full.names = FALSE))
  else character(0)

  # IDs must stay as character strings — no numeric coercion.
  # Resolve pid: CLI arg wins, else the hard-coded default, else a random XML id.
  args <- commandArgs(trailingOnly = TRUE)
  pid <- if (length(args) > 0) {
    args[1]
  } else {
    ""
  }
  if (is.null(pid) || !nzchar(pid)) {
    if (length(all_ids) == 0)
      stop("No paper id given and no XMLs found in ", XML_DIR)
    pid <- sample(all_ids, 1L)
  }
  cat("\n══════════════════════════════════════════════════════════════════════\n")
  cat(sprintf("  Paper: %s\n", pid))
  cat("══════════════════════════════════════════════════════════════════════\n\n")

  src <- if (is_dataverse_id(pid)) "dataverse" else "osf"

  # ── Stage 1: run_index ───────────────────────────────────────────────────────

  KNOWN_ERROR_CODES <- c("no_links", "download_failed", "empty_repo", "too_large")

  cat("── Stage 1: run_index ──────────────────────────────────────────────────\n")

  t1_start <- proc.time()[["elapsed"]]

  stage1 <- tryCatch(
    run_index(paper_id = pid, download = TRUE),
    error = function(e) list(success = FALSE, error = conditionMessage(e))
  )

  t1_elapsed <- proc.time()[["elapsed"]] - t1_start

  if (isFALSE(stage1$success)) {
    err  <- stage1$error
    code <- if (any(startsWith(err, KNOWN_ERROR_CODES))) sub(":.*$", "", err) else "error"
    cat(sprintf("  FAILED — %s\n  %s\n\n  (Stage 2 skipped)\n", code, err))
    return(invisible(NULL))
  }

  cat(sprintf(
    "  success=TRUE  files=%s  data_files=%s  columns=%s  elapsed=%.1fs\n",
    stage1$n_files %||% "NA",
    stage1$n_data_files %||% "NA",
    stage1$n_columns %||% "NA",
    t1_elapsed
  ))

  # ── Stage 2: run_codebook_label ─────────────────────────────────────────────

  cat("\n── Stage 2: run_codebook_label ─────────────────────────────────────────\n")

  columns_path <- paper_path("outputs", src, pid, "columns.csv")

  if (!file.exists(columns_path)) {
    cat("  Stage 2 skipped — no columns.csv\n")
    return(invisible(NULL))
  }

  t2_start <- proc.time()[["elapsed"]]

  stage2 <- tryCatch(
    run_codebook_label(paper_id = pid),
    error = function(e) list(success = FALSE, error = conditionMessage(e))
  )

  t2_elapsed <- proc.time()[["elapsed"]] - t2_start

  if (isFALSE(stage2$success)) {
    cat(sprintf("  FAILED — %s\n  (Stage 3 will still run)\n", stage2$error))
  } else {

  cat(sprintf(
      "  label_status=%s  labelled=%s  unlabelled=%s  elapsed=%.1fs\n",
      stage2$label_status %||% "NA",
      stage2$n_labelled %||% "NA",
      stage2$n_unlabelled %||% "NA",
      t2_elapsed
    ))
  }

  # ── Stage 3: psychds ─────────────────────────────────────────────────────────

  cat("\n── Stage 3: convert_psychds ────────────────────────────────────────────\n")

  PSYCHDS_CSV <- file.path(PSYCHDS_OUT_DIR, "conversion_summary.csv")

  t3_start <- proc.time()[["elapsed"]]

  psychds_results <- tryCatch(
    convert_psychds(pid),
    error = function(e) list(list(
      paper_id = pid, study_group = "all",
      success = FALSE, error = conditionMessage(e),
      n_data_files = 0L, n_raw_files = 0L,
      n_variables = 0L, n_labelled = 0L,
      has_paper_metadata = FALSE, has_ground_truth = FALSE,
      output_path = NA_character_
    ))
  )

  t3_elapsed <- proc.time()[["elapsed"]] - t3_start

  append_conversion_summary(psychds_results, PSYCHDS_CSV)

  psy_ok <- all(vapply(psychds_results, function(r) isTRUE(r$success), logical(1)))
  if (psy_ok) {
    cat(sprintf("  success=TRUE  elapsed=%.1fs\n", t3_elapsed))
  } else {
    errs <- unique(vapply(psychds_results, function(r)
      if (!isTRUE(r$success)) r$error %||% "?" else NA_character_, character(1)))
    errs <- errs[!is.na(errs)]
    cat(sprintf("  FAILED — %s\n", paste(errs, collapse = "; ")))
  }

  # ── Stage 4: run_report ──────────────────────────────────────────────────────

  cat("\n── Stage 4: run_report ─────────────────────────────────────────────────\n")

  t4_start <- proc.time()[["elapsed"]]

  report <- tryCatch(
    run_report(pid, src),
    error = function(e) list(success = FALSE, error = conditionMessage(e))
  )

  t4_elapsed <- proc.time()[["elapsed"]] - t4_start

  if (isTRUE(report$success)) {
    cat(sprintf("  success=TRUE  %s  elapsed=%.1fs\n", report$html_path, t4_elapsed))
  } else {
    cat(sprintf("  FAILED — %s\n", report$error %||% "?"))
  }

  # ── Output file paths ─────────────────────────────────────────────────────────

  out_base  <- paper_path("outputs", src, pid)
  out_files <- c(
    structure = file.path(out_base, "structure.csv"),
    columns   = file.path(out_base, "columns.csv"),
    labels    = file.path(out_base, "labels.csv"),
    coverage  = file.path(out_base, "codebook_coverage.csv"),
    thinking  = file.path(out_base, "thinking_traces.csv"),
    report    = file.path(out_base, "report.html")
  )
  existing <- out_files[file.exists(out_files)]

  cat(sprintf("\n── Outputs:\n"))
  for (nm in names(existing))
    cat(sprintf("    %-10s %s\n", nm, existing[[nm]]))
  cat("\n")

})
