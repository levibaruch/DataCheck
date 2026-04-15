# Implementation Plan: Classification and Parsing Fixes (034+035+036)

**Branch**: `034-classification-parsing-fixes` | **Date**: 2026-04-14 | **Spec**: [spec.md](spec.md)

## Summary

Eight targeted fixes across `pipeline/0_index.R` and `pipeline/helper.R`: three extension classification additions, one archive extraction upgrade, one data_format guard, one post-classification fallback, two header normalisation patches, one codebook wide-format transposer, and one range variable expander. No new packages, no new output files, no schema columns added (only two new enum values: `archive_unextracted` and `rmd_pair_rule`).

---

## Technical Context

**Language/Version**: R (base R + already-installed packages: `readxl`, `haven`, `metacheck`)  
**Primary Dependencies**: `readxl` (xlsm), `system2` (unrar via shell), `haven` (codebook parsing) — all present  
**Storage**: CSV files on local filesystem; `structure.csv`, `columns.csv`, `labels.csv`, `codebook_coverage.csv`  
**Testing**: `runners/run_tests.R` → `runners/report_tests.R`; manual test papers from `tests/test_papers.csv`  
**Target Platform**: macOS/Linux (darwin 25.3.0)  
**Project Type**: CLI/library pipeline  
**Performance Goals**: No change to existing timing; RAR extraction adds one `system2` call per RAR file  
**Constraints**: No new packages (constitution Principle IV); `paper_path()` for all path construction  
**Scale/Scope**: 9 discrete code changes across 2 files + 1 docs update

---

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Crash Resilience | ✅ Pass | No new in-memory accumulation; failed RAR falls back gracefully |
| II. Paper ID Preservation | ✅ Pass | No changes to ID handling |
| III. Resource Limits | ✅ Pass | No new LLM calls; failed RAR extraction is silently dropped, no new enum values |
| IV. Centralised Helpers | ✅ Pass | All new logic in `helper.R` or `0_index.R`; no cross-script duplication |
| V. Structured Error Classification | ✅ Pass | No new error codes; `archive_unextracted` is a `data_format` value, not an error code |
| VI. Source-Aware Storage | ✅ Pass | No new storage layers; `paper_path()` not touched |

**Docs update required**: `docs/output-schemas.md` — add `rmd_pair_rule` to `type_source` enum.

---

## Project Structure

### Documentation (this feature)

```text
specs/034-classification-parsing-fixes/
├── plan.md              ← this file
├── research.md          ← decisions and rationale
├── data-model.md        ← schema changes and affected entities
└── tasks.md             ← created by /speckit.tasks
```

### Source Code

```text
pipeline/
├── 0_index.R            ← Changes 1–4, 6–8 (lines 27, 32-45, 206, 219, 755+, 799+, 835+)
└── helper.R             ← Changes 5, 9–10 (lines 142, 229, 748+, 911+)

docs/
└── output-schemas.md    ← 2 enum table additions (data_format, type_source)
```

---

## Implementation Changes (ordered by file and line proximity)

### Change 1 — Add `.rar` extraction support (`0_index.R:27` + `helper.R:142`)

**Locations**: `0_index.R:27` and `helper.R:142`  
**What**:
1. Add `"rar"` to `ARCHIVE_EXTS` at `0_index.R:27`.
2. Add a `rar` branch to `unpack_archive()` at `helper.R:142` that calls `system2("unrar", c("x", "-y", path, dest), stdout = FALSE, stderr = FALSE)`; if the system call returns a non-zero exit code or `unrar` is not found, return `NULL`.

**Effect**: RAR files are now attempted for extraction exactly like ZIP files. If extraction succeeds, their contents are indexed as normal. If extraction fails (binary unavailable or corrupt archive), `unpack_archive()` returns `NULL` and the file is dropped from `files` after the archive loop — the same behaviour as any other failed archive. No stub rows, no new enum values.

---

### Change 2 — Add `.inp`, `.ebs`, `.es` to `AGGREGATE_EXT_OVERRIDE` (`0_index.R:32-45`)

**Location**: `0_index.R:32`, within the `AGGREGATE_EXT_OVERRIDE` definition  
**What**: Add `inp = "code", ebs = "code", es = "code"` to the existing override vector.  
**Effect**: Files with these extensions in aggregate folders are classified as `type = "code"` without an LLM call. Phase 1 individual files still route to the LLM.

---

### Change 3 — Add `.xlsm` to the Excel explosion step (`0_index.R:219`)

**Location**: `0_index.R:219`  
**What**: Change `c("xlsx", "xls")` to `c("xlsx", "xls", "xlsm")`.  
**Effect**: Macro-enabled Excel files are exploded into per-sheet CSVs and deleted, exactly as `.xlsx` files are. `readxl::excel_sheets()` and `readxl::read_excel()` already support `.xlsm` natively.

---

### Change 4 — PDF `data_format` guard (`helper.R:229`)

**Location**: `helper.R:229`, in `RAW_EXTENSIONS`  
**What**: Add `"pdf"` to the `RAW_EXTENSIONS` vector.  
**Effect**: `classify_data_format("pdf")` now returns `"raw"` instead of `"tabular"`. Downstream column extraction only runs on `data_format == "tabular"` files, so PDFs with `type = "data"` will no longer trigger a column extraction attempt.

---

### Change 5 — PDF-from-Rmd post-classification fallback (`0_index.R`, after line 757)

**Location**: `0_index.R`, immediately after `file_df$data_format` is assigned (after line 757)  
**What**: Add a vectorised pass:
```r
# PDF-from-Rmd fallback: override type to "output" for PDFs co-located
# with a same-stem .Rmd / .qmd / .tex source file.
pdf_idx  <- which(file_df$ext == "pdf")
src_exts <- c("rmd", "qmd", "tex")
if (length(pdf_idx) > 0) {
  src_keys <- paste0(file_df$rel_path, "\x01", file_df$ext)
  for (i in pdf_idx) {
    stem     <- tools::file_path_sans_ext(file_df$rel_path[i])
    has_src  <- any(paste0(stem, "\x01", src_exts) %in% src_keys)
    if (has_src) {
      file_df$type[i]        <- "output"
      file_df$type_source[i] <- "rmd_pair_rule"
      file_df$data_format[i] <- NA_character_
    }
  }
}
```
**Effect**: PDFs whose `rel_path` stem matches a `.Rmd`/`.qmd`/`.tex` file in the same directory get `type = "output"`. Matching is within-directory only.

---

### Change 6 — Qualtrics ImportId stripping (`0_index.R`, inside `extract_column_info()`, after line 829)

**Location**: `0_index.R`, inside `extract_column_info()`, after the `if (is.null(df) || ncol(df) == 0)` early-return (line 829), before the `auto_named` line (line 835)  
**What**:
```r
# Qualtrics ImportId detection: strip extra header rows from Qualtrics CSV exports.
if (nrow(df) >= 2) {
  import_row <- NA_integer_
  for (.qi in seq_len(min(3, nrow(df)))) {
    if (any(grepl("^\\{.*ImportId", as.character(df[.qi, ]), perl = TRUE))) {
      import_row <- .qi; break
    }
  }
  if (!is.na(import_row)) {
    keep_after <- seq(import_row + 1L, nrow(df))
    if (length(keep_after) == 0) {
      message("  skipping (only header rows): ", basename(path)); return(NULL)
    }
    df <- df[keep_after, , drop = FALSE]
    rownames(df) <- NULL
    message("  Qualtrics header rows stripped (ImportId row ", import_row, "): ",
            basename(path))
  }
}
```
**Effect**: Qualtrics CSV exports have their ImportId row (and preceding question-text row) stripped. Downstream column type detection sees only real data rows.

---

### Change 7 — V\d+ auto-header detection (`0_index.R`, inside `extract_column_info()`, after existing `...N` block)

**Location**: `0_index.R`, inside `extract_column_info()`, after the closing `}` of the `if (mean(auto_named) > 0.5)` block (~line 898)  
**What**:
```r
# V\d+ auto-header detection: base R names headerless CSVs V1, V2, V3, ...
v_named <- grepl("^V\\d+$", names(df))
if (mean(v_named) > 0.5) {
  sub_header_row <- NULL
  for (i in seq_len(min(MULTILEVEL_HEADER_LOOKAHEAD, nrow(df)))) {
    candidate <- as.character(df[i, ])
    has_real  <- any(!is.na(candidate) & nzchar(candidate) & candidate != "NA" &
                     !grepl("^V\\d+$", candidate) &
                     is.na(suppressWarnings(as.numeric(candidate))))
    if (has_real) { sub_header_row <- i; break }
  }
  if (!is.null(sub_header_row)) {
    new_names           <- as.character(df[sub_header_row, ])
    fallback            <- is.na(new_names) | !nzchar(new_names)
    new_names[fallback] <- names(df)[fallback]
    new_names           <- make.unique(new_names)
    df                  <- df[(sub_header_row + 1):nrow(df), , drop = FALSE]
    names(df)           <- new_names
    message("  V\\d+ header resolved (row ", sub_header_row + 1, " as header): ",
            basename(path))
  }
}
```
**Effect**: CSVs where base R named all columns `V1`/`V2`/`V3` get their real column names from the first sub-header row found within the lookahead window.

---

### Change 8 — Wide codebook transpose (`helper.R`, inside `parse_codebook()` CSV branch, around line 773)

**Location**: `helper.R`, inside `parse_codebook()`, CSV branch, after encoding fallback (~line 785), before header-scan loop (~line 789)  
**What**:
```r
# Wide-format detection: ≥50% of first-column values are known statistic names.
WIDE_STAT_NAMES <- c("mean", "sd", "se", "min", "max", "median",
                     "label", "type", "note", "n")
col1_vals <- trimws(tolower(as.character(raw[, 1])))
col1_vals  <- col1_vals[nzchar(col1_vals)]
if (length(col1_vals) > 0 && mean(col1_vals %in% WIDE_STAT_NAMES) >= 0.5) {
  message("  wide-format codebook detected — transposing: ", src)
  var_names  <- as.character(raw[1, ])
  stat_names <- as.character(raw[, 1])
  traw       <- as.data.frame(t(raw[, -1, drop = FALSE]), stringsAsFactors = FALSE)
  names(traw)   <- stat_names[-1]
  traw          <- cbind(data.frame(variable = var_names[-1], stringsAsFactors = FALSE),
                         traw)
  raw <- traw; rownames(raw) <- NULL
}
```
**Effect**: Wide-format codebooks are transposed into long format. The existing `.find_codebook_cols()` header scan then matches against the transposed column names normally.

---

### Change 9 — Range variable expansion in `match_column_labels()` (`helper.R:938`)

**Location**: `helper.R`, inside `match_column_labels()`, after `norm_var <- normalize_varname(...)` (line 938)  
**What**:
```r
# Range expansion: "V1–V10" → individual rows V1..V10 before matching.
range_pat <- "^([A-Za-z]*)\\s*(\\d+)\\s*[-\u2013]\\s*(\\d+)$"
range_rows <- grep(range_pat, codebook_vars_df$codebook_variable, perl = TRUE)
if (length(range_rows) > 0) {
  expanded <- Filter(Negate(is.null), lapply(range_rows, function(i) {
    m     <- regexpr(range_pat, codebook_vars_df$codebook_variable[i], perl = TRUE)
    parts <- regmatches(codebook_vars_df$codebook_variable[i],
                        regexec(range_pat, codebook_vars_df$codebook_variable[i],
                                perl = TRUE))[[1]]
    prefix <- parts[2]; start <- as.integer(parts[3]); end <- as.integer(parts[4])
    if (is.na(start) || is.na(end) || start > end) return(NULL)
    row <- codebook_vars_df[i, ]
    do.call(rbind, lapply(seq(start, end), function(n) {
      row$codebook_variable <- paste0(prefix, n); row
    }))
  }))
  if (length(expanded) > 0) {
    codebook_vars_df <- rbind(codebook_vars_df[-range_rows, , drop = FALSE],
                              do.call(rbind, expanded))
    norm_var <- normalize_varname(codebook_vars_df$codebook_variable)
  }
}
```
**Effect**: Range entries like `V1–V10` are expanded to 10 individual rows before matching. Each row inherits the original label, source, and group.

---

## Complexity Tracking

No constitution violations.
