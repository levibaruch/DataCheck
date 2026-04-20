# 0_index.R
# ─────────────────────────────────────────────────────────────────────────────
# Full pipeline: download → unpack → understand structure → classify files
#                → extract columns + sample values → save
#
# Exports: run_index(paper_id = NA)
#
# Input:  paper_id (character, or NA to pick randomly)
# Output: list with pipeline results (see return value at bottom of function)
#         data_check/structure/<paper_id>_structure.csv   (one row per file)
#         data_check/structure/<paper_id>_columns.csv     (one row per column)
# ─────────────────────────────────────────────────────────────────────────────

library(metacheck)
source("data_check/pipeline/helper.R")
source("data_check/pipeline/prompts.R")

llm_use(TRUE)
llm_model("ollama/gpt-oss:20b-cloud")

# ── Constants ─────────────────────────────────────────────────────────────────


if (!exists("DATA_DIR"))         DATA_DIR         <- "./data_check/data"
if (!exists("OUTPUT_DIR"))       OUTPUT_DIR       <- "./data_check/outputs"
if (!exists("PSYCHDS_OUT_DIR"))  PSYCHDS_OUT_DIR  <- "./data_check/psychds"
if (!exists("GROUND_TRUTH_DIR")) GROUND_TRUTH_DIR <- "./data_check/ground_truth"
ARCHIVE_EXTS    <- c("zip", "gz", "tar", "tgz", "bz2", "xz", "rar")


# Closed set of valid file type values (from output-schemas.md).
# Any LLM response containing a type not in this set triggers a retry.


if (!exists("LLM_TEMPERATURE"))   LLM_TEMPERATURE   <- 0.7
if (!exists("LLM_THINK_LEVEL"))   LLM_THINK_LEVEL   <- "low"
if (!exists("LLM_BATCH_SIZE"))    LLM_BATCH_SIZE    <- 30
if (!exists("LLM_RETRY_LIMIT"))   LLM_RETRY_LIMIT   <- 4L
if (!exists("LLM_ERROR_LOG"))     LLM_ERROR_LOG     <- "./data_check/logs/llm_batch_errors.log"
if (!exists("LLM_SENTINEL_VAL"))  LLM_SENTINEL_VAL  <- "llm_error"
if (!exists("CAPTURE_THINKING"))  CAPTURE_THINKING  <- FALSE
if (!exists("THINKING_LOG_PATH")) THINKING_LOG_PATH <- NULL

N_DATA_READ     <- 5
MAX_TOTAL_DATA_MB <- 10 * 1024  # 10 GB total data read cap per paper across all data files
MAX_FILE_READ_SEC <- 1 * 60    # per-file read timeout (seconds); file is skipped if exceeded

VALID_FILE_TYPES <- c(
  "data", "codebook", "code", "software", "output",
  "supplemental", "readme", "asset", "other", LLM_SENTINEL_VAL
)
VALID_COL_TYPES <- c("continuous", "binary", "categorical", "ordinal", "date", "id",
                     "text", "continuous_comma_decimal", "continuous_outliers_excluded",
                     "empty", "constant", "unknown",
                     LLM_SENTINEL_VAL)
if (!exists("MAX_COL_TYPE_LLM_CALLS"))      MAX_COL_TYPE_LLM_CALLS      <- 5L
if (!exists("MAX_CHAR_COL_TYPE_LLM_CALLS")) MAX_CHAR_COL_TYPE_LLM_CALLS <- 3L
if (!exists("MAX_GRANULARITY_LLM_CALLS"))   MAX_GRANULARITY_LLM_CALLS   <- 1L  # US3: max LLM calls for granularity (aggregate folders with unclear signals)
if (!exists("MAX_DATA_FILES"))              MAX_DATA_FILES              <- Inf  # cap on tabular data files to column-extract per paper (Inf = no cap)
if (!exists("FULL_RUN"))                    FULL_RUN                    <- FALSE
if (!exists("SKIP_COLUMNS"))               SKIP_COLUMNS                <- FALSE  # TRUE = skip column extraction entirely
if (!exists("COLUMNS_ONLY"))               COLUMNS_ONLY                <- FALSE  # TRUE = skip download+LLM, read existing structure.csv, run columns only
# Folders with more than this many files are treated as aggregate datasets
AGGREGATE_THRESHOLD <- 20
# Max rows to scan below row 1 for a usable sub-header in multi-level CSV files
MULTILEVEL_HEADER_LOOKAHEAD <- 3L
# Directory names longer than this many words are truncated; spaces → underscores
MAX_DIR_WORDS   <- 5

# Local repository of more xmls. Remove to fallback to psychsci.
XML_DIR <- "/Volumes/Models/expanded_xml" #"./data-raw/psychsci/grobid_0.8.2-full"

# Repositories that host open data badges and other useless junk
BADGE_REPOS <- c("tvyxz", "osf.io/tvyxz/", "osf.io/tvyxz")

# ── Pipeline function ─────────────────────────────────────────────────────────

run_index <- function(paper_id = NA, download = TRUE, output_dir = NULL, structure_prompt_version = "current") {

  t_start <- proc.time()[["elapsed"]]

  # Select STRUCTURE_PROMPT body based on version (for AB testing)
  structure_body <- switch(structure_prompt_version,
    "v0"      = STRUCTURE_PROMPT_v0,
    "v1"      = STRUCTURE_PROMPT_v1,
    "current" = STRUCTURE_PROMPT,
    STRUCTURE_PROMPT  # default
  )

  # ── 0. Resolve paper ────────────────────────────────────────────────────────

  if (is.na(paper_id)) {
    xml_files <- list.files(XML_DIR, pattern = "\\.xml$", full.names = FALSE)
    if (length(xml_files) == 0) stop("No XML files found in ", XML_DIR)
    paper_id  <- tools::file_path_sans_ext(sample(xml_files, 1))
    message("── Randomly selected paper: ", paper_id)
  }
  print(paper_id)

  is_dv      <- is_dataverse_id(paper_id)
  source     <- if (is_dv) "dataverse" else "osf"
  
  eff_dir <- if (!is.null(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    output_dir
  } else paper_output_dir(source, paper_id)

  target_dir <- paper_path("data", source, paper_id)

  # Warn if data exists at the legacy flat path but not at the new source-aware path
  legacy_dir <- file.path(DATA_DIR, paper_id)
  if (!dir.exists(target_dir) && dir.exists(legacy_dir))
    warning(sprintf(
      "Legacy data found at '%s'; expected source-aware path '%s' does not exist. ",
      legacy_dir, target_dir
    ))

  # ── COLUMNS_ONLY: skip download + LLM; read existing structure.csv ───────────

  if (COLUMNS_ONLY) {
    structure_out <- file.path(eff_dir, "structure.csv")
    if (!file.exists(structure_out))
      stop("columns_only_missing_structure: no structure.csv found for paper ", paper_id)
    file_df <- read.csv(structure_out, stringsAsFactors = FALSE,
                        colClasses = c(paper_id = "character"))
    agg_dirs <- unique(file_df$aggregate_folder[
      !is.na(file_df$aggregate_folder) & nchar(file_df$aggregate_folder) > 0
    ])
    t_download <- 0
    t_llm      <- 0
    message("── COLUMNS_ONLY: skipping download + LLM; loaded ",
            nrow(file_df), " files from existing structure.csv")
  } else {

  # ── 1. Download ─────────────────────────────────────────────────────────────

  t_download_start <- proc.time()[["elapsed"]]
  if (is_dv) {
    # ── Dataverse: skip download; verify directory exists ────────────────────
    if (!dir.exists(target_dir))
      stop("dataverse_dir_missing: no directory found at ", target_dir,
           " for deposit ", paper_id)
    t_download <- 0
    message("── Dataverse deposit: skipping download, reading from ", target_dir)
  } else if (download) {
    xml_path <- file.path(XML_DIR, paste0(paper_id, ".xml"))
    paper    <- read(xml_path)
    stopifnot(!is.null(paper$id))

    links        <- osf_links(paper)
    unique_links <- setdiff(unique(links$text), BADGE_REPOS)

    if (length(unique_links) == 0) {
      stop("no_links: paper ", paper_id, " has no OSF data links")
    }

    if (!dir.exists(target_dir)) {
      osf_file_download(unique_links, download_to = target_dir,
                        max_download_size = 10e9, max_file_size = NULL)
    }
  }

  # ── 2. Sanitize directory names ─────────────────────────────────────────────

  sanitize_name <- function(name) {
    words <- strsplit(trimws(name), "\\s+")[[1]]
    words <- gsub("[^A-Za-z0-9_\\-]", "", words)  # strip ; : ? and other special chars
    words <- words[nchar(words) > 0]
    paste(head(words, MAX_DIR_WORDS), collapse = "_")
  }

  if (dir.exists(target_dir)) {
    all_dirs <- list.dirs(target_dir, full.names = TRUE, recursive = TRUE)
    all_dirs <- all_dirs[all_dirs != target_dir]

    for (i in seq_along(all_dirs)) {
      d <- all_dirs[i]
      if (!dir.exists(d)) next
      dname <- basename(d)
      if (!grepl("[^A-Za-z0-9_.\\-]", dname)) next  # skip if already clean
      new_name <- sanitize_name(dname)
      new_path <- file.path(dirname(d), new_name)
      if (new_path != d && !file.exists(new_path)) {
        file.rename(d, new_path)
        old_prefix <- paste0(d, "/")
        new_prefix <- paste0(new_path, "/")
        needs_update <- startsWith(all_dirs, old_prefix)
        all_dirs[needs_update] <- paste0(new_prefix,
          substr(all_dirs[needs_update], nchar(old_prefix) + 1L, nchar(all_dirs[needs_update])))
      }
    }
  }

  # ── 3. Unpack archives ──────────────────────────────────────────────────────

  # Helper: strip .git internals — repos sometimes include git-tracked task
  # scripts whose .git/ objects would otherwise flood the file list with
  # hundreds of meaningless SHA blobs.
  drop_git <- function(paths) paths[!grepl("(^|/)\\.git(/|$)", paths, perl = TRUE)]

  files <- if (dir.exists(target_dir)) {
    drop_git(list.files(target_dir, full.names = TRUE, recursive = TRUE))
  } else {
    character(0)
  }

  if (length(files) == 0) {
    if (!dir.exists(target_dir)) {
      stop("download_failed: OSF download produced no directory for paper ", paper_id)
    } else {
      stop("empty_repo: directory exists but contains no files for paper ", paper_id)
    }
  }

  archive_paths <- files[tolower(tools::file_ext(files)) %in% ARCHIVE_EXTS]

  if (length(archive_paths) > 0) {
    n_already <- sum(vapply(archive_paths, function(p) {
      dir.exists(file.path(dirname(p), tools::file_path_sans_ext(basename(p))))
    }, logical(1)))
    n_new <- length(archive_paths) - n_already
    parts <- c(
      if (n_new     > 0) sprintf("%d unpacked", n_new),
      if (n_already > 0) sprintf("%d already done", n_already)
    )
    cat(col_dim(sprintf("── %d archive(s): %s\n", length(archive_paths), paste(parts, collapse = ", "))))
    suppressMessages(lapply(archive_paths, unpack_archive))
    files <- drop_git(list.files(target_dir, full.names = TRUE, recursive = TRUE))
    files <- files[!(tolower(tools::file_ext(files)) %in% ARCHIVE_EXTS)]
  }

  # ── 3b. Explode multi-sheet Excel files into per-sheet CSVs ─────────────────
  # Each sheet becomes <stem>_<sheet_name>.csv alongside the original.
  # The original xlsx/xls is then deleted so downstream sees only flat CSVs.

  excel_paths <- files[tolower(tools::file_ext(files)) %in% c("xlsx", "xls", "xlsm")]
  if (length(excel_paths) > 0) {
    for (xl in excel_paths) {
      sheets <- tryCatch(readxl::excel_sheets(xl), error = function(e) {
        warning("Could not read sheets from ", basename(xl), ": ", conditionMessage(e))
        character(0)
      })
      if (length(sheets) == 0) next
      stem    <- tools::file_path_sans_ext(xl)
      n_written       <- 0L
      n_renamed       <- 0L
      rename_examples <- character(0)
      for (sh in sheets) {
        df <- tryCatch(
          suppressMessages(
            as.data.frame(readxl::read_excel(xl, sheet = sh), stringsAsFactors = FALSE)
          ),
          error = function(e) {
            warning("  skipping sheet '", sh, "' in ", basename(xl),
                    ": ", conditionMessage(e))
            NULL
          }
        )
        if (is.null(df) || nrow(df) == 0) next
        unnamed_mask <- grepl("^\\.\\.\\.\\d+$", names(df))
        n_renamed <- n_renamed + sum(unnamed_mask)
        if (sum(unnamed_mask) > 0) {
          named_examples <- head(names(df)[!unnamed_mask], 4L)
          if (length(named_examples) > 0)
            rename_examples <- c(rename_examples, named_examples)
        }
        safe_sh  <- gsub("[/\\\\:*?\"<>|]", "_", sh)
        out_path <- paste0(stem, "_", safe_sh, ".csv")
        write.csv(df, out_path, row.names = FALSE)
        n_written <- n_written + 1L
      }
      if (n_written > 0) {
        rename_note <- if (n_renamed > 0) {
          ex <- unique(rename_examples)
          ex_str <- if (length(ex) > 0)
            paste0("; named: ", paste(head(ex, 4L), collapse = ", "),
                   if (length(ex) > 4L) " ..." else "")
          else ""
          sprintf("  [%d unnamed%s]", n_renamed, ex_str)
        } else ""
        message("  exploded ", basename(xl), " \u2192 ", n_written, " CSV(s)", rename_note)
        file.remove(xl)
      }
    }
    # Refresh file list after explosion
    files <- drop_git(list.files(target_dir, full.names = TRUE, recursive = TRUE))
    files <- files[!(tolower(tools::file_ext(files)) %in% ARCHIVE_EXTS)]
  }

  # ── 3b-ii. Explode multi-object RData / Rda files into per-object CSVs ───────
  # An .rda/.rdata may contain several data.frame objects.  Each becomes
  # <stem>_<varname>.csv alongside the original; original is deleted once at
  # least one CSV is written.  Single-object files are left untouched —
  # read_data_head() handles them fine as-is.
  rdata_paths <- files[tolower(tools::file_ext(files)) %in% c("rda", "rdata")]
  if (length(rdata_paths) > 0) {
    rdata_exploded <- FALSE
    for (rp in rdata_paths) {
      env <- new.env()
      ok  <- tryCatch({
        withCallingHandlers(
          load(rp, envir = env),
          warning = function(w) {
            if (grepl("namespace.*is not available", conditionMessage(w),
                      ignore.case = TRUE))
              invokeRestart("muffleWarning")
          }
        )
        TRUE
      }, error = function(e) {
        warning("Could not load ", basename(rp), ": ", conditionMessage(e))
        FALSE
      })
      if (!ok) next
      dfs <- Filter(is.data.frame, as.list(env))
      if (length(dfs) < 2) next    # 0 or 1 data frame — no explosion needed
      stem      <- tools::file_path_sans_ext(rp)
      n_written <- 0L
      for (nm in names(dfs)) {
        df <- dfs[[nm]]
        if (nrow(df) == 0) next
        safe_nm  <- gsub("[/\\\\:*?\"<>|]", "_", nm)
        out_path <- paste0(stem, "_", safe_nm, ".csv")
        tryCatch(
          { write.csv(df, out_path, row.names = FALSE); n_written <- n_written + 1L },
          error = function(e)
            warning("  could not write ", basename(out_path), ": ", conditionMessage(e))
        )
      }
      if (n_written > 0) {
        message("  exploded ", basename(rp), " → ", n_written, " CSV(s)")
        file.remove(rp)
        rdata_exploded <- TRUE
      }
    }
    if (rdata_exploded) {
      files <- drop_git(list.files(target_dir, full.names = TRUE, recursive = TRUE))
      files <- files[!(tolower(tools::file_ext(files)) %in% ARCHIVE_EXTS)]
    }
  }

  # ── 3c. Remove duplicate files ──────────────────────────────────────────────
  # Files with the same basename AND byte-size are candidate duplicates.
  # For text-based formats (csv/tsv/txt/dat), confirm by comparing the first
  # 3 lines; for other formats, name+size alone is treated as sufficient.
  # Duplicates are dropped from 'files' before LLM classification so they
  # don't consume LLM calls or column-extraction time. Only the first
  # occurrence of each duplicate group is kept.
  finfo       <- file.info(files)
  dedup_key   <- paste(basename(files), finfo$size, sep = "\01")
  is_dup_cand <- duplicated(dedup_key) | duplicated(dedup_key, fromLast = TRUE)

  if (any(is_dup_cand)) {
    text_exts <- c("csv", "tsv", "txt", "dat")
    dup_files <- character(0)

    for (k in unique(dedup_key[is_dup_cand])) {
      group <- files[dedup_key == k]
      ext   <- tolower(tools::file_ext(group[1]))
      if (ext %in% text_exts) {
        fingerprints <- vapply(group, function(p) {
          tryCatch(paste(readLines(p, n = 3L, warn = FALSE), collapse = "\n"),
                   error = function(e) "")
        }, character(1))
        dup_files <- c(dup_files, group[duplicated(fingerprints)])
      } else {
        dup_files <- c(dup_files, group[-1L])   # keep first, discard rest
      }
    }

    if (length(dup_files) > 0) {
      message("── Removed ", length(dup_files), " duplicate file(s) (same name, size",
              ", and content)")
      files <- setdiff(files, dup_files)
    }
  }

  # ── 4. Build relative-path tree ─────────────────────────────────────────────

  norm_base  <- normalizePath(target_dir, mustWork = FALSE)
  rel_paths  <- sub(paste0("^", norm_base, "/?"), "",
                    normalizePath(files, mustWork = FALSE))

  # ── 5. Detect aggregate folders ─────────────────────────────────────────────
  # Two patterns are treated as aggregate (collapsed to a single sentinel row):
  #
  #  A) FLAT AGGREGATE: a folder with > AGGREGATE_THRESHOLD direct file children.
  #
  #  B) PARTICIPANT AGGREGATE: a folder whose immediate subdirectories are mostly
  #     numeric-looking names (participant / subject IDs such as 17230, 17238 …)
  #     and there are > AGGREGATE_THRESHOLD such subfolders.
  #
  #     Detection uses list.dirs() rather than inferring ancestry from rel_paths.
  #     The path-decomposition approach (grandparents = strip filename from path)
  #     produces grandparent == top_dirs for every file, so it can never find
  #     numeric child *directories* — only files whose name is numeric.  More
  #     importantly it silently fails for participant folders nested more than one
  #     level below the paper root (e.g. paper/Fear/FCTM_Data/FCTM_Exp1/17230/).

  top_dirs   <- dirname(rel_paths)
  dir_counts <- table(top_dirs)

  # Pattern A
  flat_agg_dirs <- names(dir_counts[dir_counts > AGGREGATE_THRESHOLD])

  # Pattern B — scan actual directory tree so depth doesn't matter
  all_actual_dirs <- list.dirs(target_dir, full.names = FALSE, recursive = TRUE)
  all_actual_dirs <- all_actual_dirs[all_actual_dirs != ""]
  all_actual_dirs <- all_actual_dirs[
    !grepl("(^|/)\\.git(/|$)", all_actual_dirs, perl = TRUE)]

  participant_agg_dirs <- character(0)
  for (d in all_actual_dirs) {
    prefix      <- paste0(d, "/")
    children    <- all_actual_dirs[startsWith(all_actual_dirs, prefix)]
    child_names <- sub(prefix, "", children, fixed = TRUE)
    # Keep only *direct* children (no slash = no further nesting)
    child_names <- child_names[!grepl("/", child_names, fixed = TRUE)]
    if (length(child_names) == 0) next
    n_participant <- sum(vapply(child_names, is_participant_id, logical(1L)))
    if (n_participant > AGGREGATE_THRESHOLD) {
      participant_agg_dirs <- c(participant_agg_dirs, d)
    }
  }

  agg_dirs <- unique(c(flat_agg_dirs, participant_agg_dirs))
  is_under_participant_agg <- vapply(rel_paths, function(p) {
    any(startsWith(p, paste0(participant_agg_dirs, "/")))
  }, logical(1))

  is_aggregate <- (top_dirs %in% flat_agg_dirs) | is_under_participant_agg

  # ── 5b. Group aggregate folders by extension ──────────────────────────────────
  # Each aggregate folder is split into extension groups by group_aggregate_folder().
  # Groups with >= AGGREGATE_THRESHOLD members → sample_paths join the Phase 1 LLM
  # batch; the LLM result is propagated to all members (type_source = "aggregate_llm").
  # Groups with < AGGREGATE_THRESHOLD members → members routed individually to Phase 1.

  extra_singletons <- character(0)
  agg_groups_list  <- list()  # all extension groups that produce sentinels

  if (any(is_aggregate)) {
    cat(col_cyan(sprintf("\n── Aggregate folders (%d detected) \u2014 classifying:\n", length(agg_dirs))))
    for (d in agg_dirs) {
      if (d %in% participant_agg_dirs) {
        members <- rel_paths[startsWith(rel_paths, paste0(d, "/"))]
      } else {
        members <- rel_paths[top_dirs == d]
      }

      groups <- group_aggregate_folder(members, folder = d)

      for (g in groups) {
        # Detect if this group is a participant series (extended pattern detection)
        is_series <- FALSE
        if (d %in% participant_agg_dirs) {
          # In participant aggregate dirs, check if members follow participant ID pattern
          # (numeric, sub###, s##, P##, ID##, participant##, pp##, vp##, subj##)
          basenames <- basename(dirname(g$members))
          n_participant <- sum(vapply(basenames, is_participant_id, logical(1L)))
          is_series <- (n_participant > (length(g$members) / 2))  # majority match participant patterns
        }
        g$is_series <- is_series

        if (g$route_individually) {
          extra_singletons <- c(extra_singletons, g$members)
        } else {
          agg_groups_list <- c(agg_groups_list, list(g))
          cat(sprintf("  \u00d7%-4d  %s/.%s\n",
                      length(g$members), d, g$ext))
        }
      }
    }
  }

  # Collect sample paths from all sentinel extension groups
  agg_sample_paths <- unlist(lapply(agg_groups_list, `[[`, "sample_paths"),
                             use.names = FALSE)

  non_agg_relpaths <- c(rel_paths[!is_aggregate], extra_singletons)

  # Phase 1: individual (non-aggregate) files only. Aggregates classified in Phase 2.
  llm_paths <- non_agg_relpaths

  # ── 6. LLM: classify all paths in a single phase ────────────────────────────

  if (!is_dv) t_download <- proc.time()[["elapsed"]] - t_download_start

  t_llm_start   <- proc.time()[["elapsed"]]
  MAX_LLM_CALLS <- 10
  n_p1_calls <- ceiling(length(llm_paths) / LLM_BATCH_SIZE)
  n_p2_calls <- ceiling(length(agg_groups_list) / LLM_BATCH_SIZE)
  if (!FULL_RUN && (n_p1_calls + n_p2_calls) > MAX_LLM_CALLS) {
    stop("too_large: ", length(llm_paths), " individual + ", length(agg_groups_list),
         " aggregate paths would require ", n_p1_calls + n_p2_calls,
         " LLM calls (max ", MAX_LLM_CALLS, ")")
  }

  # Build a compact experiment-map summary from prior batch results to pass as
  # context to subsequent batches, improving cross-batch group label consistency.
  build_structure_summary <- function(exp_map, type_map, last_entry = NULL) {
    sections <- character(0)

    if (!is.null(last_entry)) {
      sections <- c(sections,
        paste0("Last classified file (continue consistently from here):\n",
               '- "', last_entry$path, '" → type: ', last_entry$type,
               ', group: ', last_entry$group))
    }

    if (length(type_map) > 0) {
      type_lines <- vapply(names(type_map), function(tp) {
        examples <- unique(type_map[[tp]])
        paste0("- ", tp, ': "', paste(head(examples, 2L), collapse = '", "'), '"')
      }, character(1))
      sections <- c(sections,
        paste0("Known type classifications from prior batches:\n",
               paste(type_lines, collapse = "\n")))
    }

    if (length(exp_map) > 0) {
      grp_lines <- vapply(names(exp_map), function(grp) {
        tokens <- unique(exp_map[[grp]])
        paste0("- ", grp, ': "', paste(head(tokens, 3L), collapse = '", "'), '"')
      }, character(1))
      sections <- c(sections,
        paste0("Known experiment structure from prior batches:\n",
               paste(grp_lines, collapse = "\n")))
    }

    if (length(sections) == 0) return("Classify this repository tree:")
    paste0(
      paste(sections, collapse = "\n\n"),
      "\nApply these classifications consistently to the following paths.\n\n",
      "Classify this repository tree:"
    )
  }

  build_sentinel_summary <- function(exp_map, type_map) {
    sections <- character(0)

    if (length(type_map) > 0) {
      type_lines <- vapply(names(type_map), function(tp) {
        examples <- unique(type_map[[tp]])
        paste0("- ", tp, ': "', paste(head(examples, 2L), collapse = '", "'), '"')
      }, character(1))
      sections <- c(sections,
        paste0("Known type classifications from Phase 1:\n",
               paste(type_lines, collapse = "\n")))
    }

    if (length(exp_map) > 0) {
      grp_lines <- vapply(names(exp_map), function(grp) {
        tokens <- unique(exp_map[[grp]])
        paste0("- ", grp, ': "', paste(head(tokens, 3L), collapse = '", "'), '"')
      }, character(1))
      sections <- c(sections,
        paste0("Known experiment structure from Phase 1 classification:\n",
               paste(grp_lines, collapse = "\n")))
    }

    if (length(sections) == 0) return("Classify these aggregate folder series:")
    paste0(
      paste(sections, collapse = "\n\n"),
      "\nUse these assignments when classifying the following aggregate series.\n\n",
      "Classify these aggregate folder series:"
    )
  }

  build_agg_descriptors <- function(agg_groups_list) {
    vapply(agg_groups_list, function(g) {
      fnames <- paste0('"', paste(basename(g$sample_paths), collapse = '", "'), '"')
      sprintf('{"path": "%s/.%s", "ext": "%s", "n_files": %d, "filenames": [%s]}',
              g$folder, g$ext, g$ext, length(g$members), fnames)
    }, character(1))
  }

  update_experiment_map <- function(exp_map, batch_result) {
    grp_values <- batch_result$group
    for (i in seq_along(grp_values)) {
      grp <- grp_values[i]
      if (!is.na(grp) && grepl("^(ex|pilot|shared)", grp)) {
        token <- basename(dirname(batch_result$path[i]))
        if (nchar(token) == 0 || token == ".") token <- basename(batch_result$path[i])
        exp_map[[grp]] <- unique(c(exp_map[[grp]], token))
      }
    }
    exp_map
  }

  update_type_map <- function(type_map, batch_result) {
    for (i in seq_along(batch_result$type)) {
      tp <- batch_result$type[i]
      if (!is.na(tp)) {
        example <- basename(batch_result$path[i])
        type_map[[tp]] <- unique(c(type_map[[tp]], example))
      }
    }
    type_map
  }

  # ── Phase 1: classify non-aggregate + singleton paths ─────────────────────

  experiment_map   <- list()
  type_map         <- list()
  last_entry       <- NULL
  structure_parsed <- NULL
  agg_parsed       <- NULL

  if (length(llm_paths) > 0) {
    chunks <- split(llm_paths, ceiling(seq_along(llm_paths) / LLM_BATCH_SIZE))
    cat(col_dim(sprintf("── Classifying %d file path(s) via LLM (%d batch(es))\n",
                length(llm_paths), length(chunks))))

    for (i in seq_along(chunks)) {
      prefix       <- if (i == 1) "Classify this repository tree:" else
                        build_structure_summary(experiment_map, type_map, last_entry)
      batch_result <- llm_batch(
        paths           = chunks[[i]],
        system_prompt   = paste0(SINGLE_HEADER, structure_body),
        user_prefix     = prefix,
        key_col         = "path",
        extra_cols      = c("type", "group"),
        fallback_vals   = list(type = "other", group = "shared"),
        sentinel_cols   = "type",
        paper_id        = paper_id,
        stage_name      = "file-type Phase 1",
        batch_nr        = i,
        n_batches_total = length(chunks)
      )
      batch_result$prompt_nr <- i
      structure_parsed <- rbind(structure_parsed, batch_result)
      experiment_map   <- update_experiment_map(experiment_map, batch_result)
      type_map         <- update_type_map(type_map, batch_result)
      last_entry       <- batch_result[nrow(batch_result), ]
    }
  }

  # ── Phase 2: classify aggregate folder sentinels ────────────────────────────
  if (length(agg_groups_list) > 0) {
    agg_descriptors <- build_agg_descriptors(agg_groups_list)
    agg_chunks      <- split(agg_descriptors, ceiling(seq_along(agg_descriptors) / LLM_BATCH_SIZE))
    cat(col_dim(sprintf("── Classifying %d aggregate folder(s) via LLM\n", length(agg_groups_list))))

    for (i in seq_along(agg_chunks)) {
      prefix <- if (i == 1) "Classify these aggregate folders:" else
                  build_sentinel_summary(experiment_map, type_map)
      batch_result <- llm_batch(
        paths           = agg_chunks[[i]],
        system_prompt   = paste0(AGGREGATE_HEADER, structure_body),
        user_prefix     = prefix,
        key_col         = "path",
        extra_cols      = c("type", "group"),
        fallback_vals   = list(type = "other", group = "shared"),
        sentinel_cols   = "type",
        paper_id        = paper_id,
        stage_name      = "file-type Phase 2",
        input_type      = "json_descriptor",
        batch_nr        = i,
        n_batches_total = length(agg_chunks)
      )
      batch_result$prompt_nr <- i
      agg_parsed      <- rbind(agg_parsed, batch_result)
      experiment_map  <- update_experiment_map(experiment_map, batch_result)
      type_map        <- update_type_map(type_map, batch_result)
    }
  }

  # ── 7. Propagate Phase 1 results to aggregate group members ──────────────────
  # For each extension group where route_individually = FALSE (sample_paths sent to
  # Phase 1 LLM), look up the LLM type/group assignment from a sample path and
  # propagate to all member files. Members get type_source = "aggregate_llm".
  #
  # data_granularity distinction:
  #   "individual" — detected participant series (per-participant data files)
  #   "combined"   — flat aggregate or non-series files
  #
  # Groups with route_individually = TRUE are already in non_agg_relpaths and
  # classified individually in Phase 1 (type_source = "llm").

  agg_expanded <- list()

  if (length(agg_groups_list) > 0) {
    cat(col_cyan("\n── Aggregate classification results:\n"))
    for (grp in agg_groups_list) {
      # Look up the aggregate in Phase 2 results by composite key (folder/.ext)
      key     <- paste0(grp$folder, "/.", grp$ext)
      agg_idx <- match(key, agg_parsed$path)
      if (is.na(agg_idx)) {
        warning("Aggregate key not found in Phase 2 results: ", key)
        next
      }

      sample_row <- agg_parsed[agg_idx, ]
      agg_type   <- sample_row$type
      agg_group  <- sample_row$group

      # Handle NA defaults from Phase 1
      if (is.na(agg_type))   agg_type   <- "other"
      if (is.na(agg_group))  agg_group  <- "shared"

      # data_granularity: "individual" for detected participant series, "combined" otherwise
      is_series      <- isTRUE(grp$is_series)
      is_data        <- agg_type == "data"
      data_gran      <- ifelse(is_data & is_series, "individual",
                               ifelse(is_data, "combined", NA_character_))

      # Create a row for each member file
      member_df <- data.frame(
        path               = file.path(norm_base, grp$members),
        rel_path           = grp$members,
        type               = agg_type,
        group              = agg_group,
        aggregate_folder   = grp$folder,
        type_source        = "aggregate_llm",
        data_granularity   = data_gran,
        granularity_source = ifelse(is_data, "folder_heuristic", NA_character_),
        is_sentinel        = FALSE,
        prompt_nr          = sample_row$prompt_nr,
        stringsAsFactors   = FALSE
      )

      agg_expanded <- c(agg_expanded, list(member_df))

      gran_label <- if (is_data) { if (is_series) "individual" else "combined" } else ""
      cat(sprintf("  \u00d7%-4d  %-58s \u2192  %-18s %s\n",
                  length(grp$members),
                  paste0(grp$folder, "/.", grp$ext),
                  paste0(agg_type, " / ", agg_group),
                  gran_label))
    }
  }

  agg_expanded_df <- if (length(agg_expanded) > 0)
    do.call(rbind, agg_expanded)
  else
    NULL

  # Phase 1 rows: all non-aggregate files + singletons routed from aggregates.
  # data_granularity = "combined" for data files; NA for non-data.
  p1_types <- if (!is.null(structure_parsed))
    structure_parsed$type[match(non_agg_relpaths, structure_parsed$path)]
  else
    rep(NA_character_, length(non_agg_relpaths))
  p1_groups <- if (!is.null(structure_parsed))
    structure_parsed$group[match(non_agg_relpaths, structure_parsed$path)]
  else
    rep(NA_character_, length(non_agg_relpaths))
  p1_prompt_nrs <- if (!is.null(structure_parsed))
    structure_parsed$prompt_nr[match(non_agg_relpaths, structure_parsed$path)]
  else
    rep(NA_integer_, length(non_agg_relpaths))
  p1_types[is.na(p1_types)]   <- "other"
  p1_groups[is.na(p1_groups)] <- "shared"

  p1_is_data <- p1_types == "data"
  non_agg_df <- data.frame(
    path               = file.path(norm_base, non_agg_relpaths),
    rel_path           = non_agg_relpaths,
    type               = p1_types,
    group              = p1_groups,
    aggregate_folder   = NA_character_,
    type_source        = "llm",
    data_granularity   = ifelse(p1_is_data, "combined", NA_character_),
    granularity_source = ifelse(p1_is_data, "default_combined", NA_character_),
    is_sentinel        = FALSE,
    prompt_nr          = p1_prompt_nrs,
    stringsAsFactors   = FALSE
  )

  file_df          <- rbind(non_agg_df, agg_expanded_df)


  file_df$paper_id <- paper_id
  file_df$filename <- basename(file_df$path)
  file_df$ext      <- tolower(tools::file_ext(file_df$path))
  file_df$data_format <- ifelse(file_df$type == "data",
                                classify_data_format(file_df$ext),
                                NA_character_)

  # ── US1: Filename-pattern granularity heuristic ──────────────────────────────
  # For non-aggregate data files with no granularity signal yet, apply filename
  # heuristic: if filename stem matches participant ID pattern, mark "individual".
  data_idx <- which(file_df$type == "data" & file_df$granularity_source == "default_combined")
  if (length(data_idx) > 0) {
    stems <- tools::file_path_sans_ext(file_df$filename[data_idx])
    is_participant <- vapply(stems, is_participant_id, logical(1L))
    matched_idx <- data_idx[is_participant]
    if (length(matched_idx) > 0) {
      file_df$data_granularity[matched_idx] <- "individual"
      file_df$granularity_source[matched_idx] <- "filename_heuristic"
    }
  }

  # ── US3: LLM-assisted granularity for aggregate data files with unclear signals ─
  # Target: data files in aggregate folders (granularity_source == "folder_heuristic")
  # where the folder structure does NOT clearly indicate participant series
  # (i.e., subdirectory names don't match participant patterns).
  # Use LLM to infer granularity based on FILENAME PATTERNS, not columns.
  unclear_agg_idx <- which(file_df$type == "data" &
                           file_df$granularity_source == "folder_heuristic" &
                           !is.na(file_df$aggregate_folder) &
                           nchar(file_df$aggregate_folder) > 0)

  if (length(unclear_agg_idx) > 0) {
    # For each unclear aggregate, check if its subdirs match participant patterns
    unclear_agg_folders <- unique(file_df$aggregate_folder[unclear_agg_idx])
    gran_queries <- list()  # Collect queries for single LLM call
  
    for (agg_folder in unclear_agg_folders) {

      # Get subdirs in this aggregate folder (exclude NA in aggregate_folder)
      subdir_match <- !is.na(file_df$aggregate_folder) & file_df$aggregate_folder == agg_folder & file_df$type == "data"

      subdir_names <- unique(basename(dirname(file_df$rel_path[subdir_match])))
      # Check if majority match participant patterns
      n_participant <- sum(vapply(subdir_names, is_participant_id, logical(1L)))
      has_clear_signal <- (n_participant > (length(subdir_names) / 2))

      if (has_clear_signal) {
        # Aggregate folder itself (or its parent) is participant-named → directly mark individual
        target_idx <- which(file_df$aggregate_folder == agg_folder & file_df$type == "data")
        if (length(target_idx) > 0) {
          file_df$data_granularity[target_idx] <- "individual"
          file_df$granularity_source[target_idx] <- "folder_name_heuristic"
        }
      } else {

        # No clear participant signal: analyze filename patterns (exclude NA in aggregate_folder)
        agg_data_files <- file_df$rel_path[
          !is.na(file_df$aggregate_folder) &
          file_df$aggregate_folder == agg_folder &
          file_df$type == "data" &
          file_df$granularity_source != "filename_heuristic"
        ]

        if (length(agg_data_files) > 0) {
          # Detect repeating filename pattern in this aggregate
          # Use basenames (not full paths) for pattern detection
          agg_data_basenames <- basename(agg_data_files)

          pattern_info <- detect_filename_pattern(agg_data_basenames, verbose = FALSE)

          if (!is.null(pattern_info)) {
            # Check if single pattern or multiple patterns found (min 5 matches required)
            if (!is.null(pattern_info$count) && pattern_info$count >= 8) {
              # Single pattern case
              gran_queries[[agg_folder]] <- list(
                folder_path = agg_folder,
                filename_pattern = pattern_info$pattern,  # Actual regex: ^Exp[0-9]+_[0-9]+\.dat$
                example_files = pattern_info$examples,
                all_patterns = pattern_info$pattern,  # Store for DB
                target_files = agg_data_files
              )
            } else if (!is.null(pattern_info$multiple_patterns)) {
              # Multiple patterns case
              pattern_display <- paste(names(pattern_info$multiple_patterns), collapse=" | ")
              gran_queries[[agg_folder]] <- list(
                folder_path = agg_folder,
                filename_pattern = "(multiple patterns)",
                example_files = pattern_info$examples,
                all_patterns = names(pattern_info$multiple_patterns),  # All regex patterns for DB
                multiple_patterns = pattern_info$multiple_patterns,    # Full pattern details
                pattern_display = pattern_display,  # For user_prefix
                target_files = agg_data_files
              )
            }
          }

          # If no pattern detected at all, send raw samples
          if (is.null(pattern_info) || !agg_folder %in% names(gran_queries)) {
            gran_queries[[agg_folder]] <- list(
              folder_path = agg_folder,
              filename_pattern = "(no clear pattern)",
              example_files = head(agg_data_basenames, 10),
              all_patterns = character(0),
              target_files = agg_data_files
            )
          }
        } else {
        }
      }
    }

    # If queries collected, send to LLM in single call
    if (length(gran_queries) > 0) {

      # Send all queries — llm_batch() handles chunking internally
      queries_to_send <- gran_queries
      llm_input <- names(queries_to_send)  # folder names as simple paths for llm_batch

      # Build rich context into user_prefix for the LLM
      # Use full folder path as identifier (matches llm_input)
      prefix_details <- lapply(seq_along(queries_to_send), function(i) {
        q <- queries_to_send[[i]]
        examples_str <- paste(head(q$example_files, 5), collapse = ", ")
        fold_id <- names(queries_to_send)[i]
        # If multiple patterns, show all; otherwise show single pattern
        pattern_str <- if (!is.null(q$pattern_display)) {
          q$pattern_display
        } else {
          q$filename_pattern
        }
        sprintf("%s: pattern=%s examples=%s", fold_id, pattern_str, examples_str)
      })
      user_prefix_full <- paste(c("Classify file granularity based on filename patterns:",
                                   "", "For each folder below, return its granularity:",
                                   "", unlist(prefix_details)),
                                collapse = "\n")


      # Call LLM with GRANULARITY_PROMPT
      cat(col_dim(sprintf("── Inferring granularity for %d aggregate folder(s) via LLM\n",
                  length(gran_queries))))
      gran_result <- tryCatch({
        llm_batch(paths = llm_input, system_prompt = GRANULARITY_PROMPT,
                  user_prefix = user_prefix_full,
                  key_col = "folder_path", extra_cols = "granularity",
                  fallback_vals = list(granularity = NA_character_))
      }, error = function(e) {
        message(sprintf("  [US3-llm] ERROR: %s", conditionMessage(e)))
        NULL
      })


      # Update granularity_source for all files in queried aggregates
      if (!is.null(gran_result) && nrow(gran_result) > 0) {
        for (.i in seq_len(nrow(gran_result))) {
          agg_folder_result <- gran_result$folder_path[.i]
          gran_val <- gran_result$granularity[.i]

          if (!is.na(gran_val) && gran_val %in% c("individual", "combined")) {
            # Update all target files in this aggregate
            target_files <- gran_queries[[agg_folder_result]]$target_files
            file_idx <- which(file_df$rel_path %in% target_files)
            if (length(file_idx) > 0) {
              file_df$data_granularity[file_idx] <- gran_val
              file_df$granularity_source[file_idx] <- "llm"
            }
            q <- gran_queries[[agg_folder_result]]
            pattern_display <- if (!is.null(q$pattern_display)) q$pattern_display else q$filename_pattern
            gran_col <- if (gran_val == "individual") col_green else col_dim
            cat(gran_col(sprintf("  \u2514 granularity  %-10s  %s  [%d file(s)]\n",
                        gran_val, pattern_display, length(file_idx))))
          }
        }
      }

      # Pattern inference: if a pattern was classified as "individual" by LLM,
      # apply that pattern to ALL other data files (both within same aggregate and other aggregates)
      # to catch additional individual files not sent to LLM
      if (!is.null(gran_result) && nrow(gran_result) > 0) {
        # Collect all individual patterns found (including multiple patterns per aggregate)
        individual_patterns <- c()  # character vector of regex patterns
        for (.i in seq_len(nrow(gran_result))) {
          agg_folder_result <- gran_result$folder_path[.i]
          gran_val <- gran_result$granularity[.i]
          if (gran_val == "individual") {
            q <- gran_queries[[agg_folder_result]]
            # Collect all patterns for this aggregate (single or multiple)
            if (!is.null(q$all_patterns) && length(q$all_patterns) > 0) {
              individual_patterns <- c(individual_patterns, q$all_patterns)
            } else {
              individual_patterns <- c(individual_patterns, q$filename_pattern)
            }
          }
        }

        # Apply each individual pattern to NON-aggregate data files (flat folders)
        if (length(individual_patterns) > 0) {
          # Find all non-aggregate data files NOT yet classified as "individual"
          non_agg_data_idx <- which(
            file_df$type == "data" &
            file_df$data_granularity != "individual" &
            is.na(file_df$aggregate_folder)
          )

          for (pattern_regex in individual_patterns) {
            if (length(non_agg_data_idx) > 0) {
              # Check which of these match the pattern (match against basenames only)
              other_files <- file_df$rel_path[non_agg_data_idx]
              other_basenames <- basename(other_files)
              pattern_matches <- grep(pattern_regex, other_basenames)
              if (length(pattern_matches) > 0) {
                match_idx <- non_agg_data_idx[pattern_matches]
                file_df$data_granularity[match_idx] <- "individual"
                file_df$granularity_source[match_idx] <- "llm_pattern_inference"
              }
            }
          }
        }
      }

      # Save all detected patterns + LLM classification for validation (false pos/neg detection)
      tryCatch({
        regex_db_path <- "data_check/docs/detected_granularity_patterns.csv"
        dir.create(dirname(regex_db_path), showWarnings = FALSE, recursive = TRUE)

        # For each LLM result, find the matching query and save pattern + classification
        for (.i in seq_len(nrow(gran_result))) {
          result_folder <- gran_result$folder_path[.i]
          llm_classification <- gran_result$granularity[.i]

          if (result_folder %in% names(gran_queries)) {
            query <- gran_queries[[result_folder]]
            example_files <- head(query$example_files, 3)

            # Handle single or multiple patterns
            patterns_to_save <- if (!is.null(query$all_patterns) && length(query$all_patterns) > 0) {
              query$all_patterns
            } else {
              query$filename_pattern
            }

            # Create one row per pattern
            for (pattern_regex in patterns_to_save) {
              db_row <- data.frame(
                paper_id = paper_id,
                pattern_regex = pattern_regex,
                example_file_1 = if (length(example_files) >= 1) example_files[1] else NA_character_,
                example_file_2 = if (length(example_files) >= 2) example_files[2] else NA_character_,
                example_file_3 = if (length(example_files) >= 3) example_files[3] else NA_character_,
                llm_classification = llm_classification,
                detected_date = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                stringsAsFactors = FALSE
              )

              if (!file.exists(regex_db_path)) {
                write.csv(db_row, regex_db_path, row.names = FALSE)
              } else {
                existing <- read.csv(regex_db_path, stringsAsFactors = FALSE)
                updated <- rbind(existing, db_row)
                updated <- updated[!duplicated(updated[, c("pattern_regex", "paper_id")]), ]
                write.csv(updated, regex_db_path, row.names = FALSE)
              }
            }
          }
        }
      }, error = function(e) {
        warning("Failed to save regex patterns: ", conditionMessage(e))
      })
    }
  }

  # ── PDF-from-Rmd fallback ────────────────────────────────────────────────────
  # After classification and group assignment, override type to "output" for PDFs
  # that share a stem with a same-directory .Rmd / .qmd / .tex source file.
  # Runs post-classification so group context is already resolved.
  pdf_idx <- which(file_df$ext == "pdf")
  if (length(pdf_idx) > 0) {
    src_keys <- paste0(tools::file_path_sans_ext(file_df$rel_path), "\x01",
                       file_df$ext)
    src_exts <- c("rmd", "qmd", "tex")
    for (.i in pdf_idx) {
      stem         <- tools::file_path_sans_ext(file_df$rel_path[.i])
      matched_keys <- paste0(stem, "\x01", src_exts)
      src_idx      <- which(src_keys %in% matched_keys)
      if (length(src_idx) > 0) {
        file_df$type[.i]        <- "output"
        file_df$type_source[.i] <- "rmd_pair_rule"
        file_df$data_format[.i] <- NA_character_
        message("  PDF compiled from source — type set to output: ",
                file_df$filename[.i])
        for (.j in src_idx) {
          file_df$type[.j]        <- "code"
          file_df$type_source[.j] <- "rmd_pair_rule"
          file_df$data_format[.j] <- NA_character_
          message("  Source file for compiled PDF — type set to code: ",
                  file_df$filename[.j])
        }
      }
    }
  }

  # ── 8. Save structure ────────────────────────────────────────────────────────

  structure_out <- file.path(eff_dir, "structure.csv")
  cat(col_cyan("\n── File inventory ──────────────────────────────\n"))
  local({
    type_order <- c("data","code","codebook","asset","output",
                    "supplemental","software","readme","other")
    groups     <- sort(unique(file_df$group[!is.na(file_df$group)]))
    types_present <- intersect(type_order,
                               unique(file_df$type[!is.na(file_df$type)]))
    # Abbreviate long type names for column headers
    abbrev <- c(data="data", code="code", codebook="codebk",
                asset="asset", output="output", supplemental="suppl",
                software="softw", readme="readme", other="other")
    hdrs   <- vapply(types_present, function(t) abbrev[[t]], character(1))
    col_w  <- pmax(nchar(hdrs), 5L)
    grp_w  <- max(nchar(groups)) + 2L

    # Header row
    cat(sprintf("  %-*s", grp_w, ""))
    for (j in seq_along(hdrs))
      cat(sprintf("  %*s", col_w[j], hdrs[j]))
    cat("\n")

    # Separator
    cat("  ", strrep("\u2500", grp_w), sep = "")
    for (j in seq_along(col_w)) cat("  ", strrep("\u2500", col_w[j]), sep = "")
    cat("\n")

    # Data rows
    for (grp in groups) {
      sub <- file_df[!is.na(file_df$group) & file_df$group == grp, ]
      cat(sprintf("  %-*s", grp_w, grp))
      for (j in seq_along(types_present)) {
        n <- sum(!is.na(sub$type) & sub$type == types_present[j])
        cat(sprintf("  %*s", col_w[j], if (n > 0) n else "."))
      }
      cat("\n")
    }
  })

  t_llm <- proc.time()[["elapsed"]] - t_llm_start

  } # end if (!COLUMNS_ONLY)

  t_col_start <- proc.time()[["elapsed"]]
  # ── 9. Extract columns + sample values from data files ───────────────────────

  if (SKIP_COLUMNS) {
    message("── Column extraction skipped (SKIP_COLUMNS = TRUE)")
    columns_df   <- NULL
    columns_out  <- NULL
    data_files   <- file_df[FALSE, ]  # empty frame for n_tabular_files below
  } else {

  # Only "data" files are column-extracted. Files with type = "output", "supplemental",
  # "codebook", "code", "asset", "readme", or "other" are excluded by this filter.
  data_files <- file_df[file_df$type == "data" & !file_df$is_sentinel &
                          !is.na(file_df$data_format) & file_df$data_format == "tabular", ]
  if (!FULL_RUN && is.finite(MAX_DATA_FILES) && nrow(data_files) > MAX_DATA_FILES) {
    message("── Capping data files: ", nrow(data_files), " → keeping first ", MAX_DATA_FILES)
    data_files <- data_files[seq_len(MAX_DATA_FILES), ]
  }
  message("── Extracting columns + statistics from ", nrow(data_files), " data file(s)")

  MAX_FILE_MB <- 500  # skip data files larger than this

  # Mutable accumulator — tracks cumulative MB read so far for this paper.
  # Using an environment so the closure inside extract_column_info can update it.
  .read_state <- new.env(parent = emptyenv())
  .read_state$mb_read   <- 0
  .read_state$limit_hit <- FALSE

  extract_column_info <- function(path, rel_path, group) {
    file_mb <- file.info(path)$size / 1048576
    cat(sprintf("  [%s] %s  (%.1f MB)", group, basename(path), file_mb))
    if (!is.na(file_mb) && file_mb > MAX_FILE_MB) {
      cat(sprintf("  [skipped: too large]\n"))
      return(NULL)
    }
    # Aggregate data cap: skip this file if adding it would exceed the per-paper limit.
    if (!is.na(file_mb) && (.read_state$mb_read + file_mb) > MAX_TOTAL_DATA_MB) {
      if (!.read_state$limit_hit) {
        cat(sprintf("  [skipped: GB limit reached]\n"))
        .read_state$limit_hit <- TRUE
      } else {
        cat("\n")
      }
      return(NULL)
    }
    timed_out <- FALSE
    df <- tryCatch({
      setTimeLimit(elapsed = MAX_FILE_READ_SEC, transient = TRUE)
      result <- read_data_head(path, n_rows = Inf)
      setTimeLimit(elapsed = Inf, transient = FALSE)
      result
    }, error = function(e) {
      setTimeLimit(elapsed = Inf, transient = FALSE)
      timed_out <<- TRUE
      cat(sprintf("  [skipped: timed out]\n"))
      NULL
    })
    if (timed_out) return(NULL)
    if (is.null(df) || ncol(df) == 0) {
      cat("  [skipped: unreadable or empty]\n")
      return(NULL)
    }
    if (!is.na(file_mb)) .read_state$mb_read <- .read_state$mb_read + file_mb

    # ── Qualtrics ImportId detection ─────────────────────────────────────────────
    # Detect by scanning the first 3 data rows for the ImportId pattern and strip.
    if (nrow(df) >= 2) {
      import_row <- NA_integer_
      for (.qi in seq_len(min(3L, nrow(df)))) {
        if (any(grepl("^\\{.*ImportId", as.character(df[.qi, ]), perl = TRUE))) {
          import_row <- .qi
          break
        }
      }
      if (!is.na(import_row)) {
        keep_after <- seq(import_row + 1L, nrow(df))
        if (length(keep_after) == 0) {
          cat("  [skipped: Qualtrics headers only]\n")
          return(NULL)
        }
        df <- df[keep_after, , drop = FALSE]
        rownames(df) <- NULL
        cat(sprintf("  [Qualtrics: row %d stripped]", import_row))
      }
    }

    auto_named <- grepl("^\\.\\.\\.\\d+$", names(df))

    # ── Multi-level header recovery ────────────────────────────────────────────
    # Initialise col_header_group as all-NA (default when no multi-level structure).
    col_header_group <- rep(NA_character_, ncol(df))

    if (mean(auto_named) > 0.5) {
      # Extract group labels from row-1 names and forward-fill across spans.
      # "SHAM...3" → prefix "SHAM"; "...4" → "" → NA → filled from last real prefix.
      row1_names   <- names(df)
      raw_prefixes <- sub("\\.\\.\\.\\d+$", "", row1_names)
      raw_prefixes[!nzchar(raw_prefixes)] <- NA_character_
      last_grp <- NA_character_
      col_header_group <- vapply(raw_prefixes, function(p) {
        if (!is.na(p)) last_grp <<- p
        last_grp
      }, character(1))

      # Branch 1: scan for a better sub-header row.
      sub_header_row    <- NULL
      current_auto_frac <- mean(auto_named)
      for (i in seq_len(min(MULTILEVEL_HEADER_LOOKAHEAD, nrow(df)))) {
        candidate      <- as.character(df[i, ])
        cand_auto_frac <- mean(grepl("^\\.\\.\\.\\d+$", candidate))
        # A real sub-header cell must be non-empty, non-NA, non-...N, and non-numeric.
        # Pure numeric rows are data rows, not label rows.
        has_real       <- any(!is.na(candidate) & nzchar(candidate) &
                              candidate != "NA" &
                              !grepl("^\\.\\.\\.\\d+$", candidate) &
                              is.na(suppressWarnings(as.numeric(candidate))))
        if (cand_auto_frac < current_auto_frac && has_real) {
          sub_header_row <- i
          break
        }
      }

      if (!is.null(sub_header_row)) {
        # Use sub-header values as column names.
        # NA or empty cells fall back to the original ...N name (preserves uniqueness).
        new_names           <- as.character(df[sub_header_row, ])
        fallback            <- is.na(new_names) | !nzchar(new_names)
        new_names[fallback] <- row1_names[fallback]
        new_names           <- make.unique(new_names)
        df                  <- df[(sub_header_row + 1):nrow(df), , drop = FALSE]
        names(df)           <- new_names
        # col_header_group is aligned column-wise; row slicing above does not affect it.
        cat(sprintf("  [multi-level: row %d as header]", sub_header_row + 1))
      } else {
        # Branch 2: no sub-header found — group context not meaningful without a sub-header.
        col_header_group <- rep(NA_character_, ncol(df))
        has_any_real     <- any(!auto_named)
        if (has_any_real) {
          cat("  [multi-level: partial labels retained]")
          # proceed with df as-is
        } else {
          cat("  [skipped: multi-level, no usable sub-header]\n")
          return(NULL)
        }
      }
    }

    # ── V\d+ auto-header detection ───────────────────────────────────────────────
    # base R names headerless CSVs V1, V2, V3, ... — the same issue as ...N above
    # but for CSV files read without column headers.  Apply the same sub-header
    # lookahead; no group-label extraction (V-names carry no prefix context).
    v_named <- grepl("^V\\d+$", names(df))
    if (mean(v_named) > 0.5) {
      v_sub_header_row <- NULL
      for (.vi in seq_len(min(MULTILEVEL_HEADER_LOOKAHEAD, nrow(df)))) {
        candidate <- as.character(df[.vi, ])
        has_real  <- any(!is.na(candidate) & nzchar(candidate) &
                         candidate != "NA" &
                         !grepl("^V\\d+$", candidate) &
                         is.na(suppressWarnings(as.numeric(candidate))))
        if (has_real) { v_sub_header_row <- .vi; break }
      }
      if (!is.null(v_sub_header_row)) {
        new_names           <- as.character(df[v_sub_header_row, ])
        fallback            <- is.na(new_names) | !nzchar(new_names)
        new_names[fallback] <- names(df)[fallback]
        new_names           <- make.unique(new_names)
        df                  <- df[(v_sub_header_row + 1):nrow(df), , drop = FALSE]
        names(df)           <- new_names
        col_header_group    <- rep(NA_character_, ncol(df))
        cat(sprintf("  [V\\d+ header: row %d as header]", v_sub_header_row + 1))
      }
    }

    sample_vals <- vapply(df, function(col) {
      vals <- as.character(col[!is.na(col)])
      if (length(vals) == 0) "" else paste(head(vals, N_DATA_READ), collapse = " | ")
    }, character(1))

    # ── Classify each column ───────────────────────────────────────────────────
    col_classifications <- lapply(names(df), function(col) {
      classify_col_type_rules(col, df[[col]])
    })

    col_types <- vapply(col_classifications, function(cls) {
      if (is.null(cls$col_type) || is.na(cls$col_type)) NA_character_ else cls$col_type
    }, character(1))

    ambiguous_idx <- vapply(col_classifications, `[[`, logical(1), "ambiguous")

    is_numeric_vec <- vapply(col_classifications, function(cls) {
      isTRUE(cls$is_numeric)
    }, logical(1))

    n_coerced_vec <- vapply(col_classifications, function(cls) {
      v <- cls$n_coerced
      if (is.null(v) || is.na(v)) NA_integer_ else as.integer(v)
    }, integer(1))

    # Unique sample values for LLM classification of ambiguous columns
    sample_vals_unique <- vapply(seq_along(names(df)), function(i) {
      if (!ambiguous_idx[i]) return(NA_character_)
      x_noNA <- df[[names(df)[i]]]
      x_noNA <- x_noNA[!is.na(x_noNA)]
      cap    <- 20L
      uniq_v <- unique(x_noNA)[seq_len(min(cap, length(unique(x_noNA))))]
      paste(as.character(uniq_v), collapse = ", ")
    }, character(1))

    col_stats <- lapply(seq_along(names(df)), function(i) {
      col <- names(df)[i]
      cls <- col_classifications[[i]]

      # n_unique: distinct non-NA values in the source column (all col_types)
      x_raw_col    <- df[[col]]
      n_unique_val <- length(unique(x_raw_col[!is.na(x_raw_col)]))

      # Determine which numeric vector to use for statistics
      x_for_stats <- cls$numeric_values
      if (is.null(x_for_stats) && isTRUE(cls$ambiguous) && isTRUE(cls$is_numeric)) {
        x_for_stats <- df[[col]]  # ambiguous numeric — compute tentative stats
      }

      if (is.null(x_for_stats)) {
        # Non-numeric, non-ambiguous: report n/n_missing/n_unique only
        n_miss <- sum(is.na(x_raw_col))
        n_val  <- length(x_raw_col) - n_miss
        return(list(n = n_val, n_missing = n_miss, n_unique = n_unique_val,
                    mean = NA, sd = NA, se = NA,
                    median = NA, min = NA, max = NA, range = NA,
                    p25 = NA, p75 = NA, iqr = NA, skewness = NA, kurtosis = NA))
      }

      x_comp <- as.numeric(x_for_stats)
      x_comp <- x_comp[!is.na(x_comp) & !is.nan(x_comp)]
      n      <- length(x_comp)
      n_miss <- sum(is.na(x_for_stats))
      if (n == 0) {
        return(list(n = 0L, n_missing = n_miss, n_unique = n_unique_val,
                    mean = NA, sd = NA, se = NA,
                    median = NA, min = NA, max = NA, range = NA,
                    p25 = NA, p75 = NA, iqr = NA, skewness = NA, kurtosis = NA))
      }
      mn   <- mean(x_comp)
      s    <- if (n > 1) sd(x_comp) else NA_real_
      se   <- if (!is.na(s)) s / sqrt(n) else NA_real_
      med  <- median(x_comp)
      mn_v <- min(x_comp)
      mx_v <- max(x_comp)
      p25  <- quantile(x_comp, 0.25, names = FALSE)
      p75  <- quantile(x_comp, 0.75, names = FALSE)
      skew <- if (n > 2 && !is.na(s) && s > 0) mean((x_comp - mn)^3) / s^3 else NA_real_
      kurt <- if (n > 3 && !is.na(s) && s > 0) mean((x_comp - mn)^4) / s^4 - 3 else NA_real_
      list(n = n, n_missing = n_miss, n_unique = n_unique_val,
           mean = mn, sd = s, se = se,
           median = med, min = mn_v, max = mx_v, range = mx_v - mn_v,
           p25 = p25, p75 = p75, iqr = p75 - p25, skewness = skew, kurtosis = kurt)
    })

    stats_mat <- do.call(rbind, lapply(col_stats, as.data.frame, stringsAsFactors = FALSE))

    cat("\n")
    list(
      columns = data.frame(
        paper_id             = paper_id,
        source_file          = rel_path,
        filename             = basename(path),
        group                = group,
        col_header_group     = col_header_group,
        column_name          = names(df),
        sample_values        = sample_vals,
        col_type             = col_types,
        n_coerced            = n_coerced_vec,
        stats_mat,
        sample_values_unique = sample_vals_unique,
        is_numeric           = is_numeric_vec,
        stringsAsFactors = FALSE,
        row.names     = NULL
      )
    )
  }

  column_list  <- mapply(extract_column_info,
                         path = data_files$path, rel_path = data_files$rel_path,
                         group = data_files$group, SIMPLIFY = FALSE)
  column_list  <- Filter(Negate(is.null), column_list)
  columns_df   <- do.call(rbind, lapply(column_list, function(x) x$columns))

  # ── Batch 1: numeric-ambiguous columns → continuous (LLM disabled) ────────
  # LLM classification for numeric columns fails 100% of the time and always
  # falls back to continuous anyway. Skip the call; assign directly.
  if (!is.null(columns_df) && nrow(columns_df) > 0) {
    num_ambig_rows <- which(is.na(columns_df$col_type) & columns_df$is_numeric)
    if (length(num_ambig_rows) > 0) {
      columns_df$col_type[num_ambig_rows] <- "continuous"
      cat(col_dim(sprintf("── col_type Batch 1 (numeric): %d column(s) assigned continuous (LLM skipped)\n",
              length(num_ambig_rows))))
    }
  }

  # ── Batch 2: character-ambiguous columns (CHAR_COLUMN_TYPE_PROMPT) ────────
  if (!is.null(columns_df) && nrow(columns_df) > 0) {
    char_ambig_rows <- which(is.na(columns_df$col_type) & !columns_df$is_numeric)
    if (length(char_ambig_rows) > 0) {
      max_char_cols <- MAX_CHAR_COL_TYPE_LLM_CALLS * LLM_BATCH_SIZE
      if (!FULL_RUN && length(char_ambig_rows) > max_char_cols)
        char_ambig_rows <- char_ambig_rows[seq_len(max_char_cols)]
      descriptors <- paste0('"', columns_df$column_name[char_ambig_rows], '"',
                            " (samples: ", columns_df$sample_values_unique[char_ambig_rows], ")")
      cat(col_dim(sprintf("── LLM col_type Batch 2 (character): classifying %d column(s)\n",
              length(char_ambig_rows))))
      llm_result <- tryCatch(
        llm_batch(
          paths         = descriptors,
          system_prompt = CHAR_COLUMN_TYPE_PROMPT,
          user_prefix   = "Classify each column:",
          key_col       = "descriptor",
          extra_cols    = "col_type",
          fallback_vals = list(col_type = "text"),
          sentinel_cols = "col_type",
          paper_id      = paper_id,
          stage_name    = "col-type Batch 2"
        ),
        error = function(e) {
          warning("LLM col_type Batch 2 failed: ", conditionMessage(e))
          data.frame(descriptor = descriptors,
                     col_type   = rep("text", length(descriptors)),
                     stringsAsFactors = FALSE)
        }
      )
      returned_types <- llm_result$col_type
      invalid_mask   <- !returned_types %in% VALID_COL_TYPES
      if (any(invalid_mask)) {
        bad_types <- unique(returned_types[invalid_mask])
        cat(col_dim(sprintf("── col_type Batch 2: %d invalid type(s) remapped to text: %s\n",
                sum(invalid_mask), paste(bad_types, collapse = ", "))))
        returned_types[invalid_mask] <- "text"
      }
      columns_df$col_type[char_ambig_rows] <- returned_types

      # Fallback: LLM "unknown" for a character column → "text".
      char_unknown <- char_ambig_rows[columns_df$col_type[char_ambig_rows] == "unknown"]
      if (length(char_unknown) > 0) {
        columns_df$col_type[char_unknown] <- "text"
        cat(col_dim(sprintf("── col_type fallback: %d character column(s) reclassified from unknown → text\n",
                length(char_unknown))))
      }
    }
  }

  # ── Final cleanup: fallback NAs, stat suppression, drop transient column ──
  if (!is.null(columns_df) && nrow(columns_df) > 0) {
    columns_df$col_type[is.na(columns_df$col_type)] <- "unknown"
    stat_cols     <- c("mean", "sd", "se", "median", "min", "max", "range",
                       "p25", "p75", "iqr", "skewness", "kurtosis")
    numeric_types <- c("continuous", "continuous_comma_decimal",
                       "continuous_outliers_excluded")
    suppress_rows <- !columns_df$col_type %in% numeric_types
    columns_df[suppress_rows, stat_cols] <- NA
    columns_df$sample_values_unique <- NULL
    columns_df$is_numeric           <- NULL
  }

  } # end if (!SKIP_COLUMNS)

  n_individual <- sum(file_df$data_granularity == "individual", na.rm = TRUE)
  n_combined   <- sum(file_df$data_granularity == "combined",   na.rm = TRUE)
  cat(col_dim(sprintf("── data_granularity: %d individual, %d combined data file(s)\n",
          n_individual, n_combined)))

  write.csv(
    file_df[, c("paper_id", "path", "rel_path", "filename", "ext",
                "type", "type_source", "group", "aggregate_folder",
                "data_granularity", "granularity_source", "prompt_nr", "data_format")],
    structure_out, row.names = FALSE
  )

  if (!is.null(columns_df) && nrow(columns_df) > 0) {
    columns_out   <- file.path(eff_dir, "columns.csv")
    invalid_types <- setdiff(unique(columns_df$col_type), VALID_COL_TYPES)
    if (length(invalid_types) > 0)
      warning("Unknown col_type values: ", paste(invalid_types, collapse = ", "))
    write.csv(columns_df, columns_out, row.names = FALSE)
  } else {
    message("── No columns extracted")
    columns_df  <- NULL
    columns_out <- NULL
  }

  t_col <- proc.time()[["elapsed"]] - t_col_start
  elapsed <- proc.time()[["elapsed"]] - t_start

  # ── Return structured result ─────────────────────────────────────────────────

  list(
    paper_id       = paper_id,
    success        = TRUE,
    error          = NULL,
    elapsed_sec    = elapsed,
    download_sec   = t_download,
    llm_sec        = t_llm,
    column_sec     = t_col,
    n_files        = nrow(file_df),
    n_data_files   = sum(file_df$type == "data" & !file_df$is_sentinel, na.rm = TRUE),
    n_tabular_files = nrow(data_files),
    n_agg_dirs     = length(agg_dirs),
    n_individual   = n_individual,
    n_combined     = n_combined,
    n_columns      = if (!is.null(columns_df)) nrow(columns_df) else 0L,
    n_source_files = if (!is.null(columns_df)) length(unique(columns_df$source_file)) else 0L,
    source         = if (is_dv) "dataverse" else "osf",
    type_counts    = table(file_df$type),
    group_counts   = table(file_df$group),
    file_df        = file_df,
    columns_df     = columns_df,
    structure_path = structure_out,
    columns_path   = columns_out
  )
}
