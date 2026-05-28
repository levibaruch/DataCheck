# validate_psychds.R
# ---------------------------------------------------------------------------
# Validate the psychDS reconstructions produced by run_full_120b_json.R against
# the psych-DS spec, using the npm `psychds-validator` CLI:
#   https://www.npmjs.com/package/psychds-validator
#
# The unit of validation is ONE psychDS dataset = one row of conversion_summary.csv
# with success=TRUE (each carries an `output_path`; multi-study papers contribute
# several study-* dirs, single-study papers one root dir).
#
# For each dataset it runs:
#   npx psychds-validator <output_path> --json --showWarnings
# parses the JSON, and records validity + issue counts/keys.
#
# Outputs:
#   results/eval/full_120b_json/validation_summary.csv   one row per dataset
#
# Usage: Rscript runners/eval/validate_psychds.R
#        or source() from an interactive session.
# ---------------------------------------------------------------------------

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

RUN_BASE      <- "./results/eval/full_120b_json"
CONV_SUMMARY  <- file.path(RUN_BASE, "conversion_summary.csv")
OUT_PATH      <- file.path(RUN_BASE, "validation_summary.csv")

# psychds-validator invocation. `--no-install` fails fast if the package is
# missing rather than silently downloading it.
VALIDATOR     <- c("--no-install", "psychds-validator")
VALIDATOR_BIN <- "npx"

if (!file.exists(CONV_SUMMARY))
  stop("conversion_summary.csv not found: ", CONV_SUMMARY,
       "\nRun runners/eval/run_full_120b_json.R first.")

# Confirm the validator is reachable before churning through datasets.
probe <- suppressWarnings(tryCatch(
  system2(VALIDATOR_BIN, c(VALIDATOR, "--version"), stdout = TRUE, stderr = TRUE),
  error = function(e) NULL
))
probe_status <- if (is.null(probe)) 1L else (attr(probe, "status") %||% 0L)
if (is.null(probe) || probe_status != 0)
  stop("psychds-validator not runnable via `", VALIDATOR_BIN, " ",
       paste(VALIDATOR, collapse = " "), "`.\n",
       "Install it: npm i -g psychds-validator  (or npm i psychds-validator)\n",
       "Got: ", paste(probe, collapse = " "))
cat(sprintf("psychds-validator version: %s\n", paste(probe, collapse = " ")))

conv <- read.csv(CONV_SUMMARY, stringsAsFactors = FALSE,
                 colClasses = c(paper_id = "character"))

# conversion_summary.csv is append-only, so re-runs leave stale rows for the
# same paper — and re-runs can change the study grouping, so per-dataset dedup
# is not enough. A run emits a paper's groups consecutively, so each paper's
# most recent run is its LAST contiguous block of rows. Keep only that block
# per paper, then rewrite the file in place (DESTRUCTIVE — drops older runs).
pid   <- conv$paper_id
block <- cumsum(c(TRUE, pid[-1] != pid[-length(pid)]))
conv  <- conv[block == ave(block, pid, FUN = max), ]
write.csv(conv, CONV_SUMMARY, row.names = FALSE)

ok_rows  <- (conv$success %in% c(TRUE, "TRUE")) &
            !is.na(conv$output_path) & nzchar(conv$output_path)
datasets <- conv[ok_rows, ]
if (nrow(datasets) == 0) stop("No successful conversions with an output_path to validate.")

# Resume: skip datasets already validated (matched by output_path). Read the
# prior results into memory; tolerate a corrupt/unreadable file by starting fresh.
acc        <- NULL
done_paths <- character(0)
if (file.exists(OUT_PATH)) {
  prev <- tryCatch(read.csv(OUT_PATH, stringsAsFactors = FALSE,
                            colClasses = c(paper_id = "character")),
                   error = function(e) NULL)
  if (is.null(prev)) {
    warning("Existing ", OUT_PATH, " unreadable — revalidating from scratch.")
  } else {
    acc <- prev
    done_paths <- prev$output_path
  }
}

# Write the whole accumulated frame atomically (temp + rename) so a kill mid-run
# can never leave a half-written / NUL-padded file.
write_all <- function(df, path) {
  tmp <- paste0(path, ".tmp")
  write.csv(df, tmp, row.names = FALSE)
  file.rename(tmp, path)
}

# Run the validator on one directory; return parsed fields.
validate_one <- function(dir) {
  raw <- suppressWarnings(tryCatch(
    system2(VALIDATOR_BIN, c(VALIDATOR, shQuote(dir), "--json", "--showWarnings"),
            stdout = TRUE, stderr = FALSE),
    error = function(e) NULL
  ))
  if (is.null(raw) || length(raw) == 0)
    return(list(parsed = FALSE, valid = NA, n_errors = NA, n_warnings = NA,
                error_keys = "", warning_keys = ""))
  j <- tryCatch(jsonlite::fromJSON(paste(raw, collapse = "\n"), simplifyVector = FALSE),
                error = function(e) NULL)
  if (is.null(j) || is.null(j$issues))
    return(list(parsed = FALSE, valid = NA, n_errors = NA, n_warnings = NA,
                error_keys = "", warning_keys = ""))
  sev  <- vapply(j$issues, function(i) i$severity %||% NA_character_, character(1))
  keys <- vapply(j$issues, function(i) i$key %||% NA_character_, character(1))
  list(
    parsed       = TRUE,
    valid        = isTRUE(j$valid),
    n_errors     = sum(sev == "error",   na.rm = TRUE),
    n_warnings   = sum(sev == "warning", na.rm = TRUE),
    error_keys   = paste(unique(keys[sev == "error"]),   collapse = ";"),
    warning_keys = paste(unique(keys[sev == "warning"]), collapse = ";")
  )
}

divider <- paste0(rep("-", 72), collapse = "")
cat(sprintf("%s\n  Validating %d psychDS dataset(s) (%d already done)\n%s\n",
            divider, nrow(datasets), sum(datasets$output_path %in% done_paths), divider))

for (i in seq_len(nrow(datasets))) {
  row <- datasets[i, ]
  cat(sprintf("[%d/%d] %s / %s ... ", i, nrow(datasets), row$paper_id, row$study_group))

  if (row$output_path %in% done_paths) { cat("[SKIP]\n"); next }
  if (!dir.exists(row$output_path))    { cat("[MISSING DIR]\n"); next }

  v <- validate_one(row$output_path)
  out <- data.frame(
    paper_id     = row$paper_id,
    study_group  = row$study_group,
    output_path  = row$output_path,
    parsed       = v$parsed,
    valid        = v$valid,
    n_errors     = v$n_errors,
    n_warnings   = v$n_warnings,
    error_keys   = v$error_keys,
    warning_keys = v$warning_keys,
    stringsAsFactors = FALSE
  )
  acc <- rbind(acc, out)
  write_all(acc, OUT_PATH)   # rewrite full file each step → crash-safe resume

  if (!v$parsed) cat("PARSE FAIL\n")
  else cat(sprintf("%s  (errors=%d warnings=%d)\n",
                   if (isTRUE(v$valid)) "VALID" else "INVALID",
                   v$n_errors, v$n_warnings))
}

# Aggregate report from the in-memory accumulator (covers prior + new rows).
all <- acc
if (is.null(all) || nrow(all) == 0) {
  cat("\nNothing validated.\n")
} else {
  is_valid <- all$valid %in% c(TRUE, "TRUE")
  n_valid  <- sum(is_valid, na.rm = TRUE)
  n_total  <- nrow(all)
  paper_ok <- tapply(is_valid, all$paper_id, all)  # paper passes iff all its studies do
  err_keys <- unlist(strsplit(all$error_keys[nzchar(all$error_keys)], ";"))
  top_errs <- sort(table(err_keys), decreasing = TRUE)

  cat(sprintf("\n%s\n  Validation summary\n%s\n", divider, divider))
  cat(sprintf("  Datasets valid : %d / %d (%.1f%%)\n",
              n_valid, n_total, 100 * n_valid / n_total))
  cat(sprintf("  Papers  valid  : %d / %d (all studies pass)\n",
              sum(paper_ok), length(paper_ok)))
  if (length(top_errs) > 0) {
    cat("  Most common error keys (up to 5 sample paper_ids each):\n")
    for (k in head(names(top_errs), 10)) {
      has_k    <- vapply(strsplit(all$error_keys, ";"), function(ks) k %in% ks, logical(1))
      samples  <- head(unique(all$paper_id[has_k]), 5)
      cat(sprintf("    %4d  %s\n           %s\n",
                  top_errs[[k]], k, paste(samples, collapse = ", ")))
    }
  }
}
cat(sprintf("\n  Per-dataset detail: %s\n%s\n", OUT_PATH, divider))
