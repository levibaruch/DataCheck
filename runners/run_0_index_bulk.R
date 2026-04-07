# run_index_bulk.R
# ─────────────────────────────────────────────────────────────────────────────
# Run run_index() across all (or N) papers, writing results incrementally
# to a CSV so that progress survives crashes. On restart, already-completed
# papers are skipped automatically.
# ─────────────────────────────────────────────────────────────────────────────

source("data_check/pipeline/0_index.R")

# ── Config ────────────────────────────────────────────────────────────────────

FULL_RUN     <- TRUE         # TRUE = no LLM call caps (file classification + col_type)
SKIP_COLUMNS <- TRUE        # TRUE = skip column extraction (file indexing only)
N_RUNS       <- Inf          # Inf = all papers; set an integer to cap
SEED        <- NULL         # set an integer for reproducibility, or NULL
SHUFFLE     <- TRUE         # TRUE = randomise paper order; FALSE = process in discovery order
SUMMARY_CSV <- "./data_check/results/bulk_summary.csv"
DOWNLOAD    <- TRUE         # Whether the script should attempt downloads or not

LLM_BATCH_SIZE         <- 20L  # paths sent per LLM call for file classification
MAX_COL_TYPE_LLM_CALLS <- 5L   # max LLM calls for column type classification per paper

# Set FROM_LOCAL = TRUE to skip downloading and re-process already-downloaded
# datasets from the data/ folder. Discovers paper IDs from existing subdirs
# instead of XML files — useful for re-runs after pipeline changes.
FROM_LOCAL  <- TRUE

# Set RESUME = FALSE to ignore prior bulk_summary.csv and re-run everything.
# Typically set FALSE when doing a FROM_LOCAL re-run after pipeline changes.
RESUME      <- TRUE

# Set PRIORITISE_GT = TRUE to process papers that have a ground_truth CSV first.
# Within each group (GT / non-GT), the existing SHUFFLE/SEED ordering applies.
PRIORITISE_GT <- TRUE
GT_DIR        <- "./data_check/ground_truth"

if (FROM_LOCAL) DOWNLOAD <- FALSE

# ── Discover all papers ──────────────────────────────────────────────────────

if (FROM_LOCAL) {
  all_ids <- list.dirs(DATA_DIR, full.names = FALSE, recursive = FALSE)
  all_ids <- all_ids[nchar(all_ids) > 0]
  if (length(all_ids) == 0) stop("No paper directories found in ", DATA_DIR)
} else {
  all_ids <- tools::file_path_sans_ext(
    list.files(XML_DIR, pattern = "\\.xml$", full.names = FALSE)
  )
  if (length(all_ids) == 0) stop("No XML files found in ", XML_DIR)
}

# ── Load prior progress ─────────────────────────────────────────────────────

done_ids <- character(0)
if (file.exists(SUMMARY_CSV)) {
  prior <- tryCatch(read.csv(SUMMARY_CSV, stringsAsFactors = FALSE, colClasses = c(paper_id = "character")), error = function(e) NULL)
  if (!is.null(prior) && "paper_id" %in% names(prior)) {
    # Backfill run_at column if missing (one-time migration)
    if (!"run_at" %in% names(prior)) {
      prior <- cbind(prior[, "paper_id", drop = FALSE],
                     run_at = NA_character_,
                     prior[, setdiff(names(prior), "paper_id"), drop = FALSE])
      write.csv(prior, SUMMARY_CSV, row.names = FALSE)
      message("── Migrated bulk_summary.csv: added run_at column")
    }
    if (RESUME) {
      done_ids <- unique(as.character(prior$paper_id))
      message("── Resuming: ", length(done_ids), " paper(s) already processed, skipping")
    }
  }
}

# ── Determine papers to run ─────────────────────────────────────────────────

remaining_ids <- setdiff(all_ids, done_ids)
if (SHUFFLE) {
  if (!is.null(SEED)) set.seed(SEED)
  remaining_ids <- sample(remaining_ids)
}
if (PRIORITISE_GT) {
  gt_ids <- sub("\\.csv$", "", list.files(GT_DIR, pattern = "\\.csv$"))
  is_gt  <- remaining_ids %in% gt_ids
  remaining_ids <- c(remaining_ids[is_gt], remaining_ids[!is_gt])
  message("── GT priority: ", sum(is_gt), " GT paper(s) moved to front")
}
if (is.finite(N_RUNS) && N_RUNS < length(remaining_ids)) {
  remaining_ids <- remaining_ids[seq_len(N_RUNS)]
}

n_total    <- length(remaining_ids)
n_prior    <- length(done_ids)

if (n_total == 0) {
  message("── Nothing to do — all papers already processed.")
  q(save = "no")
}

message("── Will process ", n_total, " paper(s)")

# ── Helper: append one row to the summary CSV ───────────────────────────────

na_fallback <- function(x, na = NA) if (is.null(x) || length(x) == 0) na else x

append_summary_row <- function(r) {
  row <- data.frame(
    paper_id     = na_fallback(r$paper_id, NA_character_),
    run_at       = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    success      = r$success,
    error        = na_fallback(r$error, NA_character_),
    elapsed_ms   = round(na_fallback(r$elapsed_sec, NA_real_) * 1000),
    download_ms  = round(na_fallback(r$download_sec, NA_real_) * 1000),
    llm_ms       = round(na_fallback(r$llm_sec, NA_real_) * 1000),
    column_ms    = round(na_fallback(r$column_sec, NA_real_) * 1000),
    n_files      = na_fallback(r$n_files, NA_integer_),
    n_data_files    = na_fallback(r$n_data_files, NA_integer_),
    n_tabular_files = na_fallback(r$n_tabular_files, NA_integer_),
    n_agg_dirs   = na_fallback(r$n_agg_dirs, NA_integer_),
    n_individual = na_fallback(r$n_individual, NA_integer_),
    n_combined   = na_fallback(r$n_combined, NA_integer_),
    n_columns    = na_fallback(r$n_columns, NA_integer_),
    n_src_files  = na_fallback(r$n_source_files, NA_integer_),
    stringsAsFactors = FALSE
  )
  write_header <- !file.exists(SUMMARY_CSV)
  write.table(row, SUMMARY_CSV, append = TRUE, sep = ",",
              row.names = FALSE, col.names = write_header)
}

# ── Run ──────────────────────────────────────────────────────────────────────

for (i in seq_along(remaining_ids)) {
  pid <- remaining_ids[i]

  # Double-check: re-read CSV in case a prior iteration already covered this ID
  if (RESUME && file.exists(SUMMARY_CSV)) {
    already <- tryCatch(read.csv(SUMMARY_CSV, stringsAsFactors = FALSE, colClasses = c(paper_id = "character")), error = function(e) NULL)
    if (!is.null(already) && pid %in% already$paper_id) {
      message("  skipping (already in CSV): ", pid)
      next
    }
  }

  cat("\n══════════════════════════════════════════════════════════════════════\n")
  cat(sprintf("  Run %d / %d  (overall %d / %d)  —  %s\n",
              i, n_total, n_prior + i, n_prior + n_total, pid))
  cat("══════════════════════════════════════════════════════════════════════\n")

  run_once <- function(download = TRUE) {
    tryCatch(
      run_index(paper_id = pid, download = download),
      error = function(e) {
        msg <- conditionMessage(e)
        # If the folder is empty, delete it and retry the download once only if download = TRUE
        if (grepl("^empty_repo:", msg) && download) {
          empty_dir <- file.path(DATA_DIR, pid)
          if (dir.exists(empty_dir)) {
            message("  empty_repo — deleting empty folder and retrying: ", empty_dir)
            unlink(empty_dir, recursive = TRUE)
          }
          tryCatch(
            run_index(paper_id = pid, download = download),
            error = function(e2) {
              message("  FAILED (retry): ", conditionMessage(e2))
              list(
                paper_id       = pid,
                success        = FALSE,
                error          = conditionMessage(e2),
                elapsed_sec    = NA_real_,
                n_files        = NA_integer_,
                n_data_files   = NA_integer_,
                n_agg_dirs     = NA_integer_,
                n_individual   = NA_integer_,
                n_combined     = NA_integer_,
                n_columns      = NA_integer_,
                n_source_files = NA_integer_
              )
            }
          )
        } else {
          message("  FAILED: ", msg)
          list(
            paper_id       = pid,
            success        = FALSE,
            error          = msg,
            elapsed_sec    = NA_real_,
            n_files        = NA_integer_,
            n_data_files   = NA_integer_,
            n_agg_dirs     = NA_integer_,
            n_individual   = NA_integer_,
            n_combined     = NA_integer_,
            n_columns      = NA_integer_,
            n_source_files = NA_integer_
          )
        }
      }
    )
  }

  result <- run_once(download = DOWNLOAD)

  append_summary_row(result)
}

# ── Print summary ────────────────────────────────────────────────────────────

summary_df <- read.csv(SUMMARY_CSV, stringsAsFactors = FALSE, colClasses = c(paper_id = "character"))

cat("\n\n")
cat("╔══════════════════════════════════════════════════════════════════════╗\n")
cat("║                       BULK RUN SUMMARY                              ║\n")
cat("╚══════════════════════════════════════════════════════════════════════╝\n\n")

cat("── Per-run results ────────────────────────────────────────────────────\n")
print(summary_df[, setdiff(names(summary_df), "error")], row.names = FALSE)

n_ok   <- sum(summary_df$success)
n_fail <- nrow(summary_df) - n_ok

cat(sprintf("\n── Success rate: %d / %d  (%.0f%%)\n",
            n_ok, nrow(summary_df), 100 * n_ok / nrow(summary_df)))

if (n_fail > 0) {
  cat("\n── Failures:\n")
  fails <- summary_df[!summary_df$success, ]
  for (j in seq_len(nrow(fails))) {
    cat(sprintf("   %s — %s\n", fails$paper_id[j], fails$error[j]))
  }
}

if (n_ok > 0) {
  ok_times <- summary_df$elapsed_ms[summary_df$success] / 1000
  cat(sprintf(
    "\n── Elapsed time (successful runs):\n   mean=%.1fs  median=%.1fs  min=%.1fs  max=%.1fs\n",
    mean(ok_times), median(ok_times), min(ok_times), max(ok_times)
  ))

  ok_rows <- summary_df[summary_df$success, ]
  cat("\n── Coverage (successful runs):\n")
  cat(sprintf("   Files per paper      — mean=%.1f  median=%.1f  range=[%d,%d]\n",
              mean(ok_rows$n_files),      median(ok_rows$n_files),
              min(ok_rows$n_files),       max(ok_rows$n_files)))
  cat(sprintf("   Data files per paper — mean=%.1f  median=%.1f  range=[%d,%d]\n",
              mean(ok_rows$n_data_files), median(ok_rows$n_data_files),
              min(ok_rows$n_data_files),  max(ok_rows$n_data_files)))
  cat(sprintf("   Columns extracted    — mean=%.1f  median=%.1f  range=[%d,%d]\n",
              mean(ok_rows$n_columns),    median(ok_rows$n_columns),
              min(ok_rows$n_columns),     max(ok_rows$n_columns)))

  n_no_data <- sum(ok_rows$n_data_files == 0)
  if (n_no_data > 0) {
    cat(sprintf("\n   ⚠  %d paper(s) produced zero data files:\n", n_no_data))
    for (pid in ok_rows$paper_id[ok_rows$n_data_files == 0]) cat("      ", pid, "\n")
  }

  n_no_cols <- sum(ok_rows$n_data_files > 0 & ok_rows$n_columns == 0)
  if (n_no_cols > 0) {
    cat(sprintf("   ⚠  %d paper(s) had data files but zero columns extracted:\n", n_no_cols))
    for (pid in ok_rows$paper_id[ok_rows$n_data_files > 0 & ok_rows$n_columns == 0]) {
      cat("      ", pid, "\n")
    }
  }
}

cat("\n── Results saved to: ", SUMMARY_CSV, "\n")
