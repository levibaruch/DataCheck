# rerun_sav_codebook_labels.R
# -----------------------------------------------------------------------------
# Re-runs codebook label extraction (stage 2) for every paper in the
# full_120b_json eval whose structure.csv contains a .sav file classified
# as type == "data".
#
# Background: parse_codebook() was calling haven::read_dta() on .sav files,
# which errors. Embedded SPSS variable labels were silently lost. This runner
# fixes that by re-running only stage 2 on affected papers, now that
# parse_codebook correctly calls read_sav for .sav files.
#
# Reads from and writes to:  results/eval/full_120b_json/outputs/
# Does NOT touch: column extraction, PsychDS, or production outputs/.
#
# Usage: Rscript runners/pipeline/rerun_sav_codebook_labels.R
#        or source() from an interactive session.
# -----------------------------------------------------------------------------

EVAL_RESULTS_DIR <- "results/eval"
RUN_BASE         <- file.path(EVAL_RESULTS_DIR, "full_120b_json")
OUTPUT_DIR       <- file.path(RUN_BASE, "outputs")   # must be set before 0_index.R

source("pipeline/0_index.R")
source("pipeline/2_codebook_label.R")

# ── Pin the LLM model (Groq gpt-oss-20b) ────────────────────────────────────
LLM_MODEL        <- "groq/openai/gpt-oss-20b"
LLM_TEMPERATURE  <- 0.3
LLM_THINK_LEVEL  <- "low"
CAPTURE_THINKING <- TRUE
llm_use(TRUE)
llm_model(LLM_MODEL)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

local({

  # ── Find all papers with a .sav codebook file ──────────────────────────────
  cat("Scanning", OUTPUT_DIR, "for papers with .sav data files...\n\n")

  sources <- c("osf", "dataverse")
  affected <- list()

  for (src in sources) {
    src_dir <- file.path(OUTPUT_DIR, src)
    if (!dir.exists(src_dir)) next
    pids <- list.dirs(src_dir, full.names = FALSE, recursive = FALSE)
    for (pid in pids) {
      struct_path <- paper_path("outputs", src, pid, "structure.csv")
      if (!file.exists(struct_path)) next
      st <- tryCatch(read.csv(struct_path, stringsAsFactors = FALSE),
                     error = function(e) NULL)
      if (is.null(st) || !"type" %in% names(st)) next
      paths <- if ("rel_path" %in% names(st)) st$rel_path else st$filename
      is_sav_cb <- st$type == "data" & grepl("\\.sav$", paths, ignore.case = TRUE)
      if (any(is_sav_cb, na.rm = TRUE))
        affected[[length(affected) + 1L]] <- list(pid = pid, src = src)
    }
  }

  if (length(affected) == 0) {
    cat("No papers found with .sav data files. Nothing to do.\n")
    return(invisible(NULL))
  }

  cat(sprintf("Found %d affected paper(s):\n", length(affected)))
  for (a in affected)
    cat(sprintf("  [%s] %s\n", a$src, a$pid))
  cat("\n")

  # ── Re-run codebook label stage for each ───────────────────────────────────
  results <- list()

  for (i in seq_along(affected)) {
    pid <- affected[[i]]$pid
    src <- affected[[i]]$src

    cat(sprintf("[%d/%d] %s (%s)\n", i, length(affected), pid, src))

    columns_path <- paper_path("outputs", src, pid, "columns.csv")
    if (!file.exists(columns_path)) {
      cat("  SKIP — no columns.csv\n\n")
      results[[i]] <- list(pid = pid, src = src, status = "skipped_no_columns")
      next
    }

    t_start <- proc.time()[["elapsed"]]
    res <- tryCatch(
      run_codebook_label(paper_id = pid),
      error = function(e) {
        cat(sprintf("  FAILED (exception) — %s\n", conditionMessage(e)))
        traceback()
        list(success = FALSE, error = conditionMessage(e))
      }
    )
    elapsed <- proc.time()[["elapsed"]] - t_start

    # run_codebook_label() has no `success` field; it returns labels_df etc on
    # success, and the tryCatch handler injects success = FALSE on exception.
    if (!isFALSE(res$success)) {
      cat(sprintf("  OK  status=%s  labelled=%s  unlabelled=%s  elapsed=%.1fs\n\n",
                  res$label_status %||% "?",
                  res$n_labelled   %||% "?",
                  res$n_unlabelled %||% "?",
                  elapsed))
      results[[i]] <- list(pid = pid, src = src, status = "ok",
                           label_status = res$label_status %||% NA_character_,
                           n_labelled   = res$n_labelled   %||% NA_integer_,
                           n_unlabelled = res$n_unlabelled %||% NA_integer_,
                           elapsed      = elapsed)
    } else {
      err_msg <- res$error %||% "unknown error"
      cat(sprintf("  FAILED — %s\n\n", err_msg))
      results[[i]] <- list(pid = pid, src = src, status = "failed",
                           error = err_msg)
    }
  }

  # ── Summary ────────────────────────────────────────────────────────────────
  n_ok      <- sum(vapply(results, function(r) r$status == "ok",               logical(1)))
  n_failed  <- sum(vapply(results, function(r) r$status == "failed",           logical(1)))
  n_skipped <- sum(vapply(results, function(r) r$status == "skipped_no_columns", logical(1)))

  cat("══════════════════════════════════════════════════════\n")
  cat(sprintf("  Done.  ok=%d  failed=%d  skipped=%d\n", n_ok, n_failed, n_skipped))
  if (n_failed > 0) {
    cat("  Failed:\n")
    for (r in results[vapply(results, function(x) x$status == "failed", logical(1))])
      cat(sprintf("    [%s] %s — %s\n", r$src, r$pid, r$error))
  }
  cat("══════════════════════════════════════════════════════\n")

  invisible(results)
})
