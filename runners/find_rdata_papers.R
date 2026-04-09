# find_rdata_papers.R
# ─────────────────────────────────────────────────────────────────────────────
# Scans all downloaded paper directories for .rda / .rdata files and writes
# a CSV index of findings.
#
# Usage: Rscript data_check/runners/find_rdata_papers.R
#
# Output: data_check/results/rdata_index.csv
#   paper_id   – paper ID (character)
#   rel_path   – path relative to the paper's data directory
#   n_objects  – total number of R objects in the file
#   n_df       – number of data.frame objects
#   df_names   – comma-separated names of data.frame objects
#   file_bytes – file size in bytes
# ─────────────────────────────────────────────────────────────────────────────

DATA_DIR   <- "./data_check/data"
OUTPUT_CSV <- "./data_check/results/rdata_index.csv"

paper_ids <- list.dirs(DATA_DIR, full.names = FALSE, recursive = FALSE)
paper_ids <- paper_ids[nchar(paper_ids) > 0]

if (length(paper_ids) == 0) stop("No paper directories found in ", DATA_DIR)

cat(sprintf("Scanning %d paper directories for .rda/.rdata files...\n", length(paper_ids)))

rows <- list()

for (pid in paper_ids) {
  paper_dir <- file.path(DATA_DIR, pid)
  all_files <- list.files(paper_dir, full.names = TRUE, recursive = TRUE)
  rdata_files <- all_files[tolower(tools::file_ext(all_files)) %in% c("rda", "rdata")]

  if (length(rdata_files) == 0) next

  for (fp in rdata_files) {
    env <- new.env()
    ok  <- tryCatch({ load(fp, envir = env); TRUE },
                    error = function(e) {
                      warning("Could not load ", fp, ": ", conditionMessage(e))
                      FALSE
                    })

    rel_path   <- sub(paste0("^", paper_dir, "/?"), "", fp)
    file_bytes <- file.info(fp)$size

    if (!ok) {
      rows[[length(rows) + 1L]] <- data.frame(
        paper_id   = pid,
        rel_path   = rel_path,
        n_objects  = NA_integer_,
        n_df       = NA_integer_,
        df_names   = NA_character_,
        file_bytes = file_bytes,
        stringsAsFactors = FALSE
      )
      next
    }

    objs <- as.list(env)
    dfs  <- Filter(is.data.frame, objs)

    rows[[length(rows) + 1L]] <- data.frame(
      paper_id   = pid,
      rel_path   = rel_path,
      n_objects  = length(objs),
      n_df       = length(dfs),
      df_names   = if (length(dfs) > 0) paste(names(dfs), collapse = ", ") else "",
      file_bytes = file_bytes,
      stringsAsFactors = FALSE
    )
  }
}

if (length(rows) == 0) {
  cat("No .rda/.rdata files found.\n")
} else {
  out <- do.call(rbind, rows)
  dir.create(dirname(OUTPUT_CSV), recursive = TRUE, showWarnings = FALSE)
  write.csv(out, OUTPUT_CSV, row.names = FALSE)
  cat(sprintf("Found %d file(s) across %d paper(s) → %s\n",
              nrow(out), length(unique(out$paper_id)), OUTPUT_CSV))
  cat(sprintf("  multi-DF files (n_df >= 2): %d\n", sum(!is.na(out$n_df) & out$n_df >= 2L)))
}
