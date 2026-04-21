# run_full_pipeline_bulk.R
# ─────────────────────────────────────────────────────────────────────────────
# Full pipeline bulk runner: runs index → codebook → psychds for every paper.
# Each stage is attempted per-paper before moving to the next paper, so a
# crash leaves maximally complete output rather than stranding all papers at
# stage 1.  Each stage resumes independently on restart.
# ─────────────────────────────────────────────────────────────────────────────

source("data_check/pipeline/0_index.R")
source("data_check/pipeline/2_codebook_label.R")
source("data_check/pipeline/3_psychds_convert.R")

# ── Config (mirrors run_0_index_bulk.R) ───────────────────────────────────────

DATA_DIR       <- "/Volumes/NINJAV/data"
OUTPUT_DIR     <- "/Volumes/NINJAV/DataCheckOut/outputs"
PSYCHDS_OUT_DIR <- "/Volumes/NINJAV/DataCheckOut/psychds"

FULL_RUN       <- TRUE
SKIP_COLUMNS   <- FALSE
N_RUNS         <- Inf
SEED           <- NULL
SHUFFLE        <- TRUE
DOWNLOAD       <- TRUE
FROM_LOCAL     <- TRUE
RESUME         <- TRUE

PRIORITISE_GT  <- TRUE
GT_DIR         <- "./data_check/ground_truth"

LLM_BATCH_SIZE         <- 20L
MAX_COL_TYPE_LLM_CALLS <- 5L
MAX_DATA_FILES         <- 30L
MAX_CODEBOOK_FILES     <- 10L

INDEX_CSV    <- "./data_check/results/bulk_summary.csv"
CODEBOOK_CSV <- "./data_check/results/codebook_summary.csv"
PSYCHDS_CSV  <- file.path(PSYCHDS_OUT_DIR, "conversion_summary.csv")
TRACKER_CSV  <- "./data_check/results/pipeline_tracker.csv"

MAX_DATA_MB  <- 10000   # psychds stage: skip if data folder exceeds this

# HEURISTIC = TRUE: skip a stage if its output files already exist on disk,
# regardless of whether the paper appears in the summary CSVs.  Useful for
# recovering from a messy run where outputs were written but the CSV was not.
#   Index    → structure.csv present in outputs/<source>/<id>/
#   Codebook → labels.csv present in outputs/<source>/<id>/
#   PsychDS  → any subdirectory present in psychds/<source>/<id>/
HEURISTIC <- TRUE

if (FROM_LOCAL) DOWNLOAD <- FALSE

# ── Discover papers ───────────────────────────────────────────────────────────

if (FROM_LOCAL) {
  all_papers_df <- list_downloaded_papers()
  if (is.null(all_papers_df))
    stop("No paper directories found under any source in ", DATA_DIR)
  all_ids     <- all_papers_df$paper_id
  all_sources <- all_papers_df$source
} else {
  all_ids     <- tools::file_path_sans_ext(
    list.files(XML_DIR, pattern = "\\.xml$", full.names = FALSE)
  )
  all_sources <- rep("osf", length(all_ids))
  if (length(all_ids) == 0) stop("No XML files found in ", XML_DIR)
}

# ── Backfill bulk_summary.csv run_at column if missing ────────────────────────

if (file.exists(INDEX_CSV)) {
  prior <- tryCatch(read.csv(INDEX_CSV, stringsAsFactors = FALSE,
                              colClasses = c(paper_id = "character")),
                    error = function(e) NULL)
  if (!is.null(prior) && "paper_id" %in% names(prior) &&
      !"run_at" %in% names(prior)) {
    prior <- cbind(prior[, "paper_id", drop = FALSE],
                   run_at = NA_character_,
                   prior[, setdiff(names(prior), "paper_id"), drop = FALSE])
    write.csv(prior, INDEX_CSV, row.names = FALSE)
    message("── Migrated bulk_summary.csv: added run_at column")
  }
}

# ── Determine paper order (all papers — tracker controls skipping) ─────────────

remaining_ids     <- all_ids
remaining_sources <- all_sources

if (SHUFFLE) {
  if (!is.null(SEED)) set.seed(SEED)
  ord               <- sample(length(remaining_ids))
  remaining_ids     <- remaining_ids[ord]
  remaining_sources <- remaining_sources[ord]
}

# OSF before dataverse
is_osf            <- remaining_sources == "osf"
remaining_ids     <- c(remaining_ids[is_osf],     remaining_ids[!is_osf])
remaining_sources <- c(remaining_sources[is_osf], remaining_sources[!is_osf])

if (PRIORITISE_GT) {
  gt_ids <- sub("\\.csv$", "", list.files(file.path(GT_DIR, "osf"), pattern = "\\.csv$"))
  is_gt  <- remaining_ids %in% gt_ids
  remaining_ids     <- c(remaining_ids[is_gt],     remaining_ids[!is_gt])
  remaining_sources <- c(remaining_sources[is_gt], remaining_sources[!is_gt])
  message("── GT priority: ", sum(is_gt), " GT paper(s) moved to front")
}

if (is.finite(N_RUNS) && N_RUNS < length(remaining_ids)) {
  remaining_ids     <- remaining_ids[seq_len(N_RUNS)]
  remaining_sources <- remaining_sources[seq_len(N_RUNS)]
}

n_total <- length(remaining_ids)

if (n_total == 0) {
  message("── Nothing to do — no papers discovered.")
  q(save = "no")
}

message("── Will process ", n_total, " paper(s) through full pipeline")

# ── Helpers ───────────────────────────────────────────────────────────────────

na_fallback <- function(x, na = NA) if (is.null(x) || length(x) == 0) na else x

folder_size_mb <- function(path) {
  if (!dir.exists(path)) return(0)
  files <- list.files(path, recursive = TRUE, full.names = TRUE)
  files <- files[!dir.exists(files)]
  if (length(files) == 0) return(0)
  sum(file.info(files)$size, na.rm = TRUE) / 1024^2
}

append_index_row <- function(r) {
  row <- data.frame(
    paper_id        = na_fallback(r$paper_id, NA_character_),
    run_at          = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    success         = r$success,
    error           = na_fallback(r$error, NA_character_),
    elapsed_ms      = round(na_fallback(r$elapsed_sec,  NA_real_) * 1000),
    download_ms     = round(na_fallback(r$download_sec, NA_real_) * 1000),
    llm_ms          = round(na_fallback(r$llm_sec,      NA_real_) * 1000),
    column_ms       = round(na_fallback(r$column_sec,   NA_real_) * 1000),
    n_files         = na_fallback(r$n_files,        NA_integer_),
    n_data_files    = na_fallback(r$n_data_files,   NA_integer_),
    n_tabular_files = na_fallback(r$n_tabular_files, NA_integer_),
    n_agg_dirs      = na_fallback(r$n_agg_dirs,     NA_integer_),
    n_individual    = na_fallback(r$n_individual,   NA_integer_),
    n_combined      = na_fallback(r$n_combined,     NA_integer_),
    n_columns       = na_fallback(r$n_columns,      NA_integer_),
    n_src_files     = na_fallback(r$n_source_files, NA_integer_),
    source          = na_fallback(r$source, "osf"),
    stringsAsFactors = FALSE
  )
  write_header <- !file.exists(INDEX_CSV)
  write.table(row, INDEX_CSV, append = TRUE, sep = ",",
              row.names = FALSE, col.names = write_header)
}

append_codebook_row <- function(r, elapsed_sec) {
  row <- data.frame(
    paper_id        = na_fallback(r$paper_id, NA_character_),
    success         = isTRUE(r$success),
    error           = na_fallback(r$error, NA_character_),
    elapsed_ms      = round(na_fallback(elapsed_sec, NA_real_) * 1000),
    n_labelled      = na_fallback(r$n_labelled, NA_integer_),
    n_unlabelled    = na_fallback(r$n_unlabelled, NA_integer_),
    n_codebook_vars = na_fallback(r$n_codebook_vars, NA_integer_),
    n_matched_vars  = na_fallback(r$n_matched_vars, NA_integer_),
    label_status    = na_fallback(r$label_status, NA_character_),
    stringsAsFactors = FALSE
  )
  write_header <- !file.exists(CODEBOOK_CSV)
  write.table(row, CODEBOOK_CSV, append = TRUE, sep = ",",
              row.names = FALSE, col.names = write_header)
}

already_done_codebook <- function(pid) {
  if (!file.exists(CODEBOOK_CSV)) return(FALSE)
  df <- tryCatch(
    read.csv(CODEBOOK_CSV, stringsAsFactors = FALSE,
             colClasses = c(paper_id = "character")),
    error = function(e) NULL
  )
  !is.null(df) && pid %in% df$paper_id
}

# ── Tracker helpers ───────────────────────────────────────────────────────────
# pipeline_tracker.csv: one row per paper, updated after each stage.
# Columns: paper_id, source, index, codebook, psychds
# Values:  "ok" | "fail" | "skip" | "pending"

load_tracker <- function() {
  if (!file.exists(TRACKER_CSV)) return(data.frame(
    paper_id = character(), source = character(),
    index = character(), codebook = character(), psychds = character(),
    stringsAsFactors = FALSE
  ))
  tryCatch(
    read.csv(TRACKER_CSV, stringsAsFactors = FALSE,
             colClasses = c(paper_id = "character")),
    error = function(e) data.frame(
      paper_id = character(), source = character(),
      index = character(), codebook = character(), psychds = character(),
      stringsAsFactors = FALSE
    )
  )
}

tracker_get <- function(tr, pid, stage) {
  row <- tr[tr$paper_id == pid, , drop = FALSE]
  if (nrow(row) == 0 || !stage %in% names(row)) return("pending")
  val <- row[[stage]][1]
  if (is.na(val) || val == "") "pending" else val
}

tracker_set <- function(pid, src, stage, status) {
  tr <- load_tracker()
  idx <- which(tr$paper_id == pid)
  if (length(idx) == 0) {
    tr <- rbind(tr, data.frame(
      paper_id = pid, source = src,
      index = "pending", codebook = "pending", psychds = "pending",
      stringsAsFactors = FALSE
    ))
    idx <- nrow(tr)
  }
  tr[[stage]][idx] <- status
  write.csv(tr, TRACKER_CSV, row.names = FALSE)
  invisible(tr)
}

# Scan all papers and populate tracker from disk + summary CSVs.
# Called once at startup so the loop always has authoritative state.
# Papers already in the tracker are not overwritten (their status is trusted).
init_tracker <- function(all_ids, all_sources) {
  tr <- load_tracker()

  # Load summary CSVs once
  idx_df <- tryCatch(read.csv(INDEX_CSV,    stringsAsFactors = FALSE,
                               colClasses = c(paper_id = "character")),
                      error = function(e) NULL)
  cb_df  <- tryCatch(read.csv(CODEBOOK_CSV, stringsAsFactors = FALSE,
                               colClasses = c(paper_id = "character")),
                      error = function(e) NULL)
  psy_df <- tryCatch(read.csv(PSYCHDS_CSV,  stringsAsFactors = FALSE,
                               colClasses = c(paper_id = "character")),
                      error = function(e) NULL)

  n_new <- 0L
  for (k in seq_along(all_ids)) {
    pid <- all_ids[k]
    src <- all_sources[k]
    if (pid %in% tr$paper_id) next  # already tracked — trust existing status

    # ── Index ────────────────────────────────────────────────────────────────
    idx_row <- if (!is.null(idx_df)) idx_df[idx_df$paper_id == pid, , drop = FALSE] else NULL
    idx_st <- if (!is.null(idx_row) && nrow(idx_row) > 0) {
      if (isTRUE(as.logical(idx_row$success[1]))) "ok" else "fail"
    } else if (file.exists(paper_path("outputs", src, pid, "structure.csv"))) {
      "ok"
    } else "pending"

    # ── Codebook ─────────────────────────────────────────────────────────────
    cb_row <- if (!is.null(cb_df)) cb_df[cb_df$paper_id == pid, , drop = FALSE] else NULL
    cb_st <- if (idx_st == "fail") "skip"
    else if (!is.null(cb_row) && nrow(cb_row) > 0) {
      if (isTRUE(as.logical(cb_row$success[1]))) "ok" else "fail"
    } else if (file.exists(paper_path("outputs", src, pid, "labels.csv"))) {
      "ok"
    } else if (!file.exists(paper_path("outputs", src, pid, "columns.csv"))) {
      "no_cols"
    } else "pending"

    # ── PsychDS ──────────────────────────────────────────────────────────────
    psy_rows <- if (!is.null(psy_df)) psy_df[psy_df$paper_id == pid, , drop = FALSE] else NULL
    psychds_dir <- file.path(PSYCHDS_OUT_DIR, src, pid)
    psy_st <- if (idx_st == "fail") "skip"
    else if (!is.null(psy_rows) && nrow(psy_rows) > 0) {
      if (any(as.logical(psy_rows$success) == TRUE, na.rm = TRUE)) "ok" else "fail"
    } else if (dir.exists(psychds_dir) &&
               length(list.dirs(psychds_dir, recursive = FALSE)) > 0) {
      "ok"
    } else "pending"

    tr <- rbind(tr, data.frame(
      paper_id = pid, source = src,
      index = idx_st, codebook = cb_st, psychds = psy_st,
      stringsAsFactors = FALSE
    ))
    n_new <- n_new + 1L
  }

  write.csv(tr, TRACKER_CSV, row.names = FALSE)
  message(sprintf("── Tracker: %d existing + %d newly scanned → %d total",
                  nrow(tr) - n_new, n_new, nrow(tr)))
  tr
}

already_done_psychds <- function(pid) {
  if (!file.exists(PSYCHDS_CSV)) return(FALSE)
  df <- tryCatch(
    read.csv(PSYCHDS_CSV, stringsAsFactors = FALSE,
             colClasses = c(paper_id = "character")),
    error = function(e) NULL
  )
  if (is.null(df) || nrow(df) == 0) return(FALSE)
  succeeded <- df[!is.na(df$success) & df$success == TRUE, ]
  pid %in% succeeded$paper_id
}

# ── Initialise tracker (scan all papers once before the loop) ─────────────────

init_tracker(all_ids, all_sources)

# ── Main loop ─────────────────────────────────────────────────────────────────

skip_since_last <- 0L

for (i in seq_along(remaining_ids)) {
  pid <- remaining_ids[i]
  src <- remaining_sources[i]

  tr <- load_tracker()

  idx_tracked <- tracker_get(tr, pid, "index")
  cb_tracked  <- tracker_get(tr, pid, "codebook")
  psy_tracked <- tracker_get(tr, pid, "psychds")

  # Check if all stages will skip — if so, count silently and continue
  already_indexed_q <- idx_tracked %in% c("ok", "fail") ||
    (HEURISTIC && file.exists(paper_path("outputs", src, pid, "structure.csv")))
  already_cb_q  <- cb_tracked  %in% c("ok", "fail", "no_cols", "skip", "no_columns")
  already_psy_q <- psy_tracked %in% c("ok", "fail", "skip")

  if (already_indexed_q && already_cb_q && already_psy_q) {
    skip_since_last <- skip_since_last + 1L
    next
  }

  if (skip_since_last > 0) {
    cat(sprintf("  (%d paper(s) already done \u2014 skipped)\n", skip_since_last))
    skip_since_last <- 0L
  }

  cat(col_bold(sprintf("\n\u2550\u2550 #%d / %d  \u2022  %s / %s\n", i, n_total, src, pid)))

  # ── Stage 1: Index ──────────────────────────────────────────────────────────

  needs_columns <- !SKIP_COLUMNS &&
    !file.exists(paper_path("outputs", src, pid, "columns.csv"))
  already_indexed <- !needs_columns &&
    (idx_tracked %in% c("ok", "fail") ||
     (HEURISTIC && file.exists(paper_path("outputs", src, pid, "structure.csv"))))

  index_success <- FALSE

  if (already_indexed) {
    index_success <- idx_tracked == "ok" ||
      (HEURISTIC && file.exists(paper_path("outputs", src, pid, "structure.csv")) &&
       idx_tracked != "fail")
    if (index_success) {
      struct_path <- paper_path("outputs", src, pid, "structure.csv")
      struct_df <- tryCatch(
        read.csv(struct_path, stringsAsFactors = FALSE),
        error = function(e) NULL
      )
      if (!is.null(struct_df) && all(c("type", "group") %in% names(struct_df))) {
        cat(col_cyan("── File inventory (cached) ──────────────────────\n"))
        grps <- sort(unique(struct_df$group[!is.na(struct_df$group)]))
        for (grp in grps) {
          sub    <- struct_df[!is.na(struct_df$group) & struct_df$group == grp, ]
          counts <- sort(table(sub$type), decreasing = TRUE)
          parts  <- paste(sprintf("%s\u00d7%d", names(counts), as.integer(counts)),
                          collapse = "  ")
          cat(sprintf("  %-10s  %s\n", grp, parts))
        }
      }
    }
  } else {
    cat("  ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈\n")
    cat(col_cyan("  [index]    running ...\n"))
    index_result <- tryCatch(
      run_index(paper_id = pid, download = DOWNLOAD),
      error = function(e) {
        msg <- conditionMessage(e)
        if (grepl("^empty_repo:", msg) && DOWNLOAD) {
          empty_dir <- paper_path("data", src, pid)
          if (dir.exists(empty_dir)) {
            message("  empty_repo — deleting and retrying: ", empty_dir)
            unlink(empty_dir, recursive = TRUE)
          }
          tryCatch(
            run_index(paper_id = pid, download = DOWNLOAD),
            error = function(e2) list(
              paper_id = pid, success = FALSE,
              error = conditionMessage(e2), source = src
            )
          )
        } else {
          list(paper_id = pid, success = FALSE, error = msg, source = src)
        }
      }
    )
    append_index_row(index_result)
    index_success <- isTRUE(index_result$success)
    tracker_set(pid, src, "index", if (index_success) "ok" else "fail")
    # Index re-ran — downstream stages must re-run regardless of prior status
    tracker_set(pid, src, "codebook", "pending")
    tracker_set(pid, src, "psychds",  "pending")
    if (index_success) {
      n_agg <- na_fallback(index_result$n_agg_dirs, 0L)
      cat(col_green(sprintf("  \u2514 index     \u2713  %d files%s \u00b7 %d data \u00b7 %d cols  (%.1fs)\n",
                  na_fallback(index_result$n_files, 0L),
                  if (n_agg > 0) sprintf(" (%d aggregate folder(s))", n_agg) else "",
                  na_fallback(index_result$n_data_files, 0L),
                  na_fallback(index_result$n_columns, 0L),
                  na_fallback(index_result$elapsed_sec, 0))))
    } else {
      cat(col_red(sprintf("  \u2514 index     \u2717  FAILED: %s\n",
                  na_fallback(index_result$error, "?"))))
    }
  }

  if (!index_success) {
    if (tracker_get(load_tracker(), pid, "codebook") == "pending")
      tracker_set(pid, src, "codebook", "skip")
    if (tracker_get(load_tracker(), pid, "psychds") == "pending")
      tracker_set(pid, src, "psychds", "skip")
    next
  }

  # ── Stage 2: Codebook ───────────────────────────────────────────────────────

  cb_tracked  <- tracker_get(load_tracker(), pid, "codebook")
  has_columns <- file.exists(paper_path("outputs", src, pid, "columns.csv"))
  has_labels  <- file.exists(paper_path("outputs", src, pid, "labels.csv"))

  if (!has_columns) {
    message("  [codebook] skipping — no columns.csv")
    if (cb_tracked == "pending") tracker_set(pid, src, "codebook", "no_cols")
  } else if (cb_tracked %in% c("ok", "fail") ||
             (HEURISTIC && has_labels && cb_tracked != "fail")) {
    message("  [codebook] skipping (", cb_tracked, "): ", pid)
    if (cb_tracked == "pending") tracker_set(pid, src, "codebook", "ok")
  } else {
    cat("  ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈\n")
    cat(col_yellow("  [codebook] running ...\n"))
    t_start <- proc.time()[["elapsed"]]
    cb_result <- tryCatch(
      run_codebook_label(paper_id = pid),
      error = function(e) list(
        paper_id = pid, success = FALSE, error = conditionMessage(e)
      )
    )
    elapsed <- proc.time()[["elapsed"]] - t_start
    if (is.null(cb_result$success))  cb_result$success  <- TRUE
    if (is.null(cb_result$error))    cb_result$error    <- NA_character_
    if (is.null(cb_result$paper_id)) cb_result$paper_id <- pid
    append_codebook_row(cb_result, elapsed)
    tracker_set(pid, src, "codebook", if (isTRUE(cb_result$success)) "ok" else "fail")
    # Codebook re-ran — psychds must re-run too
    tracker_set(pid, src, "psychds", "pending")
    if (isTRUE(cb_result$success)) {
      n_lab <- na_fallback(cb_result$n_labelled, 0L)
      n_tot <- na_fallback(cb_result$n_labelled + cb_result$n_unlabelled, 0L)
      pct   <- if (n_tot > 0) round(100 * n_lab / n_tot) else 0L
      cat(col_green(sprintf("  \u2514 codebook  \u2713  %d / %d cols labelled (%d%%)  (%.1fs)\n",
                  n_lab, n_tot, pct, elapsed)))
    } else {
      cat(col_red(sprintf("  \u2514 codebook  \u2717  FAILED: %s\n",
                  na_fallback(cb_result$error, "?"))))
    }
  }

  # ── Stage 3: PsychDS ────────────────────────────────────────────────────────

  psy_tracked       <- tracker_get(load_tracker(), pid, "psychds")
  psychds_paper_dir <- file.path(PSYCHDS_OUT_DIR, src, pid)
  has_psychds_dir   <- dir.exists(psychds_paper_dir) &&
                       length(list.dirs(psychds_paper_dir, recursive = FALSE)) > 0

  if (psy_tracked %in% c("ok", "fail") ||
      (HEURISTIC && has_psychds_dir && psy_tracked != "fail")) {
    if (psy_tracked == "pending") tracker_set(pid, src, "psychds", "ok")
  } else {
    if (is.finite(MAX_DATA_MB)) {
      mb <- folder_size_mb(paper_path("data", src, pid))
      if (mb > MAX_DATA_MB) {
        cat(col_red(sprintf("  \u2514 psychds   \u2717  skipped \u2014 %.1f MB > %.0f MB limit\n",
                    mb, MAX_DATA_MB)))
        next
      }
    }
    cat("  ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈\n")
    cat(col_magenta("  [psychds]  running ...\n"))
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
    append_conversion_summary(psychds_results, PSYCHDS_CSV)
    psy_ok <- all(vapply(psychds_results, function(r) isTRUE(r$success), logical(1)))
    tracker_set(pid, src, "psychds", if (psy_ok) "ok" else "fail")
    if (psy_ok) {
      cat(col_green(sprintf("  \u2514 psychds   \u2713  done\n")))
    } else {
      failed_errs <- vapply(psychds_results, function(r)
        if (!isTRUE(r$success)) na_fallback(r$error, "?") else NA_character_,
        character(1))
      failed_errs <- failed_errs[!is.na(failed_errs)]
      cat(col_red(sprintf("  \u2514 psychds   \u2717  FAILED: %s\n",
                          paste(unique(failed_errs), collapse = "; "))))
    }
  }

  # ── Output file paths ────────────────────────────────────────────────────────
  out_base <- paper_path("outputs", src, pid)
  out_files <- c(
    structure = file.path(out_base, "structure.csv"),
    columns   = file.path(out_base, "columns.csv"),
    labels    = file.path(out_base, "labels.csv"),
    coverage  = file.path(out_base, "codebook_coverage.csv")
  )
  existing <- out_files[file.exists(out_files)]
  if (length(existing) > 0) {
    cat(col_dim("  \u2514 outputs:\n"))
    for (nm in names(existing))
      cat(col_dim(sprintf("      %-10s %s\n", nm, existing[[nm]])))
  }
}

# Flush any remaining skip counter after the loop
if (skip_since_last > 0)
  cat(sprintf("  (%d paper(s) already done \u2014 skipped)\n", skip_since_last))

# ── Final summary ─────────────────────────────────────────────────────────────

cat("\n\n")
cat("╔══════════════════════════════════════════════════════════════════════╗\n")
cat("║                    FULL PIPELINE BULK SUMMARY                       ║\n")
cat("╚══════════════════════════════════════════════════════════════════════╝\n\n")

print_summary <- function(path, label, extras = NULL) {
  if (!file.exists(path)) { cat(sprintf("── %s: no results file found\n", label)); return() }
  df    <- tryCatch(read.csv(path, stringsAsFactors = FALSE,
                              colClasses = c(paper_id = "character")),
                    error = function(e) NULL)
  if (is.null(df)) { cat(sprintf("── %s: could not read results\n", label)); return() }
  n_ok   <- sum(as.logical(df$success), na.rm = TRUE)
  n_fail <- nrow(df) - n_ok
  cat(sprintf("── %s: %d / %d succeeded (%.0f%%)\n",
              label, n_ok, nrow(df), 100 * n_ok / max(nrow(df), 1)))
  if (!is.null(extras)) extras(df)
  if (n_fail > 0) {
    fails <- df[!as.logical(df$success) %in% TRUE, ]
    for (j in seq_len(min(nrow(fails), 10))) {
      cat(sprintf("   FAIL  %s \u2014 %s\n",
                  fails$paper_id[j],
                  if ("error" %in% names(fails)) fails$error[j] else "?"))
    }
  }
}

print_summary(INDEX_CSV, "Index (bulk_summary.csv)", extras = function(df) {
  if ("n_files"      %in% names(df)) cat(sprintf("   total files      : %s\n",   format(sum(df$n_files,      na.rm=TRUE), big.mark=",")))
  if ("n_columns"    %in% names(df)) cat(sprintf("   total columns    : %s\n",   format(sum(df$n_columns,    na.rm=TRUE), big.mark=",")))
  if ("n_individual" %in% names(df)) cat(sprintf("   individual files : %s\n",   format(sum(df$n_individual, na.rm=TRUE), big.mark=",")))
  if ("n_combined"   %in% names(df)) cat(sprintf("   combined files   : %s\n",   format(sum(df$n_combined,   na.rm=TRUE), big.mark=",")))
  if ("elapsed_ms"   %in% names(df)) cat(sprintf("   avg elapsed      : %.1fs / paper\n", mean(df$elapsed_ms/1000, na.rm=TRUE)))
})

print_summary(CODEBOOK_CSV, "Codebook (codebook_summary.csv)", extras = function(df) {
  has_cb <- df[!is.na(df$n_labelled) & !is.na(df$n_unlabelled), ]
  if (nrow(has_cb) > 0) {
    tot_lab <- sum(has_cb$n_labelled)
    tot_all <- sum(has_cb$n_labelled + has_cb$n_unlabelled)
    if (tot_all > 0)
      cat(sprintf("   overall label rate: %.0f%%  (%s / %s cols)\n",
                  100 * tot_lab / tot_all,
                  format(tot_lab, big.mark=","), format(tot_all, big.mark=",")))
  }
})

print_summary(PSYCHDS_CSV, "PsychDS (conversion_summary.csv)")

cat("\n── Done.\n")
