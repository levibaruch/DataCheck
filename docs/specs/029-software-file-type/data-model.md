# Data Model: Software File Type (029)

**Date**: 2026-04-02

## Schema Change

### `structure.csv` — `type` column

No new columns. One new enum value added to the existing `type` field.

| Field | Type | Previous enum | New enum |
|---|---|---|---|
| `type` | character | `"data"`, `"codebook"`, `"code"`, `"output"`, `"supplemental"`, `"readme"`, `"asset"`, `"other"` | + `"software"` |

All other fields are unchanged. `data_format` remains `NA` for `software` rows (it applies to `type = "data"` only).

---

## Entity: `software` File Type

**What it represents**: A file whose primary purpose is to run the experiment — stimulus delivery applications, task presentation programs, data collection tools, compiled binaries, and installers.

**Key attributes**:
- `type = "software"` in `structure.csv`
- `data_format = NA` (never column-extracted)
- `group` assigned by LLM or aggregate-sentinel logic (same rules as all other types)

**Boundaries**:
- `code`: analysis scripts, data cleaning scripts, modelling scripts, notebooks → always `code`
- `software`: experiment task runners, stimulus delivery apps, compiled programs, installers
- `other`: OS metadata, lock files, `.DS_Store` → still `other`

---

## State Transitions

No new lifecycle states. `software` files follow the same path as `code` and `other` files:
- Classified → written to `structure.csv` → excluded from column extraction

---

## Validation Rules

- `data_format` MUST be `NA` for all `type = "software"` rows.
- `software` MUST NOT appear as a `col_type` value (column types are a separate taxonomy).
- Ground truth files (`ground_truth/<paper_id>.csv`) accept `type_gt = "software"` as a valid correction; no migration of existing rows required.
