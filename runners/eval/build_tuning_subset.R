# build_tuning_subset.R
# Use all test_papers.csv papers as the tuning subset.
# Check GT coverage across all 9 file types.
# Flag any missing types for manual addition.
# Write results/eval/tuning_subset.csv

source("runners/eval/eval_helpers.R")

VALID_TYPES <- c("data", "codebook", "code", "software", "output",
                 "supplemental", "readme", "asset", "other")

papers_df <- read.csv(
  "./tests/eval_papers.csv",
  colClasses       = c(id = "character", source = "character"),
  stringsAsFactors = FALSE
)
if (!"source" %in% names(papers_df)) papers_df$source <- "osf"

cat(sprintf("Tuning subset: %d papers from test_papers.csv\n", nrow(papers_df)))

# Check file type coverage across GT files
covered_types <- character(0)
for (i in seq_len(nrow(papers_df))) {
  pid <- papers_df$id[i]
  src <- papers_df$source[i] %||% "osf"
  gt  <- read_gt(pid, src)
  if (!is.null(gt) && "type_gt" %in% names(gt))
    covered_types <- union(covered_types, unique(gt$type_gt[!is.na(gt$type_gt)]))
}

missing_types <- setdiff(VALID_TYPES, covered_types)

cat(sprintf("Covered types:  %s\n", paste(sort(covered_types), collapse = ", ")))
if (length(missing_types) > 0) {
  cat(sprintf(
    "\nWARNING: Missing types in tuning subset: %s\n",
    paste(missing_types, collapse = ", ")
  ))
  cat("Add papers with these file types to tests/test_papers.csv before running Step 1.\n\n")
} else {
  cat("All 9 file types covered.\n\n")
}

# Write tuning_subset.csv
dir.create(EVAL_RESULTS_DIR, recursive = TRUE, showWarnings = FALSE)
out_path <- file.path(EVAL_RESULTS_DIR, "tuning_subset.csv")
write.csv(papers_df[, c("id", "source")], out_path, row.names = FALSE)
cat(sprintf("Written: %s\n", out_path))
