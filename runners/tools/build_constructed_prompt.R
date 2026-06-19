# build_constructed_prompt.R
# ─────────────────────────────────────────────────────────────────────────────
# Emit the FULLY CONSTRUCTED LLM prompts (system + user message, with the paper's
# real content spliced in) exactly as the pipeline assembles them, for use as a
# worked example in the report appendix. Unlike export_prompts_appendix.R (which
# dumps the bare templates from prompts.R), this shows what the model actually
# receives at each stage.
#
# Stages rendered (in pipeline order):
#   1. File classification   0_index.R run_index()  -> llm_batch()   [Phase 1]
#   2. Column-type           0_index.R              -> llm_batch()   [char Batch 2]
#   3. Codebook parsing      helper.R .run_llm_chunk_loop() -> llm_ollama()
#   4. Column <-> codebook    helper.R match_column_labels()  -> llm_ollama()
#   (Label-merge is noted; it fires only on conflicting definitions.)
#
# Stages 1/2 go through llm_batch(), which appends a strict JSON-array contract to
# the user turn; stages 3/4 call llm_ollama() directly, so no suffix is appended.
# Stages that did not fire for the chosen paper render an explanatory note instead
# of a fabricated prompt.
#
# Default paper: GambleWalker bike-helmet study (OSF 0956797615620784). It exercises
# stages 1, 3 and 4; stage 2 is skipped because every column resolves via rules.
#
# Usage:  Rscript runners/tools/build_constructed_prompt.R [paper_id] [out.tex]
# Output: docs/appendix_constructed_prompt.tex
# ─────────────────────────────────────────────────────────────────────────────

if (basename(getwd()) == "tools") setwd("../..")   # run from repo root

# Constants helper.R functions expect at runtime (subset; we never call the LLM).
LLM_BATCH_SIZE        <- 30      # 0_index.R Phase-1 batch size
MAX_CODEBOOK_FILE_MB  <- 100
CODEBOOK_HEADER_LOOKAHEAD <- 5L
N_DATA_READ           <- 5

suppressWarnings(suppressMessages({
  source("pipeline/prompts.R")
  source("pipeline/helper.R")
}))

args     <- commandArgs(trailingOnly = TRUE)
PAPER_ID <- if (length(args) >= 1) args[[1]] else "0956797615620784"
OUT_PATH <- if (length(args) >= 2) args[[2]] else "docs/appendix_constructed_prompt.tex"

# ── Locate data + outputs directories ─────────────────────────────────────────
data_candidates <- c(file.path("data", "osf", PAPER_ID),
                     file.path("data", "dataverse", PAPER_ID),
                     file.path("data", PAPER_ID))
target_dir <- data_candidates[dir.exists(data_candidates)][1]
if (is.na(target_dir)) stop("No data directory for paper ", PAPER_ID)

out_candidates <- c(file.path("outputs", "example_outputs", PAPER_ID),
                    file.path("outputs", "osf", PAPER_ID),
                    file.path("outputs", "dataverse", PAPER_ID))
out_dir <- out_candidates[dir.exists(out_candidates)][1]   # may be NA

# ── Repository tree (mirrors run_index steps 3-4) ─────────────────────────────
drop_git  <- function(p) p[!grepl("(^|/)\\.git(/|$)", p, perl = TRUE)]
files     <- drop_git(list.files(target_dir, full.names = TRUE, recursive = TRUE))
if (length(files) == 0) stop("No files under ", target_dir)
norm_base <- normalizePath(target_dir, mustWork = FALSE)
rel_paths <- sort(sub(paste0("^", norm_base, "/?"), "",
                      normalizePath(files, mustWork = FALSE)))
abs_of    <- function(rp) file.path(norm_base, rp)

# File types come from the saved structure.csv (matched on rel_path), so stage
# selection follows the pipeline's own classification rather than re-running it.
structure_df <- if (!is.na(out_dir) && file.exists(file.path(out_dir, "structure.csv")))
  read.csv(file.path(out_dir, "structure.csv"), stringsAsFactors = FALSE,
           colClasses = c(paper_id = "character")) else NULL
type_of <- function(rp) if (is.null(structure_df)) NA_character_ else
  structure_df$type[match(rp, structure_df$rel_path)]
fmt_of  <- function(rp) if (is.null(structure_df)) NA_character_ else
  structure_df$data_format[match(rp, structure_df$rel_path)]

# ── llm_batch() user-turn assembly (numbered list + JSON contract) ────────────
batch_user_msg <- function(prefix, items) paste0(
  prefix, "\n\n",
  paste(seq_along(items), items, sep = ". ", collapse = "\n"),
  "\n\nReturn ONLY a JSON array with exactly ", length(items),
  " objects — one per input above. Echo every path character-for-character.",
  " No truncation. No notes. No text outside the array."
)

# ── LaTeX emission ────────────────────────────────────────────────────────────
sanitize <- function(x) {
  x <- gsub("—", "--", x); x <- gsub("–", "--", x); x <- gsub("→", "->", x)
  x <- gsub("─", "-",  x); x <- gsub("’", "'",  x); x <- gsub("‘", "'",  x)
  x <- gsub("“", "\"", x); x <- gsub("”", "\"", x); x <- gsub(" ", " ", x)
  x
}
lst <- function(body, label) paste0(
  "\\begin{lstlisting}[breaklines=true, breakatwhitespace=true,\n",
  "  basicstyle=\\small\\ttfamily,\n",
  "  caption={", label, "}, label={lst:", gsub("[^a-z0-9]+", "-", tolower(label)), "}]\n",
  sanitize(body), "\n\\end{lstlisting}\n"
)
texesc <- function(x) gsub("_", "\\\\_", x)
note   <- function(x) paste0("\\noindent\\textit{", x, "}\\\\\n")

sections <- character(0)
add <- function(...) sections <<- c(sections, ...)

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — File classification (run_index Phase 1, batch 1)
# ─────────────────────────────────────────────────────────────────────────────
add("\\subsection{Stage 1: File Classification}",
    note(sprintf(paste0("First (and here only) batch of the file-classification ",
                 "call. The system prompt is fixed; the user message embeds the ",
                 "repository tree of paper \\texttt{%s} as a numbered list. Sent ",
                 "via \\texttt{llm\\_batch()}, which appends the JSON-array contract."),
                 texesc(PAPER_ID))),
    lst(paste0(SINGLE_HEADER_MD, STRUCTURE_PROMPT_MD), "Stage 1 -- System prompt"),
    lst(batch_user_msg("Classify this repository tree:", head(rel_paths, LLM_BATCH_SIZE)),
        "Stage 1 -- User message"))

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — Column-type classification (0_index.R character Batch 2)
# Fires only for columns left ambiguous by rules AND non-numeric. Reconstructed
# by running the same deterministic rules over each tabular data file.
# ─────────────────────────────────────────────────────────────────────────────
add("\\subsection{Stage 2: Column-Type Classification}")
data_rps <- rel_paths[!is.na(type_of(rel_paths)) & type_of(rel_paths) == "data" &
                      !is.na(fmt_of(rel_paths))  & fmt_of(rel_paths)  == "tabular"]
descriptors <- character(0)
for (rp in data_rps) {
  df <- tryCatch(read_data_head(abs_of(rp), n_rows = Inf), error = function(e) NULL)
  if (is.null(df) || ncol(df) == 0) next
  for (i in seq_along(df)) {
    cls <- tryCatch(classify_col_type_rules(names(df)[i], df[[i]]), error = function(e) NULL)
    if (is.null(cls)) next
    if (is.na(cls$col_type) && !isTRUE(cls$is_numeric)) {   # char-ambiguous
      x <- df[[i]][!is.na(df[[i]])]
      uniq <- unique(x)[seq_len(min(20L, length(unique(x))))]
      descriptors <- c(descriptors,
                       paste0(names(df)[i], " — samples: ", paste(as.character(uniq), collapse = ", ")))
    }
  }
}
if (length(descriptors) > 0) {
  add(note(sprintf("%d character column(s) could not be typed by rules and were sent to the LLM.",
                   length(descriptors))),
      lst(CHAR_COLUMN_TYPE_PROMPT, "Stage 2 -- System prompt"),
      lst(batch_user_msg("Classify each column:", descriptors), "Stage 2 -- User message"))
} else {
  add(note(sprintf(paste0("Not triggered for paper \\texttt{%s}: every column in the ",
              "data file(s) was resolved by deterministic rules (numeric / id / binary), ",
              "so no character columns were sent to the LLM. This stage fires only when a ",
              "data file contains free-text or otherwise ambiguous non-numeric columns."),
              texesc(PAPER_ID))))
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 — Codebook parsing (.run_llm_chunk_loop, chunk 1). Called via
# llm_ollama() directly — no JSON-array contract appended.
# ─────────────────────────────────────────────────────────────────────────────
add("\\subsection{Stage 3: Codebook Parsing}")
cb_rps <- rel_paths[!is.na(type_of(rel_paths)) & type_of(rel_paths) %in% c("codebook", "readme")]
if (length(cb_rps) > 0) {
  rp  <- cb_rps[1]
  ext <- tolower(tools::file_ext(rp))
  text <- if (ext %in% c("docx","doc","pdf","rtf","odt")) .extract_rich_text(abs_of(rp), ext)
          else paste(readLines(abs_of(rp), warn = FALSE), collapse = "\n")
  lines      <- strsplit(text, "\n")[[1]]
  chunk_text <- paste(head(lines, 100), collapse = "\n")    # first 100-line chunk
  user_msg   <- paste0("Extract all variable definitions from this codebook text:\n\n", chunk_text)
  add(note(sprintf(paste0("Codebook \\texttt{%s} (first 100-line chunk). The rich-text ",
              "extractor strips RTF control words to plain text. Called via ",
              "\\texttt{llm\\_ollama()} directly, so no JSON-array contract is appended."),
              texesc(basename(rp)))),
      lst(CODEBOOK_PARSE_PROMPT, "Stage 3 -- System prompt"),
      lst(user_msg, "Stage 3 -- User message"))
} else {
  add(note("No codebook/readme file for this paper."))
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4 — Column <-> codebook matching (match_column_labels secondary pass).
# Reconstructs the unlabelled-columns / unmatched-variables sets that survive the
# rule-based matcher, using saved columns.csv + codebook_coverage.csv. (Group
# scoping and range-expansion are omitted; immaterial for single-group papers.)
# ─────────────────────────────────────────────────────────────────────────────
add("\\subsection{Stage 4: Column--Codebook Matching}")
cols_path <- if (!is.na(out_dir)) file.path(out_dir, "columns.csv") else NA
cov_path  <- if (!is.na(out_dir)) file.path(out_dir, "codebook_coverage.csv") else NA
if (!is.na(out_dir) && file.exists(cols_path) && file.exists(cov_path)) {
  cols_df <- read.csv(cols_path, stringsAsFactors = FALSE, colClasses = c(paper_id = "character"))
  cov_df  <- read.csv(cov_path,  stringsAsFactors = FALSE, colClasses = c(paper_id = "character"))
  norm_col <- normalize_varname(cols_df$column_name)
  norm_var <- normalize_varname(cov_df$codebook_variable)
  unlabelled <- cols_df$column_name[!norm_col %in% norm_var]
  unmatched  <- cov_df$codebook_variable[!norm_var %in% norm_col]
  if (length(unlabelled) > 0 && length(unmatched) > 0) {
    body <- paste0(
      "Data columns (unlabelled):\n",
      paste(seq_along(unlabelled), unlabelled, sep = ". ", collapse = "\n"),
      "\n\nCodebook variables (unmatched):\n",
      paste(seq_along(unmatched), unmatched, sep = ". ", collapse = "\n"))
    add(note(paste0("After rule-based name matching, the residual unlabelled columns and ",
                "unmatched codebook variables are sent to the LLM to resolve naming ",
                "mismatches (here the \\texttt{STAI} variables). Called via ",
                "\\texttt{llm\\_ollama()} directly.")),
        lst(COLUMN_MATCH_PROMPT, "Stage 4 -- System prompt"),
        lst(body, "Stage 4 -- User message"))
  } else {
    add(note("Not triggered: rule-based matching covered every column, leaving nothing for the LLM."))
  }
} else {
  add(note("No saved columns.csv / codebook\\_coverage.csv available to reconstruct this stage."))
}

# Label-merge footnote
add("\\subsection{Conditional Stage: Label Merge}",
    note(paste0("The label-merge call fires only when a column name maps to multiple, ",
         "semantically different codebook definitions. Paper \\texttt{", texesc(PAPER_ID),
         "} has no such conflicts, so this stage did not run. Its template is in the ",
         "prompt appendix.")))

# ── Assemble document ─────────────────────────────────────────────────────────
header <- c(
  "% Auto-generated by runners/tools/build_constructed_prompt.R",
  "% Do not edit by hand -- re-run the script to regenerate.",
  sprintf("%% Paper: %s   Files: %d", PAPER_ID, length(rel_paths)),
  "% Preamble requirement: \\usepackage{listings}",
  "",
  "\\section{Worked Example: Constructed Pipeline Prompts}",
  "",
  note(sprintf(paste0("The listings below reproduce the complete prompts the pipeline ",
       "sends to the language model when processing paper \\texttt{%s} (the GambleWalker ",
       "bicycle-helmet study), with the paper's own files and data spliced in. Each stage ",
       "shows the fixed system prompt and the constructed user message."),
       texesc(PAPER_ID))),
  "")

dir.create(dirname(OUT_PATH), showWarnings = FALSE, recursive = TRUE)
writeLines(c(header, sections), OUT_PATH)
cat(sprintf("Written: %s  (paper %s)\n", OUT_PATH, PAPER_ID))
