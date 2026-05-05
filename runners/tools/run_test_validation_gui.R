# run_test_validation_gui.R
# ─────────────────────────────────────────────────────────────────────────────
# Launches the validation GUI in test mode:
#   - reads structure CSVs from  tests/outputs/<paper_id>/
#   - writes ground truth to     tests/ground_truth/<paper_id>.csv
#   - shows only the papers listed in tests/test_papers.csv
#
# Usage (from repo root):    Rscript runners/run_test_validation_gui.R
# Usage (from ):  Rscript runners/run_test_validation_gui.R
# Usage (interactive):       source("runners/run_test_validation_gui.R")
# ─────────────────────────────────────────────────────────────────────────────

dc_root <- normalizePath(
  if (basename(getwd()) == "data_check") "." else "data_check"
)

test_papers <- read.csv(
  file.path(dc_root, "tests", "test_papers.csv"),
  colClasses       = c(id = "character"),
  stringsAsFactors = FALSE
)

options(
  dc_root          = dc_root,
  dc_outputs_dir   = file.path(dc_root, "tests", "outputs", "osf"),
  dc_gt_dir        = file.path(dc_root, "tests", "ground_truth", "osf"),
  dc_papers_filter = test_papers$id[test_papers$source == "osf"]
)

shiny::runApp(file.path(dc_root, "tools", "validation_gui"))
