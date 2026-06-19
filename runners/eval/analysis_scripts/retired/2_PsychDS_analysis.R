#!/usr/bin/env Rscript
# eval_psychds.R — reporting layer for the PsychDS conversion + validation of the
# frozen gpt-oss-120b + JSON run. validate_psychds.R is the *runner* (it calls the
# psychds-validator CLI and writes validation_summary.csv); this turns that plus
# conversion_summary.csv into the thesis §0.1.3 figures/tables.
#
# Unit of conversion = one study group (a repository contributes one or more).
# A group must convert (DataCheck produced a valid PsychDS dir) before it can be
# validated, so the funnel is: groups processed → converted → validated.
#
# Reads  (under <run_base>/): conversion_summary.csv, validation_summary.csv
# Writes (under <run_base>/): psychds_summary.md
#                             psychds_conversion.csv   (conversion failure reasons)
#                             psychds_error_keys.csv   (validator error-key counts)
#                             plots/psychds_funnel.png      (processed→converted→valid)
#                             plots/psychds_error_keys.png  (error keys, invalid sets)
#
# Run from the repo root:  Rscript runners/eval/eval_psychds.R [run_base]
local({
  args     <- commandArgs(trailingOnly = TRUE)
  RUN_BASE <- if (length(args) >= 1) args[[1]] else "results/eval/full_120b_json"
  CONV_PATH <- file.path(RUN_BASE, "conversion_summary.csv")
  VAL_PATH  <- file.path(RUN_BASE, "validation_summary.csv")
  if (!file.exists(CONV_PATH)) stop("No conversion_summary.csv at ", CONV_PATH,
                                    " — run run_full_120b_json.R first.")

  MD_PATH    <- file.path(RUN_BASE, "psychds_summary.md")
  CONV_CSV   <- file.path(RUN_BASE, "psychds_conversion.csv")
  ERRKEY_CSV <- file.path(RUN_BASE, "psychds_error_keys.csv")
  PLOT_DIR   <- file.path(RUN_BASE, "plots")
  dir.create(PLOT_DIR, recursive = TRUE, showWarnings = FALSE)

  istrue <- function(x) x %in% c(TRUE, "TRUE")

  conv <- read.csv(CONV_PATH, stringsAsFactors = FALSE, colClasses = c(paper_id = "character"))
  val  <- if (file.exists(VAL_PATH))
            read.csv(VAL_PATH, stringsAsFactors = FALSE, colClasses = c(paper_id = "character"))
          else NULL

  # ── 1. Conversion funnel ────────────────────────────────────────────────────
  n_groups   <- nrow(conv)
  n_repos    <- length(unique(conv$paper_id))
  conv_ok    <- istrue(conv$success)
  n_conv     <- sum(conv_ok)
  fail       <- conv[!conv_ok, ]
  n_fail     <- nrow(fail)
  repos_fail <- length(unique(fail$paper_id))

  # Failure reasons (the `error` column is the DataCheck-side parse/convert error).
  reason <- function(e) {
    e <- ifelse(is.na(e) | !nzchar(e), "unspecified", e)
    e <- sub("\\n.*$", "", e)                      # first line only
    e <- ifelse(grepl("UTF-8|locale|invalid in this", e), "encoding (non-UTF-8 input)", e)
    e <- ifelse(grepl("no_data_files", e), "no data files in group", e)
    e
  }
  fr <- sort(table(reason(fail$error)), decreasing = TRUE)
  conv_df <- data.frame(
    reason   = names(fr),
    n_groups = as.integer(fr),
    n_repos  = vapply(names(fr), function(r)
                 length(unique(fail$paper_id[reason(fail$error) == r])), integer(1)),
    row.names = NULL, stringsAsFactors = FALSE
  )
  write.csv(conv_df, CONV_CSV, row.names = FALSE)

  # ── 2. Validation outcomes ──────────────────────────────────────────────────
  errkey_df <- NULL
  if (!is.null(val) && nrow(val) > 0) {
    parsed   <- istrue(val$parsed)
    is_valid <- istrue(val$valid)
    n_val    <- nrow(val)
    n_valid  <- sum(is_valid, na.rm = TRUE)
    n_inval  <- sum(parsed & !is_valid, na.rm = TRUE)
    n_unpars <- sum(!parsed, na.rm = TRUE)
    paper_ok <- tapply(is_valid, val$paper_id, all)        # paper valid iff all studies pass

    ek <- unlist(strsplit(val$error_keys[nzchar(val$error_keys)], ";"))
    ek_tab <- sort(table(ek), decreasing = TRUE)
    errkey_df <- data.frame(error_key = names(ek_tab), n_datasets = as.integer(ek_tab),
                            row.names = NULL, stringsAsFactors = FALSE)
    write.csv(errkey_df, ERRKEY_CSV, row.names = FALSE)
  }

  # ── Plots (base R; palette shared with the other eval reports) ───────────────
  PA_COL <- "#4C72B0"; FP_COL <- "#C44E52"; GREEN <- "#55A868"; GREY <- "#BDBDBD"

  # funnel: groups processed → converted → validated valid (stacked loss bars)
  png(file.path(PLOT_DIR, "psychds_funnel.png"), width = 900, height = 600, res = 100)
  par(mar = c(4, 5, 3, 1), mgp = c(2.6, 0.6, 0))
  if (!is.null(errkey_df)) {
    heights <- c(n_groups, n_conv, n_valid)
    labs    <- c("processed", "converted", "valid PsychDS")
  } else {
    heights <- c(n_groups, n_conv); labs <- c("processed", "converted")
  }
  b <- barplot(heights, names.arg = labs, col = PA_COL, border = NA,
               ylab = "study groups", ylim = c(0, n_groups * 1.1),
               main = "PsychDS conversion + validation funnel")
  text(b, heights + n_groups * 0.03, heights, cex = 0.9, col = PA_COL)
  dev.off()

  # validator error keys (only datasets that produced ≥1 error)
  if (!is.null(errkey_df) && nrow(errkey_df) > 0) {
    e <- errkey_df[order(errkey_df$n_datasets), ]
    png(file.path(PLOT_DIR, "psychds_error_keys.png"), width = 1000, height = 620, res = 100)
    par(mar = c(4.5, 17, 3, 2), mgp = c(2.6, 0.6, 0))
    bb <- barplot(e$n_datasets, names.arg = e$error_key, horiz = TRUE, las = 1,
                  border = NA, col = FP_COL, cex.names = 0.8,
                  xlab = "invalid datasets", xlim = c(0, max(e$n_datasets) * 1.15),
                  main = "PsychDS validator error keys")
    text(e$n_datasets + max(e$n_datasets) * 0.01, bb, e$n_datasets,
         cex = 0.8, col = FP_COL, adj = 0)
    dev.off()
  }

  # ── Markdown report ──────────────────────────────────────────────────────────
  md_tbl <- function(df, align = NULL) {
    nm <- names(df)
    if (is.null(align)) align <- rep("---", length(nm))
    body <- apply(df, 1, function(r) paste0("| ", paste(r, collapse = " | "), " |"))
    c(paste0("| ", paste(nm, collapse = " | "), " |"),
      paste0("| ", paste(align, collapse = " | "), " |"), body)
  }
  L <- c(
    "# PsychDS conversion + validation summary — frozen gpt-oss-120b + JSON run", "",
    sprintf("- Source: `%s`", RUN_BASE),
    sprintf("- Generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), "",
    "## 1. Conversion", "",
    sprintf("- **%d** study groups processed from **%d** repositories.", n_groups, n_repos),
    sprintf("- **%d** groups converted successfully (%.1f%%); **%d** failed (%.1f%%), across %d repositories.",
            n_conv, 100 * n_conv / n_groups, n_fail, 100 * n_fail / n_groups, repos_fail),
    "- Failures occur inside DataCheck (parse/convert), before PsychDS validation can start:", "",
    md_tbl(conv_df, c("---", "---:", "---:")), ""
  )
  if (!is.null(errkey_df)) {
    L <- c(L, "## 2. Validation", "",
      sprintf("- **%d** converted datasets validated against the PsychDS spec.", n_val),
      sprintf("- **%d** valid (%.1f%%), **%d** invalid (%.1f%%), **%d** unparseable validator output.",
              n_valid, 100 * n_valid / n_val, n_inval, 100 * n_inval / n_val, n_unpars),
      sprintf("- Repository level: **%d / %d** repositories fully valid (every study group passes).",
              sum(paper_ok, na.rm = TRUE), length(paper_ok)), "",
      "- Validator error keys across invalid datasets (a dataset may raise several):", "",
      md_tbl(errkey_df, c("---", "---:")), "",
      "![funnel](plots/psychds_funnel.png)", "",
      "![error keys](plots/psychds_error_keys.png)", "")
  } else {
    L <- c(L, "## 2. Validation", "",
      "_validation_summary.csv not found — run `runners/eval/validate_psychds.R` first._", "",
      "![funnel](plots/psychds_funnel.png)", "")
  }
  writeLines(L, MD_PATH)

  cat(sprintf("Wrote:\n  %s\n  %s\n", MD_PATH, CONV_CSV))
  if (!is.null(errkey_df)) cat(sprintf("  %s\n", ERRKEY_CSV))
  cat(sprintf("  %s/psychds_funnel.png%s\n", PLOT_DIR,
              if (!is.null(errkey_df)) " + psychds_error_keys.png" else ""))
})
