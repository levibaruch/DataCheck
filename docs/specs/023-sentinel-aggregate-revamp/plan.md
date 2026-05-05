# Implementation Plan: Sentinel/Aggregate System Revamp

**Branch**: `023-sentinel-aggregate-revamp` | **Date**: 2026-03-27 | **Spec**: `specs/023-sentinel-aggregate-revamp/spec.md`
**Input**: Feature specification from `/specs/023-sentinel-aggregate-revamp/spec.md`

## Summary

Replace the single-opaque-sentinel aggregate system in `0_index.R` with a two-phase classification pipeline: Phase 1 classifies all non-aggregate (individual) files; Phase 2 classifies aggregate sub-sentinels using Phase 1 results as context. Within each aggregate folder, a new `detect_series()` helper groups files by their common filename prefix into sub-sentinels — enabling the LLM to assign per-condition group labels (e.g. 20 IAT task-condition series → 20 distinct group assignments). New `type_source`, `aggregate_folder`, and `data_granularity` columns make the full classification chain auditable.

## Technical Context

**Language/Version**: R (base R only — no new packages)
**Primary Dependencies**: `metacheck` (`llm_batch()`), `haven`, `readxl`, `jsonlite` — all already installed
**Storage**: CSV files on local filesystem — `outputs/<paper_id>/structure.csv`, `ground_truth/<paper_id>.csv`
**Testing**: Manual smoke-test via `run_index()` on the IAT paper and PICCBI paper
**Target Platform**: macOS/Linux (same as existing pipeline)
**Project Type**: CLI pipeline / data processing
**Performance Goals**: Total LLM call count per paper must not increase (SC-005)
**Constraints**: Phase 1 + Phase 2 combined ≤ `MAX_LLM_CALLS` (10); base R only
**Scale/Scope**: Aggregate folders with up to ~600 files; ~20 sub-sentinels per folder in worst case

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Crash Resilience | ✅ PASS | `structure.csv` still written at step 10; no new in-memory-only accumulation |
| II. Paper ID Preservation | ✅ PASS | No change to `paper_id` handling |
| III. Conservative Resource Limits | ✅ PASS | Phase 1 + Phase 2 share `MAX_LLM_CALLS = 10`; `too_large` guard applied to combined count (FR-012 edge case handled) |
| IV. Centralised Shared Helpers and Prompts | ✅ PASS | `detect_series()` → `helper.R`; new `SENTINEL_PROMPT` → `prompts.R`; no inline prompt strings |
| V. Structured Error Classification | ✅ PASS | No new error codes needed; existing `too_large` covers Phase 2 overflow |

**Post-design re-check**: All principles continue to pass. No violations requiring justification.

## Project Structure

### Documentation (this feature)

```text
specs/023-sentinel-aggregate-revamp/
├── plan.md              # This file
├── research.md          # Phase 0 output — all decisions resolved
├── data-model.md        # Phase 1 output — entities, schema changes, algorithm
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
data_check/
├── pipeline/
│   ├── 0_index.R               # PRIMARY change surface — two-phase LLM loop, sub-grouping,
│   │                           #   expansion, new structure.csv columns
│   ├── prompts.R               # ADD: SENTINEL_PROMPT for Phase 2
│   └── helper.R                # ADD: detect_series() helper function
├── tools/
│   └── validation_gui/
│       ├── app.R               # UPDATE: is_raw → data_granularity tri-state selector
│       └── gt_store.R          # UPDATE: is_raw_gt → data_granularity_gt, NA for non-data
├── docs/
│   ├── output-schemas.md       # UPDATE: type_source enum, add aggregate_folder + data_granularity,
│   │                           #   remove is_raw column
│   └── pipeline.md             # UPDATE: flow diagram step 4–7 description, two-phase classification
└── specs/023-sentinel-aggregate-revamp/
    ├── plan.md
    ├── research.md
    ├── data-model.md
    └── tasks.md
```

Note: `pipeline/3_psychds_convert.R` also needs `is_raw` → `data_granularity` migration (per spec TODO).

**Structure Decision**: Single project (Option 1). All changes are within the existing `pipeline/`, `tools/`, and `docs/` tree. No new directories created.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations — section not applicable.

---

## Phase 0 Research Summary

See `research.md` for full decisions. Key resolved questions:

1. **Series detection**: Longest-common-prefix after stripping numeric/ID/date suffix with `sub("[-_][A-Za-z0-9]*[0-9][A-Za-z0-9]*[-_]?.*$", "", ...)`. Files whose stripped prefix equals their full basename are singletons → routed to Phase 1.
2. **Sub-sentinel format**: Structured descriptor string `folder/[prefix: "...", N files, .ext, samples: ...]` — embeds series prefix (primary LLM signal), count, extension, and 5 real filenames.
3. **Phase 2 mechanics**: One `llm_batch()` call (or more if sub-sentinels > `LLM_BATCH_SIZE`) using `SENTINEL_PROMPT` with Phase 1 experiment map injected as user prefix. Counts toward same `MAX_LLM_CALLS` limit.
4. **`type_source` enum**: `"llm"` / `"extension_rule"` / `"sentinel_llm"`. Retire `"rule"`.
5. **`data_granularity` logic**: `"individual"` for series-member expanded files; `"combined"` for Phase 1 files and single-sentinel-fallback expanded files; `NA` for non-data.
6. **Extensions to remove from override table**: `.txt`, `.dat` (too ambiguous).
7. **Validation GUI**: `is_raw` checkbox → `data_granularity` select input (3 states: `"individual"`, `"combined"`, unset); `is_raw_gt` → `data_granularity_gt`.
8. **`aggregate_folder` column**: Relative path of aggregate parent folder; `NA` for non-aggregate rows.

## Phase 1 Design Summary

See `data-model.md` for full schema and algorithm. Key artifacts:

### `structure.csv` schema changes
- **Add**: `type_source` (after `type`), `aggregate_folder` (after `group`), `data_granularity` (after `aggregate_folder`)
- **Remove**: `is_raw`
- **`type_source` enum**: `"llm"` | `"extension_rule"` | `"sentinel_llm"`

### New helper: `detect_series(filenames)`
Location: `pipeline/helper.R`. Takes a character vector of filenames, returns `list(sub_sentinels, singletons)`.

### New prompt: `SENTINEL_PROMPT`
Location: `pipeline/prompts.R`. Receives Phase 1 experiment map context + sub-sentinel descriptors; returns same JSON schema as `STRUCTURE_PROMPT`.

### Updated processing order in `0_index.R`
Steps 5–7 become:
1. Detect aggregate folders (existing)
2. `detect_series()` per aggregate → sub-sentinels + singletons (singletons join Phase 1 paths)
3. Pre-resolve sub-sentinel types via `AGGREGATE_EXT_OVERRIDE`
4. Phase 1 `llm_batch()` over non-aggregate + singleton paths
5. Phase 2 `llm_batch()` over sub-sentinels with Phase 1 summary prefix
6. Expand sub-sentinels → per-file rows with `aggregate_folder`, `type_source`, `data_granularity`
7. Emit FR-011 diagnostic per aggregate folder

### `AGGREGATE_EXT_OVERRIDE` changes
Remove `txt` and `dat` entries (ambiguous between data and non-data).
