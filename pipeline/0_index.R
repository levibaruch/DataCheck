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

DATA_DIR         <- "./data_check/data"
OUTPUT_DIR       <- "./data_check/outputs"
PSYCHDS_OUT_DIR  <- "./data_check/psychds"
GROUND_TRUTH_DIR <- "./data_check/ground_truth"
ARCHIVE_EXTS    <- c("zip", "gz", "tar", "tgz", "bz2", "xz")
# Extension-based type overrides applied after aggregate sentinel expansion.
# Maps lowercase file extension → definitive type for unambiguous file kinds.
# Extensions absent from this map (e.g. txt, dat, rda) retain the sentinel's
# inherited type unchanged.
AGGREGATE_EXT_OVERRIDE <- c(
  r = "code", rmd = "code", qmd = "code", py = "code", m = "code",
  do = "code", sps = "supplemental", jl = "code", js = "code", sh = "code",
  bash = "code", pl = "code", rb = "code", cpp = "code", c = "code",
  h = "code", java = "code", scala = "code", sql = "code",
  exe = "software", app = "software", jar = "software",
  msi = "software", dmg = "software",
  jpg = "asset", jpeg = "asset", png = "asset", gif = "asset",
  bmp = "asset", tiff = "asset", tif = "asset", svg = "asset",
  mp4 = "asset", avi = "asset", mov = "asset", mp3 = "asset",
  wav = "asset", flac = "asset",
  csv = "data", sav = "data", dta = "data", sas7bdat = "data",
  xlsx = "data", xls = "data", rds = "data"
)
if (!exists("LLM_BATCH_SIZE"))  LLM_BATCH_SIZE  <- 30
if (!exists("LLM_RETRY_LIMIT")) LLM_RETRY_LIMIT <- 3L
if (!exists("LLM_ERROR_LOG"))   LLM_ERROR_LOG   <- "./data_check/logs/llm_batch_errors.log"
if (!exists("LLM_SENTINEL_VAL")) LLM_SENTINEL_VAL <- "llm_error"
N_DATA_READ     <- 5
MAX_TOTAL_DATA_MB <- 10 * 1024  # 10 GB total data read cap per paper across all data files
MAX_FILE_READ_SEC <- 5 * 60    # per-file read timeout (seconds); file is skipped if exceeded
VALID_COL_TYPES <- c("continuous", "binary", "categorical", "ordinal", "date", "id",
                     "text", "continuous_comma_decimal", "continuous_outliers_excluded",
                     "empty", "constant", "unknown",
                     LLM_SENTINEL_VAL)
if (!exists("MAX_COL_TYPE_LLM_CALLS"))      MAX_COL_TYPE_LLM_CALLS      <- 5L
if (!exists("MAX_CHAR_COL_TYPE_LLM_CALLS")) MAX_CHAR_COL_TYPE_LLM_CALLS <- 3L
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

BADGE_REPOS <- c("tvyxz", "osf.io/tvyxz/", "osf.io/tvyxz")

# ── Pipeline function ─────────────────────────────────────────────────────────

run_index <- function(paper_id = NA, download = TRUE, output_dir = NULL) {

  t_start <- proc.time()[["elapsed"]]

  # ── 0. Resolve paper ────────────────────────────────────────────────────────

  if (is.na(paper_id)) {
    xml_files <- list.files(XML_DIR, pattern = "\\.xml$", full.names = FALSE)
    if (length(xml_files) == 0) stop("No XML files found in ", XML_DIR)
    paper_id  <- tools::file_path_sans_ext(sample(xml_files, 1))
    message("── Randomly selected paper: ", paper_id)
  }

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
    message("── Unpacking ", length(archive_paths), " archive(s)")
    lapply(archive_paths, unpack_archive)
    files <- drop_git(list.files(target_dir, full.names = TRUE, recursive = TRUE))
    files <- files[!(tolower(tools::file_ext(files)) %in% ARCHIVE_EXTS)]
  }

  # ── 3b. Explode multi-sheet Excel files into per-sheet CSVs ─────────────────
  # Each sheet becomes <stem>_<sheet_name>.csv alongside the original.
  # The original xlsx/xls is then deleted so downstream sees only flat CSVs.

  excel_paths <- files[tolower(tools::file_ext(files)) %in% c("xlsx", "xls")]
  if (length(excel_paths) > 0) {
    for (xl in excel_paths) {
      sheets <- tryCatch(readxl::excel_sheets(xl), error = function(e) {
        warning("Could not read sheets from ", basename(xl), ": ", conditionMessage(e))
        character(0)
      })
      if (length(sheets) == 0) next
      stem    <- tools::file_path_sans_ext(xl)
      n_written <- 0L
      for (sh in sheets) {
        df <- tryCatch(
          as.data.frame(readxl::read_excel(xl, sheet = sh), stringsAsFactors = FALSE),
          error = function(e) {
            warning("  skipping sheet '", sh, "' in ", basename(xl),
                    ": ", conditionMessage(e))
            NULL
          }
        )
        if (is.null(df) || nrow(df) == 0) next
        # Sanitize sheet name for use in a filename (replace path-unsafe chars)
        safe_sh  <- gsub("[/\\\\:*?\"<>|]", "_", sh)
        out_path <- paste0(stem, "_", safe_sh, ".csv")
        write.csv(df, out_path, row.names = FALSE)
        n_written <- n_written + 1L
      }
      if (n_written > 0) {
        message("  exploded ", basename(xl), " → ", n_written, " CSV(s)")
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
      ok  <- tryCatch({ load(rp, envir = env); TRUE },
                      error = function(e) {
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
    n_numeric <- sum(grepl("^\\d+$", child_names))
    if (n_numeric > AGGREGATE_THRESHOLD) {
      participant_agg_dirs <- c(participant_agg_dirs, d)
    }
  }

  agg_dirs <- unique(c(flat_agg_dirs, participant_agg_dirs))
  is_under_participant_agg <- vapply(rel_paths, function(p) {
    any(startsWith(p, paste0(participant_agg_dirs, "/")))
  }, logical(1))

  is_aggregate <- (top_dirs %in% flat_agg_dirs) | is_under_participant_agg
  aggregate_df <- NULL

  # ── 5b. Sub-group aggregate folders into series-based sub-sentinels ──────────
  # Each aggregate folder is split by detect_series() into:
  #   - Sub-sentinels (one per series, or one fallback sentinel for the whole folder)
  #   - Singletons (unique files routed back to Phase 1 for individual classification)
  # Descriptor strings carry the series prefix, file count, extension, and sample
  # filenames so Phase 2 LLM can assign accurate group labels per condition.

  extra_singletons <- character(0)

  if (any(is_aggregate)) {
    agg_all <- lapply(agg_dirs, function(d) {
      if (d %in% participant_agg_dirs) {
        members <- rel_paths[startsWith(rel_paths, paste0(d, "/"))]
      } else {
        members <- rel_paths[top_dirs == d]
      }

      sr <- detect_series(members)

      # Singletons from this folder go to Phase 1
      extra_singletons <<- c(extra_singletons, sr$singletons)

      if (nrow(sr$sub_sentinels) == 0) return(NULL)

      ss <- sr$sub_sentinels

      # FR-011: diagnostic per aggregate folder
      message("── Aggregate folder: ", d, " → ", nrow(ss), " sub-sentinel(s)")
      for (j in seq_len(nrow(ss))) {
        message(sprintf("   [%s] %d files, .%s",
                        ss$prefix[j], ss$file_count[j], ss$dominant_ext[j]))
      }

      # Build descriptor strings (sent to Phase 2 LLM)
      ss$descriptor <- vapply(seq_len(nrow(ss)), function(j) {
        samp <- paste(ss$sample_files[[j]], collapse = ", ")
        if (ss$is_series[j]) {
          sprintf('%s/[prefix: "%s", %d files, .%s, samples: %s]',
                  d, ss$prefix[j], ss$file_count[j], ss$dominant_ext[j], samp)
        } else {
          sprintf('%s/[mixed, %d files, .%s, samples: %s]',
                  d, ss$file_count[j], ss$dominant_ext[j], samp)
        }
      }, character(1))

      ss$folder <- d
      ss
    })

    agg_list <- Filter(Negate(is.null), agg_all)

    if (length(agg_list) > 0) {
      aggregate_df <- do.call(rbind, agg_list)

      # Pre-resolve type for sub-sentinels whose dominant extension is unambiguous
      ext_resolved <- AGGREGATE_EXT_OVERRIDE[tolower(aggregate_df$dominant_ext)]
      aggregate_df$type_resolved <- ifelse(!is.na(ext_resolved),
                                           ext_resolved, NA_character_)
    }
  }

  non_agg_relpaths <- c(rel_paths[!is_aggregate], extra_singletons)

  # Phase 1 paths: non-aggregate files + singletons routed back from aggregates.
  # Phase 2 paths: aggregate sub-sentinels (descriptor strings).
  # If aggregate_df is NULL (no aggregate dirs found), only Phase 1 runs.
  llm_paths <- non_agg_relpaths

  # ── 6. LLM: understand repository structure (two-phase classification) ────────
  #
  # Phase 1: classify all non-aggregate paths (llm_paths = non_agg_relpaths).
  # Phase 2: classify aggregate sub-sentinels using Phase 1 results as context.
  # Both phases count toward MAX_LLM_CALLS.

  if (!is_dv) t_download <- proc.time()[["elapsed"]] - t_download_start

  t_llm_start <- proc.time()[["elapsed"]]
  MAX_LLM_CALLS  <- 10
  n_phase1_calls <- ceiling(length(llm_paths) / LLM_BATCH_SIZE)
  n_phase2_calls <- if (!is.null(aggregate_df) && nrow(aggregate_df) > 0)
                      ceiling(nrow(aggregate_df) / LLM_BATCH_SIZE) else 0L
  n_llm_calls    <- n_phase1_calls + n_phase2_calls
  if (!FULL_RUN && n_llm_calls > MAX_LLM_CALLS) {
    stop("too_large: ", length(llm_paths), " non-aggregate paths + ",
         if (!is.null(aggregate_df)) nrow(aggregate_df) else 0L,
         " sub-sentinels would require ", n_llm_calls, " LLM calls (max ",
         MAX_LLM_CALLS, ")")
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

  if (length(llm_paths) > 0) {
    chunks <- split(llm_paths, ceiling(seq_along(llm_paths) / LLM_BATCH_SIZE))

    for (i in seq_along(chunks)) {
      prefix       <- if (i == 1) "Classify this repository tree:" else
                        build_structure_summary(experiment_map, type_map, last_entry)
      batch_result <- llm_batch(
        paths         = chunks[[i]],
        system_prompt = STRUCTURE_PROMPT,
        user_prefix   = prefix,
        key_col       = "path",
        extra_cols    = c("type", "group"),
        fallback_vals = list(type = "other", group = "shared"),
        sentinel_cols = "type",
        paper_id      = paper_id,
        stage_name    = "file-type Phase 1"
      )
      batch_result$prompt_nr <- i
      structure_parsed <- rbind(structure_parsed, batch_result)
      experiment_map   <- update_experiment_map(experiment_map, batch_result)
      type_map         <- update_type_map(type_map, batch_result)
      last_entry       <- batch_result[nrow(batch_result), ]
    }
  }
  n_phase1_batches <- if (!is.null(structure_parsed)) max(structure_parsed$prompt_nr) else 0L

  # ── Phase 2: classify aggregate sub-sentinels with Phase 1 context ─────────

  sentinel_parsed <- NULL

  if (!is.null(aggregate_df) && nrow(aggregate_df) > 0) {
    sentinel_type_map <- list()
    s_chunks <- split(aggregate_df$descriptor,
                      ceiling(seq_along(aggregate_df$descriptor) / LLM_BATCH_SIZE))

    for (i in seq_along(s_chunks)) {
      pfx          <- build_sentinel_summary(experiment_map, type_map)
      if (i > 1) {
        pfx        <- build_sentinel_summary(experiment_map,
                                             update_type_map(type_map, sentinel_parsed))
      }
      batch_result <- llm_batch(
        paths         = s_chunks[[i]],
        system_prompt = SENTINEL_PROMPT,
        user_prefix   = pfx,
        key_col       = "path",
        extra_cols    = c("type", "group"),
        fallback_vals = list(type = "other", group = "shared"),
        sentinel_cols = "type",
        paper_id      = paper_id,
        stage_name    = "file-type Phase 2"
      )
      batch_result$prompt_nr <- n_phase1_batches + i
      sentinel_parsed   <- rbind(sentinel_parsed, batch_result)
      sentinel_type_map <- update_type_map(sentinel_type_map, batch_result)
    }

    # Merge Phase 2 results back into aggregate_df; apply type_resolved override
    agg_merged <- merge(aggregate_df, sentinel_parsed,
                        by.x = "descriptor", by.y = "path", all.x = TRUE)
    # Where type was already resolved by extension rule, use that; else use LLM type
    agg_merged$final_type  <- ifelse(!is.na(agg_merged$type_resolved),
                                     agg_merged$type_resolved,
                                     agg_merged$type)
    agg_merged$final_group <- agg_merged$group
    agg_merged$final_type[is.na(agg_merged$final_type)]   <- "other"
    agg_merged$final_group[is.na(agg_merged$final_group)] <- "shared"

    # FR-011: post-Phase-2 diagnostic per aggregate folder
    for (d in unique(agg_merged$folder)) {
      rows <- agg_merged[agg_merged$folder == d, ]
      message(sprintf("── Aggregate [%s]: Phase 2 assigned %d sub-sentinel(s)",
                      d, nrow(rows)))
      for (j in seq_len(nrow(rows))) {
        message(sprintf("   [%s] type=%s, group=%s",
                        rows$prefix[j], rows$final_type[j], rows$final_group[j]))
      }
    }

    aggregate_df <- agg_merged
  }

  # ── 7. Expand sub-sentinels back to individual files ─────────────────────────
  # Each sub-sentinel row in aggregate_df carries:
  #   folder_members (list-col) — rel_paths of all files in this series
  #   final_type / final_group  — Phase 2 LLM result + extension override applied
  #   type_resolved             — non-NA when extension override was used for type
  #   is_series                 — TRUE = detected series, FALSE = fallback sentinel
  #
  # Per-file type resolution:
  #   1. Check per-file extension against AGGREGATE_EXT_OVERRIDE.
  #   2. If override hit → type = override value, type_source = "extension_rule"
  #   3. If no override  → type = sub-sentinel's final_type (Phase 2 LLM result),
  #                         type_source = "sentinel_llm"
  #
  # data_granularity:
  #   "individual" — file is part of a detected series (is_series = TRUE)
  #   "combined"   — fallback sentinel file (is_series = FALSE) or Phase 1 file

  if (!is.null(aggregate_df) && nrow(aggregate_df) > 0) {
    agg_expanded <- lapply(seq_len(nrow(aggregate_df)), function(i) {
      row     <- aggregate_df[i, ]
      members <- row$folder_members[[1]]
      if (length(members) == 0) {
        warning("Sub-sentinel has no members: ", row$folder, "/", row$prefix)
        return(NULL)
      }

      # Per-file extension override
      member_exts  <- tolower(tools::file_ext(members))
      ext_override <- AGGREGATE_EXT_OVERRIDE[member_exts]
      has_override <- !is.na(ext_override)

      types       <- ifelse(has_override, ext_override, row$final_type)
      type_source <- ifelse(has_override, "extension_rule", "sentinel_llm")

      # data_granularity: "individual" for detected-series members; "combined" for fallback
      is_data        <- types == "data"
      data_gran      <- ifelse(is_data & isTRUE(row$is_series), "individual",
                               ifelse(is_data, "combined", NA_character_))

      data.frame(
        path             = file.path(norm_base, members),
        rel_path         = members,
        type             = types,
        group            = row$final_group,
        aggregate_folder = row$folder,
        type_source      = type_source,
        data_granularity = data_gran,
        is_sentinel      = FALSE,
        prompt_nr        = if ("prompt_nr" %in% names(row)) row$prompt_nr else NA_integer_,
        stringsAsFactors = FALSE
      )
    })
    agg_expanded_df <- do.call(rbind, Filter(Negate(is.null), agg_expanded))
  } else {
    agg_expanded_df <- NULL
  }

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
    path             = file.path(norm_base, non_agg_relpaths),
    rel_path         = non_agg_relpaths,
    type             = p1_types,
    group            = p1_groups,
    aggregate_folder = NA_character_,
    type_source      = "llm",
    data_granularity = ifelse(p1_is_data, "combined", NA_character_),
    is_sentinel      = FALSE,
    prompt_nr        = p1_prompt_nrs,
    stringsAsFactors = FALSE
  )

  file_df          <- rbind(non_agg_df, agg_expanded_df)
  file_df$paper_id <- paper_id
  file_df$filename <- basename(file_df$path)
  file_df$ext      <- tolower(tools::file_ext(file_df$path))
  file_df$data_format <- ifelse(file_df$type == "data",
                                classify_data_format(file_df$ext),
                                NA_character_)

  # ── 8. Save structure ────────────────────────────────────────────────────────

  structure_out <- file.path(eff_dir, "structure.csv")
  cat("\n── File inventory ──────────────────────────────\n")
  print(table(paste0(file_df$type, " / ", file_df$group)))

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
  if (is.finite(MAX_DATA_FILES) && nrow(data_files) > MAX_DATA_FILES) {
    message("── Capping data files: ", nrow(data_files), "sskipping")
    columns_df   <- NULL
    columns_out  <- NULL
    data_files   <- file_df[FALSE, ]  
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
    if (!is.na(file_mb) && file_mb > MAX_FILE_MB) {
      message("  skipping (too large: ", round(file_mb), " MB): ", basename(path))
      return(NULL)
    }
    # Aggregate data cap: skip this file if adding it would exceed the per-paper limit.
    if (!is.na(file_mb) && (.read_state$mb_read + file_mb) > MAX_TOTAL_DATA_MB) {
      if (!.read_state$limit_hit) {
        message("  stopping column extraction: total data read would exceed ",
                round(MAX_TOTAL_DATA_MB / 1024, 0), " GB limit (",
                round(.read_state$mb_read / 1024, 1), " GB already read)")
        .read_state$limit_hit <- TRUE
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
      message("  skipping (timed out after ", round(MAX_FILE_READ_SEC / 60), " min): ",
              basename(path))
      NULL
    })
    if (timed_out) return(NULL)
    if (is.null(df) || ncol(df) == 0) {
      message("  skipping (unreadable or empty): ", basename(path))
      return(NULL)
    }
    if (!is.na(file_mb)) .read_state$mb_read <- .read_state$mb_read + file_mb

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
        message("  multi-level header resolved (used row ", sub_header_row + 1,
                " as header): ", basename(path))
      } else {
        # Branch 2: no sub-header found — group context not meaningful without a sub-header.
        col_header_group <- rep(NA_character_, ncol(df))
        has_any_real     <- any(!auto_named)
        if (has_any_real) {
          message("  multi-level header detected (partial labels retained): ",
                  basename(path))
          # proceed with df as-is
        } else {
          # skip: entirely placeholder header with no recoverable sub-header
          message("  skipping (multi-level header, no usable sub-header found): ",
                  basename(path))
          return(NULL)
        }
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
      cap    <- if (isTRUE(is_numeric_vec[i])) 10L else 20L
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
      message("── col_type Batch 1 (numeric): ", length(num_ambig_rows),
              " column(s) assigned continuous (LLM skipped)")
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
      message("── LLM col_type Batch 2 (character): classifying ",
              length(char_ambig_rows), " column(s)")
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
        message("── col_type Batch 2: ", sum(invalid_mask),
                " invalid type(s) remapped to text: ",
                paste(bad_types, collapse = ", "))
        returned_types[invalid_mask] <- "text"
      }
      columns_df$col_type[char_ambig_rows] <- returned_types

      # Fallback: LLM "unknown" for a character column → "text".
      char_unknown <- char_ambig_rows[columns_df$col_type[char_ambig_rows] == "unknown"]
      if (length(char_unknown) > 0) {
        columns_df$col_type[char_unknown] <- "text"
        message("── col_type fallback: ", length(char_unknown),
                " character column(s) reclassified from unknown \u2192 text")
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
  message("── data_granularity: ", n_individual, " individual, ",
          n_combined, " combined data file(s)")

  write.csv(
    file_df[, c("paper_id", "path", "rel_path", "filename", "ext",
                "type", "type_source", "group", "aggregate_folder",
                "data_granularity", "is_sentinel", "prompt_nr", "data_format")],
    structure_out, row.names = FALSE
  )
  message("── Saved structure → ", structure_out)

  if (!is.null(columns_df) && nrow(columns_df) > 0) {
    columns_out   <- file.path(eff_dir, "columns.csv")
    invalid_types <- setdiff(unique(columns_df$col_type), VALID_COL_TYPES)
    if (length(invalid_types) > 0)
      warning("Unknown col_type values: ", paste(invalid_types, collapse = ", "))
    write.csv(columns_df, columns_out, row.names = FALSE)
    message("── Saved columns  → ", columns_out,
            "  (", nrow(columns_df), " rows across ",
            length(unique(columns_df$source_file)), " file(s))")
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
