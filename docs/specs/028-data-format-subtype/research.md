# Research: Feature 028 — Data Format Sub-classification

## Finding 1: Column extraction gate location

**Decision**: Gate at `pipeline/0_index.R` line 683 by adding `& data_format == "tabular"` to the existing filter. No other structural change needed.

**Rationale**: Line 683 is already the single entry point that selects files for the column extraction loop. Adding the condition there gates all downstream I/O (`read_data_head()`, size checks, column statistics) with one change.

**Alternatives considered**: Gating inside `extract_column_info()` at line 694 — rejected because the function is called from a `lapply` and the caller would still iterate over raw files; the filter at 683 avoids the iteration entirely.

---

## Finding 2: `data_format` assignment location

**Decision**: Assign `data_format` immediately after line 668, where `ext` is computed and added to `file_df`. The new column is derived from `ext` via `classify_data_format()`.

**Rationale**: `ext` is the only input needed, it is already lower-cased at line 668 (`tolower(tools::file_ext(...))`), and assigning at this point ensures the column is present for both the extraction gate (line 683) and the structure.csv write (line 1029).

**Implementation**: `file_df$data_format <- ifelse(file_df$type == "data", classify_data_format(file_df$ext), NA_character_)`

---

## Finding 3: `classify_data_format()` placement

**Decision**: New function in `pipeline/helper.R`. Takes a character vector of extensions, returns a character vector of `"tabular"` / `"raw"` / `NA`.

**Rationale**: Constitution Principle IV mandates that shared helpers live in `helper.R`. This function is called by `0_index.R`, the ground truth repair runner, and the audit runner — all three need the same lookup table.

**Extension lookup table**:
- `tabular`: csv, tsv, txt, dat, xlsx, xls, sav, dta, sas7bdat
- `raw`: edf, bdf, acq, mat, mp4, avi, mov, wav, mp3
- `.rds`/`.rda`/`.rdata`: not in either list — fall to `"tabular"` via conservative fallback (deferred feature)
- Any other extension: `"tabular"` fallback
- Called with `type != "data"`: returns `NA`

Note: `sas7bdat` must be included in `"tabular"` — it appears in the constitution's supported-formats list but was omitted in the spec's FR-002. Corrected here.

---

## Finding 4: structure.csv write — column list

**Decision**: Add `"data_format"` to the column vector at lines 1029-1031 of `0_index.R`.

**Current**: `c("paper_id", "path", "rel_path", "filename", "ext", "type", "type_source", "group", "aggregate_folder", "data_granularity", "is_sentinel", "prompt_nr")`

**New**: same + `"data_format"` appended as last column.

---

## Finding 5: Ground truth file schema

**Current columns**: `paper_id`, `rel_path`, `type_gt`, `group_gt`, `data_granularity_gt`, `validated_at`, `annotator`

**New column**: `data_format_gt` — derived from `tools::file_ext(rel_path)` via `classify_data_format()`. `NA` for non-data rows (where `type_gt != "data"`).

**103 files** in `ground_truth/`, all named `<paper_id>.csv`. Repair helper must use `colClasses = c(paper_id = "character")` (Constitution Principle II).

---

## Finding 6: `bulk_summary.csv` — new column

**Decision**: Add `n_tabular_files` (integer). Computed as `sum(file_df$type == "data" & file_df$data_format == "tabular" & !file_df$is_sentinel)` before the structure.csv write.

**Rationale**: Existing `n_data_files` counts all `type == "data"` files. The new column tells operators how many of those were actually column-extracted. The gap (`n_data_files - n_tabular_files`) is the count of raw-format data files, useful for diagnosing papers heavy in recordings.

---

## Finding 7: PsychDS routing

**File**: `pipeline/3_psychds_convert.R` line 663.

**Current**: `data_files <- files_df[!is.na(files_df$type) & files_df$type == "data", ]` — all data files enter the conversion loop.

**Decision**: Split into two sets inside the loop using `row$data_format`. If `data_format == "raw"` (or NA for backward-compat with old structure.csv lacking the column): copy to `data/raw/` and `next`. If `data_format == "tabular"` (or NA fallback): proceed with existing conversion logic.

**Backward compatibility**: `data_format` may be absent from pre-fix `structure.csv` files loaded by PsychDS. Guard with `!is.null(row$data_format) && !is.na(row$data_format) && row$data_format == "raw"`.

---

## Finding 8: Validation GUI badge

**File**: `tools/validation_gui/app.R`. Badge rendering at line ~1042.

**Decision**: Add a small secondary badge after the type badge for `data`-typed rows showing `data_format`. Use distinct muted styling (not a full type badge). Two CSS classes: `.tbadge-df-tabular` and `.tbadge-df-raw`.

**Proposed CSS**:
- `.tbadge-df-tabular`: light green-grey tint, label "tab"
- `.tbadge-df-raw`: light amber tint, label "raw"
- Dark-mode variants needed.

---

## Finding 9: `STRUCTURE_PROMPT` changes — Cluster 0 (mp4) and Cluster 1 (mat)

**Current hard-case rule for images/audio/video**: Routes to asset/output/supplemental based on folder and filename context. Participant-naming rule overrides to `data`.

**Problem**: The participant-naming rule fires correctly for `.mp4` eye-tracking clips → `data`, but downstream column extraction then fails. The prompt fix is not to change the outcome (`type = data` is still correct) but to clarify the rule is about semantic classification, not processability. This ensures the LLM isn't confused when `data_format = "raw"` is introduced in the schema docs.

**Change**: Add `.mat` to the hard-case section with the same heuristic as `.rds`/`.rdata`:
- Participant/subject-named `.mat` files → `data`
- Filename contains result, output, model, fit, figure, plot → `output`
- Folder context (data/ vs results/) as tiebreaker
- Truly ambiguous → `data`

No change needed for `.mp4` classification itself (it's already correct). The fix prevents the LLM from second-guessing correct `data` classifications for media.
