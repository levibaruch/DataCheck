# rerun_psychds_osf.R
# ─────────────────────────────────────────────────────────────────────────────
# Reprocess the PsychDS conversion stage (stage 3) ONLY, for OSF papers only.
# Picks up the latest 3_psychds_convert.R features and rewrites the converted
# datasets under PSYCHDS_OUT_DIR/<id>/.  Does NOT touch dataverse papers.
#
# Index / codebook / report stages are assumed already done — this reads the
# existing outputs/osf/<id>/ CSVs and regenerates the psychds output.
#
# Run from the project root:
#   Rscript runners/pipeline/rerun_psychds_osf.R
# ─────────────────────────────────────────────────────────────────────────────

# ── Locate project root (so relative paths resolve regardless of cwd) ─────────
args      <- commandArgs(trailingOnly = FALSE)
file_arg  <- sub("^--file=", "", args[grep("^--file=", args)])
script_dir <- if (length(file_arg) > 0) dirname(normalizePath(file_arg)) else getwd()
proj_root  <- normalizePath(file.path(script_dir, "..", ".."))
setwd(proj_root)
message("── Project root: ", proj_root)

# ── Config ────────────────────────────────────────────────────────────────────
DATA_DIR         <- "/Volumes/NINJAV/data"
OUTPUT_DIR       <- "/Volumes/NINJAV/DataCheckOut/outputs"
PSYCHDS_OUT_DIR  <- "/Volumes/NINJAV/DataCheckOut/psychds"
GROUND_TRUTH_DIR <- "./tests/ground_truth"

PSYCHDS_CSV <- file.path(PSYCHDS_OUT_DIR, "conversion_summary.csv")

# RESUME = TRUE: skip a paper whose psychds/<id>/ already has content.
# Set FALSE to force every OSF paper to re-convert.
RESUME      <- TRUE

# Skip the conversion if the paper's source data folder exceeds this (MB).
MAX_DATA_MB <- 10000

# Globals must exist before sourcing (3_psychds_convert.R reads them at load).
source("pipeline/3_psychds_convert.R")

# ── Discover OSF papers from the outputs directory ────────────────────────────
osf_out_dir <- file.path(OUTPUT_DIR, "osf")
if (!dir.exists(osf_out_dir))
  stop("No OSF outputs directory at ", osf_out_dir)

all_ids <- list.dirs(osf_out_dir, full.names = FALSE, recursive = FALSE)
all_ids <- all_ids[nzchar(all_ids)]
# Only papers that actually produced a structure.csv can be converted.
all_ids <- all_ids[file.exists(file.path(osf_out_dir, all_ids, "structure.csv"))]

n_total <- length(all_ids)
if (n_total == 0) stop("No OSF papers with structure.csv under ", osf_out_dir)
message("── ", n_total, " OSF paper(s) with index output")

# ── Helpers ───────────────────────────────────────────────────────────────────
folder_size_mb <- function(path) {
  if (!dir.exists(path)) return(0)
  files <- list.files(path, recursive = TRUE, full.names = TRUE)
  files <- files[!dir.exists(files)]
  if (length(files) == 0) return(0)
  sum(file.info(files)$size, na.rm = TRUE) / 1024^2
}

psychds_done <- function(id) {
  d <- file.path(PSYCHDS_OUT_DIR, id)
  dir.exists(d) && length(list.files(d, recursive = TRUE)) > 0
}

# ── Main loop ─────────────────────────────────────────────────────────────────
n_ok <- 0L; n_fail <- 0L; n_skip <- 0L
t0 <- proc.time()[["elapsed"]]

for (i in seq_along(all_ids)) {
  pid <- all_ids[i]

  if (RESUME && psychds_done(pid)) {
    n_skip <- n_skip + 1L
    next
  }

  mb <- folder_size_mb(file.path(DATA_DIR, "osf", pid))
  if (is.finite(MAX_DATA_MB) && mb > MAX_DATA_MB) {
    cat(sprintf("[%d/%d] %s  ✗ skipped — %.0f MB > %.0f MB limit\n",
                i, n_total, pid, mb, MAX_DATA_MB))
    n_skip <- n_skip + 1L
    next
  }

  cat(sprintf("\n[%d/%d] %s\n", i, n_total, pid))

  results <- tryCatch(
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

  append_conversion_summary(results, PSYCHDS_CSV)

  if (all(vapply(results, function(r) isTRUE(r$success), logical(1)))) {
    n_ok <- n_ok + 1L
  } else {
    n_fail <- n_fail + 1L
    errs <- unique(vapply(results, function(r)
      if (!isTRUE(r$success)) as.character(r$error) else NA_character_,
      character(1)))
    errs <- errs[!is.na(errs)]
    cat("    FAILED: ", paste(errs, collapse = "; "), "\n", sep = "")
  }
}

# ── Summary ───────────────────────────────────────────────────────────────────
elapsed <- proc.time()[["elapsed"]] - t0
cat("\n────────────────────────────────────────────────────────\n")
cat(sprintf("PsychDS rerun (OSF only): %d ok, %d failed, %d skipped  (%.1f min)\n",
            n_ok, n_fail, n_skip, elapsed / 60))
cat("Summary CSV: ", PSYCHDS_CSV, "\n", sep = "")
