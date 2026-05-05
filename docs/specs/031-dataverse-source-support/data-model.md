# Data Model: Harvard Dataverse Source Support

**Feature**: 031-dataverse-source-support  
**Date**: 2026-04-08

---

## Schema Changes

### `bulk_summary.csv` — new `source` column

| Column | Type | Values | Notes |
|---|---|---|---|
| `source` | character | `"osf"`, `"dataverse"` | Added at end of row. OSF runner writes `"osf"`; Dataverse runner writes `"dataverse"`. Existing rows without this column read as `NA` — consumers must handle `NA` as `"osf"` for backward compatibility. |

**Full updated schema** (additions marked ★):

```
paper_id, run_at, success, error, elapsed_ms, download_ms, llm_ms, column_ms,
n_files, n_data_files, n_tabular_files, n_agg_dirs, n_individual, n_combined,
n_columns, n_src_files, source ★
```

---

### `run_index()` return list — new `source` field

The return list from `run_index()` gains one field:

| Field | Type | Value |
|---|---|---|
| `source` | character | `"osf"` or `"dataverse"` — derived from `is_dataverse_id(paper_id)` |

Failure return stubs (in `run_0_index_bulk.R` error handlers) must also include `source`.

---

### New error code

| Code | Meaning | When raised |
|---|---|---|
| `dataverse_dir_missing` | The `data/dataverse/<doi_slug>/` directory does not exist | `run_index()` called with a Dataverse ID and the deposit has not been placed in `data/dataverse/` |

Existing codes that still apply to Dataverse:

| Code | Applies? | Notes |
|---|---|---|
| `no_links` | No | Dataverse never goes through the OSF link-resolution step |
| `download_failed` | No | No network download for Dataverse |
| `empty_repo` | Yes | Deposit directory exists but contains zero files after scanning |
| `too_large` | Yes | LLM path cap still enforced |

---

## Directory Layout

```
data_check/
├── data/
│   ├── <osf_paper_id>/          # existing OSF raw data cache
│   │   └── ...
│   └── dataverse/               # NEW — Dataverse raw data cache
│       └── doi_10.7910_DVN_XXXXX/
│           └── (pre-downloaded deposit files, any depth)
├── outputs/
│   ├── <osf_paper_id>/          # existing OSF outputs (unchanged)
│   └── doi_10.7910_DVN_XXXXX/   # NEW — Dataverse outputs (same schema)
│       ├── structure.csv
│       ├── columns.csv
│       └── (labels.csv, codebook_coverage.csv if codebook step run)
└── psychds/
    ├── <osf_paper_id>/           # existing OSF psychDS output (unchanged)
    └── doi_10.7910_DVN_XXXXX/    # NEW — Dataverse psychDS output
        └── (standard psychDS layout)
```

---

## Constants (additions to `0_index.R`)

| Constant | Value | Purpose |
|---|---|---|
| `DATAVERSE_DATA_DIR` | `file.path(DATA_DIR, "dataverse")` | Root for all Dataverse deposit directories |

---

## Helper function (addition to `helper.R`)

```r
# Returns TRUE if paper_id is a Harvard Dataverse DOI slug.
# OSF paper IDs are always numeric strings and never start with "doi_".
is_dataverse_id <- function(paper_id) {
  startsWith(as.character(paper_id), "doi_")
}
```

---

## PsychDS provenance block changes

### Before (current)
```json
"metacheck:source_repository": {
  "platform": "osf",
  "download_path": "data/<paper_id>/"
}
```

### After (OSF paper — unchanged)
```json
"metacheck:source_repository": {
  "platform": "osf",
  "download_path": "data/<paper_id>/"
}
```

### After (Dataverse paper — new)
```json
"metacheck:source_repository": {
  "platform": "dataverse",
  "download_path": "data/dataverse/<doi_slug>/"
}
```

The `build_dataset_description()` function signature gains a `source` parameter (default `"osf"` for backward compatibility). Caller (`convert_psychds()`) passes `source` derived from `bulk_summary.csv`'s `source` column, or from `is_dataverse_id(paper_id)` as fallback.
