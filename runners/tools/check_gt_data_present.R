# check_gt_data_present.R
# ─────────────────────────────────────────────────────────────────────────────
# Verify that every ground-truth file has its corresponding raw data folder
# present on the Models drive at data/<source>/<paper_id>/.
#
# Usage: Rscript runners/tools/check_gt_data_present.R [--copy-from PATH]
#
#   --copy-from PATH   optional source root to cp -R missing folders from
#                       (e.g. /Volumes/NINJAV/data). Prints suggested commands
#                       only; does not execute.
#
# Exit code 0 if all present, 1 if any missing.
# ─────────────────────────────────────────────────────────────────────────────

GT_ROOT   <- "tests/ground_truth"
DATA_ROOT <- "data"

args       <- commandArgs(trailingOnly = TRUE)
copy_from  <- {
  i <- match("--copy-from", args)
  if (!is.na(i) && i < length(args)) args[i + 1] else NA_character_
}

sources <- list.dirs(GT_ROOT, recursive = FALSE, full.names = FALSE)
if (length(sources) == 0) stop("No source subdirs under ", GT_ROOT)

missing <- data.frame(source = character(0), paper_id = character(0),
                      expected = character(0), stringsAsFactors = FALSE)
ok_count <- 0L

for (src in sources) {
  gt_files <- list.files(file.path(GT_ROOT, src), pattern = "\\.csv$",
                         full.names = FALSE)
  for (f in gt_files) {
    pid      <- tools::file_path_sans_ext(f)
    expected <- file.path(DATA_ROOT, src, pid)
    if (dir.exists(expected)) {
      ok_count <- ok_count + 1L
    } else {
      missing <- rbind(missing,
                       data.frame(source = src, paper_id = pid,
                                  expected = expected,
                                  stringsAsFactors = FALSE))
    }
  }
}

cat(sprintf("GT papers with data present: %d\n", ok_count))
cat(sprintf("GT papers MISSING data:      %d\n", nrow(missing)))

if (nrow(missing) > 0) {
  cat("\nMissing paper folders:\n")
  for (i in seq_len(nrow(missing))) {
    cat(sprintf("  [%s] %s  →  %s\n",
                missing$source[i], missing$paper_id[i], missing$expected[i]))
  }
  if (!is.na(copy_from)) {
    cat("\nSuggested copy commands (review before running):\n")
    for (i in seq_len(nrow(missing))) {
      src_path <- file.path(copy_from, missing$source[i], missing$paper_id[i])
      cat(sprintf("  cp -R %s %s\n", shQuote(src_path),
                  shQuote(file.path(DATA_ROOT, missing$source[i]))))
    }
  }
  quit(status = 1)
}

cat("\nAll GT papers have data present.\n")
