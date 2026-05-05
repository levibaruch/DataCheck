# Contract: `outputs/<paper_id>/structure.csv`

**Changed in feature 022**: Added `type_source` column; `group` value `"other"` replaced by `"shared"`.

## Column Schema

| Column | Type | Nullable | Values / Constraints |
|---|---|---|---|
| `paper_id` | character | NO | Leading zeros preserved |
| `path` | character | NO | Absolute local path |
| `rel_path` | character | NO | Path relative to paper download dir |
| `filename` | character | NO | Basename |
| `ext` | character | NO | Lowercase file extension |
| `type` | character | NO | One of: `data`, `codebook`, `code`, `supplemental`, `doc`, `readme`, `asset`, `other` |
| `group` | character | NO | One of: `ex<N>`, `pilot<N>`, `shared`, `na` — **no longer includes `other`** |
| `type_source` | character | NO | **NEW** — `"rule"` or `"llm"` |
| `is_raw` | logical | YES | `TRUE` if raw/unprocessed; `NA` for non-data files |
| `is_sentinel` | logical | NO | `TRUE` if row represents a collapsed folder |

## Invariants

1. `type` ∈ `{data, codebook, code, supplemental, doc, readme, asset, other}` — exactly one per row.
2. `group` ∈ `{ex<N>, pilot<N>, shared, na}` — exactly one per row, no legacy `other`.
3. `group = "na"` ↔ `type ∈ {readme, asset, other}` — if type is any other value, group must not be `na`.
4. `type_source` ∈ `{"rule", "llm"}` — never NA.
5. `paper_id` is character type (read with `colClasses = c(paper_id = "character")`).

## Breaking Change Note

The old group value `"other"` is no longer produced. Any code reading `structure.csv` that filters
on `group == "other"` will return 0 rows. Filter on `group == "shared"` instead.

No backward compatibility shim is provided — all papers are re-run after this feature merges.
