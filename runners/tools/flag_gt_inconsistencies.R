setwd(dirname(dirname(dirname(normalizePath(
  if (interactive()) "runners/tools/flag_gt_inconsistencies.R"
  else sub("--file=", "", grep("--file=", commandArgs(FALSE), value = TRUE)[1])
)))))

GT_DIR <- file.path("tests", "ground_truth")
if (!dir.exists(GT_DIR)) stop("GT dir not found: ", GT_DIR)

cat("Reading GT files from:", GT_DIR, "\n\n")

gt_files <- list.files(GT_DIR, pattern = "[.]csv$", recursive = TRUE, full.names = TRUE)
if (length(gt_files) == 0) stop("No GT CSV files found under: ", GT_DIR)

gt <- do.call(rbind, lapply(gt_files, function(f) {
  d <- tryCatch(
    read.csv(f, stringsAsFactors = FALSE, na.strings = c("", "NA"),
             colClasses = c(paper_id = "character")),
    error = function(e) { warning("Failed: ", f); NULL }
  )
  if (is.null(d)) return(NULL)
  d$source_file <- basename(dirname(f))
  d
}))

cat("Total rows:", nrow(gt), "\n")
cat("Papers:    ", length(unique(gt$paper_id)), "\n\n")

# ── helpers ───────────────────────────────────────────────────────────────────

has_val <- function(x) !is.na(x) & nzchar(trimws(x))
is_data <- has_val(gt$type_gt) & trimws(gt$type_gt) == "data"

DISPLAY_COLS <- c("paper_id", "rel_path", "type_gt", "group_gt",
                  "data_granularity_gt", "data_format_gt", "source_file")

checks <- list()

checks[["data_missing_granularity"]] <- list(
  label = "type='data' but data_granularity_gt missing",
  rows  = gt[ is_data & !has_val(gt$data_granularity_gt), ]
)
checks[["spurious_granularity"]] <- list(
  label = "data_granularity_gt set but type != 'data'",
  rows  = gt[!is_data &  has_val(gt$data_granularity_gt), ]
)
checks[["data_missing_format"]] <- list(
  label = "type='data' but data_format_gt missing",
  rows  = gt[ is_data & !has_val(gt$data_format_gt), ]
)
checks[["spurious_format"]] <- list(
  label = "data_format_gt (raw/tabular) set but type != 'data'",
  rows  = gt[!is_data &  has_val(gt$data_format_gt), ]
)

dup_key  <- paste(gt$paper_id, gt$rel_path, sep = "|||")
dup_rows <- gt[duplicated(dup_key) | duplicated(dup_key, fromLast = TRUE), ]
checks[["duplicate_paths"]] <- list(
  label = "duplicate rel_path within same paper_id",
  rows  = dup_rows[order(dup_rows$paper_id, dup_rows$rel_path), ]
)
checks[["missing_group"]] <- list(
  label = "group_gt missing",
  rows  = gt[!has_val(gt$group_gt), ]
)

# ── console report ────────────────────────────────────────────────────────────

report_block <- function(label, df) {
  cat(sprintf("── %s  (%d rows) ──────────────────\n", label, nrow(df)))
  if (nrow(df) == 0) { cat("  (none)\n\n"); return(invisible(NULL)) }
  cols <- intersect(DISPLAY_COLS, names(df))
  print(df[, cols], row.names = FALSE)
  cat("\n")
}

for (chk in checks) report_block(chk$label, chk$rows)

total <- sum(sapply(checks, function(x) nrow(x$rows)))
cat(sprintf("Total inconsistencies: %d\n\n", total))

# ── markdown report ───────────────────────────────────────────────────────────

md_table <- function(df) {
  cols <- intersect(DISPLAY_COLS, names(df))
  df   <- df[, cols, drop = FALSE]
  header <- paste0("| ", paste(cols, collapse = " | "), " |")
  sep    <- paste0("| ", paste(rep("---", length(cols)), collapse = " | "), " |")
  rows   <- apply(df, 1, function(r) {
    paste0("| ", paste(ifelse(is.na(r), "", r), collapse = " | "), " |")
  })
  paste(c(header, sep, rows), collapse = "\n")
}

lines <- c(
  "# Ground Truth Inconsistency Report",
  "",
  sprintf("**Date:** %s  ", Sys.Date()),
  sprintf("**Total rows:** %d  ", nrow(gt)),
  sprintf("**Papers:** %d  ", length(unique(gt$paper_id))),
  sprintf("**Total inconsistencies:** %d", total),
  ""
)

for (name in names(checks)) {
  chk <- checks[[name]]
  n   <- nrow(chk$rows)
  lines <- c(lines,
    sprintf("## %s  (%d)", chk$label, n),
    ""
  )
  if (n == 0) {
    lines <- c(lines, "_None_", "")
  } else {
    lines <- c(lines, md_table(chk$rows), "")
  }
}

dir.create("results", showWarnings = FALSE)

md_path <- file.path("results", "gt_inconsistencies.md")
writeLines(lines, md_path)
cat("Report saved:", md_path, "\n")

for (name in names(checks)) {
  df <- checks[[name]]$rows
  if (nrow(df) > 0) {
    f <- file.path("results", sprintf("gt_%s.csv", name))
    write.csv(df, f, row.names = FALSE)
    cat("Saved:", f, "\n")
  }
}
