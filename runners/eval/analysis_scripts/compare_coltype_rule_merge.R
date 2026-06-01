# compare_coltype_rule_merge.R
# ─────────────────────────────────────────────────────────────────────────────
# NON-DESTRUCTIVE check: does merging Rule 6a (decimal→continuous) into Rule 6
# (integer numeric) change any deterministic column classification?
#
# We do NOT rerun structure.csv. We read the FROZEN gpt-oss-120b JSON structure
# rows (type == "data"), read each data file with read_data_head(Inf), and apply
# BOTH the original classify_col_type_rules() and an alternative classify_col_type()
# that folds 6a into a single is.numeric() check. Per-column outputs compared.
#
# Output: results/eval/coltype_rule_merge_diff.csv  (only differing columns)
#         + a summary printed to stdout.
# ─────────────────────────────────────────────────────────────────────────────

source("pipeline/helper.R")   # read_data_head, sniff_delimiter, detect_header, classify_col_type_rules

MAX_FILE_READ_SEC <- 20L
N_ROWS_READ <- 10000L   # cap: both variants see identical df, so row count can't change their agreement

# ── Alternative: Rule 6a folded into Rule 6 (one is.numeric block) ────────────
classify_col_type_combined <- function(col_name, values) {
  x_noNA  <- values[!is.na(values)]
  n_noNA  <- length(x_noNA)
  if (n_noNA == 0)
    return(list(col_type = "empty", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))
  n_unique <- length(unique(x_noNA))

  id_pat <- paste0(
    "(?i)(",
    "^(participant|subject|subj|respondent|pp|ppt|pid|sub)$",
    "|^id$",
    "|[_\\-\\.](id|number|num|nr|no|code)$",
    "|^(subjectid|subjectnumber|responseid|recordid|participantid|",
    "subjectno|subjectnum|subjectcode|participantno|participantnum)$",
    "|^sub[_\\-]\\d",
    "|^(participant|subject|subj|pp|sub)[_\\-]?\\d+$",
    ")"
  )
  if (grepl(id_pat, col_name, perl = TRUE))
    return(list(col_type = "id", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))
  if (n_unique == 1)
    return(list(col_type = "constant", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))
  if (n_unique == 2)
    return(list(col_type = "binary", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))
  char_sample <- as.character(unique(x_noNA))[seq_len(min(20, n_unique))]
  n_date_ok   <- sum(vapply(char_sample, function(v) {
    tryCatch(!is.na(as.Date(v)), warning = function(w) FALSE, error = function(e) FALSE)
  }, logical(1)))
  if (n_date_ok / length(char_sample) >= 0.70)
    return(list(col_type = "date", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))
  if (median(nchar(as.character(x_noNA))) > 40)
    return(list(col_type = "text", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))

  # ── MERGED 6a + 6: single numeric handler ──────────────────────────────────
  # decimal OR >20 unique → continuous; else integer with 3–20 unique → LLM.
  if (is.numeric(values)) {
    if (any(x_noNA != floor(x_noNA)) || n_unique > 20)
      return(list(col_type = "continuous", ambiguous = FALSE, numeric_values = values,
                  n_coerced = NA_integer_, is_numeric = FALSE))
    return(list(col_type = NA_character_, ambiguous = TRUE, numeric_values = values,
                n_coerced = NA_integer_, is_numeric = TRUE))
  }

  x_sub  <- suppressWarnings(as.numeric(gsub(",", ".", as.character(x_noNA), fixed = TRUE)))
  pct_ok <- sum(!is.na(x_sub)) / n_noNA
  if (pct_ok >= 0.95) {
    num_vec   <- suppressWarnings(as.numeric(gsub(",", ".", as.character(values), fixed = TRUE)))
    n_coerced <- sum(is.na(x_sub))
    return(list(col_type = "continuous_comma_decimal", ambiguous = FALSE,
                numeric_values = num_vec, n_coerced = n_coerced, is_numeric = FALSE))
  }
  if (pct_ok >= 0.80) {
    num_vec   <- suppressWarnings(as.numeric(gsub(",", ".", as.character(values), fixed = TRUE)))
    n_coerced <- sum(is.na(x_sub))
    return(list(col_type = "continuous_outliers_excluded", ambiguous = FALSE,
                numeric_values = num_vec, n_coerced = n_coerced, is_numeric = FALSE))
  }
  return(list(col_type = NA_character_, ambiguous = TRUE, numeric_values = NULL,
              n_coerced = NA_integer_, is_numeric = FALSE))
}

norm <- function(cls) {
  ct <- if (is.null(cls$col_type) || is.na(cls$col_type)) "<NA>" else cls$col_type
  nc <- if (is.null(cls$n_coerced) || is.na(cls$n_coerced)) "<NA>" else as.character(cls$n_coerced)
  paste(ct, isTRUE(cls$ambiguous), isTRUE(cls$is_numeric), nc, sep = "|")
}

frozen_files <- Sys.glob("results/eval/outputs/step2/osf/*/gpt-oss-120b-low_json/structure.csv")
cat(sprintf("Frozen papers: %d\n", length(frozen_files)))

diffs   <- list()
n_cols  <- 0L
n_files <- 0L
n_papers_with_data <- 0L

t0 <- Sys.time()
fmt_hms <- function(sec) {
  sec <- as.integer(round(sec)); h <- sec %/% 3600; m <- (sec %% 3600) %/% 60; s <- sec %% 60
  sprintf("%02d:%02d:%02d", h, m, s)
}
N <- length(frozen_files)
trunc_str <- function(s, n) if (nchar(s) > n) paste0(substr(s, 1, n - 1), "…") else s

for (pi in seq_along(frozen_files)) {
  sf <- frozen_files[pi]
  paper_id <- basename(dirname(dirname(sf)))
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  eta     <- if (pi > 1) elapsed / (pi - 1) * (N - (pi - 1)) else NA_real_
  rate    <- if (elapsed > 0) n_cols / elapsed else 0
  cat(sprintf("\r%-120s\n[%s] elapsed=%s eta=%s | paper %3d/%d %s | files=%d cols=%d (%.0f/s) diffs=%d\n",
              "", format(Sys.time(), "%H:%M:%S"), fmt_hms(elapsed),
              if (is.na(eta)) "--:--:--" else fmt_hms(eta),
              pi, N, paper_id, n_files, n_cols, rate, length(diffs)))
  flush.console()
  st <- tryCatch(read.csv(sf, stringsAsFactors = FALSE), error = function(e) NULL)
  if (is.null(st) || !"type" %in% names(st)) next
  data_rows <- st[st$type == "data" & !is.na(st$path), , drop = FALSE]
  if (nrow(data_rows) == 0) next
  n_papers_with_data <- n_papers_with_data + 1L

  for (r in seq_len(nrow(data_rows))) {
    path <- data_rows$path[r]
    if (!file.exists(path)) next
    df <- tryCatch({
      setTimeLimit(elapsed = MAX_FILE_READ_SEC, transient = TRUE)
      res <- read_data_head(path, n_rows = N_ROWS_READ)
      setTimeLimit(elapsed = Inf, transient = FALSE)
      res
    }, error = function(e) { setTimeLimit(elapsed = Inf, transient = FALSE); NULL })
    if (is.null(df) || ncol(df) == 0) next
    n_files <- n_files + 1L

    fb <- trunc_str(basename(path), 32)
    for (i in seq_along(df)) {
      cn  <- names(df)[i]
      cat(sprintf("\r  %s  col %d/%d %-28s cols=%d diffs=%d%-15s",
                  fb, i, ncol(df), trunc_str(cn, 28), n_cols, length(diffs), ""))
      flush.console()
      o   <- tryCatch(classify_col_type_rules(cn, df[[i]]),    error = function(e) NULL)
      c2  <- tryCatch(classify_col_type_combined(cn, df[[i]]), error = function(e) NULL)
      if (is.null(o) || is.null(c2)) next
      n_cols <- n_cols + 1L
      if (!identical(norm(o), norm(c2))) {
        diffs[[length(diffs) + 1L]] <- data.frame(
          paper_id = paper_id, file = basename(path), column = cn,
          original = norm(o), combined = norm(c2), stringsAsFactors = FALSE)
      }
    }
  }
}

cat(sprintf("Papers with data files: %d\nData files read: %d\nColumns classified: %d\nColumns differing: %d\n",
            n_papers_with_data, n_files, n_cols, length(diffs)))

if (length(diffs) > 0) {
  out <- do.call(rbind, diffs)
  dir.create("results/eval", showWarnings = FALSE, recursive = TRUE)
  write.csv(out, "results/eval/coltype_rule_merge_diff.csv", row.names = FALSE)
  cat("Wrote diffs → results/eval/coltype_rule_merge_diff.csv\n")
  print(head(out, 50))
} else {
  cat("IDENTICAL: merging Rule 6a into Rule 6 produces the same classification for every column.\n")
}
