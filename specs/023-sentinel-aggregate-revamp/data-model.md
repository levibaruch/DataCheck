# Data Model: Sentinel/Aggregate System Revamp

**Feature**: 023-sentinel-aggregate-revamp
**Phase**: 1 — Design

---

## Entities

### 1. Sub-Sentinel

A compact descriptor for one series (or the whole folder if no series was detected) within an aggregate folder. Constructed in memory during pipeline execution; never written to disk as-is. Consumed by Phase 2 `llm_batch()`.

| Field | Type | Description |
|---|---|---|
| `folder` | character | Relative path of the aggregate folder (e.g. `"ASD_CTL/RA_IATData"`) |
| `prefix` | character | Common filename prefix of the series (e.g. `"FlowerInsectCong-"`), or `"mixed"` for single-sentinel fallback |
| `file_count` | integer | Number of files in this series |
| `dominant_ext` | character | Most common file extension in the series |
| `samples` | character[5] | Up to 5 real filenames from the series |
| `is_series` | logical | `TRUE` if a series was detected; `FALSE` for single-sentinel fallback |
| `type_resolved` | character \| NA | Pre-resolved type from extension override table, or `NA` if ambiguous |
| `descriptor_string` | character | Formatted string sent to LLM (see format below) |

**Descriptor string format**:
```
folder/[prefix: "FlowerInsectCong-", 47 files, .txt, samples: FlowerInsectCong-RA0001-20190401.txt, ...]
```
For single-sentinel fallback (no series):
```
folder/[mixed, 55 files, .html, samples: intro.html, consent.html, ...]
```

**State transitions**:
1. Aggregate folder detected → `detect_series()` produces N sub-sentinels per folder
2. Each sub-sentinel may get `type_resolved` set by `AGGREGATE_EXT_OVERRIDE` lookup before Phase 2
3. Phase 2 LLM assigns `type` (if not resolved) and `group`
4. Sub-sentinel is expanded into N individual file rows

---

### 2. Expanded File Row

A row in `structure.csv` for a real file originally collapsed under a sub-sentinel. Extends the existing `structure.csv` schema.

**New columns added**:

| Column | Type | Enum / Notes |
|---|---|---|
| `type_source` | character | `"llm"` \| `"extension_rule"` \| `"sentinel_llm"` |
| `aggregate_folder` | character \| NA | Relative path of aggregate folder; `NA` for non-aggregate files |
| `data_granularity` | character \| NA | `"individual"` \| `"combined"` \| `NA` |

**Validation rules**:
- `type_source` must be non-null for every row
- `aggregate_folder` non-null ↔ file was expanded from a sentinel
- `data_granularity` = `NA` when `type ≠ "data"`
- `data_granularity` = `"individual"` only when `aggregate_folder` is non-null AND file is from a detected series (not single-sentinel fallback)
- `type_source` = `"sentinel_llm"` or `"extension_rule"` only when `aggregate_folder` is non-null

**`is_raw` column**: Retired. Replaced by `data_granularity`. Removed from `structure.csv` output.

---

### 3. Phase 1 Classification Result

Output of the existing `llm_batch()` loop over non-aggregate paths. Unchanged from current.

| Field | Type | Description |
|---|---|---|
| `path` | character | Relative file path |
| `type` | character | LLM-assigned type |
| `group` | character | LLM-assigned group |

---

### 4. Phase 2 Classification Result

Output of `llm_batch()` over sub-sentinel descriptors using `SENTINEL_PROMPT`.

| Field | Type | Description |
|---|---|---|
| `path` | character | Sub-sentinel descriptor string (used as key) |
| `type` | character | LLM-assigned type (may be overridden if already resolved) |
| `group` | character | LLM-assigned group |

---

### 5. Experiment Map (updated)

The `experiment_map` list built incrementally during Phase 1. Used as context in Phase 2. Unchanged structure from current, but Phase 2 now receives the fully-populated map.

| Field | Type | Description |
|---|---|---|
| key | character | Group label (e.g. `"ex1"`, `"pilot2"`) |
| value | character[] | Representative path tokens for that group |

---

## `structure.csv` Schema Changes

### Added columns

| Column | Position | Default for existing rows |
|---|---|---|
| `type_source` | after `type` | `"llm"` for Phase 1 rows, appropriate value for aggregate rows |
| `aggregate_folder` | after `group` | `NA` |
| `data_granularity` | after `aggregate_folder` | `NA` (non-data); `"combined"` (data, Phase 1) |

### Removed columns

| Column | Replacement |
|---|---|
| `is_raw` | `data_granularity` |

### `type_source` enum (replaces old `"rule"`)

| Value | Meaning |
|---|---|
| `"llm"` | Assigned by Phase 1 LLM classification |
| `"extension_rule"` | Assigned by `AGGREGATE_EXT_OVERRIDE` lookup |
| `"sentinel_llm"` | Inherited from Phase 2 sentinel LLM classification |

---

## `ground_truth/<paper_id>.csv` Schema Changes

| Old column | New column | Type | Notes |
|---|---|---|---|
| `is_raw_gt` | `data_granularity_gt` | character \| NA | `"individual"` \| `"combined"` \| `NA` |

---

## Helper Function: `detect_series()`

**Location**: `pipeline/helper.R`
**Signature**: `detect_series(filenames) → list of sub-sentinel data.frames`

**Algorithm**:
1. Strip trailing suffix: `prefix <- sub("[-_][A-Za-z0-9]*[0-9][A-Za-z0-9]*[-_]?.*$", "", basename, perl=TRUE)` — removes ID/date suffixes starting at a separator followed by a segment containing digits.
2. Group by `prefix` (minimum prefix length 2 characters).
3. Files where `prefix == basename` (no suffix stripped) or whose prefix-group has only 1 member → singleton; go back to Phase 1 as individual non-aggregate paths.
4. Remaining groups → each becomes one sub-sentinel.
5. Build `descriptor_string` for each sub-sentinel.

**Returns**: `list(sub_sentinels = data.frame(...), singletons = character[])` where `singletons` are paths to route to Phase 1.

---

## `AGGREGATE_EXT_OVERRIDE` Changes

| Change | Extension | Old value | New value |
|---|---|---|---|
| Remove | `txt` | `"data"` (implied via sentinel inheritance) | — (removed; ambiguous) |
| Remove | `dat` | `"data"` (implied) | — (removed; ambiguous) |

All other entries unchanged.

---

## New Prompt: `SENTINEL_PROMPT`

**Location**: `pipeline/prompts.R`
**Used by**: Phase 2 `llm_batch()` call in `0_index.R`

Contract: receives a list of sub-sentinel descriptor strings (one per series). Returns a JSON array with `{"path": "<descriptor_string>", "type": "<type>", "group": "<group>"}` per entry. Uses the same type/group enum as `STRUCTURE_PROMPT`. The user prefix injects the Phase 1 experiment map summary.

---

## Processing Flow (updated step 4–7)

```
Step 4: Build file tree
Step 5: Detect aggregate folders (flat + participant)
Step 5b: NEW — detect_series() within each aggregate folder
          → sub_sentinels per folder
          → singletons routed back to non_agg_relpaths
Step 5c: Resolve sub-sentinel types via AGGREGATE_EXT_OVERRIDE
Step 6: Phase 1 — llm_batch(non_agg_relpaths, STRUCTURE_PROMPT)
Step 6b: NEW — Phase 2 — llm_batch(sub_sentinels, SENTINEL_PROMPT, prefix=phase1_summary)
Step 7: Expand sub-sentinels → per-file rows with type/group/type_source/aggregate_folder
Step 7b: NEW — compute data_granularity per row
Step 8: Build file_df: rbind(Phase 1 rows, expanded aggregate rows)
Step 9: Emit FR-011 diagnostics per aggregate folder
Step 10: Write structure.csv (new columns)
```
