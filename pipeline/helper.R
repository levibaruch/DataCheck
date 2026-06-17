# ── Terminal color helpers ─────────────────────────────────────────────────────
.ansi <- function(code, x) paste0("\033[", code, "m", x, "\033[0m")
col_cyan    <- function(x) .ansi("36",   x)
col_yellow  <- function(x) .ansi("33",   x)
col_magenta <- function(x) .ansi("35",   x)
col_green   <- function(x) .ansi("32",   x)
col_red     <- function(x) .ansi("31",   x)
col_dim     <- function(x) .ansi("2",    x)
col_bold    <- function(x) .ansi("1",    x)

# ── Output directory helper ───────────────────────────────────────────────────
local({
  dc <- getOption("dc_root")
  if (!is.null(dc)) {
    source(file.path(dc, "pipeline", "ollama.R"))
  } else {
    source("pipeline/ollama.R")
  }
})
# Returns TRUE if paper_id is a Harvard Dataverse DOI slug.
# OSF paper IDs are always numeric strings and never start with "doi_".
is_dataverse_id <- function(paper_id) {
  startsWith(as.character(paper_id), "doi_")
}

# Make a source-specific ID safe for filesystem paths.
# Replaces ':' and '/' with '_' so DOIs like "doi:10.7910/DVN/ABC" become
# "doi_10.7910_DVN_ABC" — consistent with the existing Dataverse directory
# naming convention and compatible with is_dataverse_id().
sanitize_id <- function(id) {
  gsub("[:/]", "_", as.character(id))
}

# Central path resolver — all per-paper filesystem paths route through here.
# layer:    "data" | "outputs" | "psychds" | "ground_truth"
# source:   registered source identifier — "osf" | "dataverse"
# paper_id: source-specific identifier (will be sanitized for filesystem use)
# ...:      optional additional path components forwarded to file.path()
# Note: DATA_DIR, OUTPUT_DIR, PSYCHDS_OUT_DIR, GROUND_TRUTH_DIR must be
#       defined in the calling script before paper_path() is invoked.
paper_path <- function(layer, source, paper_id, ...) {
  KNOWN_SOURCES <- c("osf", "dataverse")
  if (!source %in% KNOWN_SOURCES)
    stop(sprintf("paper_path: unknown source '%s'. Valid sources: %s",
                 source, paste(KNOWN_SOURCES, collapse = ", ")))
  root <- switch(layer,
    data         = DATA_DIR,
    outputs      = OUTPUT_DIR,
    psychds      = PSYCHDS_OUT_DIR,
    ground_truth = GROUND_TRUTH_DIR,
    stop(sprintf("paper_path: unknown layer '%s'", layer))
  )
  file.path(root, source, sanitize_id(paper_id), ...)
}

# Return the per-paper output directory path, creating it if necessary.
# source and paper_id must be character strings.
paper_output_dir <- function(source, paper_id) {
  dir_path <- paper_path("outputs", source, paper_id)
  if (!dir.exists(dir_path)) dir.create(dir_path, recursive = TRUE)
  dir_path
}

# Scan data/<source>/ for each registered source and return a data.frame
# with columns: source (character), paper_id (character).
# Returns NULL if no paper directories are found under any source.
list_downloaded_papers <- function() {
  KNOWN_SOURCES <- c("osf", "dataverse")
  rows <- lapply(KNOWN_SOURCES, function(src) {
    src_dir <- file.path(DATA_DIR, src)
    if (!dir.exists(src_dir)) return(NULL)
    ids <- list.dirs(src_dir, full.names = FALSE, recursive = FALSE)
    ids <- ids[nzchar(ids)]
    if (length(ids) == 0L) return(NULL)
    data.frame(source = src, paper_id = ids, stringsAsFactors = FALSE)
  })
  result <- do.call(rbind, Filter(Negate(is.null), rows))
  if (is.null(result) || nrow(result) == 0L) return(NULL)
  result
}

# ── Text file helpers ─────────────────────────────────────────────────────────

# Sniff the delimiter of a text file by counting candidate characters in the
# first non-empty line.  Returns the most frequent one, defaulting to ",".
sniff_delimiter <- function(path) {
  line <- character(0)
  con  <- file(path, "r")
  on.exit(close(con))
  for (i in seq_len(10)) {
    line <- readLines(con, n = 1, warn = FALSE)
    if (length(line) == 0) break                         # EOF: empty file
    l <- trimws(line)
    if (nchar(l) > 0 && !startsWith(l, "#")) break      # found a non-blank, non-comment line
  }
  if (length(line) == 0) return(",")     # empty file — return safe default
  candidates <- c(",", ";", "\t", "|")
  counts     <- vapply(candidates, function(d)
    nchar(line) - nchar(gsub(d, "", line, fixed = TRUE)), integer(1))
  if (max(counts) == 0) "," else candidates[which.max(counts)]
}

# Decide whether a delimited text file (csv/tsv/txt/dat) has a header row.
# Headerless files (raw Mplus .dat, numeric matrices) make read.delim consume
# the first DATA row as column names — corrupting headers (duplicate/numeric
# pseudo-names) and silently dropping a row. We treat a file as headerless when
# its first non-comment row already looks like numeric data AND so does the
# second: real headers carry at least one textual label. With <2 readable rows
# we cannot tell, so we assume a header (preserves prior behaviour). Used by
# both read_data_head() and read_full_data() so columns.csv and the converted
# CSV agree on column names.
detect_header <- function(path, sep) {
  con   <- file(path, "r")
  on.exit(close(con))
  lines <- character(0)
  while (length(lines) < 2) {
    l <- readLines(con, n = 1, warn = FALSE)
    if (length(l) == 0) break                                  # EOF
    if (nzchar(trimws(l)) && !startsWith(trimws(l), "#")) lines <- c(lines, l)
  }
  if (length(lines) < 2) return(TRUE)                          # can't tell → header
  split_row <- function(l)
    trimws(gsub('^"|"$', '', strsplit(l, sep, fixed = TRUE)[[1]]))
  is_num <- function(x) {
    if (!nzchar(x)) return(TRUE)                               # blank: not textual
    if (toupper(x) %in% c("NA", "NAN", "NULL", "INF", "-INF", "+INF")) return(TRUE)
    suppressWarnings(!is.na(as.numeric(x)))
  }
  all_num <- function(toks) length(toks) > 0 && all(vapply(toks, is_num, logical(1)))
  !(all_num(split_row(lines[1])) && all_num(split_row(lines[2])))
}

# Read the first n_rows of a data file regardless of format.
# Returns a data.frame, or NULL on failure / unsupported format.
read_data_head <- function(path, n_rows = 3) {
  ext <- tolower(tools::file_ext(path))
  tryCatch({
    switch(ext,
      csv  = ,
      txt  = ,
      tsv  = ,
      dat  = {
        sep <- if (ext == "tsv") "\t" else sniff_delimiter(path)
        hdr <- detect_header(path, sep)
        df  <- suppressWarnings(
          read.delim(path, sep = sep, header = hdr, nrows = n_rows,
                     check.names = FALSE, stringsAsFactors = FALSE)
        )
        # If any character column contains invalid UTF-8 bytes (e.g. Windows-1252
        # encoded files), retry with latin1 so downstream string ops don't crash.
        has_invalid <- any(vapply(df, function(col) {
          is.character(col) && any(is.na(iconv(col, from = "UTF-8", to = "UTF-8")))
        }, logical(1)))
        if (has_invalid) {
          df <- suppressWarnings(
            read.delim(path, sep = sep, header = hdr, nrows = n_rows,
                       check.names = FALSE, stringsAsFactors = FALSE,
                       fileEncoding = "latin1")
          )
        }
        # Headerless: synthesize stable col_N names (the first data row was kept).
        if (!hdr && !is.null(df) && ncol(df) > 0)
          names(df) <- paste0("col_", seq_len(ncol(df)))
        df
      },
      xlsx = ,
      xls  = readxl::read_excel(path, n_max = n_rows),
      sav  = as.data.frame(haven::read_sav(path, n_max = n_rows)),
      dta  = as.data.frame(haven::read_dta(path, n_max = n_rows)),
      sas7bdat = as.data.frame(haven::read_sas(path, n_max = n_rows)),
      rds  = {
        obj <- readRDS(path)
        if (is.data.frame(obj)) head(obj, n_rows) else NULL
      },
      rda  = ,
      rdata = {
        env <- new.env()
        load(path, envir = env)
        dfs <- Filter(is.data.frame, as.list(env))
        if (length(dfs) > 0) head(dfs[[1]], n_rows) else NULL
      },
      NULL   # unsupported
    )
  }, error = function(e) {
    # Re-throw time-limit errors so callers can detect and report timeouts.
    if (grepl("time limit", conditionMessage(e), ignore.case = TRUE)) stop(e)
    warning("Could not read ", basename(path), ": ", conditionMessage(e))
    NULL
  })
}

# ── Archive helpers ───────────────────────────────────────────────────────────

# Match the dir-sanitization rule applied in 0_index.R step 2: collapse
# whitespace to "_", strip special chars, truncate to MAX_DIR_WORDS. Applied
# to the archive stem so the extracted dir lands on the post-sanitize name on
# first extract — preventing re-extraction → duplicate-tree drift across runs.
sanitize_basename <- function(name) {
  max_words <- if (exists("MAX_DIR_WORDS")) MAX_DIR_WORDS else 5L
  words <- strsplit(trimws(name), "\\s+")[[1]]
  words <- gsub("[^A-Za-z0-9_\\-]", "", words)
  words <- words[nchar(words) > 0]
  paste(head(words, max_words), collapse = "_")
}

unpack_archive <- function(path) {
  ext      <- tolower(tools::file_ext(path))
  raw_stem <- tools::file_path_sans_ext(basename(path))
  # For tar archives, sanitize dest dir name to match post-extract sanitization
  # done in 0_index.R step 2. Standalone-compressed files (gz/bz2/xz of a
  # single file) keep the raw stem — that's the *output filename*, not a dir.
  is_tar_like  <- !(ext %in% c("gz", "bz2", "xz")) ||
                   grepl("\\.(tar\\.(gz|bz2|xz)|tgz)$", tolower(basename(path)))
  stem <- if (is_tar_like) sanitize_basename(raw_stem) else raw_stem
  dest <- file.path(dirname(path), stem)

  # Standalone compressed files (e.g. data.csv.gz, data.csv.bz2, data.csv.xz)
  # are NOT tar archives — decompress to a single file instead
  is_standalone <- (ext %in% c("gz", "bz2", "xz") &&
    !grepl("\\.(tar\\.(gz|bz2|xz)|tgz)$", tolower(basename(path))))

  if (is_standalone) {
    # dest is the decompressed file path (e.g. data.csv)
    if (file.exists(dest)) {
      message("  skipping (already unpacked): ", basename(path))
      return(dirname(path))
    }
    message("  decompressing: ", basename(path), " → ", dest)
    tryCatch({
      if (ext == "gz") {
        con_in <- gzfile(path, "rb")
      } else if (ext == "bz2") {
        con_in <- bzfile(path, "rb")
      } else {
        con_in <- xzfile(path, "rb")
      }
      con_out <- file(dest, "wb")
      on.exit({ close(con_in); close(con_out) })
      while (length(chunk <- readBin(con_in, "raw", n = 1048576L)) > 0)
        writeBin(chunk, con_out)
      dirname(path)
    }, error = function(e) {
      warning("Failed to decompress ", basename(path), ": ", conditionMessage(e))
      NULL
    })
  } else {
    if (dir.exists(dest)) {
      message("  skipping (already unpacked): ", basename(path))
      return(dest)
    }

    dir.create(dest, recursive = TRUE)
    message("  unpacking: ", basename(path), " → ", dest)

    tryCatch({
      if (ext == "zip") {
        utils::unzip(path, exdir = dest)
      } else if (ext == "rar") {
        # Requires unrar to be installed (e.g. brew install rar on macOS).
        # system2 returns 127 when the binary is not found; non-zero → error.
        ret <- system2("unrar", c("x", "-y", shQuote(normalizePath(path)),
                                  shQuote(dest)),
                       stdout = FALSE, stderr = FALSE)
        if (ret != 0) stop("unrar exited with code ", ret,
                           " (is unrar installed?)")
      } else {
        # tar, tgz, tar.gz, tar.bz2, tar.xz — untar auto-detects compression
        utils::untar(path, exdir = dest)
      }
      dest
    }, error = function(e) {
      warning("Failed to unpack ", basename(path), ": ", conditionMessage(e))
      NULL
    })
  }
}

# ── Rule-based classification ─────────────────────────────────────────────────

classify_by_rules <- function(path) {
  # tolower() normalises .R/.Rmd/.QMD etc. so ext_map keys can be plain lowercase
  fname <- tolower(basename(path))
  ext   <- tools::file_ext(fname)
  stem  <- tools::file_path_sans_ext(fname)

  # 1. Name pattern takes priority (catches codebooks saved as .xlsx, .csv, etc.)
  for (label in names(RULES$name_patterns)) {
    if (grepl(RULES$name_patterns[[label]], stem, perl = TRUE)) {
      return(list(label = label, certain = TRUE))
    }
  }

  # 2. Unambiguous extension
  if (ext %in% names(RULES$ext_map)) {
    # txt is a common catch-all — mark uncertain
    certain <- !(ext %in% c("txt"))
    return(list(label = RULES$ext_map[[ext]], certain = certain))
  }

  # 3. Ambiguous extensions (csv, xlsx, xls, html) and unknowns — send to LLM
  list(label = NA_character_, certain = FALSE)
}

# ── Data format sub-classification ───────────────────────────────────────────

TABULAR_EXTENSIONS <- c("csv", "tsv", "txt", "dat", "xlsx", "xls", "sav", "dta", "sas7bdat")
RAW_EXTENSIONS     <- c(
  # EEG / physiological recordings
  "edf", "bdf", "acq", "gdf", "rec", "cnt",
  "vhdr", "vmrk", "eeg",          # BrainVision
  "mff",                           # EGI/Philips
  "set", "fdt",                    # EEGLAB
  "fif",                           # MNE / MEG
  # Neuroimaging
  "nii", "img", "hdr",             # NIfTI / Analyze
  "mgh", "mgz",                    # FreeSurfer
  "mnc",                           # MINC
  "dcm",                           # DICOM
  # Motion capture / biomechanics
  "c3d", "trc", "mot", "sto",
  # MATLAB / array formats
  "mat",
  # HDF5 / scientific array formats
  "h5", "hdf5", "hdf",
  "nc", "cdf",                     # NetCDF
  # NumPy / Python serialised arrays
  "npy", "npz",
  "pkl", "pickle",
  # Eye-tracking
  "asc",                           # EyeLink ASCII export
  # Audio
  "wav", "mp3", "flac", "ogg", "m4a", "aiff", "aif", "au", "wma",
  # Video
  "mp4", "avi", "mov", "mkv", "wmv", "m4v", "flv", "webm", "3gp",
  # Generic binary
  "bin", "raw",
  # Document formats — never tabular; guard against LLM mis-classifying a PDF as data
  "pdf", "docx", "doc", "odt", "rtf"
)

# Takes a character vector of lowercase file extensions (no leading dot).
# Returns "tabular" or "raw" for each element — never NA.
# Unknown extensions fall back to "tabular" (conservative).
classify_data_format <- function(ext) {
  ifelse(ext %in% RAW_EXTENSIONS, "raw", "tabular")
}

# ── Column type classification ─────────────────────────────────────────────────

# Rule-based classification of a single data column.
# Returns list(col_type, ambiguous, numeric_values, n_coerced):
#   col_type      : character label from VALID_COL_TYPES, or NA when LLM is needed
#   ambiguous     : TRUE when the column should be sent to the LLM
#   numeric_values: numeric vector for stat computation (may be normalised),
#                   or NULL when the column is non-numeric
#   n_coerced     : integer count of values coerced to NA during normalisation,
#                   or NA_integer_ when no normalisation was applied
classify_col_type_rules <- function(col_name, values) {
  x_noNA  <- values[!is.na(values)]
  n_noNA  <- length(x_noNA)

  # Rule 1: all NA
  if (n_noNA == 0)
    return(list(col_type = "empty", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))

  n_unique <- length(unique(x_noNA))

  # Rule 2: ID column — name matches common psychology/survey/BIDS identifier patterns.
  #         Hard-classified directly; no LLM routing; no value-type constraint.
  #         Name pattern takes precedence over all value-based rules below.
  id_pat <- paste0(
    "(?i)(",
    "^(participant|subject|subj|respondent|pp|ppt|pid|sub)$",          # standalone root words
    "|^id$",                                                             # standalone "id"
    "|[_\\-\\.](id|number|num|nr|no|code)$",                           # ends with id/number/nr suffix
    "|^(subjectid|subjectnumber|responseid|recordid|participantid|",    # compound forms (no separator)
    "subjectno|subjectnum|subjectcode|participantno|participantnum)$",
    "|^sub[_\\-]\\d",                                                   # BIDS: sub-01, sub_01
    "|^(participant|subject|subj|pp|sub)[_\\-]?\\d+$",                 # root + numeric suffix
    ")"
  )
  if (grepl(id_pat, col_name, perl = TRUE))
    return(list(col_type = "id", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))

  # Rule 3: constant — exactly 1 unique non-NA value (degenerate/placeholder column)
  if (n_unique == 1)
    return(list(col_type = "constant", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))

  # Rule 4: binary — exactly 2 unique non-NA values
  if (n_unique == 2)
    return(list(col_type = "binary", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))

  # Rule 4: date — try as.Date on a sample of up to 20 unique string values
  char_sample <- as.character(unique(x_noNA))[seq_len(min(20, n_unique))]
  n_date_ok   <- sum(vapply(char_sample, function(v) {
    tryCatch(!is.na(as.Date(v)), warning = function(w) FALSE, error = function(e) FALSE)
  }, logical(1)))
  if (n_date_ok / length(char_sample) >= 0.70)
    return(list(col_type = "date", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))

  # Rule 5: free text — long median string length
  if (median(nchar(as.character(x_noNA))) > 40)
    return(list(col_type = "text", ambiguous = FALSE, numeric_values = NULL,
                n_coerced = NA_integer_, is_numeric = FALSE))

  # Rule 6: numeric column — decimal and high-cardinality cases both resolve to
  # continuous in one check (merged from the former Rule 6a + Rule 6; verified
  # identical on the 120b-JSON validation set via
  # runners/eval/analysis_scripts/compare_coltype_rule_merge.R — 0 differing columns).
  #   - any fractional value       → continuous (VAS / ratio scales, no LLM)
  #   - > 20 unique integer values → continuous (no LLM)
  #   - 3–20 unique integer values → route to LLM (ordinal vs continuous vs categorical).
  #     is_numeric = TRUE flags integer-numeric columns so a post-LLM fallback can
  #     replace "unknown" → "continuous" when the LLM cannot determine the type.
  if (is.numeric(values)) {
    if (any(x_noNA != floor(x_noNA)) || n_unique > 20)
      return(list(col_type = "continuous", ambiguous = FALSE, numeric_values = values,
                  n_coerced = NA_integer_, is_numeric = FALSE))
    return(list(col_type = NA_character_, ambiguous = TRUE, numeric_values = values,
                n_coerced = NA_integer_, is_numeric = TRUE))
  }

  # Rule 7: comma-decimal normalisation for character columns
  x_sub  <- suppressWarnings(as.numeric(gsub(",", ".", as.character(x_noNA), fixed = TRUE)))
  pct_ok <- sum(!is.na(x_sub)) / n_noNA
  if (pct_ok >= 0.95) {
    num_vec    <- suppressWarnings(as.numeric(gsub(",", ".", as.character(values), fixed = TRUE)))
    n_coerced  <- sum(is.na(x_sub))  # non-NA values that failed conversion
    return(list(col_type = "continuous_comma_decimal", ambiguous = FALSE,
                numeric_values = num_vec, n_coerced = n_coerced, is_numeric = FALSE))
  }
  if (pct_ok >= 0.80) {
    num_vec    <- suppressWarnings(as.numeric(gsub(",", ".", as.character(values), fixed = TRUE)))
    n_coerced  <- sum(is.na(x_sub))  # non-NA values that failed conversion
    return(list(col_type = "continuous_outliers_excluded", ambiguous = FALSE,
                numeric_values = num_vec, n_coerced = n_coerced, is_numeric = FALSE))
  }

  # Rule 9: char-ambiguous — all remaining character columns route to Batch 2 (character LLM)
  return(list(col_type = NA_character_, ambiguous = TRUE, numeric_values = NULL,
              n_coerced = NA_integer_, is_numeric = FALSE))
}

# ── LLM helpers ───────────────────────────────────────────────────────────────

# Strip markdown fences and stray backticks the LLM may add around values
extract_json <- function(txt) {
  if (length(txt) == 0 || is.na(txt)) return(NA_character_)
  txt <- trimws(txt)
  # Remove ```json ... ``` or ``` ... ``` wrappers
  txt <- gsub("^```(?:json)?\\s*|\\s*```$", "", txt, perl = TRUE)
  txt <- trimws(txt)
  # Extract only the outermost JSON array [...] — discard any prose the LLM
  # appended after the closing bracket (e.g. "(Note: paths truncated ...)")
  m <- regexpr("(?s)\\[.*\\]", txt, perl = TRUE)
  if (!is.na(m) && m != -1) txt <- regmatches(txt, m)
  txt
}

clean_llm_values <- function(df) {
  # Strip backticks the LLM wraps around individual field values, e.g. `data`
  for (col in names(df)) {
    if (is.character(df[[col]])) {
      df[[col]] <- gsub("`", "", df[[col]], fixed = TRUE)
    }
  }
  df
}


# Run an LLM prompt over a character vector in batches, joining results by a
# key column.  Returns a data.frame with columns c(key_col, extra_cols).
#
# Args:
#   paths         — character vector of file paths to classify (one row per path)
#   system_prompt — LLM system prompt (role/task description)
#   user_prefix   — text prepended to each chunk's numbered path list
#   key_col       — name of the column the LLM echoes back as the join key (usually "path")
#   extra_cols    — names of the classification columns expected in the LLM JSON response
#   fallback_vals — named list; values used when the LLM omits a field for a specific row
#   sentinel_cols — subset of extra_cols that receive LLM_SENTINEL_VAL (not fallback) on
#                   total chunk failure, marking those rows as "LLM never answered"
#   paper_id      — passed through to the error log only (for traceability)
#   stage_name    — passed through to the error log only (e.g. "file_type", "col_type")
llm_batch <- function(paths, system_prompt, user_prefix, key_col, extra_cols,
                      fallback_vals,
                      sentinel_cols  = NULL,
                      paper_id       = NULL,
                      stage_name     = NULL,
                      input_type     = "filepath",
                      match_keys     = NULL,
                      batch_nr       = NULL,
                      n_batches_total = NULL) {
  # input_type: "filepath" (default) = file paths as numbered list; "json_descriptor" = JSON array
  # match_keys: optional short keys for join — when set, paths are display-only and match_keys
  #             are used as chunk_match_keys instead. Allows long descriptor strings as display
  #             text while echoing only short keys (e.g. column names) in LLM JSON output.

  # Divide paths into fixed-size chunks (LLM_BATCH_SIZE = 20).
  # Each chunk becomes one LLM call so prompts stay within the model's context window.
  chunk_indices <- split(seq_along(paths), ceiling(seq_along(paths) / LLM_BATCH_SIZE))
  chunks        <- split(paths,            ceiling(seq_along(paths) / LLM_BATCH_SIZE))
  chunks_idx    <- chunk_indices  # used below when match_keys is set
  all_parsed    <- vector("list", length(chunks))  # pre-allocated; filled in loop below

  for (i in seq_along(chunks)) {
    # Honour a user-initiated abort: if a sentinel file exists, stop immediately
    # rather than continuing to fire LLM calls for the rest of the paper.
    if (exists("SKIP_FILE") && file.exists(SKIP_FILE))
      stop("user_skip: skip signal detected — user requested paper be aborted")

    chunk_paths <- chunks[[i]]

    # For JSON descriptors, extract the "path" field from each JSON string for matching.
    # Store both the full JSON (for fallback) and extracted paths (for merge logic).
    if (!is.null(match_keys)) {
      # Caller-supplied short keys: paths are display-only; match_keys drive the join.
      chunk_match_keys <- match_keys[chunks_idx[[i]]]
    } else if (input_type == "json_descriptor") {
      # Extract path field from JSON: {"path": "...", ...} → extract the path value
      chunk_match_keys <- vapply(chunk_paths, function(json_str) {
        m <- regmatches(json_str, regexpr('"path"\\s*:\\s*"([^"]+)"', json_str), invert = FALSE)
        if (length(m[[1]]) > 0) {
          sub('^.*"path"\\s*:\\s*"([^"]+)".*$', '\\1', json_str)
        } else {
          NA_character_
        }
      }, character(1L))
    } else {
      chunk_match_keys <- chunk_paths
    }

    # Format input for LLM based on input_type:
    # - filepath: numbered list (e.g., "1. path/to/file.csv\n2. path/to/file2.csv")
    # - json_descriptor: JSON array (e.g., "[{...}, {...}]")
    if (input_type == "json_descriptor") {
      # For JSON descriptors, format as a JSON array
      chunk_text <- paste0("[\n", paste(chunk_paths, collapse = ",\n"), "\n]")
    } else {
      # Default filepath format: numbered list
      chunk_text <- paste(seq_along(chunk_paths), chunk_paths, sep = ". ", collapse = "\n")
    }

    # Assemble the full user-turn message: caller-supplied prefix + input +
    # strict JSON-only instruction.  The trailing instruction is appended here (not
    # in the caller) so every llm_batch call enforces the same output contract.
    chunk_input <- paste0(user_prefix, "\n\n", chunk_text,
                          "\n\nReturn ONLY a JSON array with exactly ", length(chunk_paths),
                          " objects — one per input above. Echo every path character-for-character.",
                          " No truncation. No notes. No text outside the array.")

    # The columns we must find in the parsed response.
    needed_cols    <- c(key_col, extra_cols)

    # Pre-build a fallback data.frame for this chunk.  Used in two places:
    #   1. Per-row: fill NAs left by merge when the LLM omitted a row's key.
    #   2. Whole-chunk: returned when all retries are exhausted.
    chunk_fallback <- as.data.frame(
      c(list(keys = chunk_match_keys),
        setNames(lapply(fallback_vals, rep, length(chunk_paths)), extra_cols)),
      stringsAsFactors = FALSE
    )
    names(chunk_fallback)[1] <- key_col  # rename generic "keys" to the caller's key name

    # ── Retry state ──────────────────────────────────────────────────────────
    attempt       <- 1L    # current attempt number (1-indexed)
    last_raw      <- NULL  # most recent raw LLM response object
    last_err      <- NULL  # the error from the most recent failed parse attempt
    last_fail_raw <- NULL  # raw response from the last *failed* attempt (for log)
    success       <- FALSE

    while (TRUE) {
      llm_params      <- list(temperature = LLM_TEMPERATURE, think = LLM_THINK_LEVEL)
      do_capture      <- exists("CAPTURE_THINKING") && isTRUE(CAPTURE_THINKING) &&
                         exists("THINKING_LOG_PATH") && !is.null(THINKING_LOG_PATH)
      raw             <- if (grepl("^groq/", LLM_MODEL))
                          llm_groq(system_prompt = system_prompt, text = chunk_input,
                                   model = LLM_MODEL, params = llm_params,
                                   think = LLM_THINK_LEVEL,
                                   capture_thinking = do_capture)
                        else
                          llm_ollama(system_prompt = system_prompt, text = chunk_input,
                                     params = llm_params, capture_thinking = do_capture)
      last_raw        <- raw

      # Try to parse and validate the response.  tryCatch returns either the
      # merged data.frame (success) or the error object (failure) — checked below.
      parsed <- tryCatch({
        # extract_json() strips markdown fences; fromJSON parses the array;
        # clean_llm_values() strips stray backtick characters from string fields.
        result <- clean_llm_values(jsonlite::fromJSON(extract_json(raw$answer), flatten = TRUE))

        # Feature 038: Validate response count — LLM must return exactly one object per input path.
        # Incomplete responses (fewer objects than paths sent) indicate an error condition
        # and should trigger retry, not silent fallback fill.
        if (nrow(result) != length(chunk_paths)) {
          # Log incomplete response detection before raising error (for operator visibility)
          pid   <- if (!is.null(paper_id))   paper_id   else "<unknown>"
          stage <- if (!is.null(stage_name)) stage_name else "<unknown>"
          dir.create(dirname(LLM_ERROR_LOG), recursive = TRUE, showWarnings = FALSE)
          cat(sprintf("[%s] paper_id=%s stage=%s chunk=%d n_items=%d paths_sent=%d paths_received=%d incomplete_detected=TRUE attempt=%d\n--- raw response ---\n%s\n---\n\n",
                      format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
                      pid, stage, i, length(chunk_paths), length(chunk_paths), nrow(result), attempt,
                      raw$answer),
              file = LLM_ERROR_LOG, append = TRUE)
          stop("Incomplete LLM response: expected ", length(chunk_paths), " objects, received ", nrow(result))
        }

        # Validate that the model returned all required columns.
        if (!all(needed_cols %in% names(result))) {
          stop("Response missing fields: ",
               paste(setdiff(needed_cols, names(result)), collapse = ", "))
        }

        # Deduplicate LLM response on the key column before merging — duplicate
        # echoed keys (e.g. same basename returned twice) cause a many-to-many
        # join that drops rows.  Keep first occurrence of each key.
        result <- result[!duplicated(result[[key_col]]), needed_cols, drop = FALSE]

        # Left-join the LLM result onto the original chunk paths so that:
        #   a) every input path is represented in the output (all.x = TRUE), and
        #   b) paths the LLM silently dropped get NA filled with fallback_vals below.
        merged <- merge(
          data.frame(x = chunk_match_keys, stringsAsFactors = FALSE) |> setNames(key_col),
          result,
          by = key_col, all.x = TRUE
        )

        # Fill any NAs introduced by missing rows with the caller-supplied fallback.
        for (col in extra_cols) merged[[col]][is.na(merged[[col]])] <- fallback_vals[[col]]

        # merge() does not guarantee row order — restore the original chunk_match_keys order.
        merged[match(chunk_match_keys, merged[[key_col]]), ]
      }, error = function(e) e)

      # After a clean parse, validate the "type" column if present.
      # If any type is invalid, convert to simpleError so the existing retry
      # path below handles it identically to a parse failure.
      if (!inherits(parsed, "error") && "type" %in% names(parsed)) {
        invalid_types <- parsed$type[!vapply(parsed$type, is_valid_type, logical(1L))]
        if (length(invalid_types) > 0L) {
          parsed <- simpleError(sprintf(
            "llm_validation: invalid type value(s): %s",
            paste(unique(invalid_types), collapse = ", ")
          ))
        }
      }

      if (!inherits(parsed, "error")) {
        # Sanitize invalid group values to "shared" (no retry; defensive only).
        if ("group" %in% names(parsed)) {
          invalid_groups <- !vapply(parsed$group, is_valid_group, logical(1L))
          if (any(invalid_groups)) {
            parsed$group[invalid_groups] <- "shared"
          }
        }
        success <- TRUE
        break  # clean parse + valid types — exit retry loop
      }

      # Parse or validation failed — record state and decide whether to retry.
      last_err      <- parsed
      last_fail_raw <- raw
      if (attempt <= LLM_RETRY_LIMIT) {
        batch_label <- if (!is.null(batch_nr) && !is.null(n_batches_total))
          sprintf("batch %d/%d", batch_nr, n_batches_total)
        else
          sprintf("chunk %d", i)
        retry_reason <- if (inherits(parsed, "error"))
          substr(gsub("[\n\r]", " ", conditionMessage(parsed)), 1L, 60L)
        else ""
        cat(col_dim(sprintf("\u2500\u2500 LLM %s retry %d/%d \u2014 %s \u2500\u2500\n",
                            batch_label, attempt, LLM_RETRY_LIMIT, retry_reason)))
        attempt <- attempt + 1L
      } else {
        break  # retry budget exhausted — fall through to failure handler
      }
    }

    # ── Post-retry: record result or apply sentinel fallback ─────────────────
    if (success) {
      # If we succeeded but only after retrying, log the details so we can
      # review which prompts caused transient failures.
      if (attempt > 1L) {
        pid   <- if (!is.null(paper_id))   paper_id   else "<unknown>"
        stage <- if (!is.null(stage_name)) stage_name else "<unknown>"
        dir.create(dirname(LLM_ERROR_LOG), recursive = TRUE, showWarnings = FALSE)
        cat(sprintf("[%s] paper_id=%s stage=%s chunk=%d n_items=%d retries=%d SUCCEEDED\n--- system prompt ---\n%s\n--- user prompt ---\n%s\n--- last failed response ---\n%s\n---\n\n",
                    format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
                    pid, stage, i, length(chunk_paths), attempt - 1L,
                    system_prompt,
                    chunk_input,
                    last_fail_raw$answer),
            file = LLM_ERROR_LOG, append = TRUE)
      }
      all_parsed[[i]] <- parsed

      # Thinking trace capture: one row per batch call (chunk) in the CSV.
      # The full trace is stored; per-file classifications are listed in the MD.
      if (do_capture) {
        thinking_txt <- last_raw$thinking[[1L]] %||% ""
        answer_txt   <- last_raw$answer[[1L]]   %||% ""
        pid_lbl      <- if (!is.null(paper_id))   paper_id   else "<unknown>"
        stage_lbl    <- if (!is.null(stage_name)) stage_name else "<unknown>"
        n_words      <- length(strsplit(trimws(thinking_txt), "\\s+")[[1L]])

        tokens_in_total  <- sum(last_raw$tokens_in,  na.rm = TRUE)
        tokens_out_total <- sum(last_raw$tokens_out, na.rm = TRUE)

        log_row <- data.frame(
          paper_id         = pid_lbl,
          stage_name       = stage_lbl,
          chunk            = i,
          n_paths          = length(chunk_paths),
          paths            = paste(chunk_paths, collapse = " | "),
          thinking         = thinking_txt,
          n_thinking_words = n_words,
          answer           = answer_txt,
          model            = llm_model(),
          think_level      = LLM_THINK_LEVEL,
          temperature      = LLM_TEMPERATURE,
          tokens_in        = if (tokens_in_total  > 0) tokens_in_total  else NA_integer_,
          tokens_out       = if (tokens_out_total > 0) tokens_out_total else NA_integer_,
          stringsAsFactors = FALSE
        )

        # ── CSV (one row per prompt call) ────────────────────────────────────
        suppressWarnings(
          write.table(log_row,
                      file      = THINKING_LOG_PATH,
                      sep       = ",",
                      col.names = !file.exists(THINKING_LOG_PATH),
                      row.names = FALSE,
                      append    = TRUE,
                      qmethod   = "double")
        )

        # ── Markdown (human-readable) ────────────────────────────────────────
        md_path  <- sub("\\.csv$", ".md", THINKING_LOG_PATH)
        md_lines <- c(
          sprintf("## %s — stage: %s — chunk %d  (%d paths, %d words, model: %s, think: %s, temp: %.1f)",
                  pid_lbl, stage_lbl, i, length(chunk_paths), n_words,
                  llm_model(), LLM_THINK_LEVEL, LLM_TEMPERATURE),
          "",
          "### Files sent",
          ""
        )
        for (j in seq_along(chunk_paths)) {
          md_lines <- c(md_lines, sprintf("%d. `%s`", j, chunk_paths[[j]]))
        }
        md_lines <- c(md_lines, "", "### Classifications", "")
        for (j in seq_along(chunk_paths)) {
          pred <- if ("type" %in% names(parsed) && j <= length(parsed$type))
                    parsed$type[[j]] else "?"
          grp  <- if ("group" %in% names(parsed) && j <= length(parsed$group))
                    parsed$group[[j]] else NA_character_
          label <- if (!is.na(grp)) sprintf("**%s** / %s", pred, grp) else sprintf("**%s**", pred)
          md_lines <- c(md_lines, sprintf("- `%s` → %s", chunk_paths[[j]], label))
        }
        if (nzchar(trimws(thinking_txt))) {
          md_lines <- c(md_lines, "", "### Thinking trace", "", thinking_txt)
        }
        if (nzchar(trimws(answer_txt))) {
          md_lines <- c(md_lines, "", "### LLM output", "", "```json", answer_txt, "```")
        }
        md_lines <- c(md_lines, "", "---", "")
        cat(paste(md_lines, collapse = "\n"),
            file = md_path, append = TRUE, sep = "")
        cat("\n", file = md_path, append = TRUE)
      }
    } else {
      # All retries exhausted — log the failure and substitute sentinel values
      # so downstream stages can detect which rows were never answered by the LLM.
      pid   <- if (!is.null(paper_id))   paper_id   else "<unknown>"
      stage <- if (!is.null(stage_name)) stage_name else "<unknown>"
      dir.create(dirname(LLM_ERROR_LOG), recursive = TRUE, showWarnings = FALSE)
      cat(sprintf("[%s] paper_id=%s stage=%s chunk=%d n_items=%d\n--- system prompt ---\n%s\n--- user prompt ---\n%s\n--- raw response ---\n%s\n---\n\n",
                  format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
                  pid, stage, i, length(chunk_paths),
                  system_prompt,
                  chunk_input,
                  last_raw$answer),
          file = LLM_ERROR_LOG, append = TRUE)
      warning("Chunk ", i, " failed after ", LLM_RETRY_LIMIT, " retries: ",
              conditionMessage(last_err), "; using sentinel")

      # Build error_fallback: sentinel_cols get LLM_SENTINEL_VAL (a special marker
      # meaning "LLM never classified this") while non-sentinel cols get their normal
      # fallback_vals (a best-guess default that won't confuse downstream aggregation).
      error_fallback <- chunk_fallback
      for (col in extra_cols) {
        val <- if (col %in% sentinel_cols) LLM_SENTINEL_VAL else fallback_vals[[col]]
        error_fallback[[col]] <- rep(val, length(chunk_paths))
      }
      all_parsed[[i]] <- error_fallback
    }
  }

  # Combine all chunks back into a single data.frame with the same columns.
  do.call(rbind, all_parsed)
}

# ── Codebook parsing helpers ──────────────────────────────────────────────────

# Normalise a variable name for case-insensitive, whitespace-tolerant matching.
# Applies tolower, trims whitespace, collapses interior spaces, strips
# leading/trailing underscores and dots.
normalize_varname <- function(x) {
  x <- tolower(x)
  x <- trimws(x)
  x <- gsub("[_]+", " ", x)   # treat underscores as word separators (e.g. SSS_total → sss total)
  x <- gsub("\\s+", " ", x)  # collapse any resulting multiple spaces
  x <- gsub("^[\\.]+|[\\.]+$", "", x)  # strip leading/trailing dots
  x <- trimws(x)
  x
}

# Reduce each word in a label to its root using the Porter stemming algorithm
# (SnowballC::wordStem). Falls back to a crude trailing-"s" stripper when
# SnowballC is unavailable, so the pipeline still runs in minimal environments
# (Principle I: Crash Resilience). Operates on one already-lowercased,
# punctuation-stripped string and returns the space-joined stemmed words.
.stem_words <- local({
  have_snowball <- NULL  # cached availability check
  function(s) {
    if (is.null(have_snowball))
      have_snowball <<- requireNamespace("SnowballC", quietly = TRUE)
    words <- strsplit(s, " ", fixed = TRUE)[[1]]
    words <- words[nzchar(words)]
    if (length(words) == 0) return("")
    if (isTRUE(have_snowball)) {
      stemmed <- tryCatch(SnowballC::wordStem(words, language = "porter"),
                          error = function(e) NULL)
      if (!is.null(stemmed)) return(paste(stemmed, collapse = " "))
    }
    # Fallback: strip a single trailing "s" from words of >= 8 chars.
    paste(sub("^([a-z]{7,})s$", "\\1", words, perl = TRUE), collapse = " ")
  }
})

# Normalise a label string for semantic-equivalence comparison.
# Strips possessives and punctuation, applies Porter stemming, and collapses
# whitespace so that minor wording differences (e.g. "Participants' responses"
# vs "Participant response") normalise to the same string.
normalize_label <- function(x) {
  x <- tolower(x)
  x <- gsub("'s|'s|\u2019s|\u2018s", "", x, perl = TRUE)  # strip possessives (straight + curly)
  x <- gsub("[^a-z0-9 ]", " ", x)                          # non-alphanumeric → space
  x <- gsub("\\s+", " ", trimws(x))                        # collapse whitespace
  vapply(x, .stem_words, character(1), USE.NAMES = FALSE)  # Porter stem each word
}

# Scan a data.frame's column headers for a "variable name" column and a
# "label/description" column.  Returns list(var_col, lab_col) or NULL.
.find_codebook_cols <- function(col_names) {
  var_col <- grep(
    paste0("(?i)^(var(iable)?|name|column|field|variable[_ ]?name|varname|item)$"),
    col_names, perl = TRUE, value = TRUE
  )[1]
  lab_col <- grep(
    paste0("(?i)^(label|description|desc|definition|meaning|explanation|text|",
           "label[_ ]?text|question|question[_ ]?text|variable[_ ]?description|",
           "variable[_ ]?label|var[_ ]?label)$"),
    col_names, perl = TRUE, value = TRUE
  )[1]
  if (is.na(var_col) || is.na(lab_col)) return(NULL)
  list(var_col = var_col, lab_col = lab_col)
}

# Extract variable-label pairs from a structured data.frame (CSV/Excel rows).
# Returns NULL when no matching header columns are found.
.extract_structured_codebook <- function(df, src) {
  if (is.null(df) || nrow(df) == 0 || ncol(df) < 2) return(NULL)
  cols <- .find_codebook_cols(names(df))
  if (is.null(cols)) return(NULL)
  rows <- df[nzchar(trimws(as.character(df[[cols$var_col]]))), , drop = FALSE]
  if (nrow(rows) == 0) return(NULL)
  data.frame(
    codebook_variable = as.character(rows[[cols$var_col]]),
    label             = as.character(rows[[cols$lab_col]]),
    codebook_source   = src,
    group             = NA_character_,
    stringsAsFactors  = FALSE
  )
}

# Extract embedded variable labels from a haven-read data.frame (SPSS/Stata/SAS).
# df   — data.frame read via haven::read_sav/read_dta/read_sas (n_max=0 is fine)
# src  — basename of the source file, written to codebook_source in the result
# Returns a data.frame with columns: codebook_variable, label, codebook_source, group
# or NULL if no labelled columns found. Caller adds parse_method = "haven".
.extract_haven_labels <- function(df, src) {
  labels <- vapply(names(df), function(col) {
    lbl <- attr(df[[col]], "label")
    if (is.null(lbl)) NA_character_ else trimws(as.character(lbl[1]))
  }, character(1))
  has_label <- !is.na(labels) & nzchar(labels)
  if (!any(has_label)) return(NULL)
  data.frame(
    codebook_variable = names(df)[has_label],
    label             = labels[has_label],
    codebook_source   = src,
    group             = NA_character_,
    stringsAsFactors  = FALSE
  )
}

# Map free-text experiment context strings to canonical group codes.
# e.g. "Experiment 1" -> "ex1", "Study 2a" -> "ex2a", "Pilot 1" -> "pilot1"
.infer_group <- function(context_str) {
  vapply(context_str, function(s) {
    if (is.null(s) || is.na(s) || !nzchar(trimws(as.character(s))))
      return(NA_character_)
    s <- trimws(as.character(s))
    # Pilot takes priority — never reclassify a pilot as "ex"
    m <- regmatches(s, regexpr("(?i)pilot\\s*(\\d+[a-z]?)", s, perl = TRUE))
    if (length(m) > 0 && nzchar(m)) {
      num <- sub("(?i)pilot\\s*", "", m, perl = TRUE)
      return(paste0("pilot", tolower(num)))
    }
    m <- regmatches(s, regexpr("(?i)(experiment|study)\\s*(\\d+[a-z]?)", s, perl = TRUE))
    if (length(m) > 0 && nzchar(m)) {
      num <- sub("(?i)(experiment|study)\\s*", "", m, perl = TRUE)
      return(paste0("ex", tolower(num)))
    }
    NA_character_
  }, character(1), USE.NAMES = FALSE)
}

# Strip RTF control codes from a character string, returning plain text.
# Used internally by .extract_rich_text() for .rtf files.
.strip_rtf <- function(text) {
  text <- gsub("\\\\[a-z]+\\-?[0-9]*\\s?", " ", text)  # control words
  text <- gsub("\\\\[^a-z\n]",             " ", text)  # control symbols
  text <- gsub("[{}]",                      "",  text)  # braces
  text <- gsub("\\s+",                      " ", text)  # collapse whitespace
  trimws(text)
}

# Extract plain text from a rich-text or binary codebook file.
# Returns a single character string (possibly empty) on any failure.
# Supports: docx (officer), pdf (pdftools), rtf (regex strip),
#           doc (textutil on macOS), odt (unzip + XML strip).
# officer >= 0.7.0 and pdftools >= 3.0.0 must be installed (both are already present).
.extract_rich_text <- function(path, ext) {
  tryCatch({
    switch(ext,
      docx = {
        if (!requireNamespace("officer", quietly = TRUE)) return("")
        doc  <- officer::read_docx(path)
        summ <- officer::docx_summary(doc)
        txt  <- as.character(summ$text)
        paste(txt[nzchar(trimws(txt))], collapse = "\n")
      },
      pdf = {
        if (!requireNamespace("pdftools", quietly = TRUE)) return("")
        pages <- pdftools::pdf_text(path)
        paste(pages, collapse = "\n")
      },
      rtf = {
        lines <- readLines(path, warn = FALSE)
        .strip_rtf(paste(lines, collapse = "\n"))
      },
      doc = {
        # Legacy binary Word (OLE2) — readLines() produces binary garbage.
        # Use macOS textutil to convert to plain text; fall back to empty string.
        if (nzchar(Sys.which("textutil"))) {
          lines <- system2("textutil", c("-convert", "txt", "-stdout",
                                         shQuote(path)),
                           stdout = TRUE, stderr = FALSE)
          paste(lines, collapse = "\n")
        } else ""
      },
      odt = {
        # OpenDocument is a ZIP containing content.xml — readLines() returns
        # binary ZIP noise.  Unzip content.xml and strip XML tags instead.
        tmp <- tempfile()
        on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
        dir.create(tmp)
        result <- tryCatch({
          utils::unzip(path, files = "content.xml", exdir = tmp)
          xml_path <- file.path(tmp, "content.xml")
          if (!file.exists(xml_path)) return("")
          raw <- paste(readLines(xml_path, warn = FALSE), collapse = "\n")
          # Strip XML tags, decode common entities, collapse whitespace
          txt <- gsub("<[^>]+>", " ", raw)
          txt <- gsub("&amp;",  "&", txt, fixed = TRUE)
          txt <- gsub("&lt;",   "<", txt, fixed = TRUE)
          txt <- gsub("&gt;",   ">", txt, fixed = TRUE)
          txt <- gsub("&apos;", "'", txt, fixed = TRUE)
          txt <- gsub("&quot;", '"', txt, fixed = TRUE)
          txt <- gsub("\\s+",   " ", txt)
          trimws(txt)
        }, error = function(e) "")
        result
      },
      ""  # unknown extension
    )
  }, error = function(e) "")
}

# Read a codebook file and return a data.frame of variable definitions with
# columns: codebook_variable, label, codebook_source, group.
# Returns NULL (with warning) on failure, oversized file, or no definitions found.
# Relies on MAX_CODEBOOK_FILE_MB, MAX_CODEBOOK_LLM_CALLS, CODEBOOK_PARSE_PROMPT
# being defined in the calling script (same pattern as LLM_BATCH_SIZE in llm_batch).
parse_codebook <- function(path) {
  if (!file.exists(path)) {
    warning("Codebook file not found: ", basename(path))
    return(NULL)
  }
  file_mb <- file.info(path)$size / 1048576
  if (!is.na(file_mb) && file_mb > MAX_CODEBOOK_FILE_MB) {
    warning("Skipping codebook (", round(file_mb), " MB > ", MAX_CODEBOOK_FILE_MB,
            " MB limit): ", basename(path))
    return(NULL)
  }
  ext <- tolower(tools::file_ext(path))
  src <- basename(path)

  # ── Structured extraction (rule-based) ──────────────────────────────────────
  result <- tryCatch({
    switch(ext,
      csv = , tsv = , dat = local({
        sep <- if (ext == "tsv") "\t" else sniff_delimiter(path)
        # Read without treating any row as a header so we can scan for it.
        raw <- tryCatch(
          read.delim(path, sep = sep, header = FALSE, check.names = FALSE,
                     stringsAsFactors = FALSE),
          error = function(e) NULL
        )
        if (is.null(raw) || nrow(raw) == 0) return(NULL)
        # Retry with latin1 if UTF-8 produces invalid bytes (mirrors read_data_head).
        has_invalid <- any(vapply(raw, function(col) {
          is.character(col) && any(is.na(iconv(col, from = "UTF-8", to = "UTF-8")))
        }, logical(1)))
        if (has_invalid) {
          raw <- tryCatch(
            read.delim(path, sep = sep, header = FALSE, check.names = FALSE,
                       stringsAsFactors = FALSE, fileEncoding = "latin1"),
            error = function(e) NULL
          )
          if (is.null(raw) || nrow(raw) == 0) return(NULL)
        }

        # ── Wide-format detection ─────────────────────────────────────────────
        # Some codebooks are stored in wide format: variables as columns, statistics
        # as rows (e.g. first column contains "mean", "sd", "label", ...).
        # Detect by checking whether ≥50% of first-column values are known statistic
        # names; if so, transpose so that variable names become the first column.
        WIDE_STAT_NAMES <- c("mean", "sd", "se", "min", "max", "median",
                             "n")
        col1_vals <- trimws(tolower(as.character(raw[, 1])))
        col1_vals <- col1_vals[nzchar(col1_vals)]
        if (length(col1_vals) > 0 &&
            mean(col1_vals %in% WIDE_STAT_NAMES) >= 0.5) {
          message("  wide-format codebook detected — transposing: ", src)
          var_names  <- as.character(raw[1, ])          # variable names (header row)
          stat_names <- as.character(raw[, 1])           # stat names (first column)
          traw <- as.data.frame(t(raw[, -1, drop = FALSE]),
                                stringsAsFactors = FALSE)
          names(traw) <- stat_names[-1]
          traw <- cbind(data.frame(variable = var_names[-1],
                                   stringsAsFactors = FALSE),
                        traw)
          raw <- traw
          rownames(raw) <- NULL
        }

        # Scan rows 1..CODEBOOK_HEADER_LOOKAHEAD for a row whose values match the
        # expected codebook column patterns.
        header_row <- NA_integer_
        lookahead  <- min(nrow(raw), CODEBOOK_HEADER_LOOKAHEAD)
        for (k in seq_len(lookahead)) {
          candidate <- trimws(as.character(raw[k, ]))
          if (!is.null(.find_codebook_cols(candidate))) {
            header_row <- k
            break
          }
        }
        if (is.na(header_row)) return(NULL)
        names(raw) <- trimws(as.character(raw[header_row, ]))
        df <- raw[seq(header_row + 1L, nrow(raw)), , drop = FALSE]
        rownames(df) <- NULL
        .extract_structured_codebook(df, src)
      }),
      xlsx = , xls = {
        df <- tryCatch(
          as.data.frame(readxl::read_excel(path), stringsAsFactors = FALSE),
          error = function(e) NULL
        )
        .extract_structured_codebook(df, src)
      },
      dta =, sav = {
        df <- if (ext == "sav") haven::read_sav(path) else haven::read_dta(path)
        res <- .extract_haven_labels(df, src)
        if (!is.null(res)) attr(res, ".is_haven") <- TRUE
        res
      },
      docx = , doc = , pdf = , rtf = , odt = {
        text <- .extract_rich_text(path, ext)
        if (nchar(trimws(text)) < 10) {
          warning("No extractable text from ", src, " (", ext, ")")
          return(NULL)
        }
        strsplit(text, "\n")[[1]]  # return lines vector; handled below
      },
      NULL  # unsupported extension — fall through to LLM via readLines
    )
  }, error = function(e) {
    warning("Structured codebook parse failed for ", src, ": ", conditionMessage(e))
    NULL
  })

  # Rich-text formats return a character vector of lines (not a data.frame).
  # Route them directly to the shared LLM chunk loop below.
  rich_lines <- if (is.character(result) && !is.data.frame(result)) result else NULL

  if (!is.null(result) && is.data.frame(result) && nrow(result) > 0) {
    result$group        <- .infer_group(result$group) # TODO what the fuck is the point of this? Why would we need to infer group here when we know it upstream?
    result$parse_method <- if (isTRUE(attr(result, ".is_haven"))) "haven" else "structured"
    return(result)
  }

  # ── LLM fallback for unstructured / unparseable files ────────────────────────
  if (is.null(result) || (is.data.frame(result) && nrow(result) == 0)) {
    message("  parse_codebook: structured extraction failed for ", src, " — falling back to LLM")
    codebook_fail_log <- "logs/codebook_parse_failures.log"
    dir.create(dirname(codebook_fail_log), recursive = TRUE, showWarnings = FALSE)
    cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "|", src, "\n",
        file = codebook_fail_log, append = TRUE)
  }
  lines <- if (!is.null(rich_lines)) {
    rich_lines
  } else {
    tryCatch(
      readLines(path, warn = FALSE),
      error = function(e) {
        warning("Cannot read ", src, " for LLM parsing: ", conditionMessage(e))
        character(0)
      }
    )
  }
  if (length(lines) == 0) return(NULL)

  .run_llm_chunk_loop(lines, src)
}

# Shared LLM chunking loop used by parse_codebook() for both plain-text and
# rich-text codebook sources.  Returns a data.frame or NULL.
.run_llm_chunk_loop <- function(lines, src) {
  chunks    <- split(lines, ceiling(seq_along(lines) / 100))
  max_calls <- min(length(chunks), MAX_CODEBOOK_LLM_CALLS)
  all_vars  <- vector("list", max_calls)
  cat(col_dim(sprintf("       parse %s via LLM (%d chunk(s))\n", src, max_calls)))

  for (i in seq_len(max_calls)) {
    chunk_text <- paste(chunks[[i]], collapse = "\n")
    llm_params <- list(temperature = LLM_TEMPERATURE, think = LLM_THINK_LEVEL)
    raw <- tryCatch(
      llm_ollama(system_prompt = CODEBOOK_PARSE_PROMPT,
          text = paste0("Extract all variable definitions from this codebook text:\n\n",
                        chunk_text),
          params = llm_params),
      error = function(e) {
        warning("LLM codebook parse failed (chunk ", i, " of ", src, "): ",
                conditionMessage(e))
        list(answer = "[]")
      }
    )
    all_vars[[i]] <- tryCatch({
      parsed <- jsonlite::fromJSON(extract_json(raw$answer))
      if (!is.data.frame(parsed) ||
          !all(c("variable_name", "label") %in% names(parsed))) return(NULL)
      parsed <- parsed[nzchar(trimws(as.character(parsed$variable_name))), , drop = FALSE]
      if (nrow(parsed) == 0) return(NULL)
      ec <- if ("experiment_context" %in% names(parsed))
        as.character(parsed$experiment_context) else NA_character_
      data.frame(
        codebook_variable = as.character(parsed$variable_name),
        label             = as.character(parsed$label),
        codebook_source   = src,
        group             = .infer_group(ec),
        stringsAsFactors  = FALSE
      )
    }, error = function(e) NULL) # TODO try agian if it fails! This just hopes it goes well the first time
  }

  result <- do.call(rbind, Filter(Negate(is.null), all_vars))
  if (is.null(result) || nrow(result) == 0) {
    message("  no variables extracted from: ", src)
    return(NULL)
  }
  result$parse_method <- "llm"
  result
}

# Match columns_df (from _columns.csv) against codebook_vars_df.
# Returns a _labels.csv-shaped data.frame covering every row of columns_df.
# Handles experiment-group scoping and conflict detection.
match_column_labels <- function(columns_df, codebook_vars_df,
                                column_match_prompt = NULL,
                                label_merge_prompt  = NULL) {
  # Support both "group" and "experiment_group" column names (historic schema variants)
  col_group <- if ("group" %in% names(columns_df)) columns_df$group else
               if ("experiment_group" %in% names(columns_df)) columns_df$experiment_group else
               rep(NA_character_, nrow(columns_df))

  make_empty <- function() {
    data.frame(
      paper_id          = columns_df$paper_id,
      source_file       = columns_df$source_file,
      column_name       = columns_df$column_name,
      group             = col_group,
      label             = NA_character_,
      codebook_variable = NA_character_,
      label_source      = NA_character_,
      label_status      = "unlabelled",
      label_method      = NA_character_,
      stringsAsFactors  = FALSE
    )
  }

  if (is.null(codebook_vars_df) || nrow(codebook_vars_df) == 0) return(make_empty())
  if (is.null(columns_df)       || nrow(columns_df) == 0)       return(make_empty())

  norm_col <- normalize_varname(columns_df$column_name)

  # ── Range variable expansion ──────────────────────────────────────────────────
  # Codebooks sometimes describe item batteries with range notation, e.g. "V1–V10".
  # Expand such entries to individual rows before matching so each variable gets a
  # label.  Unicode en-dash (\u2013) and ASCII hyphen are both accepted.
  range_pat  <- "^([A-Za-z]*)\\s*(\\d+)\\s*[-\u2013]\\s*(\\d+)$"
  range_rows <- grep(range_pat, codebook_vars_df$codebook_variable, perl = TRUE)
  if (length(range_rows) > 0) {
    expanded <- Filter(Negate(is.null), lapply(range_rows, function(i) {
      parts <- regmatches(
        codebook_vars_df$codebook_variable[i],
        regexec(range_pat, codebook_vars_df$codebook_variable[i], perl = TRUE)
      )[[1]]
      prefix <- parts[2]
      start  <- as.integer(parts[3])
      end    <- as.integer(parts[4])
      if (is.na(start) || is.na(end) || start > end) return(NULL)
      row <- codebook_vars_df[i, , drop = FALSE]
      do.call(rbind, lapply(seq(start, end), function(n) {
        row$codebook_variable <- paste0(prefix, n)
        row
      }))
    }))
    if (length(expanded) > 0) {
      codebook_vars_df <- rbind(
        codebook_vars_df[-range_rows, , drop = FALSE],
        do.call(rbind, expanded)
      )
      message("  range expansion: ", length(range_rows), " range(s) → ",
              nrow(do.call(rbind, expanded)), " individual variable(s)")
    }
  }

  norm_var <- normalize_varname(codebook_vars_df$codebook_variable)

  n                <- nrow(columns_df)
  label_out        <- rep(NA_character_, n)
  cbk_var_out      <- rep(NA_character_, n)
  src_out          <- rep(NA_character_, n)
  status_out       <- rep("unlabelled",  n)
  label_method_out <- rep(NA_character_, n)

  for (i in seq_len(n)) {
    nc <- norm_col[i]
    cg <- col_group[i]

    name_idx <- which(norm_var == nc)
    if (length(name_idx) == 0) next

    matches  <- codebook_vars_df[name_idx, , drop = FALSE]
    scoped   <- matches[!is.na(matches$group), , drop = FALSE]
    unscoped <- matches[ is.na(matches$group), , drop = FALSE]

    same_group_scoped <- scoped[!is.na(scoped$group) & scoped$group == cg, , drop = FALSE]
    applicable        <- rbind(unscoped, same_group_scoped)
    other_scoped      <- scoped[!is.na(scoped$group) & scoped$group != cg, , drop = FALSE]

    if (nrow(applicable) == 0) {
      if (nrow(other_scoped) > 0) {
        # Name exists only in a different experiment's codebook
        status_out[i]  <- "ambiguous_experiment"
        label_out[i]   <- paste(unique(other_scoped$label),             collapse = " | ")
        cbk_var_out[i] <- paste(unique(other_scoped$codebook_variable), collapse = " | ")
        src_out[i]     <- paste(unique(other_scoped$codebook_source),   collapse = " | ")
      }
      next
    }

    distinct_labels <- unique(applicable$label)
    if (length(distinct_labels) > 1) {
      # Rule-based equivalence check: normalise labels and re-check uniqueness
      norm_labels <- normalize_label(distinct_labels)
      if (length(unique(norm_labels)) == 1) {
        # All labels normalise to the same string — pick the longest original label
        canonical <- distinct_labels[which.max(nchar(distinct_labels))]
        status_out[i]        <- "labelled"
        label_out[i]         <- canonical
        cbk_var_out[i]       <- applicable$codebook_variable[1]
        src_out[i]           <- paste(unique(applicable$codebook_source), collapse = " | ")
        label_method_out[i]  <- "merged_rules"
      } else {
        # Labels differ semantically — flag for LLM resolution or leave as conflict
        status_out[i]  <- "conflicting_definition"
        label_out[i]   <- paste(distinct_labels,                           collapse = " | ")
        cbk_var_out[i] <- paste(unique(applicable$codebook_variable),     collapse = " | ")
        src_out[i]     <- paste(unique(applicable$codebook_source),       collapse = " | ")
      }
    } else {
      status_out[i]  <- "labelled"
      label_out[i]   <- distinct_labels[1]
      cbk_var_out[i] <- applicable$codebook_variable[1]
      src_out[i]     <- paste(unique(applicable$codebook_source), collapse = " | ")
    }
  }

  # Set label_method for rule-matched rows (merged_rules already set above)
  label_method_out[status_out == "labelled" & is.na(label_method_out)] <- "rules"

  # ── LLM merge tier: resolve remaining conflicting_definition rows ─────────────
  if (!is.null(label_merge_prompt)) {
    conflict_idx <- which(status_out == "conflicting_definition")
    if (length(conflict_idx) > 0) {
      # Build batch input: one entry per unique conflicting column name
      conflict_cols <- unique(columns_df$column_name[conflict_idx])
      batch_input <- lapply(conflict_cols, function(cn) {
        idx1     <- conflict_idx[columns_df$column_name[conflict_idx] == cn][1]
        raw_labs <- strsplit(label_out[idx1], " | ", fixed = TRUE)[[1]]
        list(column = cn, labels = raw_labs)
      })
      prompt_body <- paste0("Variables to check:\n",
                            jsonlite::toJSON(batch_input, auto_unbox = TRUE))
      llm_params <- list(temperature = LLM_TEMPERATURE, think = LLM_THINK_LEVEL)
      merge_resp <- tryCatch(
        llm_ollama(system_prompt = label_merge_prompt, text = prompt_body, params = llm_params),
        error = function(e) {
          warning("LLM label-merge call failed: ", conditionMessage(e))
          list(answer = "[]")
        }
      )
      merge_pairs <- tryCatch({
        parsed <- jsonlite::fromJSON(extract_json(merge_resp$answer),
                                     simplifyDataFrame = TRUE)
        if (is.data.frame(parsed) && nrow(parsed) > 0 &&
            all(c("column", "equivalent", "canonical") %in% names(parsed)))
          parsed else data.frame()
      }, error = function(e) data.frame())

      if (nrow(merge_pairs) > 0) {
        for (k in seq_len(nrow(merge_pairs))) {
          if (!isTRUE(merge_pairs$equivalent[k])) next
          canonical <- as.character(merge_pairs$canonical[k])
          if (is.na(canonical) || !nzchar(canonical)) next
          apply_idx <- conflict_idx[
            columns_df$column_name[conflict_idx] == merge_pairs$column[k]
          ]
          for (i in apply_idx) {
            label_out[i]        <- canonical
            status_out[i]       <- "labelled"
            label_method_out[i] <- "merged_llm"
          }
        }
      }
    }
  }

  # ── LLM secondary pass (T005–T009) ───────────────────────────────────────────
  if (!is.null(column_match_prompt)) {

    # T006: Collect candidate sets
    unlabelled_idx      <- which(status_out == "unlabelled")
    unlabelled_norm_cols <- unique(norm_col[unlabelled_idx])

    matched_norm_vars <- unique(normalize_varname(
      cbk_var_out[status_out == "labelled" & !is.na(cbk_var_out)]
    ))
    unmatched_vars_df <- codebook_vars_df[
      !normalize_varname(codebook_vars_df$codebook_variable) %in% matched_norm_vars,
      , drop = FALSE
    ]

    if (length(unlabelled_norm_cols) > 0 && nrow(unmatched_vars_df) > 0) {

      # T007: Build prompt body and call LLM
      col_list <- paste(seq_along(unlabelled_norm_cols),
                        columns_df$column_name[match(unlabelled_norm_cols, norm_col)],
                        sep = ". ", collapse = "\n")
      var_list <- paste(seq_len(nrow(unmatched_vars_df)),
                        unmatched_vars_df$codebook_variable,
                        sep = ". ", collapse = "\n")
      prompt_body <- paste0(
        "Data columns (unlabelled):\n", col_list,
        "\n\nCodebook variables (unmatched):\n", var_list
      )

      llm_params <- list(temperature = LLM_TEMPERATURE, think = LLM_THINK_LEVEL)
      llm_resp <- tryCatch(
        llm_ollama(system_prompt = column_match_prompt, text = prompt_body, params = llm_params),
        error = function(e) {
          warning("LLM column-matching call failed: ", conditionMessage(e))
          list(answer = "[]")
        }
      )

      # T008: Parse and validate response
      pairs_df <- tryCatch({
        json_txt <- extract_json(llm_resp$answer)
        parsed   <- jsonlite::fromJSON(json_txt, simplifyDataFrame = TRUE)
        if (is.data.frame(parsed) && nrow(parsed) > 0 &&
            all(c("column_name", "codebook_variable") %in% names(parsed))) {
          parsed
        } else {
          data.frame(column_name = character(0), codebook_variable = character(0),
                     stringsAsFactors = FALSE)
        }
      }, error = function(e) {
        data.frame(column_name = character(0), codebook_variable = character(0),
                   stringsAsFactors = FALSE)
      })

      norm_unmatched_vars <- normalize_varname(unmatched_vars_df$codebook_variable)

      # Validate: both sides must be in the submitted candidate sets
      valid_pairs <- pairs_df[
        normalize_varname(pairs_df$column_name)      %in% unlabelled_norm_cols &
        normalize_varname(pairs_df$codebook_variable) %in% norm_unmatched_vars,
        , drop = FALSE
      ]

      # T009: Apply valid pairs
      for (k in seq_len(nrow(valid_pairs))) {
        pair_norm_col <- normalize_varname(valid_pairs$column_name[k])
        pair_norm_var <- normalize_varname(valid_pairs$codebook_variable[k])

        row_idxs  <- which(norm_col == pair_norm_col & status_out == "unlabelled")
        var_row   <- which(norm_unmatched_vars == pair_norm_var)[1]

        if (length(row_idxs) == 0 || is.na(var_row)) next

        for (i in row_idxs) {
          label_out[i]        <- unmatched_vars_df$label[var_row]
          cbk_var_out[i]      <- unmatched_vars_df$codebook_variable[var_row]
          src_out[i]          <- unmatched_vars_df$codebook_source[var_row]
          status_out[i]       <- "llm"
          label_method_out[i] <- "llm"
        }
      }
    }
  }

  data.frame(
    paper_id          = columns_df$paper_id,
    source_file       = columns_df$source_file,
    column_name       = columns_df$column_name,
    group             = col_group,
    label             = label_out,
    codebook_variable = cbk_var_out,
    label_source      = src_out,
    label_status      = status_out,
    label_method      = label_method_out,
    stringsAsFactors  = FALSE
  )
}

# ── PsychDS helpers ───────────────────────────────────────────────────────────

# Apply ground-truth overrides to a structure data frame.
# Reads ground_truth/<source>/<paper_id>.csv if present; for each validated
# row whose rel_path matches, overwrites type/group/data_granularity with
# type_gt/group_gt/data_granularity_gt and sets ground_truth_validated = TRUE.
# Returns structure_df unchanged (with ground_truth_validated = FALSE for all
# rows) when no GT file exists.
# source and paper_id must be character strings.
apply_ground_truth <- function(structure_df, source, paper_id) {
  structure_df$ground_truth_validated <- FALSE
  # Pre-initialise GT provenance columns to full length. Without this, the first
  # indexed write `structure_df$gt_type_gt[idx] <- ...` on a non-existent column
  # builds a vector of length idx (not nrow), so when idx < nrow R errors with
  # "replacement has <idx> rows, data has <nrow>". Only bites when the first
  # GT-matched row isn't the last row, hence the intermittent failures.
  for (.gtcol in c("gt_type_gt", "gt_group_gt", "gt_data_granularity_gt",
                   "gt_validated_at", "gt_annotator"))
    if (!.gtcol %in% names(structure_df)) structure_df[[.gtcol]] <- NA_character_
  gt_path <- paste0(paper_path("ground_truth", source, paper_id), ".csv")
  if (!file.exists(gt_path)) return(structure_df)
  gt <- tryCatch(
    read.csv(gt_path, stringsAsFactors = FALSE,
             colClasses = c(paper_id = "character")),
    error = function(e) {
      warning("apply_ground_truth: failed to read ", gt_path, ": ",
              conditionMessage(e))
      NULL
    }
  )
  if (is.null(gt) || nrow(gt) == 0) return(structure_df)
  # Migrate legacy is_raw_gt → data_granularity_gt in old GT files
  if ("is_raw_gt" %in% names(gt) && !"data_granularity_gt" %in% names(gt)) {
    gt$data_granularity_gt <- ifelse(isTRUE(gt$is_raw_gt), "individual", NA_character_)
  }
  gt_mismatches <- character(0)
  for (i in seq_len(nrow(gt))) {
    idx <- which(structure_df$rel_path == gt$rel_path[i])
    if (length(idx) == 0) {
      gt_mismatches <- c(gt_mismatches, gt$rel_path[i])
      next
    }
    if (length(idx) > 1) {
      gt_mismatches <- c(gt_mismatches, paste0(gt$rel_path[i], " (", length(idx), " matches)"))
      next
    }
    if (!is.na(gt$type_gt[i])  && nzchar(gt$type_gt[i]))
      structure_df$type[idx]  <- gt$type_gt[i]
    if (!is.na(gt$group_gt[i]) && nzchar(gt$group_gt[i]))
      structure_df$group[idx] <- gt$group_gt[i]
    if ("data_granularity_gt" %in% names(gt) && !is.na(gt$data_granularity_gt[i]))
      structure_df$data_granularity[idx] <- gt$data_granularity_gt[i]
    structure_df$ground_truth_validated[idx] <- TRUE
    # Store raw GT fields for provenance output
    structure_df$gt_type_gt[idx]              <- gt$type_gt[i]
    structure_df$gt_group_gt[idx]             <- gt$group_gt[i]
    structure_df$gt_data_granularity_gt[idx]  <- if ("data_granularity_gt" %in% names(gt))
                                                   gt$data_granularity_gt[i] else NA_character_
    if ("validated_at" %in% names(gt))
      structure_df$gt_validated_at[idx] <- gt$validated_at[i]
    if ("annotator" %in% names(gt))
      structure_df$gt_annotator[idx]   <- gt$annotator[i]
  }
  if (length(gt_mismatches) > 0) {
    warning("apply_ground_truth: ", length(gt_mismatches), " GT rows did not match structure.csv")
    if (length(gt_mismatches) <= 5) {
      for (m in gt_mismatches) warning("  - ", m)
    } else {
      for (m in head(gt_mismatches, 3)) warning("  - ", m)
      warning("  ... and ", length(gt_mismatches) - 3, " more")
    }
  }
  structure_df
}

# Sanitise a string for use as a PsychDS keyword value.
# Steps: remove extension → remove non-alphanumeric → truncate.
# Returns "" for inputs that become empty after sanitisation.
# max_chars: maximum length of the returned string (default 60).
sanitise_keyword_value <- function(x, max_chars = 60L) {
  x <- tools::file_path_sans_ext(as.character(x))  # remove extension
  x <- gsub("[^a-zA-Z0-9]", "", x)                 # alphanumeric only
  if (nchar(x) > max_chars) x <- substr(x, 1L, max_chars)
  x
}

# Extract plain text from a documentation file for machine processing.
# Supported extensions: pdf (pdftools), docx (officer), rtf (regex strip).
# Returns a character string on success — may be empty for image-only PDFs.
# Returns NULL for unsupported extensions OR if extraction throws an error;
# this lets callers distinguish "empty text" (image PDF) from "error".
# Both pdftools >= 3.0.0 and officer >= 0.7.0 are already installed.
extract_plain_text <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (!ext %in% c("pdf", "docx", "rtf")) return(NULL)
  tryCatch(
    switch(ext,
      pdf = {
        if (!requireNamespace("pdftools", quietly = TRUE)) return(NULL)
        paste(pdftools::pdf_text(path), collapse = "\n")
      },
      docx = {
        if (!requireNamespace("officer", quietly = TRUE)) return(NULL)
        doc  <- officer::read_docx(path)
        summ <- officer::docx_summary(doc)
        txt  <- as.character(summ$text)
        paste(txt[nzchar(trimws(txt))], collapse = "\n")
      },
      rtf = {
        lines <- readLines(path, warn = FALSE)
        .strip_rtf(paste(lines, collapse = "\n"))
      }
    ),
    error = function(e) NULL
  )
}

# ── Aggregate extension grouping ──────────────────────────────────────────────

# group_aggregate_folder: group files within an aggregate folder by extension.
#
# Each distinct lowercase extension forms one group. Groups with >= AGGREGATE_THRESHOLD
# members produce a sentinel (sample_paths sent to Phase 2 LLM as filenames array in
# JSON descriptor; type/group propagated to all members with type_source = "aggregate_llm").
# Groups below the threshold are routed individually to Phase 1 LLM classification.
#
# Arguments:
#   rel_paths_in_folder  character vector of relative paths of all files in the
#                        aggregate folder (may span subdirectories for participant
#                        aggregates).
#   folder               the aggregate folder name (stored on each group for
#                        use as aggregate_folder in structure.csv)
#
# Returns a list of groups, each a list with:
#   $ext               lowercase extension shared by all members (character)
#   $folder            the aggregate folder name (character)
#   $members           all rel_paths in this group (character vector)
#   $sample_paths      up to 5 evenly-spaced paths from members; become filenames array in Phase 2 JSON descriptor (character vector)
#   $route_individually TRUE if length(members) < AGGREGATE_THRESHOLD

group_aggregate_folder <- function(rel_paths_in_folder, folder = "") {
  if (length(rel_paths_in_folder) == 0) return(list())

  exts        <- tolower(tools::file_ext(basename(rel_paths_in_folder)))
  unique_exts <- unique(exts)

  lapply(unique_exts, function(e) {
    members <- rel_paths_in_folder[exts == e]
    n       <- length(members)
    srt     <- sort(members)
    samp    <- if (n <= 5L) srt else srt[round(seq(1, n, length.out = 5L))]
    list(
      ext               = e,
      folder            = folder,
      members           = members,
      sample_paths      = samp,
      route_individually = n < AGGREGATE_THRESHOLD
    )
  })
}

# ── LLM Output Validation (Feature 036) ───────────────────────────────────────


# Return TRUE if type_value is in the valid file type set.
is_valid_type <- function(type_value, valid_types = VALID_FILE_TYPES) {
  !is.na(type_value) && type_value %in% valid_types
}

# Return TRUE if group_value matches the valid group pattern.
# Valid: ex<N>, pilot<N> (optional word char suffix(es)), or "shared".
# Invalid groups are set to "shared" during final CSV write — they do NOT trigger retries.
is_valid_group <- function(group_value) {
  valid_pattern <- "^(ex|pilot)\\d+\\w*$|^shared$"
  !is.na(group_value) && grepl(valid_pattern, group_value, ignore.case = FALSE)
}

# ── Data Granularity Detection (Feature 037) ──────────────────────────────────

# Participant ID patterns for filename and directory name detection.
# Used by US1 (filename heuristic) and US2 (aggregate folder series detection).
# Extensible — add new patterns empirically from error logs as needed.
PARTICIPANT_ID_PATTERNS <- c(
  "^\\d+$",                     # purely numeric: 001, 17230
  "^sub\\d+",                   # sub prefix: sub001, sub_001
  "^subj\\d+",                  # subj prefix: subj_3, subj3
  "^s\\d{2,}$",                 # s + ≥2 digits: s01, s001 (avoid single-letter collision)
  "^[Pp]\\d+",                  # P prefix: P01, p01, P_01
  "^[Ii][Dd]\\d+",              # ID prefix: ID042, id_042
  "^participant[\\s_-]?\\d+",   # full word: participant_01, participant01, "Participant 13"
  "^pp\\d+",                    # pp prefix: pp03, pp_03
  "^vp\\d+"                     # vp prefix (German): vp07, vp_07
)

# Test whether a string matches any participant ID pattern.
# Vectorised over x; returns TRUE if any pattern matches (case-insensitive).
# Used on bare filename stems (no extension) and directory names.
is_participant_id <- function(x) {
  if (is.na(x) || x == "") return(FALSE)
  any(vapply(PARTICIPANT_ID_PATTERNS,
             function(pattern) grepl(pattern, x, ignore.case = TRUE, perl = TRUE),
             logical(1L)))
}

# ── Filename pattern detection for granularity inference (US3) ──────────────────
# Extract repeating structure from a set of filenames (e.g., sub_1.txt, sub_2.txt → sub_\\d+\\.txt)
# Returns list: pattern (regex for display), examples, count
detect_filename_pattern <- function(filenames, verbose = TRUE) {
  if (verbose) cat(sprintf("  [detect] input: %d files\n", length(filenames)))

  if (length(filenames) < 2) {
    if (verbose) cat("  [detect] FAIL: fewer than 2 files\n")
    return(NULL)
  }

  basenames <- tools::file_path_sans_ext(basename(filenames))
  exts <- tools::file_ext(filenames)

  if (verbose) {
    cat(sprintf("  [detect] basenames sample: %s\n", paste(head(basenames, 3), collapse=", ")))
    cat(sprintf("  [detect] extensions: %s\n", paste(unique(exts), collapse=", ")))
  }

  # Find common pattern by replacing all digit sequences with marker
  patterns <- unique(gsub("[0-9]+", "NUM", basenames))

  if (verbose) cat(sprintf("  [detect] unique patterns: %d (%s)\n", length(patterns), paste(patterns, collapse=" | ")))

  if (length(patterns) == 1) {
    # All files follow same pattern with numeric variation
    # Pattern has "NUM" placeholders; convert to actual regex
    pattern_base <- gsub("NUM", "[0-9]+", patterns[1], fixed = TRUE)

    if (exts[1] != "") {
      regex_pattern <- paste0("^", pattern_base, "\\.", exts[1], "$")
    } else {
      regex_pattern <- paste0("^", pattern_base, "$")
    }

    if (verbose) cat(sprintf("  [detect] regex: %s\n", regex_pattern))

    # Test pattern against all filenames
    matching_idx <- grep(regex_pattern, filenames)

    if (verbose) cat(sprintf("  [detect] matches: %d / %d files\n", length(matching_idx), length(filenames)))

    if (length(matching_idx) >= 8) {
      if (verbose) cat(sprintf("  [detect] SUCCESS: %s\n", regex_pattern))
      return(list(
        pattern = regex_pattern,              # Actual regex for matching
        examples = filenames[matching_idx][1:min(5, length(matching_idx))],
        count = length(matching_idx)
      ))
    } else {
      if (verbose) cat("  [detect] FAIL: pattern matched <= 1 file\n")
    }
  } else {
    # Multiple patterns found — return all with example counts for each
    if (verbose) cat("  [detect] Multiple patterns found, returning all\n")

    # Convert each pattern template to regex and count matches
    multiple_patterns <- list()
    for (p in patterns) {
      pattern_base <- gsub("NUM", "[0-9]+", p, fixed = TRUE)
      if (exts[1] != "") {
        regex_pattern <- paste0("^", pattern_base, "\\.", exts[1], "$")
      } else {
        regex_pattern <- paste0("^", pattern_base, "$")
      }
      matching_idx <- grep(regex_pattern, filenames)
      if (length(matching_idx) >= 8) {  # Require min 8 matches per pattern
        multiple_patterns[[regex_pattern]] <- list(
          examples = filenames[matching_idx][1:min(3, length(matching_idx))],
          count = length(matching_idx)
        )
      }
    }

    if (length(multiple_patterns) > 0) {
      if (verbose) cat(sprintf("  [detect] SUCCESS: %d patterns\n", length(multiple_patterns)))
      return(list(
        multiple_patterns = multiple_patterns,  # List of pattern → {examples, count}
        examples = head(filenames, 5)            # Overall examples
      ))
    }
  }

  NULL
}

# ── Software folder bulk detection ────────────────────────────────────────────
# Two-tier name-based detection.
#
# Tier A (unambig_patterns): folder names unique to language tooling
# (`__pycache__`, `.git`, `renv`, `node_modules`, ...). Any directory whose
# basename matches is claimed entirely — no size threshold, no extension gate.
#
# Tier B (ambig_patterns): folder names that collide with data / stimulus
# folders (`lib`, `libs`, `build`, `dist`, `vendor`). A match must also
# contain at least `ambig_threshold` files AND fail the extension-majority
# gate (>50% recognised data/media extensions → assume data, skip).
#
# Returns a list with three fields:
#   $software_rel_paths  — rel_paths claimed as software
#   $software_folder_map — named character: rel_path → matched folder path
#   $clean_rel_paths     — rel_paths not claimed by any software folder

detect_software_folders <- function(rel_paths,
                                    unambig_patterns,
                                    ambig_patterns,
                                    ambig_threshold) {
  # Tabular data extensions. Tripping this gate means the folder looks like
  # data, not code.
  DATA_EXTS <- c("csv", "tsv", "txt", "dat", "xlsx", "xls", "sav", "dta",
                 "sas7bdat", "rds", "rda", "rdata")

  empty <- list(
    software_rel_paths  = character(0),
    software_folder_map = setNames(character(0), character(0)),
    clean_rel_paths     = rel_paths
  )

  if (length(rel_paths) == 0 ||
      (length(unambig_patterns) == 0 && length(ambig_patterns) == 0))
    return(empty)

  # Build all unique directory paths present in the file list (at every depth)
  all_dirs <- unique(unlist(lapply(rel_paths, function(p) {
    d <- dirname(p)
    if (d == "." || d == "") return(character(0))
    parts <- strsplit(d, "/", fixed = TRUE)[[1]]
    vapply(seq_along(parts), function(i) paste(parts[1:i], collapse = "/"),
           character(1))
  }), use.names = FALSE))

  if (length(all_dirs) == 0) return(empty)

  # Bucket candidate dirs by tier (case-insensitive basename match)
  base_lower      <- tolower(basename(all_dirs))
  unambig_lower   <- tolower(unambig_patterns)
  ambig_lower     <- tolower(ambig_patterns)
  unambig_dirs    <- all_dirs[base_lower %in% unambig_lower]
  ambig_dirs      <- all_dirs[base_lower %in% ambig_lower]

  # Outermost first within each tier — claiming a parent strips its children
  order_by_depth <- function(d) d[order(nchar(gsub("[^/]", "", d)))]
  unambig_dirs   <- order_by_depth(unambig_dirs)
  ambig_dirs     <- order_by_depth(ambig_dirs)

  unclaimed <- rel_paths
  sw_paths  <- character(0)
  sw_map    <- character(0)

  # Tier A — claim regardless of size/extensions
  for (d in unambig_dirs) {
    if (length(unclaimed) == 0) break
    prefix  <- paste0(d, "/")
    covered <- unclaimed[startsWith(unclaimed, prefix)]
    if (length(covered) == 0) next
    sw_paths        <- c(sw_paths, covered)
    sw_map[covered] <- d
    unclaimed       <- unclaimed[!startsWith(unclaimed, prefix)]
  }

  # Tier B — threshold + extension-majority gate
  for (d in ambig_dirs) {
    if (length(unclaimed) == 0) break
    prefix  <- paste0(d, "/")
    covered <- unclaimed[startsWith(unclaimed, prefix)]
    if (length(covered) < ambig_threshold) next
    exts <- tolower(tools::file_ext(covered))
    if (mean(exts %in% DATA_EXTS) > 0.5) next
    sw_paths        <- c(sw_paths, covered)
    sw_map[covered] <- d
    unclaimed       <- unclaimed[!startsWith(unclaimed, prefix)]
  }

  list(
    software_rel_paths  = sw_paths,
    software_folder_map = sw_map,
    clean_rel_paths     = unclaimed
  )
}
