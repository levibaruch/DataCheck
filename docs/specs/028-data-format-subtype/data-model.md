# Data Model: Feature 028 — Data Format Sub-classification

## Schema Changes

### `outputs/<paper_id>/structure.csv` — new column

| Column | Type | Nullable | Position |
|--------|------|----------|----------|
| `data_format` | character | YES — `NA` for all `type != "data"` rows | Last column (appended) |

**Values**:

| Value | Meaning | Extensions |
|-------|---------|------------|
| `"tabular"` | Column-actionable; `read_data_head()` will be called | csv, tsv, txt, dat, xlsx, xls, sav, dta, sas7bdat, rds*, rda*, rdata*, + any unknown extension |
| `"raw"` | Not column-actionable; skipped by column extraction | edf, bdf, acq, mat, mp4, avi, mov, wav, mp3 |
| `NA` | Not a data file; `data_format` not applicable | All rows where `type != "data"` |

*`rds`/`rda`/`rdata` fall to `"tabular"` via conservative fallback. Dedicated handling deferred.

**Assignment**: Computed post-LLM by `classify_data_format(ext)` in `helper.R`. Never set by the LLM.

---

### `ground_truth/<paper_id>.csv` — new column

| Column | Type | Nullable | Position |
|--------|------|----------|----------|
| `data_format_gt` | character | YES — `NA` for all `type_gt != "data"` rows | Last column (appended by repair helper) |

**Values**: same as `data_format` above. Derived from `tools::file_ext(rel_path)` via `classify_data_format()`.

**Note**: This column is backfilled by `runners/repair_ground_truth_data_format.R` — it is never set during the live annotation session (the validation GUI does not write it). Future GUI versions may allow manual override.

---

### `results/bulk_summary.csv` — new column

| Column | Type | Nullable | Position |
|--------|------|----------|----------|
| `n_tabular_files` | integer | NO — `0` if no tabular data files | After `n_data_files` |

**Value**: count of rows in `structure.csv` where `type == "data"` and `data_format == "tabular"` and `is_sentinel == FALSE`.

**Relationship**: `n_tabular_files <= n_data_files` always. The gap is the count of raw-format data files in the paper.

---

## New Shared Constant: Extension Lookup

Defined in `pipeline/helper.R` as two character vectors and one function:

```
TABULAR_EXTENSIONS  <- c("csv", "tsv", "txt", "dat", "xlsx", "xls", "sav", "dta", "sas7bdat")
RAW_EXTENSIONS      <- c("edf", "bdf", "acq", "mat", "mp4", "avi", "mov", "wav", "mp3")

classify_data_format(ext_vec)
  Input:  character vector of lowercase file extensions (no leading dot)
  Output: character vector of same length — "tabular" | "raw"
          (never NA — NA is applied by caller only for non-data rows)
  Rules:  ext in TABULAR_EXTENSIONS → "tabular"
          ext in RAW_EXTENSIONS     → "raw"
          otherwise                 → "tabular"  (conservative fallback)
```

This function is the single source of truth for `data_format` assignment. All callers — `0_index.R`, `repair_ground_truth_data_format.R`, `audit_ground_truth_data_format.R` — call this function. No inline extension lists elsewhere.

---

## New Output Files (runners)

### `results/ground_truth_repair_summary.csv`

Written by `runners/repair_ground_truth_data_format.R`. One row per processed ground truth file.

| Column | Type | Description |
|--------|------|-------------|
| `paper_id` | character | Paper identifier |
| `n_data_rows` | integer | Rows where `type_gt == "data"` |
| `n_tabular` | integer | Data rows assigned `data_format_gt = "tabular"` |
| `n_raw` | integer | Data rows assigned `data_format_gt = "raw"` |
| `n_already_present` | integer | Rows where `data_format_gt` was already set (idempotency count) |

### `results/ground_truth_audit_report.csv`

Written by `runners/audit_ground_truth_data_format.R`. One row per flagged ground truth entry.

| Column | Type | Description |
|--------|------|-------------|
| `paper_id` | character | Paper identifier |
| `rel_path` | character | Relative path of the file |
| `ext` | character | File extension |
| `type_gt` | character | Validated type (always `"data"` for flagged rows) |
| `data_format_gt` | character | Assigned format (`"raw"` for all rows in this report) |

Sorted by `paper_id`, then `rel_path`.

---

## State Transitions

`data_format` has no lifecycle — it is a deterministic property computed once from the file extension. It does not change after assignment.

For ground truth files:
- Before repair: `data_format_gt` column absent
- After repair (first run): column present; values assigned from extension lookup
- After repair (subsequent runs): existing values preserved; only missing values filled (idempotent)
