# Data Model: Sentinel / Aggregate System Redesign

**Branch**: `035-sentinel-aggregate-redesign`  
**Date**: 2026-04-14

---

## Transient: Extension Group (internal, never written to disk)

Exists only in memory during `run_index()`. Produced by `group_aggregate_folder()` in `helper.R`.

| Field | Type | Description |
|---|---|---|
| `ext` | character | Lowercase file extension shared by all members of this group |
| `members` | character vector | All relative paths in the aggregate folder with this extension |
| `sample_paths` | character vector | Up to 5 representative paths from `members`, sent to LLM |
| `route_individually` | logical | TRUE if `length(members) < AGGREGATE_THRESHOLD` — paths go to normal batch, no sentinel produced |

**State transitions**:
1. Aggregate folder detected → `group_aggregate_folder()` called → one `ExtensionGroup` per distinct extension
2. Groups with `route_individually = TRUE` → member paths appended to normal Phase 1 LLM batch
3. Groups with `route_individually = FALSE` → `sample_paths` appended to Phase 1 LLM batch; LLM result propagated to all `members`
4. After LLM classification → all member paths written as individual file rows to `structure.csv`
5. Extension group object discarded

---

## Persistent: `structure.csv` row (one row per file)

No change to the fundamental schema. Two field changes versus current:

| Field | Change | Detail |
|---|---|---|
| `is_sentinel` | **Removed** | No sentinel rows written; column dropped entirely |
| `type_source` | **New value added** | `"aggregate_llm"` — file was classified as part of an extension group via sample-path LLM |

All other existing fields (`path`, `type`, `group`, `dominant_ext`, `file_count`, etc.) are unchanged or not applicable to the new model.

**Valid `type_source` values after this feature**:

| Value | Meaning |
|---|---|
| `extension_rule` | Classified by `classify_by_rules()` from extension alone |
| `rmd_pair_rule` | Classified as output because it pairs with an Rmd/qmd/ipynb |
| `llm` | Classified by LLM as an individual path |
| `aggregate_llm` | Classified as part of an extension group (sample paths sent to LLM; result propagated to all group members) |

**Removed value**: `sentinel_llm` — no longer produced.

---

## Function: `group_aggregate_folder()` (new, in `helper.R`)

```
group_aggregate_folder(rel_paths_in_folder)
```

**Input**: character vector of all relative paths belonging to one aggregate folder  
**Output**: list of ExtensionGroup objects (one per distinct extension found in the folder)

**Rules**:
- Paths with no extension (or empty extension) form their own group keyed as `""`
- Sample paths are drawn as an evenly-spaced sample across sorted member paths (not just the first 5)
- Groups with `length(members) < AGGREGATE_THRESHOLD` have `route_individually = TRUE`

**Replaces**: `detect_series()` — entirely removed

---

## Function: `expand_sentinel_rows()` (deleted, from `3_psychds_convert.R`)

No longer needed. `structure.csv` is file-level; psychDS reads it directly.

---

## `docs/output-schemas.md` changes required

- Remove `is_sentinel` row from the `structure.csv` schema table
- Add `aggregate_llm` to the `type_source` enum values
- Remove `sentinel_llm` from the `type_source` enum values
- Update `AGGREGATE_THRESHOLD` constant value from 50 → 20 in constitution constants table
