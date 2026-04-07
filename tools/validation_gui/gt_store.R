# gt_store.R
# Ground-truth CSV read/write and paper discovery helpers.
# Paths are resolved relative to the data_check/ root set by app.R.
#
# Override options (set before launching the app to change default directories):
#   dc_outputs_dir   — override for outputs/<paper_id>/ root
#   dc_gt_dir        — override for ground_truth/ root
#   dc_papers_filter — character vector of paper IDs to expose (NULL = all)

# ── Path helpers ──────────────────────────────────────────────────────────────

get_outputs_dir <- function() {
  getOption("dc_outputs_dir",
            file.path(getOption("dc_root", "."), "outputs"))
}

get_gt_dir <- function() {
  getOption("dc_gt_dir",
            file.path(getOption("dc_root", "."), "ground_truth"))
}

# ── Canonical column order ────────────────────────────────────────────────────

GT_COLS <- c("paper_id", "rel_path", "type_gt", "group_gt",
             "data_granularity_gt", "data_format_gt", "validated_at", "annotator")

# ── Empty GT data.frame ───────────────────────────────────────────────────────

empty_gt <- function() {
  data.frame(
    paper_id             = character(0),
    rel_path             = character(0),
    type_gt              = character(0),
    group_gt             = character(0),
    data_granularity_gt  = character(0),
    data_format_gt       = character(0),
    validated_at         = character(0),
    annotator            = character(0),
    stringsAsFactors = FALSE
  )
}

# ── Paper discovery ───────────────────────────────────────────────────────────

# Returns a sorted character vector of paper IDs.
# When dc_papers_filter is set, only those IDs (with a structure.csv present)
# are returned; otherwise all subdirectories of outputs_dir are scanned.
discover_papers <- function() {
  outputs_dir <- get_outputs_dir()
  if (!dir.exists(outputs_dir)) return(character(0))
  filter <- getOption("dc_papers_filter", NULL)
  dirs <- if (!is.null(filter)) {
    filter[dir.exists(file.path(outputs_dir, filter))]
  } else {
    list.dirs(outputs_dir, full.names = FALSE, recursive = FALSE)
  }
  has_structure <- dirs[file.exists(file.path(outputs_dir, dirs, "structure.csv"))]
  sort(has_structure)
}

# ── Structure loading ─────────────────────────────────────────────────────────

load_structure <- function(paper_id) {
  path <- file.path(get_outputs_dir(), paper_id, "structure.csv")
  read.csv(path,
           colClasses      = c(paper_id    = "character",
                               is_sentinel = "logical"),
           stringsAsFactors = FALSE)
}

# ── Ground-truth read ─────────────────────────────────────────────────────────

read_gt <- function(paper_id) {
  path <- file.path(get_gt_dir(), paste0(paper_id, ".csv"))
  if (!file.exists(path)) return(empty_gt())
  tryCatch({
    df <- read.csv(path,
                   colClasses      = c(paper_id = "character"),
                   stringsAsFactors = FALSE)
    # Migrate legacy is_raw_gt column to data_granularity_gt
    if ("is_raw_gt" %in% names(df) && !"data_granularity_gt" %in% names(df)) {
      df$data_granularity_gt <- ifelse(isTRUE(df$is_raw_gt), "individual", NA_character_)
      df$is_raw_gt <- NULL
    }
    # Ensure all expected columns are present
    for (col in setdiff(GT_COLS, names(df))) df[[col]] <- NA_character_
    # Silently correct data_granularity_gt to NA for non-data files
    non_data <- !is.na(df$type_gt) & df$type_gt != "data"
    df$data_granularity_gt[non_data] <- NA_character_
    df[GT_COLS]
  }, error = function(e) {
    warning("Could not read ground truth for ", paper_id, ": ", conditionMessage(e))
    empty_gt()
  })
}

# ── Ground-truth write ────────────────────────────────────────────────────────

# Upsert one row (matched on rel_path) into the in-memory GT data.frame.
# Returns the updated data.frame.
upsert_gt <- function(gt_df, new_row) {
  existing <- which(gt_df$rel_path == new_row$rel_path)
  if (length(existing) > 0) {
    gt_df[existing[1], ] <- new_row
  } else {
    gt_df <- rbind(gt_df, new_row)
  }
  gt_df
}

# Write the full GT data.frame to disk immediately (no batching).
write_gt <- function(paper_id, gt_df) {
  gt_dir <- get_gt_dir()
  if (!dir.exists(gt_dir)) dir.create(gt_dir, recursive = TRUE)
  path <- file.path(gt_dir, paste0(paper_id, ".csv"))
  write.csv(gt_df[GT_COLS], path, row.names = FALSE)
  invisible(path)
}

# ── Paper completion helpers ──────────────────────────────────────────────────

# Returns a named logical vector (paper_id → complete?).
# A paper is complete if its GT file has at least as many rows as its structure.
paper_is_complete <- function(papers) {
  outputs_dir <- get_outputs_dir()
  gt_dir      <- get_gt_dir()
  result <- vapply(papers, function(pid) {
    struct_path <- file.path(outputs_dir, pid, "structure.csv")
    gt_path     <- file.path(gt_dir, paste0(pid, ".csv"))
    if (!file.exists(struct_path) || !file.exists(gt_path)) return(FALSE)
    tryCatch({
      n_struct <- nrow(read.csv(struct_path, stringsAsFactors = FALSE))
      n_gt     <- nrow(read.csv(gt_path, stringsAsFactors = FALSE))
      n_struct > 0L && n_gt >= n_struct
    }, error = function(e) FALSE)
  }, logical(1L))
  result
}

# Returns a named character vector suitable for selectInput choices.
# Complete papers are prefixed with a checkmark in their display label.
make_paper_choices <- function(papers, completion) {
  labels <- ifelse(completion[papers], paste0("\u2713 ", papers), papers)
  setNames(papers, labels)
}
