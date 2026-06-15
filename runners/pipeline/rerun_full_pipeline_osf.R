# rerun_full_pipeline_osf.R
# ─────────────────────────────────────────────────────────────────────────────
# Re-run the FULL pipeline (index → codebook → psychds → report) for OSF papers
# ONLY.  Dataverse papers are never touched.
#
#   • LLM model:        groq/openai/gpt-oss-120b
#   • Structure prompt: "json"  (STRUCTURE_PROMPT_JSON variant)
#
# Data is read from local disk (no download).  Outputs are written fresh; with
# RESUME = TRUE a stage is skipped only when its output file already exists, so a
# crash can be resumed.  Delete outputs/osf/<id>/ (and psychds/<id>/) beforehand
# to force a clean rebuild.
#
# Requires GROQ_API_KEY in the environment (read at runtime; never printed).
#
# Run from the project root:
#   Rscript runners/pipeline/rerun_full_pipeline_osf.R
# ─────────────────────────────────────────────────────────────────────────────

# ── Locate project root so relative paths resolve regardless of cwd ───────────
args       <- commandArgs(trailingOnly = FALSE)
file_arg   <- sub("^--file=", "", args[grep("^--file=", args)])
script_dir <- if (length(file_arg) > 0) dirname(normalizePath(file_arg)) else getwd()
proj_root  <- normalizePath(file.path(script_dir, "..", ".."))
setwd(proj_root)
message("── Project root: ", proj_root)

if (!nzchar(Sys.getenv("GROQ_API_KEY")))
  stop("GROQ_API_KEY not set in environment — add it to ~/.Renviron and restart R")

# ── Config ────────────────────────────────────────────────────────────────────
DATA_DIR         <- "/Volumes/NINJAV/data"
OUTPUT_DIR       <- "/Volumes/NINJAV/DataCheckOut/outputs"
PSYCHDS_OUT_DIR  <- "/Volumes/NINJAV/DataCheckOut/psychds"
GROUND_TRUTH_DIR <- "./tests/ground_truth"

# LLM settings — MUST be defined before sourcing 0_index.R (it calls
# llm_model(LLM_MODEL) at load time).
LLM_MODEL                <- "groq/openai/gpt-oss-120b"
STRUCTURE_PROMPT_VERSION <- "json"

FULL_RUN         <- TRUE
CAPTURE_THINKING <- TRUE
DOWNLOAD         <- FALSE   # data is already on local disk
# RESUME = TRUE : skip a stage when its output file already exists (crash-resume)
# RESUME = FALSE: re-run EVERY stage, overwriting old output (clean rerun)
RESUME           <- TRUE

MAX_DATA_MB <- 10000        # psychds: skip if data folder exceeds this (MB)

# Skip a paper whose structure classification would need more than this many LLM
# calls (Phase 1 + Phase 2). Guards against giant repos (e.g. 45k distinct files →
# 1500+ batches). The paper is logged with a too_large error and the loop moves on.
MAX_LLM_CALLS <- 100

# Summary CSVs
INDEX_CSV    <- "./results/bulk_summary.csv"
CODEBOOK_CSV <- "./results/codebook_summary.csv"
PSYCHDS_CSV  <- file.path(PSYCHDS_OUT_DIR, "conversion_summary.csv")
REPORT_CSV   <- "./results/report_summary.csv"

dir.create("results", showWarnings = FALSE)

# ── Source pipeline stages (LLM_MODEL already set) ────────────────────────────
source("pipeline/0_index.R")
source("pipeline/2_codebook_label.R")
source("pipeline/3_psychds_convert.R")
source("pipeline/4_report.R")

message("── LLM model: ", LLM_MODEL, "  · structure prompt: ", STRUCTURE_PROMPT_VERSION)

# ── Discover OSF papers from local data ───────────────────────────────────────
osf_data_dir <- file.path(DATA_DIR, "osf")
if (!dir.exists(osf_data_dir)) stop("No OSF data directory at ", osf_data_dir)
all_ids <- list.dirs(osf_data_dir, full.names = FALSE, recursive = FALSE)
all_ids <- all_ids[nzchar(all_ids)]
n_total <- length(all_ids)
if (n_total == 0) stop("No OSF paper directories under ", osf_data_dir)
message("── ", n_total, " OSF paper(s) to process")

# On a clean rerun (RESUME = FALSE) start the per-stage summary CSVs fresh so old
# rows are not appended to. conversion_summary.csv is left alone: it may hold
# dataverse rows and append_conversion_summary() already replaces per-paper rows.
if (!RESUME) {
  for (p in c(INDEX_CSV, CODEBOOK_CSV, REPORT_CSV))
    if (file.exists(p)) {
      file.remove(p)
      message("── reset summary: ", p)
    }
}

# ── Small helpers ─────────────────────────────────────────────────────────────
na_fallback <- function(x, na = NA) if (is.null(x) || length(x) == 0) na else x

folder_size_mb <- function(path) {
  if (!dir.exists(path)) return(0)
  files <- list.files(path, recursive = TRUE, full.names = TRUE)
  files <- files[!dir.exists(files)]
  if (length(files) == 0) return(0)
  sum(file.info(files)$size, na.rm = TRUE) / 1024^2
}

append_row <- function(path, row) {
  write.table(row, path, append = file.exists(path), sep = ",",
              row.names = FALSE, col.names = !file.exists(path),
              quote = TRUE, fileEncoding = "UTF-8")
}

append_index_row <- function(r) {
  append_row(INDEX_CSV, data.frame(
    paper_id        = na_fallback(r$paper_id, NA_character_),
    run_at          = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    success         = isTRUE(r$success),
    error           = na_fallback(r$error, NA_character_),
    elapsed_ms      = round(na_fallback(r$elapsed_sec,  NA_real_) * 1000),
    download_ms     = round(na_fallback(r$download_sec, NA_real_) * 1000),
    llm_ms          = round(na_fallback(r$llm_sec,      NA_real_) * 1000),
    column_ms       = round(na_fallback(r$column_sec,   NA_real_) * 1000),
    n_files         = na_fallback(r$n_files,         NA_integer_),
    n_data_files    = na_fallback(r$n_data_files,    NA_integer_),
    n_tabular_files = na_fallback(r$n_tabular_files,  NA_integer_),
    n_agg_dirs      = na_fallback(r$n_agg_dirs,      NA_integer_),
    n_individual    = na_fallback(r$n_individual,    NA_integer_),
    n_combined      = na_fallback(r$n_combined,      NA_integer_),
    n_columns       = na_fallback(r$n_columns,       NA_integer_),
    n_src_files     = na_fallback(r$n_source_files,  NA_integer_),
    source          = na_fallback(r$source, "osf"),
    stringsAsFactors = FALSE))
}

append_codebook_row <- function(r, elapsed_sec) {
  append_row(CODEBOOK_CSV, data.frame(
    paper_id        = na_fallback(r$paper_id, NA_character_),
    success         = isTRUE(r$success),
    error           = na_fallback(r$error, NA_character_),
    elapsed_ms      = round(na_fallback(elapsed_sec, NA_real_) * 1000),
    n_labelled      = na_fallback(r$n_labelled, NA_integer_),
    n_unlabelled    = na_fallback(r$n_unlabelled, NA_integer_),
    n_codebook_vars = na_fallback(r$n_codebook_vars, NA_integer_),
    n_matched_vars  = na_fallback(r$n_matched_vars, NA_integer_),
    label_status    = na_fallback(r$label_status, NA_character_),
    stringsAsFactors = FALSE))
}

append_report_row <- function(r, elapsed_sec) {
  append_row(REPORT_CSV, data.frame(
    paper_id        = na_fallback(r$paper_id, NA_character_),
    success         = isTRUE(r$success),
    error           = na_fallback(r$error, NA_character_),
    elapsed_ms      = round(na_fallback(elapsed_sec, NA_real_) * 1000),
    n_files         = na_fallback(r$n_files, NA_integer_),
    n_columns       = na_fallback(r$n_columns, NA_integer_),
    n_labelled      = na_fallback(r$n_labelled, NA_integer_),
    n_codebook_vars = na_fallback(r$n_codebook_vars, NA_integer_),
    stringsAsFactors = FALSE))
}

opath <- function(id, f) paper_path("outputs", "osf", id, f)

# ── Main loop ─────────────────────────────────────────────────────────────────
n_idx_ok <- 0L; n_cb_ok <- 0L; n_psy_ok <- 0L; n_rep_ok <- 0L
t0 <- proc.time()[["elapsed"]]

for (i in seq_along(all_ids)) {
  pid <- all_ids[i]
  cat(sprintf("\n══ [%d/%d] osf / %s ══════════════════════════════════\n",
              i, n_total, pid))

  # ── Stage 1: Index ──────────────────────────────────────────────────────────
  index_ok <- RESUME && file.exists(opath(pid, "structure.csv"))
  if (index_ok) {
    cat("  [index]    cached\n")
  } else {
    cat("  [index]    running ...\n")
    res <- tryCatch(
      run_index(paper_id = pid, download = DOWNLOAD,
                structure_prompt_version = STRUCTURE_PROMPT_VERSION),
      error = function(e) list(paper_id = pid, success = FALSE,
                               error = conditionMessage(e), source = "osf"))
    append_index_row(res)
    index_ok <- isTRUE(res$success)
    cat(if (index_ok) sprintf("  [index]    ✓  %s files · %s cols\n",
                              na_fallback(res$n_files, "?"), na_fallback(res$n_columns, "?"))
        else sprintf("  [index]    ✗  %s\n", na_fallback(res$error, "?")))
  }
  if (index_ok) n_idx_ok <- n_idx_ok + 1L
  if (!index_ok) next

  # ── Stage 2: Codebook ───────────────────────────────────────────────────────
  has_columns <- file.exists(opath(pid, "columns.csv"))
  if (!has_columns) {
    cat("  [codebook] skip — no columns.csv\n")
  } else if (RESUME && file.exists(opath(pid, "labels.csv"))) {
    cat("  [codebook] cached\n"); n_cb_ok <- n_cb_ok + 1L
  } else {
    cat("  [codebook] running ...\n")
    t <- proc.time()[["elapsed"]]
    res <- tryCatch(run_codebook_label(paper_id = pid),
                    error = function(e) list(paper_id = pid, success = FALSE,
                                             error = conditionMessage(e)))
    if (is.null(res$success)) res$success <- TRUE
    append_codebook_row(res, proc.time()[["elapsed"]] - t)
    if (isTRUE(res$success)) n_cb_ok <- n_cb_ok + 1L
    cat(if (isTRUE(res$success)) sprintf("  [codebook] ✓  %s labelled\n", na_fallback(res$n_labelled, "?"))
        else sprintf("  [codebook] ✗  %s\n", na_fallback(res$error, "?")))
  }

  # ── Stage 3: PsychDS ────────────────────────────────────────────────────────
  psy_dir   <- file.path(PSYCHDS_OUT_DIR, pid)
  psy_cached <- RESUME && dir.exists(psy_dir) &&
                length(list.files(psy_dir, recursive = TRUE)) > 0
  if (psy_cached) {
    cat("  [psychds]  cached\n"); n_psy_ok <- n_psy_ok + 1L
  } else {
    mb <- folder_size_mb(file.path(DATA_DIR, "osf", pid))
    if (is.finite(MAX_DATA_MB) && mb > MAX_DATA_MB) {
      cat(sprintf("  [psychds]  ✗  skipped — %.0f MB > %.0f MB\n", mb, MAX_DATA_MB))
    } else {
      cat("  [psychds]  running ...\n")
      res <- tryCatch(convert_psychds(pid),
                      error = function(e) list(list(
                        paper_id = pid, study_group = "all", success = FALSE,
                        error = conditionMessage(e), n_data_files = 0L,
                        n_raw_files = 0L, n_variables = 0L, n_labelled = 0L,
                        has_paper_metadata = FALSE, has_ground_truth = FALSE,
                        output_path = NA_character_)))
      append_conversion_summary(res, PSYCHDS_CSV)
      if (all(vapply(res, function(r) isTRUE(r$success), logical(1)))) {
        n_psy_ok <- n_psy_ok + 1L
        cat("  [psychds]  ✓  done\n")
      } else {
        errs <- unique(vapply(res, function(r)
          if (!isTRUE(r$success)) as.character(r$error) else NA_character_, character(1)))
        cat("  [psychds]  ✗  ", paste(errs[!is.na(errs)], collapse = "; "), "\n", sep = "")
      }
    }
  }

  # ── Stage 4: Report ─────────────────────────────────────────────────────────
  if (RESUME && file.exists(opath(pid, "report.html"))) {
    cat("  [report]   cached\n"); n_rep_ok <- n_rep_ok + 1L
  } else {
    cat("  [report]   running ...\n")
    t <- proc.time()[["elapsed"]]
    res <- tryCatch(run_report(pid, "osf"),
                    error = function(e) list(success = FALSE,
                                             error = conditionMessage(e), paper_id = pid))
    append_report_row(res, proc.time()[["elapsed"]] - t)
    if (isTRUE(res$success)) {
      n_rep_ok <- n_rep_ok + 1L
      cat("  [report]   ✓  report.html\n")
    } else {
      cat(sprintf("  [report]   ✗  %s\n", na_fallback(res$error, "?")))
    }
  }
}

# ── Summary ───────────────────────────────────────────────────────────────────
elapsed <- proc.time()[["elapsed"]] - t0
cat("\n────────────────────────────────────────────────────────\n")
cat(sprintf("Full pipeline rerun (OSF, %s, %s prompt)\n",
            LLM_MODEL, STRUCTURE_PROMPT_VERSION))
cat(sprintf("  index    ok: %d / %d\n", n_idx_ok, n_total))
cat(sprintf("  codebook ok: %d\n", n_cb_ok))
cat(sprintf("  psychds  ok: %d\n", n_psy_ok))
cat(sprintf("  report   ok: %d\n", n_rep_ok))
cat(sprintf("  elapsed:     %.1f min\n", elapsed / 60))
