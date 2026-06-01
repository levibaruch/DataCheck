# run_full_120b_json.R
# ─────────────────────────────────────────────────────────────────────────────
# Columns → codebook → psychDS for the FROZEN gpt-oss-120b + JSON cell.
#
# The file-type classification (structure.csv) is ALREADY FINAL — produced by
# the prompt sweep at:
#   results/eval/outputs/step2/<src>/<id>/gpt-oss-120b-low_json/structure.csv
# This runner does NOT re-classify. It seeds that frozen structure.csv, then
# runs COLUMNS_ONLY + codebook + psychDS on top of it:
#
#   Stage 0    seed frozen structure.csv (no download, no structure LLM)
#   Stage 1    run_index (COLUMNS_ONLY)  → columns.csv
#   Stage 2    run_codebook_label        → labels.csv + codebook_coverage.csv
#   Stage 3    convert_psychds           → psychDS reconstruction
#   Stage 3.5  validate psychDS (psychds-validator), then DELETE it to save disk
#
# Then scores the (frozen) structure.csv against ground truth for the record.
#
# Validation is merged in from the old validate_psychds.R: each paper's psychDS
# reconstruction is validated against the psych-DS spec, the verdict recorded,
# and the reconstruction deleted (DELETE_PSYCHDS_AFTER_VALIDATE) — we keep the
# validity row, not the bytes. Requires the npm `psychds-validator` CLI on PATH.
#
# Outputs are isolated under results/eval/full_120b_json/ so this never clobbers
# the real ./outputs and ./psychds trees, nor the original step2 cell:
#   results/eval/full_120b_json/outputs/<src>/<id>/   structure,columns,labels,coverage
#   results/eval/full_120b_json/psychds/<id>/          psychDS reconstruction (transient — deleted after validation)
#   results/eval/full_120b_json/eval_summary.csv       one aggregate metrics row
#   results/eval/full_120b_json/eval_per_paper.csv     one row per paper
#   results/eval/full_120b_json/conversion_summary.csv psychDS conversion log
#   results/eval/full_120b_json/validation_summary.csv one row per validated dataset
#
# Requires: data downloaded at ./data/<src>/<id>/ (columns + psychds read it).
#
# Usage: Rscript runners/eval/run_full_120b_json.R
#        or source() from an interactive session.
# ─────────────────────────────────────────────────────────────────────────────

source("runners/eval/eval_helpers.R")
source("pipeline/prompts.R")

# ── Globals MUST be set before sourcing 0_index.R (it guards with !exists) ──────
FULL_RUN        <- TRUE    # remove per-paper caps; extract columns for ALL data files
SKIP_COLUMNS    <- FALSE   # we WANT column extraction
COLUMNS_ONLY    <- TRUE    # skip download + structure LLM; read seeded structure.csv

# Frozen classification source: the gpt-oss-120b JSON cell from the prompt sweep.
FROZEN_CELL     <- "gpt-oss-120b-low_json"
FROZEN_STEP2    <- file.path(EVAL_RESULTS_DIR, "outputs", "step2")

# Isolate outputs from the production ./outputs and ./psychds trees.
RUN_BASE        <- file.path(EVAL_RESULTS_DIR, "full_120b_json")
OUTPUT_DIR      <- file.path(RUN_BASE, "outputs")
PSYCHDS_OUT_DIR <- file.path(RUN_BASE, "psychds")
# DATA_DIR + GROUND_TRUTH_DIR keep their defaults (./data, ./tests/ground_truth).

source("pipeline/0_index.R")
source("pipeline/2_codebook_label.R")
source("pipeline/3_psychds_convert.R")

# ── The single eval cell ────────────────────────────────────────────────────
CFG <- list(
  model  = "groq/openai/gpt-oss-120b",
  think  = "low",
  temp   = 0.3,
  prompt = "json",
  label  = "gpt-oss-120b-low"
)

SUMMARY_PATH    <- file.path(RUN_BASE, "eval_summary.csv")
PAPER_PATH      <- file.path(RUN_BASE, "eval_per_paper.csv")
CONVERSION_PATH <- file.path(RUN_BASE, "conversion_summary.csv")
VALIDATION_PATH        <- file.path(RUN_BASE, "validation_summary.csv")
VALIDATION_ISSUES_PATH <- file.path(RUN_BASE, "validation_issues.csv")
VALIDATION_REPORT_PATH <- file.path(RUN_BASE, "validation_report.csv")
VALIDATION_REPORT_MD   <- file.path(RUN_BASE, "validation_report.md")
dir.create(RUN_BASE, recursive = TRUE, showWarnings = FALSE)

# ── psychDS validation (merged from validate_psychds.R) ──────────────────────
# After each paper converts, validate its psychDS dirs against the psych-DS spec
# via the npm `psychds-validator` CLI, record validity, then DELETE the psychDS
# reconstruction to save disk — we only keep the validation verdict, not the
# bytes. Set DELETE_PSYCHDS_AFTER_VALIDATE <- FALSE to retain the dirs.
DELETE_PSYCHDS_AFTER_VALIDATE <- TRUE
VALIDATOR_BIN <- "npx"
VALIDATOR     <- c("--no-install", "psychds-validator")

# Confirm the validator is reachable before churning through papers.
.vprobe <- suppressWarnings(tryCatch(
  system2(VALIDATOR_BIN, c(VALIDATOR, "--version"), stdout = TRUE, stderr = TRUE),
  error = function(e) NULL
))
.vstatus <- if (is.null(.vprobe)) 1L else (attr(.vprobe, "status") %||% 0L)
if (is.null(.vprobe) || .vstatus != 0)
  stop("psychds-validator not runnable via `", VALIDATOR_BIN, " ",
       paste(VALIDATOR, collapse = " "), "`.\n",
       "Install it: npm i -g psychds-validator  (or npm i psychds-validator)\n",
       "Got: ", paste(.vprobe, collapse = " "))
cat(sprintf("psychds-validator version: %s\n", paste(.vprobe, collapse = " ")))

# Write a whole data frame atomically (temp + rename) so a kill mid-run can
# never leave a half-written / NUL-padded CSV. Replaces append_csv for the
# validation outputs, which were getting corrupted by interleaved appends.
write_all <- function(df, path) {
  if (is.null(df) || nrow(df) == 0) return(invisible())
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(path, ".tmp")
  write.csv(df, tmp, row.names = FALSE)
  file.rename(tmp, path)
}

# Render a human-readable markdown report from the classified `report` frame
# (one row per issue/failure) plus the per-dataset validity frame `vall`.
write_md_report <- function(report, vall, run_id, path) {
  L <- c(sprintf("# psychDS validation report"), "",
         sprintf("- Run: `%s`", run_id),
         sprintf("- Generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), "")
  if (!is.null(vall) && nrow(vall) > 0) {
    iv <- vall$valid %in% c(TRUE, "TRUE")
    pk <- tapply(iv, vall$paper_id, all)
    L <- c(L, "## Summary", "",
           sprintf("- Datasets valid: **%d / %d** (%.1f%%)", sum(iv, na.rm = TRUE),
                   nrow(vall), 100 * sum(iv, na.rm = TRUE) / nrow(vall)),
           sprintf("- Papers valid (all studies pass): **%d / %d**", sum(pk), length(pk)), "")
  }
  errs <- if (!is.null(report)) report[report$severity == "error", ] else report[0, ]
  if (!is.null(errs) && nrow(errs) > 0) {
    # FAILED (no data files) and conversion failures.
    nodata <- errs[errs$key == "NO_DATA_FILES", ]
    cfail  <- errs[errs$key == "CONVERSION_FAILED", ]
    if (nrow(nodata) > 0) {
      L <- c(L, sprintf("## FAILED — no data files (%d)", nrow(nodata)), "")
      L <- c(L, sprintf("- `%s` / %s", nodata$paper_id, nodata$study_group), "")
    }
    if (nrow(cfail) > 0) {
      L <- c(L, sprintf("## FAILED — conversion error (%d)", nrow(cfail)), "")
      L <- c(L, sprintf("- `%s` / %s — %s", cfail$paper_id, cfail$study_group,
                        substr(cfail$reason, 1, 100)), "")
    }
    # Errors per reason, tagged.
    ag <- aggregate(list(n = rep(1L, nrow(errs))),
                    by = list(key = errs$key, category = errs$category), FUN = sum)
    ag <- ag[order(-ag$n), ]
    cause <- c(repository = "repo (bad source data)", converter = "converter (our bug)",
               ambiguous = "ambiguous (mixed)", structural = "structural (spec)",
               unknown = "unknown")
    L <- c(L, "## Errors per reason", "",
           "| count | category | cause | validator key |",
           "|---:|---|---|---|")
    for (i in seq_len(nrow(ag)))
      L <- c(L, sprintf("| %d | %s | %s | `%s` |", ag$n[i], ag$category[i],
                        cause[[ag$category[i]]] %||% ag$category[i], ag$key[i]))
    nrepo <- sum(errs$repo_caused %in% c(TRUE, "TRUE"))
    nconv <- sum(errs$repo_caused %in% c(FALSE, "FALSE"))
    namb  <- nrow(errs) - nrepo - nconv
    L <- c(L, "",
           sprintf("**Totals:** repository = %d · converter = %d · ambiguous/other = %d (of %d error rows)",
                   nrepo, nconv, namb, nrow(errs)), "")
  }
  writeLines(L, path)
}

# Flatten the validator's per-issue `files` field to a single string.
issue_files <- function(issue) {
  f <- issue$files %||% issue$location %||% NULL
  if (is.null(f) || length(f) == 0) return("")
  paths <- vapply(f, function(x) {
    if (is.list(x)) (x$file %||% x$path %||% x$name %||% "") else as.character(x)
  }, character(1))
  paste(unique(paths[nzchar(paths)]), collapse = ";")
}

# Run the validator on one directory; return summary fields + per-issue detail.
validate_one <- function(dir) {
  empty <- list(parsed = FALSE, valid = NA, n_errors = NA, n_warnings = NA,
                error_keys = "", warning_keys = "", issues = list())
  raw <- suppressWarnings(tryCatch(
    system2(VALIDATOR_BIN, c(VALIDATOR, shQuote(dir), "--json", "--showWarnings"),
            stdout = TRUE, stderr = FALSE),
    error = function(e) NULL
  ))
  if (is.null(raw) || length(raw) == 0) return(empty)
  j <- tryCatch(jsonlite::fromJSON(paste(raw, collapse = "\n"), simplifyVector = FALSE),
                error = function(e) NULL)
  if (is.null(j) || is.null(j$issues)) return(empty)
  sev  <- vapply(j$issues, function(i) i$severity %||% NA_character_, character(1))
  keys <- vapply(j$issues, function(i) i$key %||% NA_character_, character(1))
  list(
    parsed       = TRUE,
    valid        = isTRUE(j$valid),
    n_errors     = sum(sev == "error",   na.rm = TRUE),
    n_warnings   = sum(sev == "warning", na.rm = TRUE),
    error_keys   = paste(unique(keys[sev == "error"]),   collapse = ";"),
    warning_keys = paste(unique(keys[sev == "warning"]), collapse = ";"),
    issues       = lapply(seq_along(j$issues), function(k) {
      iss <- j$issues[[k]]
      list(severity = sev[k] %||% NA_character_,
           key      = keys[k] %||% NA_character_,
           reason   = iss$reason %||% iss$message %||% NA_character_,
           files    = issue_files(iss))
    })
  )
}
validation_results <- list()   # one summary row per dataset
validation_issues  <- list()   # one row per individual issue
failed_datasets    <- list()   # datasets that produced no validatable psychDS

# ── Issue classification: repository data fault vs converter (coding) bug ──────
# Investigation (2026-05-26) split the validator's error keys by who must fix
# them. Structural keys are psych-DS spec-completeness recommendations (neither
# a source-data fault nor our bug). Two keys are location-dependent and resolved
# in classify_issue() below.  category ∈ {repository, converter, structural,
# ambiguous}; repo_caused ∈ {TRUE, FALSE, NA}.
ISSUE_CLASS <- list(
  # ── repository: bad source data (validator correctly flags; not our bug) ────
  CSV_HEADER_REPEATED               = c("repository", "duplicate column names in source data file"),
  CSV_HEADER_LENGTH_MISMATCH        = c("repository", "ragged rows (header/row column count differ) in source"),
  FILENAME_KEYWORD_FORMATTING_ERROR = c("repository", "original filename not psych-DS keyword-formatted (raw/ copy)"),
  FILE_EMPTY                        = c("repository", "source file is empty"),
  # ── converter: our pipeline emits invalid psychDS (coding bug) ──────────────
  VARIABLE_MISSING_FROM_CSV_COLUMNS = c("converter",  "variableMeasured lists a variable absent from every emitted CSV"),
  MISSING_DATAFILE                  = c("converter",  "conversion emitted no valid CSV/TSV datafile"),
  MISSING_SIDECAR_METADATA          = c("converter",  "converter did not write a sidecar for a datafile"),
  # ── structural: psych-DS completeness recommendations (neither) ─────────────
  FILE_NOT_CHECKED                    = c("structural", "psych-DS spec completeness"),
  MISSING_CHANGES_DOC                 = c("structural", "psych-DS spec completeness"),
  MISSING_DIRECTORY_METADATA          = c("structural", "psych-DS spec completeness"),
  MISSING_RESULTS_DIRECTORY           = c("structural", "psych-DS spec completeness"),
  MISSING_README_DOC                  = c("structural", "psych-DS spec completeness"),
  MISSING_MATERIALS_DIRECTORY         = c("structural", "psych-DS spec completeness"),
  MISSING_ANALYSIS_DIRECTORY          = c("structural", "psych-DS spec completeness"),
  MISSING_DOCUMENTATION_DIRECTORY     = c("structural", "psych-DS spec completeness"),
  INVALID_SCHEMAORG_PROPERTY          = c("structural", "psych-DS spec completeness"),
  FILENAME_UNOFFICIAL_KEYWORD_WARNING = c("structural", "psych-DS spec completeness"),
  UNKNOWN_NAMESPACE                   = c("structural", "psych-DS spec completeness")
)

# Classify one issue; the two location-dependent keys use the file path bucket
# (/data/raw/ = verbatim source copy; /data/source-|granularity- = our output).
classify_issue <- function(key, files) {
  base <- ISSUE_CLASS[[key]]
  if (!is.null(base))
    return(list(category = base[1], repo_caused = base[1] == "repository", note = base[2]))
  on_raw  <- grepl("/data/raw/", files)
  on_conv <- grepl("/data/(source-|granularity-)", files)
  if (identical(key, "CSV_COLUMN_MISSING_FROM_METADATA")) {
    if (on_raw && !on_conv)
      return(list(category = "repository", repo_caused = TRUE,
                  note = "raw-copy column absent from metadata (source header issue)"))
    return(list(category = "ambiguous", repo_caused = NA,
                note = "mostly duplicate/blank/headerless source columns (repo); residual = converter dedupe asymmetry"))
  }
  if (identical(key, "CSV_FORMATTING_ERROR")) {
    if (on_conv && !on_raw)
      return(list(category = "converter", repo_caused = FALSE,
                  note = "converter wrote an unparseable CSV"))
    return(list(category = "repository", repo_caused = TRUE,
                note = "malformed source CSV"))
  }
  list(category = "unknown", repo_caused = NA, note = "unclassified validator key")
}

# ── Full GT corpus: every <src>/<id>.csv under tests/ground_truth/ ────────────
gt_files <- list.files(GT_DIR, pattern = "\\.csv$", recursive = TRUE,
                       full.names = FALSE)
if (length(gt_files) == 0) stop("No ground truth files found in ", GT_DIR)
papers_df <- data.frame(
  source = dirname(gt_files),
  id     = tools::file_path_sans_ext(basename(gt_files)),
  stringsAsFactors = FALSE
)
papers_df <- papers_df[order(papers_df$source, papers_df$id), ]

RUN_ID  <- format(Sys.time(), "%Y-%m-%d_%H-%M-%S")
divider <- paste0(rep("─", 72), collapse = "")

cat(sprintf("%s\n  Columns→codebook→psychDS on FROZEN cell  [%s]\n  cell: %s (%s) | think=%s | temp=%s\n  structure.csv FROZEN — not re-classified\n  %d papers\n%s\n",
            divider, RUN_ID, CFG$label, FROZEN_CELL, CFG$think, CFG$temp,
            nrow(papers_df), divider))

# ── Pin the model ─────────────────────────────────────────────────────────────
LLM_MODEL        <<- CFG$model
LLM_TEMPERATURE  <<- CFG$temp
LLM_THINK_LEVEL  <<- CFG$think
CAPTURE_THINKING <<- TRUE
llm_use(TRUE)
llm_model(LLM_MODEL)

KNOWN_ERROR_CODES <- c("no_links", "download_failed", "empty_repo", "too_large")
paper_results <- list()

# ── Resume: read the logs BEFORE starting; skip papers already processed ──────
# A previous run's validation_summary.csv (the logger) + eval_per_paper.csv are
# the source of truth for "done". We reload their rows into the in-memory lists
# so the final aggregate + report cover prior AND new work, and collect the set
# of finished paper_ids so they are not re-converted / re-validated / re-scored.
# CSV read helper: returns a data.frame (paper_id forced character) or NULL.
.read_log <- function(path) {
  if (!file.exists(path)) return(NULL)
  df <- tryCatch(
    read.csv(path, stringsAsFactors = FALSE, colClasses = c(paper_id = "character")),
    error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) NULL else df
}

done_pids <- character(0)

prev_val <- .read_log(VALIDATION_PATH)
if (!is.null(prev_val)) {
  for (i in seq_len(nrow(prev_val)))
    validation_results[[length(validation_results) + 1L]] <- prev_val[i, , drop = FALSE]
  done_pids <- union(done_pids, unique(prev_val$paper_id))
}

prev_iss <- .read_log(VALIDATION_ISSUES_PATH)
if (!is.null(prev_iss))
  for (i in seq_len(nrow(prev_iss)))
    validation_issues[[length(validation_issues) + 1L]] <- prev_iss[i, , drop = FALSE]

# Reload prior per-paper metrics into paper_results (keep only the fields
# aggregate_metrics consumes so rbind across rows stays rectangular). A paper
# that scored but produced no valid psychDS lives only here — union it in too.
prev_pp <- .read_log(PAPER_PATH)
if (!is.null(prev_pp)) {
  metric_cols <- c("paper_id", "n_files", "macro_f1", "micro_f1",
                   "kappa", "mcc", "accuracy", "retry_rate")
  for (i in seq_len(nrow(prev_pp))) {
    row <- prev_pp[i, , drop = FALSE]
    paper_results[[row$paper_id]] <- as.list(row[, intersect(metric_cols, names(row))])
  }
  done_pids <- union(done_pids, unique(prev_pp$paper_id))
}

if (length(done_pids) > 0)
  cat(sprintf("  resume: %d paper(s) already processed — skipping\n", length(done_pids)))

for (j in seq_len(nrow(papers_df))) {
  pid <- papers_df$id[j]
  src <- papers_df$source[j]
  out_dir <- paper_path("outputs", src, pid)   # OUTPUT_DIR/src/id (isolated base)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  # Already in the logs from a prior run — do not re-run the 120b pipeline.
  if (pid %in% done_pids) {
    cat(sprintf("\n[%d/%d] %s/%s  [SKIP — already processed]\n", j, nrow(papers_df), src, pid))
    next
  }

  cat(sprintf("\n[%d/%d] %s/%s\n", j, nrow(papers_df), src, pid))

  THINKING_LOG_PATH <<- file.path(out_dir, "thinking_traces.csv")

  # ── Stage 0: seed the FROZEN structure.csv (no re-classification) ────────────
  # The SKIP_COLUMNS step2 cell wrote a slim structure.csv lacking the
  # is_sentinel column that the COLUMNS_ONLY path requires. Read from the seed
  # (or the frozen source), ensure is_sentinel exists, write it out. Idempotent.
  seed_path <- file.path(out_dir, "structure.csv")
  read_from  <- if (file.exists(seed_path)) seed_path
                else file.path(FROZEN_STEP2, src, pid, FROZEN_CELL, "structure.csv")
  if (!file.exists(read_from)) {
    cat(sprintf("  stage0: [SKIP paper] no frozen structure.csv at %s\n", read_from))
    next
  }
  seed_df <- read.csv(read_from, stringsAsFactors = FALSE,
                      colClasses = c(paper_id = "character"))
  if (!"is_sentinel" %in% names(seed_df)) {
    seed_df$is_sentinel <- seed_df$type %in% c(SENTINEL_VAL, "llm_error")
    write.csv(seed_df, seed_path, row.names = FALSE)
    cat("  stage0: seeded frozen structure.csv (added is_sentinel)\n")
  } else if (!file.exists(seed_path)) {
    write.csv(seed_df, seed_path, row.names = FALSE)
    cat("  stage0: seeded frozen structure.csv\n")
  } else {
    cat("  stage0: [SKIP] structure.csv present + complete\n")
  }

  # ── Stage 1: run_index (COLUMNS_ONLY → columns.csv) ─────────────────────────
  if (file.exists(file.path(out_dir, "columns.csv"))) {
    cat("  stage1: [SKIP] columns.csv exists\n")
  } else {
    t0 <- proc.time()[["elapsed"]]
    s1 <- tryCatch(
      run_index(paper_id = pid, download = FALSE),
      error = function(e) list(success = FALSE, error = conditionMessage(e))
    )
    el <- round(proc.time()[["elapsed"]] - t0, 1)
    if (isFALSE(s1$success)) {
      err  <- s1$error %||% "?"
      code <- if (any(startsWith(err, KNOWN_ERROR_CODES))) sub(":.*$", "", err) else "error"
      cat(sprintf("  stage1: FAILED (%.1fs) — %s: %s\n  (stages 2-3 skipped)\n", el, code, err))
      next
    }
    cat(sprintf("  stage1: ok (%.1fs)  columns=%s\n", el, s1$n_columns %||% "NA"))
  }

  # ── Stage 2: run_codebook_label (labels + coverage) ─────────────────────────
  if (!file.exists(file.path(out_dir, "columns.csv"))) {
    cat("  stage2: [SKIP] no columns.csv\n")
  } else if (file.exists(file.path(out_dir, "labels.csv"))) {
    cat("  stage2: [SKIP] labels.csv exists\n")
  } else {
    t0 <- proc.time()[["elapsed"]]
    s2 <- tryCatch(
      run_codebook_label(paper_id = pid),
      error = function(e) list(success = FALSE, error = conditionMessage(e))
    )
    el <- round(proc.time()[["elapsed"]] - t0, 1)
    if (isFALSE(s2$success))
      cat(sprintf("  stage2: FAILED (%.1fs) — %s\n", el, s2$error %||% "?"))
    else
      cat(sprintf("  stage2: ok (%.1fs)  labelled=%s unlabelled=%s\n",
                  el, s2$n_labelled %||% "NA", s2$n_unlabelled %||% "NA"))
  }

  # ── Stage 3: convert_psychds (reconstruction) ───────────────────────────────
  t0 <- proc.time()[["elapsed"]]
  psy <- tryCatch(
    convert_psychds(pid),
    error = function(e) list(list(
      paper_id = pid, study_group = "all", success = FALSE,
      error = conditionMessage(e), n_data_files = 0L, n_raw_files = 0L,
      n_variables = 0L, n_labelled = 0L, has_paper_metadata = FALSE,
      has_ground_truth = FALSE, output_path = NA_character_
    ))
  )
  el <- round(proc.time()[["elapsed"]] - t0, 1)
  append_conversion_summary(psy, CONVERSION_PATH)
  # Record datasets with nothing to validate: conversion errored, or it
  # "succeeded" but emitted zero data files (FAILED — no data files).
  for (r in psy) {
    if (!isTRUE(r$success)) {
      failed_datasets[[length(failed_datasets) + 1L]] <- data.frame(
        paper_id = r$paper_id, study_group = r$study_group %||% "all",
        kind = "conversion_error", reason = r$error %||% "conversion failed",
        stringsAsFactors = FALSE)
    } else if ((r$n_data_files %||% 0L) == 0L) {
      failed_datasets[[length(failed_datasets) + 1L]] <- data.frame(
        paper_id = r$paper_id, study_group = r$study_group %||% "all",
        kind = "no_data_files", reason = "conversion emitted no data files",
        stringsAsFactors = FALSE)
    }
  }
  psy_ok <- all(vapply(psy, function(r) isTRUE(r$success), logical(1)))
  if (psy_ok) {
    cat(sprintf("  stage3: ok (%.1fs)  psychDS → %s\n", el, file.path(PSYCHDS_OUT_DIR, pid)))
  } else {
    errs <- unique(vapply(psy, function(r)
      if (!isTRUE(r$success)) r$error %||% "?" else NA_character_, character(1)))
    cat(sprintf("  stage3: FAILED (%.1fs) — %s\n", el,
                paste(errs[!is.na(errs)], collapse = "; ")))
  }

  # ── Stage 3.5: validate psychDS, record verdict, then delete to save disk ───
  ok_psy <- Filter(function(r) isTRUE(r$success) &&
                     !is.null(r$output_path) && !is.na(r$output_path) &&
                     nzchar(r$output_path), psy)
  for (r in ok_psy) {
    if (!dir.exists(r$output_path)) { cat(sprintf("  valid : [MISSING DIR] %s\n", r$output_path)); next }
    v <- validate_one(r$output_path)
    vrow <- data.frame(
      run_id = RUN_ID, paper_id = r$paper_id, study_group = r$study_group,
      output_path = r$output_path, parsed = v$parsed, valid = v$valid,
      n_errors = v$n_errors, n_warnings = v$n_warnings,
      error_keys = v$error_keys, warning_keys = v$warning_keys,
      stringsAsFactors = FALSE
    )
    validation_results[[length(validation_results) + 1L]] <- vrow
    for (iss in v$issues) {
      validation_issues[[length(validation_issues) + 1L]] <- data.frame(
        run_id = RUN_ID, paper_id = r$paper_id, study_group = r$study_group,
        output_path = r$output_path,
        severity = iss$severity, key = iss$key, reason = iss$reason,
        files = iss$files, stringsAsFactors = FALSE
      )
    }
    # Full atomic rewrite each step → crash-safe, never corrupt/half-written.
    write_all(do.call(rbind, validation_results), VALIDATION_PATH)
    write_all(do.call(rbind, validation_issues),  VALIDATION_ISSUES_PATH)
    if (!v$parsed) cat(sprintf("  valid : PARSE FAIL (%s)\n", r$study_group))
    else cat(sprintf("  valid : %s  errors=%d warnings=%d (%s)\n",
                     if (isTRUE(v$valid)) "VALID" else "INVALID",
                     v$n_errors, v$n_warnings, r$study_group))
  }
  if (DELETE_PSYCHDS_AFTER_VALIDATE && length(ok_psy) > 0) {
    paper_psy_dir <- file.path(PSYCHDS_OUT_DIR, pid)
    if (dir.exists(paper_psy_dir)) {
      unlink(paper_psy_dir, recursive = TRUE, force = TRUE)
      cat(sprintf("  prune : deleted psychDS dir %s\n", paper_psy_dir))
    }
  }

  # ── Score structure.csv vs GT ───────────────────────────────────────────────
  metrics <- eval_paper(pid, out_dir, src)
  if (!is.null(metrics)) {
    paper_results[[pid]] <- metrics
    cat(sprintf("  score : macro_f1=%.1f%%  accuracy=%.1f%%\n",
                metrics$macro_f1 %||% NA, metrics$accuracy %||% NA))
    pp_row <- as.data.frame(c(
      list(run_id = RUN_ID, model = CFG$model, model_label = CFG$label,
           think = as.character(CFG$think), temp = CFG$temp, prompt_format = CFG$prompt),
      metrics
    ), stringsAsFactors = FALSE)
    append_csv(pp_row, PAPER_PATH)
  } else {
    cat("  score : (no metrics)\n")
  }
}

# ── Aggregate ─────────────────────────────────────────────────────────────────
summary_row <- aggregate_metrics(
  paper_results, model = CFG$model, think = CFG$think, temp = CFG$temp,
  prompt_format = CFG$prompt, run_id = RUN_ID
)
if (!is.null(summary_row)) {
  summary_row$model_label <- CFG$label
  append_csv(summary_row, SUMMARY_PATH)
  cat(sprintf("\n  Summary: macro_f1=%.1f%%  micro_f1=%.1f%%  kappa=%.3f  n=%d\n",
              summary_row$macro_f1, summary_row$micro_f1,
              summary_row$kappa, summary_row$n_papers))
}

# ── psychDS validation aggregate + classified report ─────────────────────────
# Build validation_report.csv: every issue enriched with category / repo_caused
# / note, plus a synthetic row per FAILED (no-data) dataset. This supersedes the
# raw validation_issues.csv for human reading.
report_rows <- list()
if (length(validation_issues) > 0) {
  vi <- do.call(rbind, validation_issues)
  for (i in seq_len(nrow(vi))) {
    cl <- classify_issue(vi$key[i], vi$files[i])
    report_rows[[length(report_rows) + 1L]] <- data.frame(
      run_id = vi$run_id[i], paper_id = vi$paper_id[i], study_group = vi$study_group[i],
      output_path = vi$output_path[i], severity = vi$severity[i], key = vi$key[i],
      category = cl$category, repo_caused = cl$repo_caused, note = cl$note,
      reason = vi$reason[i], files = vi$files[i], stringsAsFactors = FALSE)
  }
}
if (length(failed_datasets) > 0) {
  fd <- do.call(rbind, failed_datasets)
  for (i in seq_len(nrow(fd))) {
    report_rows[[length(report_rows) + 1L]] <- data.frame(
      run_id = RUN_ID, paper_id = fd$paper_id[i], study_group = fd$study_group[i],
      output_path = NA_character_, severity = "error",
      key = if (fd$kind[i] == "no_data_files") "NO_DATA_FILES" else "CONVERSION_FAILED",
      category = "converter", repo_caused = FALSE,
      note = "no validatable psychDS produced", reason = fd$reason[i],
      files = "", stringsAsFactors = FALSE)
  }
}
report <- if (length(report_rows) > 0) do.call(rbind, report_rows) else NULL
write_all(report, VALIDATION_REPORT_PATH)
vall_for_md <- if (length(validation_results) > 0) do.call(rbind, validation_results) else NULL
write_md_report(report, vall_for_md, RUN_ID, VALIDATION_REPORT_MD)

cat(sprintf("\n%s\n  psychDS validation report\n%s\n", divider, divider))
if (length(validation_results) > 0) {
  vall     <- do.call(rbind, validation_results)
  is_valid <- vall$valid %in% c(TRUE, "TRUE")
  paper_ok <- tapply(is_valid, vall$paper_id, all)  # paper passes iff all studies do
  cat(sprintf("  Datasets valid : %d / %d (%.1f%%)\n",
              sum(is_valid, na.rm = TRUE), nrow(vall),
              100 * sum(is_valid, na.rm = TRUE) / nrow(vall)))
  cat(sprintf("  Papers  valid  : %d / %d (all studies pass)\n",
              sum(paper_ok), length(paper_ok)))
}

# FAILED (no data files) — datasets with nothing to validate.
if (length(failed_datasets) > 0) {
  fd  <- do.call(rbind, failed_datasets)
  nodata <- fd[fd$kind == "no_data_files", ]
  cerr   <- fd[fd$kind == "conversion_error", ]
  cat(sprintf("\n  FAILED (no data files) : %d dataset(s)\n", nrow(nodata)))
  for (i in seq_len(nrow(nodata)))
    cat(sprintf("    %s / %s\n", nodata$paper_id[i], nodata$study_group[i]))
  if (nrow(cerr) > 0) {
    cat(sprintf("  FAILED (conversion error) : %d dataset(s)\n", nrow(cerr)))
    for (i in seq_len(nrow(cerr)))
      cat(sprintf("    %s / %s — %s\n", cerr$paper_id[i], cerr$study_group[i],
                  substr(cerr$reason[i], 1, 80)))
  }
}

# Failures per reason, tagged repository vs converter (coding).
if (!is.null(report)) {
  errs <- report[report$severity == "error", ]
  if (nrow(errs) > 0) {
    tag <- c(repository = "REPO    ", converter = "CONVERTER", ambiguous = "AMBIG   ",
             structural = "STRUCT  ", unknown = "UNKNOWN ")
    agg <- aggregate(list(n = rep(1L, nrow(errs))),
                     by = list(key = errs$key, category = errs$category), FUN = sum)
    agg <- agg[order(-agg$n), ]
    cat("\n  Errors per reason  [REPO = bad source data | CONVERTER = our bug | AMBIG/STRUCT = mixed/spec]\n")
    for (i in seq_len(nrow(agg)))
      cat(sprintf("    %5d  [%s]  %s\n", agg$n[i],
                  tag[[agg$category[i]]] %||% agg$category[i], agg$key[i]))
    nrepo <- sum(errs$repo_caused %in% TRUE)
    nconv <- sum(errs$repo_caused %in% FALSE)
    namb  <- sum(is.na(errs$repo_caused))
    cat(sprintf("\n  Totals: repository=%d  converter=%d  ambiguous/other=%d  (of %d error rows)\n",
                nrepo, nconv, namb, nrow(errs)))
  }
}

psy_note <- if (DELETE_PSYCHDS_AFTER_VALIDATE) "(deleted after validation)" else PSYCHDS_OUT_DIR
cat(sprintf("\n%s\n  Done.\n  Outputs:    %s\n  psychDS:    %s\n  Summary:    %s\n  Per-paper:  %s\n  Conversion: %s\n  Validation: %s\n  Issues:     %s\n  Report:     %s\n  Report(md): %s\n%s\n",
            divider, OUTPUT_DIR, psy_note, SUMMARY_PATH, PAPER_PATH,
            CONVERSION_PATH, VALIDATION_PATH, VALIDATION_ISSUES_PATH,
            VALIDATION_REPORT_PATH, VALIDATION_REPORT_MD, divider))
