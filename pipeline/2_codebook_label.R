# 2_codebook_label.R
# ─────────────────────────────────────────────────────────────────────────────
# Reads codebook/README files for a paper and labels data columns accordingly.
#
# Exports: run_codebook_label(paper_id)
#
# Input:  paper_id (character)
#         outputs/<paper_id>/structure.csv  (from 0_index.R)
#         outputs/<paper_id>/columns.csv   (from 0_index.R)
# Output: outputs/<paper_id>/labels.csv
#         outputs/<paper_id>/codebook_coverage.csv
#
# Returns: list(
#   labels_df, coverage_df,
#   n_labelled, n_unlabelled,
#   n_codebook_vars, n_matched_vars,
#   label_status   # "ok" | "no_match" | "no_codebook"
# )
#
# Sourcing this file defines run_codebook_label() only — no side effects.
# ─────────────────────────────────────────────────────────────────────────────

library(metacheck)
source("pipeline/helper.R")
source("pipeline/prompts.R")

llm_use(TRUE)
llm_model("ollama/gpt-oss:20b-cloud")

# ── Constants ─────────────────────────────────────────────────────────────────

if (!exists("OUTPUT_DIR")) OUTPUT_DIR             <- "./outputs"
if (!exists("GROUND_TRUTH_DIR")) GROUND_TRUTH_DIR       <- "./ground_truth"
if (!exists("LLM_BATCH_SIZE")) LLM_BATCH_SIZE         <- 20L   # shared constant — needed by llm_batch() in helper.R
if (!exists("MAX_CODEBOOK_LLM_CALLS")) MAX_CODEBOOK_LLM_CALLS    <- 10L   # max LLM calls per codebook file for text parsing (ignored when FULL_RUN = TRUE)
if (!exists("MAX_CODEBOOK_FILES"))    MAX_CODEBOOK_FILES        <- 10L   # max codebook/readme files parsed per paper
if (!exists("FULL_RUN")) FULL_RUN <- FALSE
if (!exists("MAX_CODEBOOK_FILE_MB")) MAX_CODEBOOK_FILE_MB      <- 100   # codebook files larger than this (MB) are skipped
CODEBOOK_HEADER_LOOKAHEAD <- 5L    # max rows to scan for header in multi-level CSV codebooks
CODEBOOK_TYPES         <- c("codebook", "readme")

# ── Pipeline function ─────────────────────────────────────────────────────────

run_codebook_label <- function(paper_id, output_dir = NULL) {

  source  <- if (is_dataverse_id(paper_id)) "dataverse" else "osf"
  eff_dir <- if (!is.null(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    output_dir
  } else paper_output_dir(source, paper_id)

  # ── 1. Load inputs ──────────────────────────────────────────────────────────

  structure_path <- file.path(eff_dir, "structure.csv")
  columns_path   <- file.path(eff_dir, "columns.csv")

  if (!file.exists(structure_path))
    stop("Structure file not found: ", structure_path,
         "\nRun 0_index.R for this paper first.")
  if (!file.exists(columns_path))
    stop("Columns file not found: ", columns_path,
         "\nRun 0_index.R for this paper first.")

  structure_df <- read.csv(structure_path, stringsAsFactors = FALSE,
                            colClasses = c(paper_id = "character"))
  columns_df   <- read.csv(columns_path,   stringsAsFactors = FALSE,
                            colClasses = c(paper_id = "character"))

  # Support both "group" and "experiment_group" column names (historic schema variants)
  col_group <- if ("group" %in% names(columns_df)) columns_df$group else
               if ("experiment_group" %in% names(columns_df)) columns_df$experiment_group else
               rep(NA_character_, nrow(columns_df))

  # ── 2. Locate codebook/readme files ─────────────────────────────────────────

  codebook_rows <- structure_df[structure_df$type %in% CODEBOOK_TYPES, , drop = FALSE]
  if (is.finite(MAX_CODEBOOK_FILES) && nrow(codebook_rows) > MAX_CODEBOOK_FILES) {
    cat(col_dim(sprintf("    capping codebook files: %d → %d (MAX_CODEBOOK_FILES)\n",
                nrow(codebook_rows), MAX_CODEBOOK_FILES)))
    codebook_rows <- codebook_rows[seq_len(MAX_CODEBOOK_FILES), , drop = FALSE]
  }

  # ── 3. Parse codebooks or handle no_codebook case ────────────────────────────

  if (nrow(codebook_rows) == 0) {
    cat(col_yellow("  codebook  "), "no codebook files — all columns unlabelled\n")
    labels_df <- data.frame(
      paper_id          = columns_df$paper_id,
      source_file       = columns_df$source_file,
      column_name       = columns_df$column_name,
      group             = col_group,
      label             = NA_character_,
      codebook_variable = NA_character_,
      label_source      = NA_character_,
      label_status      = "no_codebook",
      label_method      = NA_character_,
      stringsAsFactors  = FALSE
    )
    codebook_vars_df <- data.frame(
      codebook_variable = character(0), label = character(0),
      codebook_source   = character(0), group = character(0),
      stringsAsFactors  = FALSE
    )

  } else {
    cat(col_yellow("  codebook  "), sprintf("parsing %d file(s)\n", nrow(codebook_rows)))
    parsed_list <- lapply(codebook_rows$path, function(p) {
      cat(col_dim(sprintf("    → %s\n", basename(p))))
      parse_codebook(p)
    })
    parsed_list <- Filter(Negate(is.null), parsed_list)

    if (length(parsed_list) == 0) {
      cat(col_yellow("  codebook  "), "no variables extracted — all columns unlabelled\n")
      codebook_vars_df <- data.frame(
        codebook_variable = character(0), label = character(0),
        codebook_source   = character(0), group = character(0),
        stringsAsFactors  = FALSE
      )
    } else {
      codebook_vars_df <- do.call(rbind, parsed_list)
      # Drop exact duplicates (same normalised variable name + label + group)
      dup_key <- paste(normalize_varname(codebook_vars_df$codebook_variable),
                       codebook_vars_df$label,
                       ifelse(is.na(codebook_vars_df$group), "", codebook_vars_df$group),
                       sep = "\x01")
      codebook_vars_df <- codebook_vars_df[!duplicated(dup_key), , drop = FALSE]
      cat(col_dim(sprintf("    extracted %d unique variable definition(s)\n", nrow(codebook_vars_df))))
    }

    # ── 4. Match columns against codebook ──────────────────────────────────────
    labels_df <- match_column_labels(columns_df, codebook_vars_df,
                                     column_match_prompt = COLUMN_MATCH_PROMPT,
                                     label_merge_prompt  = LABEL_MERGE_PROMPT)
  }

  # ── 5. Write _labels.csv ─────────────────────────────────────────────────────

  labels_out <- file.path(eff_dir, "labels.csv")
  write.csv(labels_df, labels_out, row.names = FALSE)
  n_labelled <- sum(labels_df$label_status %in% c("labelled", "llm"))

  # ── 6. Build codebook coverage table ─────────────────────────────────────────

  if (nrow(codebook_vars_df) > 0) {
    matched_norm <- unique(normalize_varname(
      labels_df$codebook_variable[labels_df$label_status %in% c("labelled", "llm") &
                                    !is.na(labels_df$codebook_variable)]
    ))
    coverage_df <- data.frame(
      paper_id          = paper_id,
      codebook_variable = codebook_vars_df$codebook_variable,
      label             = codebook_vars_df$label,
      codebook_source   = codebook_vars_df$codebook_source,
      group             = codebook_vars_df$group,
      parse_method      = codebook_vars_df$parse_method,
      match_status      = ifelse(
        normalize_varname(codebook_vars_df$codebook_variable) %in% matched_norm,
        "matched", "unmatched_in_data"
      ),
      stringsAsFactors  = FALSE
    )
  } else {
    coverage_df <- data.frame(
      paper_id          = character(0),
      codebook_variable = character(0),
      label             = character(0),
      codebook_source   = character(0),
      group             = character(0),
      parse_method      = character(0),
      match_status      = character(0),
      stringsAsFactors  = FALSE
    )
  }

  # ── 7. Write _codebook_coverage.csv ──────────────────────────────────────────

  coverage_out <- file.path(eff_dir, "codebook_coverage.csv")
  write.csv(coverage_df, coverage_out, row.names = FALSE)
  n_matched <- sum(coverage_df$match_status == "matched")

  # ── 8. Return LabellingResult ─────────────────────────────────────────────────

  n_unlabelled   <- sum(labels_df$label_status %in% c("unlabelled", "no_codebook"))
  overall_status <- if (nrow(codebook_vars_df) == 0) "no_codebook" else
                    if (n_labelled == 0) "no_match" else "ok"

  n_cb_total <- nrow(coverage_df)
  verdict_label <- switch(overall_status,
    ok          = "[OK]",
    no_match    = "[NO_MATCH]",
    no_codebook = "[NO_CODEBOOK]",
    "[UNKNOWN]"
  )
  verdict_col <- if (overall_status == "ok") col_green else col_dim
  coverage_part <- if (n_cb_total > 0)
    sprintf("  coverage=%d/%d (%d%%)",
            n_matched, n_cb_total, round(n_matched / n_cb_total * 100))
  else
    ""
  cat(col_cyan("── Codebook label: "), verdict_col(verdict_label),
      sprintf("  labelled=%d  unlabelled=%d%s\n",
              n_labelled, n_unlabelled, coverage_part))

  list(
    labels_df       = labels_df,
    coverage_df     = coverage_df,
    n_labelled      = n_labelled,
    n_unlabelled    = n_unlabelled,
    n_codebook_vars = nrow(coverage_df),
    n_matched_vars  = n_matched,
    label_status    = overall_status
  )
}
