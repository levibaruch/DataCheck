# Research: Classification and Parsing Fixes (034+035+036)

**Branch**: `034-classification-parsing-fixes`  
**Date**: 2026-04-14

---

## Decision 1: Where `.inp` / `.ebs` / `.es` overrides apply

**Decision**: Add `inp = "code"`, `ebs = "code"`, `es = "code"` to `AGGREGATE_EXT_OVERRIDE` in `0_index.R`.

**Rationale**: `AGGREGATE_EXT_OVERRIDE` is applied during aggregate sentinel expansion (step 7 of the pipeline). For non-aggregate Phase 1 individual files, type comes from the LLM only — no override table is consulted. The override still covers the high-volume case: `.inp`/`.ebs`/`.es` files typically appear inside aggregate study folders. Phase 1 individual files will continue to route to the LLM; the prompt refinements feature (033) handles improving those classifications.

**Alternatives considered**: Applying an override to Phase 1 individual files too would require duplicating override logic at `non_agg_df` construction (~line 738). Deferred to a future refactor if needed.

---

## Decision 2: `.xlsm` explosion

**Decision**: Add `"xlsm"` to the `excel_paths` filter at `0_index.R:219`. `readxl::excel_sheets()` and `readxl::read_excel()` both support `.xlsm` natively — no additional package needed.

**Rationale**: A 1-character string addition. The existing Excel explosion loop already handles multi-sheet layout, error handling, and file deletion; `.xlsm` is identical to `.xlsx` from readxl's perspective.

**Alternatives considered**: None — direct extension of existing code.

---

## Decision 3: `.rar` extraction strategy

**Decision**:
1. Add `"rar"` to `ARCHIVE_EXTS` in `0_index.R`.
2. Add a `rar` branch to `unpack_archive()` in `helper.R` that calls `system2("unrar", c("x", "-y", path, dest), stdout = FALSE, stderr = FALSE)`. If the call returns a non-zero exit code or `unrar` is not found, return `NULL`.
3. No stub rows. No new `data_format` or `type_source` values. If extraction fails, the RAR file is silently dropped from `files` after the archive loop — identical to how any other archive failure is handled.

**Rationale**: Adding new `data_format` / `type_source` enum values for a fallback case pollutes downstream analysis and reporting. The consistent behaviour is to drop unextractable archives silently; a missing RAR in `structure.csv` is a legible failure mode (the user can see the downloaded file on disk). The R `archive` package could also unpack RAR but is not currently installed and adding new packages is prohibited by the constitution.

**Alternatives considered**: Stub-row approach (adding `archive_unextracted` data_format). Rejected — introduces new enum values that complicate queries and reporting for a rare edge case.

---

## Decision 4: PDF `data_format` guard

**Decision**: Add `"pdf"` to `RAW_EXTENSIONS` in `helper.R` so that `classify_data_format("pdf")` returns `"raw"` instead of `"tabular"`.

**Rationale**: PDFs are never tabular data. `RAW_EXTENSIONS` already includes other binary/non-tabular formats. Adding `pdf` here is the minimal, idiomatic fix — `classify_data_format` has a single function body and adding a guard clause would duplicate intent. The PDF-from-Rmd override (Decision 5) handles the type assignment; this decision handles the format field for PDFs that legitimately have `type = "data"`.

**Alternatives considered**: An inline guard in `classify_data_format`. Rejected as more verbose with no benefit.

---

## Decision 5: PDF-from-Rmd post-classification fallback

**Decision**: After `file_df$data_format` is assigned at `0_index.R:755-757`, add a pass that:
1. Builds a set of PDF stems that have a same-directory `.Rmd`, `.qmd`, or `.tex` companion in `file_df`.
2. For matching PDFs, override `type = "output"` and `type_source = "rmd_pair_rule"`.

**Rationale**: This must run post-classification because `group` assignment (from LLM) must already be present in `file_df` before the override so the output row carries the correct group context. The fallback modifies only PDFs whose `type` was LLM-assigned; it is a correction, not a primary classification route.

**Alternatives considered**: Pre-classification pass before LLM. Rejected because the spec explicitly requires post-classification placement to preserve group context.

---

## Decision 6: Qualtrics ImportId stripping location

**Decision**: Add the ImportId detection immediately after `read_data_head()` returns `df` in `extract_column_info()` at `0_index.R:828`, before the `auto_named` check. The check reads: if any value in `df[1:min(3,nrow(df)), ]` matches `^\{.*ImportId`, drop rows 2 and 3 (and re-assign column names from the first row of the original read). This lives in `0_index.R` only.

**Rationale**: There is no existing Qualtrics-specific parsing code. The fix is placed within the existing column extraction function alongside the `...N` multi-level header recovery — this keeps all header-normalisation logic together. The pattern `^\{.*ImportId` is conservative enough to avoid false positives.

**Alternatives considered**: Placing the fix in `read_data_head()` in `helper.R`. Rejected because `read_data_head()` reads with `header = TRUE` by default; detecting the ImportId in the returned df (after header parsing) is simpler than modifying the read call itself. If row 2 of the raw file contains `ImportId`, it becomes the first data row in the returned df — which is where the check fires.

---

## Decision 7: V\d+ header detection

**Decision**: In `extract_column_info()`, extend the `auto_named` detection to cover `^V\d+$` patterns. Add a second detection pass immediately after the existing `...N` multi-level header recovery block (line ~898). The new branch checks `if (mean(grepl("^V\\d+$", names(df))) > 0.5)` and applies the same sub-header lookahead logic, but without the prefix-extraction step (V-names carry no group prefix).

**Rationale**: The V\d+ pattern is a direct analogue of `...N` for base-R CSV reads. The same `MULTILEVEL_HEADER_LOOKAHEAD` constant applies. The two branches are separate code blocks (not merged) because V\d+ has no group-label extraction step.

**Alternatives considered**: Merging into a single regex covering both `^\\.\\.\\.\\d+$` and `^V\\d+$`. Rejected because the prefix-extraction logic after the `...N` check is specific to `...N` naming; a merged block would require conditional logic inside the loop.

---

## Decision 8: Wide codebook transpose

**Decision**: In `parse_codebook()` in `helper.R`, within the CSV branch, insert a wide-format check before the header-row scan. After `raw` is read (header = FALSE), check whether ≥ 50% of `trimws(as.character(raw[, 1]))` values match known statistic names: `mean`, `sd`, `se`, `min`, `max`, `median`, `label`, `type`, `note`, `n`. If detected, transpose `raw` (column names become first column, stats become column headers) and proceed with the existing header scan.

**Rationale**: The statistic-name list deliberately excludes `"description"` (user feedback: normal codebooks have a `description` column alongside variable names — matching it would trigger false transpositions). The 50% threshold tolerates partial statistic lists.

**Alternatives considered**: Hard-requiring all first-column values to be statistic names. Rejected as too brittle for real codebooks with mixed rows.

---

## Decision 9: Range expansion in `match_column_labels()`

**Decision**: In `match_column_labels()` in `helper.R`, after `norm_var` is computed at line 938, expand any `codebook_vars_df` rows whose `codebook_variable` matches `^[A-Za-z]*\\d+\\s*[-–]\\s*\\d+$` by creating one new row per variable in the numeric range. The expanded rows inherit the parent row's `label`, `codebook_source`, and `group`. The original range row is removed and replaced with expanded rows before the matching loop begins.

**Rationale**: Range expansion must happen before `normalize_varname()` is called on the expanded entries (since `normalize_varname` lowercases and strips separators, which would destroy the range pattern). The expansion is pure string manipulation — no LLM call. The claim that this "has to do with LLMs" refers to the function living inside the LLM-backed label matching pipeline (`match_column_labels` calls LLM for fuzzy matching in later stages); the expansion itself is deterministic pre-processing.

**Alternatives considered**: Expanding ranges inside `parse_codebook()`. Rejected because `parse_codebook` returns raw strings from the codebook file; range expansion is about matching against data columns, which is `match_column_labels`'s responsibility.

---

## Constitution Compliance

- All changes are in `helper.R` and `0_index.R` (existing files). Constitution Principle IV (centralised helpers) is maintained.
- No new packages are introduced (RAR uses `system2()` to call an external binary).
- `paper_path()` is not affected — no new storage layers.
- No new `col_type` values, error codes, or output schema columns are added.
- `rmd_pair_rule` is a new `type_source` value for the PDF-from-Rmd fallback — requires updating `docs/output-schemas.md`.
