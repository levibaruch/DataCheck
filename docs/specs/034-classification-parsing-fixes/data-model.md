# Data Model: Classification and Parsing Fixes (034+035+036)

**Branch**: `034-classification-parsing-fixes`  
**Date**: 2026-04-14

This feature makes no structural changes to output schemas. All changes are to classification logic and parsing behaviour. The only schema-affecting change is the new `data_format` value `"archive_unextracted"` for RAR files that fail extraction.

---

## Output Schema Changes

### `structure.csv` — `type_source` column

**Existing values**: `"llm"`, `"extension_rule"`, `"sentinel_llm"`

**New value added**: `"rmd_pair_rule"` — assigned to PDFs whose type is overridden to `"output"` by the PDF-from-Rmd post-classification pass.

**Docs update required**: `docs/output-schemas.md` — add `rmd_pair_rule` to the `type_source` enum table.

### `structure.csv` — `data_format` column

No changes. RAR files that fail extraction are silently dropped; no new `data_format` values are introduced.

---

## Affected Code Entities (not schema, but key logical entities)

### `AGGREGATE_EXT_OVERRIDE` (`0_index.R:32`)
Extension → type lookup table. New entries: `inp = "code"`, `ebs = "code"`, `es = "code"`.

### `ARCHIVE_EXTS` (`0_index.R:27`)
Known archive extensions. New entry: `"rar"`.

### `RAW_EXTENSIONS` (`helper.R:229`)
Extensions for which `classify_data_format()` returns `"raw"`. New entry: `"pdf"`.

### `extract_column_info()` (`0_index.R:799`)
Column extraction closure. New behaviour:
- Qualtrics ImportId detection and row-stripping (before `auto_named` check)
- V\d+ pattern detection for headerless CSVs (after existing `...N` header recovery)

### `unpack_archive()` (`helper.R:142`)
Archive unpacking function. New behaviour:
- `rar` branch using `system2("unrar", ...)` — returns `NULL` on failure; file is silently dropped, no stub rows or new enum values

### `parse_codebook()` (`helper.R:748`) — CSV branch
Codebook parsing function, CSV path. New behaviour:
- Wide-format detection (first column ≥ 50% statistic names) → transpose `raw` before header scan

### `match_column_labels()` (`helper.R:911`)
Column-to-codebook label matching. New behaviour:
- Range expansion of `codebook_vars_df` rows matching `^[A-Za-z]*\d+\s*[-–]\s*\d+$` before matching loop

---

## No New Files

This feature modifies only:
- `pipeline/0_index.R`
- `pipeline/helper.R`
- `docs/output-schemas.md` (schema enum additions)
