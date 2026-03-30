# run_tests.R
# ─────────────────────────────────────────────────────────────────────────────
# Runs the full pipeline (index → codebook label → psychds) on the hard-dataset
# index (docs/hard-datasets.md) and prints structured output for manual review.
# No assertions — all output is for human inspection.
#
# All papers must already be downloaded (data_check/data/<paper_id>/).
# Outputs are written to:
#   data_check/tests/outputs/<paper_id>/     (stages 1 & 2)
#   data_check/tests/psychds/<paper_id>/     (stage 3)
#   data_check/tests/test_log.csv            (one row per paper, appended each run)
#
# Usage (interactive):  source("data_check/runners/run_tests.R")
# Usage (CLI):          Rscript data_check/runners/run_tests.R
# ─────────────────────────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

source("data_check/pipeline/0_index.R")
source("data_check/pipeline/2_codebook_label.R")
source("data_check/pipeline/3_psychds_convert.R")

TEST_DIR         <- "./data_check/tests"
TEST_OUTPUT_DIR  <- file.path(TEST_DIR, "outputs")
TEST_PSYCHDS_DIR <- file.path(TEST_DIR, "psychds")
TEST_LOG_PATH    <- file.path(TEST_DIR, "test_log.csv")

dir.create(TEST_OUTPUT_DIR,  recursive = TRUE, showWarnings = FALSE)
dir.create(TEST_PSYCHDS_DIR, recursive = TRUE, showWarnings = FALSE)

# ── Test papers ────────────────────────────────────────────────────────────────

TEST_PAPERS <- list(

  # ── Baselines ────────────────────────────────────────────────────────────────
  list(id = "0956797615620784",
       label = "baseline — GambleWalker (1 CSV + RTF codebook + R script)"),
  list(id = "0956797614523297",
       label = "baseline — 2 clean CSVs, ex1/ex2 groups, no codebook"),
  list(id = "0956797614559543",
       label = "baseline — readme.txt codebook, all-continuous columns"),

  # ── Column type detection ────────────────────────────────────────────────────
  list(id = "0956797614536738",
       label = "col_type: numeric ID columns — risk of unknown instead of id"),
  list(id = "0956797614557867",
       label = "col_type: alphanumeric IDs + 2 codebook files"),

  # ── Multilevel / messy CSV headers ──────────────────────────────────────────
  list(id = "0956797614533802",
       label = "multilevel headers + comma decimals + parentheses in filenames"),
  list(id = "0956797614534695",
       label = "comma decimals + multi-experiment CSV"),

  # ── Multi-study / multi-format ───────────────────────────────────────────────
  list(id = "0956797614524581",
       label = "multi-study (ex1/ex2/ex3) + CSV+SAV mix + DOCX codebook"),
  list(id = "0956797614553121",
       label = "multi-format: 10 data files + 6 codebook files across populations"),

  # ── Codebook classification ──────────────────────────────────────────────────
  list(id = "0956797614543801",
       label = "codebook: 5 codebook files + 7 data files + LIWC output columns"),
  list(id = "0956797614559730",
       label = "codebook: CSV codebook in same folder as data — misclassification risk"),

  # ── Per-participant file structure ───────────────────────────────────────────
  list(id = "0956797614547916",
       label = "per-participant: 142 .dat files across 8 experiment groups"),

  # ── Large repos ──────────────────────────────────────────────────────────────
  list(id = "0956797614561045",
       label = "large: 99 data files + 1 codebook — near too_large limit")
)

# ── Log ────────────────────────────────────────────────────────────────────────
# One row per paper. Written immediately after each paper completes.

LOG_COLS <- c(
  "run_id", "paper_id", "label",
  # per-stage success / error
  "index_success",   "index_error",
  "codebook_success", "codebook_error",
  "psychds_success",  "psychds_error",
  # index metrics
  "n_files", "n_data_files", "n_columns", "n_agg_dirs",
  "file_types", "data_groups", "col_types",
  "index_elapsed_sec",
  # codebook metrics
  "label_status", "n_labelled", "n_unlabelled", "coverage",
  "codebook_elapsed_sec",
  # psychds metrics (summarised across study groups)
  "psychds_studies", "psychds_vars", "psychds_labelled",
  "psychds_elapsed_sec"
)

write_log_row <- function(row) {
  for (col in LOG_COLS) if (is.null(row[[col]])) row[[col]] <- NA_character_
  df <- as.data.frame(row, stringsAsFactors = FALSE)[, LOG_COLS]
  write.table(df,
    file      = TEST_LOG_PATH,
    sep       = ",",
    col.names = !file.exists(TEST_LOG_PATH),
    row.names = FALSE,
    append    = TRUE,
    qmethod   = "double"
  )
}

tbl_str <- function(tbl) {
  if (length(tbl) == 0) return("")
  paste(sprintf("%s=%d", names(tbl), as.integer(tbl)), collapse = " ")
}

tbl_json <- function(tbl) {
  if (length(tbl) == 0) return("{}")
  pairs <- paste(sprintf('"%s":%d', names(tbl), as.integer(tbl)), collapse = ",")
  sprintf("{%s}", pairs)
}

# ── Display helpers ────────────────────────────────────────────────────────────

divider   <- paste0(rep("─", 72), collapse = "")
divider_h <- paste0(rep("═", 72), collapse = "")

# ── PsychDS helper ─────────────────────────────────────────────────────────────

# convert_psychds reads from the hardcoded path ./data_check/outputs/<paper_id>.
# A temporary symlink bridges test outputs to that location when needed.
run_psychds_test <- function(pid) {
  test_dir <- normalizePath(file.path(TEST_OUTPUT_DIR, pid), mustWork = TRUE)
  prod_dir <- file.path("./data_check/outputs", pid)

  used_symlink <- FALSE
  if (!file.exists(prod_dir)) {
    if (!file.symlink(test_dir, prod_dir)) {
      cat("  [psychds] could not symlink test outputs — skipped\n")
      return(list(success = FALSE, error = "symlink_failed"))
    }
    used_symlink <- TRUE
  }

  old_psychds_dir <- PSYCHDS_OUT_DIR
  PSYCHDS_OUT_DIR <<- TEST_PSYCHDS_DIR

  t_start <- proc.time()[["elapsed"]]
  results <- tryCatch(
    convert_psychds(pid),
    error = function(e) list(list(success = FALSE, error = conditionMessage(e),
                                  study_group = "all"))
  )
  elapsed <- round(proc.time()[["elapsed"]] - t_start, 1)

  PSYCHDS_OUT_DIR <<- old_psychds_dir
  if (used_symlink) unlink(prod_dir)

  n_ok   <- 0L
  n_fail <- 0L
  errors <- character(0)
  total_vars     <- 0L
  total_labelled <- 0L

  for (r in results) {
    sg <- r$study_group %||% "?"
    if (!isTRUE(r$success)) {
      n_fail <- n_fail + 1L
      errors <- c(errors, sprintf("%s:%s", sg, r$error %||% "unknown"))
      cat(sprintf("  [psychds] %-10s  ERROR: %s\n", sg, r$error %||% "unknown"))
    } else {
      n_ok <- n_ok + 1L
      total_vars     <- total_vars     + (r$n_variables %||% 0L)
      total_labelled <- total_labelled + (r$n_labelled  %||% 0L)
      cat(sprintf(
        "  [psychds] %-10s  data=%d  raw=%d  vars=%d  labelled=%d  meta=%s  gt=%s\n",
        sg,
        r$n_data_files %||% 0L, r$n_raw_files %||% 0L,
        r$n_variables  %||% 0L, r$n_labelled  %||% 0L,
        if (isTRUE(r$has_paper_metadata)) "GROBID" else "fallback",
        if (isTRUE(r$has_ground_truth))   "yes"    else "no"
      ))
    }
  }

  cat(sprintf("  [psychds] elapsed=%.1fs\n", elapsed))

  list(
    success        = n_fail == 0L,
    error          = if (length(errors) > 0) paste(errors, collapse = "; ") else NA,
    studies        = sprintf("ok=%d fail=%d", n_ok, n_fail),
    total_vars     = total_vars,
    total_labelled = total_labelled,
    elapsed        = elapsed
  )
}

# ── Main loop ──────────────────────────────────────────────────────────────────

RUN_ID <- format(Sys.time(), "%Y-%m-%d_%H-%M-%S")

cat(sprintf("\n%s\n  TEST RUN %s — %d papers\n%s\n",
  divider_h, RUN_ID, length(TEST_PAPERS), divider_h))

for (tp in TEST_PAPERS) {
  pid         <- tp$id
  label       <- tp$label
  pid_out_dir <- file.path(TEST_OUTPUT_DIR, pid)

  cat(sprintf("\n%s\n  %s\n  %s\n%s\n", divider, pid, label, divider))

  row <- list(run_id = RUN_ID, paper_id = pid, label = label)

  # ── Stage 1: index ─────────────────────────────────────────────────────────
  cat("Stage 1: index\n")

  t_start <- proc.time()[["elapsed"]]
  s1 <- tryCatch(
    run_index(paper_id = pid, download = FALSE, output_dir = pid_out_dir),
    error = function(e) list(success = FALSE, error = conditionMessage(e))
  )
  row$index_elapsed_sec <- round(proc.time()[["elapsed"]] - t_start, 1)

  if (!isTRUE(s1$success)) {
    cat(sprintf("  ERROR: %s\n", s1$error))
    row$index_success   <- FALSE
    row$index_error     <- s1$error
    row$codebook_success <- FALSE
    row$codebook_error   <- "skipped_index_failed"
    row$psychds_success  <- FALSE
    row$psychds_error    <- "skipped_index_failed"
    write_log_row(row)
    next
  }

  type_tbl  <- sort(table(s1$file_df$type), decreasing = TRUE)
  group_tbl <- sort(table(s1$file_df$group[s1$file_df$type == "data"]),
                    decreasing = TRUE)
  ct_tbl    <- if (!is.null(s1$columns_df) && nrow(s1$columns_df) > 0)
    sort(table(s1$columns_df$col_type), decreasing = TRUE) else table(character(0))

  cat(sprintf("  files=%d  data=%d  columns=%d  agg_dirs=%d  elapsed=%.1fs\n",
    s1$n_files, s1$n_data_files, s1$n_columns,
    s1$n_agg_dirs %||% 0L, row$index_elapsed_sec))
  cat(sprintf("  file types:  %s\n", tbl_str(type_tbl)))
  cat(sprintf("  data groups: %s\n", tbl_str(group_tbl)))
  if (!is.null(s1$columns_df) && nrow(s1$columns_df) > 0)
    cat(sprintf("  col_types:   %s\n", tbl_str(ct_tbl)))

  row$index_success <- TRUE
  row$n_files       <- s1$n_files
  row$n_data_files  <- s1$n_data_files
  row$n_columns     <- s1$n_columns
  row$n_agg_dirs    <- s1$n_agg_dirs %||% 0L
  row$file_types    <- tbl_json(type_tbl)
  row$data_groups   <- tbl_json(group_tbl)
  row$col_types     <- tbl_json(ct_tbl)

  # ── Stage 2: codebook label ────────────────────────────────────────────────
  cat("Stage 2: codebook label\n")

  if (!file.exists(file.path(pid_out_dir, "columns.csv"))) {
    cat("  skipped — no columns.csv\n")
    row$codebook_success <- TRUE
    row$label_status     <- "skipped_no_columns"
  } else {
    t_start <- proc.time()[["elapsed"]]
    s2 <- tryCatch(
      run_codebook_label(paper_id = pid, output_dir = pid_out_dir),
      error = function(e) list(success = FALSE, error = conditionMessage(e))
    )
    row$codebook_elapsed_sec <- round(proc.time()[["elapsed"]] - t_start, 1)

    if (is.null(s2$label_status)) {
      # tryCatch error handler returns list(success=FALSE, error=msg) — no label_status
      cat(sprintf("  ERROR: %s\n", s2$error %||% "unknown"))
      row$codebook_success <- FALSE
      row$codebook_error   <- s2$error %||% "unknown"
    } else {
      cov_str <- ""
      cov_path <- file.path(pid_out_dir, "codebook_coverage.csv")
      if (file.exists(cov_path)) {
        cov_df  <- read.csv(cov_path, stringsAsFactors = FALSE,
                            colClasses = c(paper_id = "character"))
        cov_tbl <- sort(table(cov_df$match_status), decreasing = TRUE)
        cov_str <- tbl_json(cov_tbl)
        cat(sprintf("  coverage:    %s\n", cov_str))
      }
      cat(sprintf("  status=%-12s  labelled=%s  unlabelled=%s  elapsed=%.1fs\n",
        s2$label_status %||% "NA",
        s2$n_labelled   %||% "NA",
        s2$n_unlabelled %||% "NA",
        row$codebook_elapsed_sec))

      row$codebook_success <- TRUE
      row$label_status     <- s2$label_status %||% NA
      row$n_labelled       <- s2$n_labelled   %||% NA
      row$n_unlabelled     <- s2$n_unlabelled %||% NA
      row$coverage         <- cov_str
    }
  }

  # ── Stage 3: psychds ───────────────────────────────────────────────────────
  cat("Stage 3: psychds\n")
  p3 <- run_psychds_test(pid)

  row$psychds_success  <- p3$success
  row$psychds_error    <- p3$error
  row$psychds_studies  <- p3$studies
  row$psychds_vars     <- p3$total_vars
  row$psychds_labelled <- p3$total_labelled
  row$psychds_elapsed_sec <- p3$elapsed

  write_log_row(row)
}

cat(sprintf("\n%s\n  Done  [%s]\n  outputs: %s\n  psychds: %s\n  log:     %s\n%s\n\n",
  divider_h, RUN_ID,
  TEST_OUTPUT_DIR, TEST_PSYCHDS_DIR, TEST_LOG_PATH,
  divider_h))
