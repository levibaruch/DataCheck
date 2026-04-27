# run_local_folder.R
# ─────────────────────────────────────────────────────────────────────────────
# Run the full pipeline on a local folder (no OSF / Dataverse download).
#
# Usage: set the three paths below, then source() or Run this file.
# OUTPUT_FOLDER and PSYCHDS_FOLDER will be created if they do not exist.
# ─────────────────────────────────────────────────────────────────────────────

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

# ── Configure these paths before running ──────────────────────────────────────

USER <- "levi"

INPUT_FOLDER   <- file.path("data_check/user_tests/repos",   USER)
OUTPUT_FOLDER  <- file.path("data_check/user_tests/outputs", USER)
PSYCHDS_FOLDER <- file.path("data_check/user_tests/outputs", USER)

INPUT_FOLDER   <- normalizePath(INPUT_FOLDER,   mustWork = TRUE)
OUTPUT_FOLDER  <- normalizePath(OUTPUT_FOLDER,  mustWork = FALSE)
PSYCHDS_FOLDER <- normalizePath(PSYCHDS_FOLDER, mustWork = FALSE)

# The folder name becomes the paper_id.  paper_path() builds paths as:
#   <ROOT>/<source>/<paper_id>/
# So we set DATA_DIR, OUTPUT_DIR, and PSYCHDS_OUT_DIR to a single staging root
# under OUTPUT_FOLDER, then the actual outputs land at:
#   <OUTPUT_FOLDER>/outputs/osf/<folder_name>/   ← CSVs
#   <OUTPUT_FOLDER>/psychds/osf/<folder_name>/   ← PsychDS
#   <OUTPUT_FOLDER>/data/osf/<folder_name>/      ← symlink to INPUT_FOLDER (read-only)
FOLDER_NAME <- basename(INPUT_FOLDER)

# ── Pipeline globals ───────────────────────────────────────────────────────────

FULL_RUN         <- TRUE
DATA_DIR         <- file.path(OUTPUT_FOLDER, "data")
OUTPUT_DIR       <- file.path(OUTPUT_FOLDER, "outputs")
PSYCHDS_OUT_DIR  <- file.path(PSYCHDS_FOLDER)
LLM_TEMPERATURE  <- 0.7
LLM_THINK_LEVEL  <- "low"
CAPTURE_THINKING <- TRUE

# ── Source pipeline ────────────────────────────────────────────────────────────

source("data_check/pipeline/0_index.R")
source("data_check/pipeline/2_codebook_label.R")
source("data_check/pipeline/3_psychds_convert.R")

llm_use(TRUE)
llm_model("ollama/gpt-oss:20b-cloud")

# ── Wire input folder into the data layer via symlink ─────────────────────────
# paper_path("data","osf",FOLDER_NAME) must resolve to INPUT_FOLDER.
# We create a symlink at that path so run_index(download=FALSE) finds the files.

data_link <- paper_path("data", "osf", FOLDER_NAME)
if (!file.exists(data_link)) {
  dir.create(dirname(data_link), recursive = TRUE, showWarnings = FALSE)
  file.symlink(INPUT_FOLDER, data_link)
}

# Ensure output dirs exist
dir.create(paper_path("outputs", "osf", FOLDER_NAME), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(PSYCHDS_OUT_DIR, "osf", FOLDER_NAME), recursive = TRUE, showWarnings = FALSE)

# ── Run ────────────────────────────────────────────────────────────────────────

local({

  pid <- FOLDER_NAME
  src <- "osf"

  cat("\n══════════════════════════════════════════════════════════════════════\n")
  cat(sprintf("  Local folder: %s\n", INPUT_FOLDER))
  cat(sprintf("  Paper ID:     %s\n", pid))
  cat(sprintf("  Outputs:      %s\n", OUTPUT_FOLDER))
  cat(sprintf("  PsychDS:      %s\n", file.path(OUTPUT_FOLDER, "PSYCHDS")))
  cat("══════════════════════════════════════════════════════════════════════\n\n")

  KNOWN_ERROR_CODES <- c("no_links", "download_failed", "empty_repo", "too_large")

  # ── Stage 1: classify files + extract columns ──────────────────────────────

  cat("── Stage 1: run_index ──────────────────────────────────────────────────\n")
  t1 <- proc.time()[["elapsed"]]

  stage1 <- tryCatch(
    run_index(paper_id = pid, download = FALSE),
    error = function(e) list(success = FALSE, error = conditionMessage(e))
  )

  t1e <- proc.time()[["elapsed"]] - t1

  if (isFALSE(stage1$success)) {
    code <- if (any(startsWith(stage1$error, KNOWN_ERROR_CODES)))
              sub(":.*$", "", stage1$error) else "error"
    cat(sprintf("  FAILED — %s\n  %s\n\n  (Stages 2–3 skipped)\n", code, stage1$error))
    return(invisible(NULL))
  }

  cat(sprintf(
    "  success=TRUE  files=%s  data_files=%s  columns=%s  elapsed=%.1fs\n",
    stage1$n_files %||% "NA",
    stage1$n_data_files %||% "NA",
    stage1$n_columns %||% "NA",
    t1e
  ))

  # ── Stage 2: codebook labelling ────────────────────────────────────────────

  cat("\n── Stage 2: run_codebook_label ─────────────────────────────────────────\n")

  columns_path <- paper_path("outputs", src, pid, "columns.csv")

  if (!file.exists(columns_path)) {
    cat("  Stage 2 skipped — no columns.csv\n")
  } else {
    t2 <- proc.time()[["elapsed"]]
    stage2 <- tryCatch(
      run_codebook_label(paper_id = pid),
      error = function(e) list(success = FALSE, error = conditionMessage(e))
    )
    t2e <- proc.time()[["elapsed"]] - t2

    if (isFALSE(stage2$success)) {
      cat(sprintf("  FAILED — %s\n  (Stage 3 will still run)\n", stage2$error))
    } else {
      cat(sprintf(
        "  label_status=%s  labelled=%s  unlabelled=%s  elapsed=%.1fs\n",
        stage2$label_status %||% "NA",
        stage2$n_labelled %||% "NA",
        stage2$n_unlabelled %||% "NA",
        t2e
      ))
    }
  }

  # ── Stage 3: PsychDS conversion ────────────────────────────────────────────

  cat("\n── Stage 3: convert_psychds ────────────────────────────────────────────\n")
  t3 <- proc.time()[["elapsed"]]

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

  t3e <- proc.time()[["elapsed"]] - t3

  psy_ok <- all(vapply(psychds_results, function(r) isTRUE(r$success), logical(1)))
  if (psy_ok) {
    cat(sprintf("  success=TRUE  elapsed=%.1fs\n", t3e))
  } else {
    errs <- unique(vapply(psychds_results, function(r)
      if (!isTRUE(r$success)) r$error %||% "?" else NA_character_, character(1)))
    cat(sprintf("  FAILED — %s\n", paste(errs[!is.na(errs)], collapse = "; ")))
  }

  # ── Summary ────────────────────────────────────────────────────────────────

  out_files <- c(
    structure = paper_path("outputs", src, pid, "structure.csv"),
    columns   = paper_path("outputs", src, pid, "columns.csv"),
    labels    = paper_path("outputs", src, pid, "labels.csv"),
    coverage  = paper_path("outputs", src, pid, "codebook_coverage.csv"),
    thinking  = paper_path("outputs", src, pid, "thinking_traces.csv")
  )
  existing <- out_files[file.exists(out_files)]

  # ── Flatten outputs into OUTPUT_FOLDER ────────────────────────────────────
  # paper_path() nests under osf/<id>/; move everything up to OUTPUT_FOLDER.

  nested_outputs <- paper_path("outputs", src, pid)
  nested_psychds <- file.path(PSYCHDS_OUT_DIR, pid)   # convert_psychds writes <PSYCHDS_OUT_DIR>/<paper_id> directly

  move_dir_contents <- function(from, to) {
    if (!dir.exists(from)) return(invisible(NULL))
    dir.create(to, recursive = TRUE, showWarnings = FALSE)
    files <- list.files(from, full.names = TRUE, recursive = TRUE)
    for (f in files) {
      rel  <- substring(f, nchar(from) + 2)
      dest <- file.path(to, rel)
      dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
      file.rename(f, dest)
    }
    unlink(from, recursive = TRUE)
  }

  move_dir_contents(nested_outputs, OUTPUT_FOLDER)
  move_dir_contents(nested_psychds, file.path(OUTPUT_FOLDER, "PSYCHDS"))

  # Clean up empty staging scaffolding
  unlink(file.path(OUTPUT_DIR,  src), recursive = TRUE)
  unlink(file.path(DATA_DIR,   src), recursive = TRUE)
  if (length(list.files(DATA_DIR, recursive = TRUE)) == 0) unlink(DATA_DIR, recursive = TRUE)

  # Remove any remaining empty dirs under OUTPUT_FOLDER (excluding files)
  empty_dirs <- rev(list.dirs(OUTPUT_FOLDER, full.names = TRUE, recursive = TRUE))
  for (d in empty_dirs) {
    if (d == OUTPUT_FOLDER) next
    if (length(list.files(d, recursive = TRUE)) == 0) unlink(d, recursive = TRUE)
  }

  cat("\n── Outputs:\n")
  final_files <- list.files(OUTPUT_FOLDER, full.names = TRUE, recursive = FALSE)
  for (f in final_files)
    cat(sprintf("    %s\n", f))
  cat("\n")
})
