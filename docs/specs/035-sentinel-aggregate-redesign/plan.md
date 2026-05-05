# Implementation Plan: Sentinel / Aggregate System Redesign

**Branch**: `035-sentinel-aggregate-redesign` | **Date**: 2026-04-14 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/specs/035-sentinel-aggregate-redesign/spec.md`

---

## Summary

Replace the two-phase sentinel/aggregate pipeline with a single-phase design:
- Detect aggregate folders (unchanged: flat + participant patterns)
- Group files within each aggregate folder by extension
- Each extension group with ≥ `AGGREGATE_THRESHOLD` members → up to 5 real sample paths sent to normal Phase 1 LLM batch; result propagated to all group members as `aggregate_llm` rows
- Extension groups below threshold → member paths routed individually to Phase 1
- `structure.csv` always written with one file-level row per file — no sentinel rows ever reach disk
- `detect_series()` removed; `expand_sentinel_rows()` removed; `AGGREGATE_EXT_OVERRIDE` demoted to validation-only

---

## Technical Context

**Language/Version**: R (base R only — no new packages)  
**Primary Dependencies**: `helper.R` (`llm_batch()`, `classify_by_rules()`), `0_index.R`, `3_psychds_convert.R`, `prompts.R` (`STRUCTURE_PROMPT_NEW`)  
**Storage**: CSV files — `outputs/<source>/<id>/structure.csv` (modified), `docs/output-schemas.md` (updated)  
**Testing**: `runners/run_tests.R` + `runners/report_tests.R` — full 20-paper suite  
**Target Platform**: macOS/Linux local pipeline  
**Project Type**: Pipeline modification — no external interfaces  
**Performance Goals**: LLM call count per paper must not increase vs. current baseline  
**Constraints**: Max 10 LLM calls per paper (Principle III); no new packages; all path I/O via `paper_path()`  
**Scale/Scope**: 20 test papers; ~1500 files across aggregate-heavy papers

---

## Constitution Check

| Principle | Status | Notes |
|---|---|---|
| I. Crash Resilience | ✅ Pass | `structure.csv` write is still atomic per paper; no in-memory accumulation change |
| II. Paper ID Preservation | ✅ Pass | No change to ID handling |
| III. Conservative Resource Limits | ✅ Pass | Sample paths join Phase 1 batch; total path count gate unchanged; `too_large` still fires at 300 |
| IV. Centralised Helpers | ✅ Pass | New `group_aggregate_folder()` goes in `helper.R`; no inline logic in pipeline scripts |
| V. Structured Error Classification | ✅ Pass | No new error codes; `too_large` path unchanged |
| VI. Source-Aware Storage | ✅ Pass | No change to path resolution; `paper_path()` still used throughout |

**Constitution amendment required**: Processing order step 4 must be updated (sentinel rows no longer written; expansion now happens before write). `AGGREGATE_THRESHOLD` constant value corrected to 20. This is a MINOR version bump.

---

## Project Structure

### Documentation (this feature)

```text
specs/035-sentinel-aggregate-redesign/
├── plan.md              ← this file
├── spec.md
├── research.md          ← Phase 0 complete
├── data-model.md        ← Phase 1 complete
├── checklists/
│   └── requirements.md
└── tasks.md             ← Phase 2 output (via /speckit.tasks)
```

### Source Code (files changed by this feature)

```text
pipeline/
├── 0_index.R            # Rewrite aggregate detection + routing (lines ~341–478)
├── helper.R             # Remove detect_series(); add group_aggregate_folder()
└── 3_psychds_convert.R  # Remove expand_sentinel_rows(); remove is_sentinel handling

docs/
└── output-schemas.md    # Remove is_sentinel; update type_source enum; fix AGGREGATE_THRESHOLD

.specify/memory/
└── constitution.md      # MINOR bump: update processing order step 4 + constant value
```

**Structure Decision**: Single-project pipeline modification. All changes are edits to existing files — no new files added to `pipeline/`.

---

## Phase 0: Research — Complete

See [research.md](research.md). All unknowns resolved:

- `AGGREGATE_THRESHOLD` discrepancy → code value (20) authoritative; constitution amended
- LLM call budget → sample paths join Phase 1; no separate counter needed
- `type_source` for inherited rows → `aggregate_llm`
- New function location → `group_aggregate_folder()` in `helper.R`
- Singleton threshold → same `AGGREGATE_THRESHOLD` gate
- `is_sentinel` column → removed from schema
- `expand_sentinel_rows()` → deleted

---

## Phase 1: Design — Complete

See [data-model.md](data-model.md).

**Key design decisions**:

1. **`group_aggregate_folder(rel_paths_in_folder)`** — new helper in `helper.R`
   - Groups paths by lowercase extension
   - Returns list of groups: each has `ext`, `members`, `sample_paths` (≤5, evenly spaced), `route_individually` flag
   - Groups with `length(members) < AGGREGATE_THRESHOLD` → `route_individually = TRUE`

2. **Phase 1 batch composition** — in `0_index.R`
   - Non-aggregate files: as before
   - Aggregate group samples: `sample_paths` from each group where `route_individually = FALSE`
   - Individually-routed aggregate members: appended directly when `route_individually = TRUE`
   - Single LLM phase; no Phase 2

3. **Result propagation** — in `0_index.R`
   - After LLM returns type/group for sample paths: propagate to all `members` in that group
   - All rows written to `structure.csv` with `type_source = "aggregate_llm"`
   - No `is_sentinel` column written

4. **`AGGREGATE_EXT_OVERRIDE`** — kept but demoted
   - Rename to `AGGREGATE_EXT_VALIDATION` or keep name; remove it from the classification path
   - May be used post-LLM to flag obvious misclassifications in logs (optional)

5. **`3_psychds_convert.R`**
   - Remove `expand_sentinel_rows()` function
   - Remove any `is_sentinel` column check in the file-copy loop

**No contracts** — internal pipeline, no external interfaces.

---

## Complexity Tracking

No constitution violations. No new complexity introduced.
