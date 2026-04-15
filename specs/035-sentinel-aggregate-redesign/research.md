# Research: Sentinel / Aggregate System Redesign

**Branch**: `035-sentinel-aggregate-redesign`  
**Date**: 2026-04-14

---

## Decision 1: `AGGREGATE_THRESHOLD` discrepancy

**Finding**: Constitution constants table lists `AGGREGATE_THRESHOLD = 50`. The live code in `0_index.R` has `AGGREGATE_THRESHOLD = 20`. These are inconsistent.

**Decision**: Treat the code value (20) as authoritative for this feature — the constitution table appears to be stale. The constitution amendment required by this feature (processing order change) MUST also correct the constant value to 20.

**Alternatives considered**: Bumping code to 50 — rejected, as 20 has been the effective value through all test results accumulated to date.

---

## Decision 2: LLM call budget for extension groups

**Finding**: Constitution Principle III caps file classification at 10 LLM calls per paper (batch size 30 = 300 paths). Under the new design, each extension group within an aggregate folder contributes up to 5 sample paths to the normal LLM batch. This means aggregate sample paths compete for the same call budget as non-aggregate individual paths.

**Decision**: No special budget allocation needed. Sample paths from extension groups are just regular paths in the Phase 1 batch. The existing `too_large` gate (total paths + sample paths > 300) covers the constraint automatically. No second phase, no separate counter.

**Implication**: A paper with 3 aggregate folders, each with 2 extension groups, contributes at most 30 sample paths (3 × 2 × 5) to the batch — well within budget.

---

## Decision 3: `type_source` value for aggregate-inherited rows

**Finding**: `structure.csv` records `type_source` to indicate how each file was classified. Currently sentinel rows get `type_source = "sentinel_llm"`. Under the new design, the LLM classifies sample paths (which would naturally get `type_source = "llm"`), and all other members of the extension group inherit that classification.

**Decision**: Rows that inherit classification from a group sample path get `type_source = "aggregate_llm"`. The 5 sample paths themselves also get `type_source = "aggregate_llm"` (not plain `"llm"`) to distinguish them from individually-classified paths. This preserves the ability to audit aggregate classification separately in test reports.

**Alternatives considered**: Using plain `"llm"` for sample paths — rejected, as it would lose traceability and break the `sentinel_llm` metric comparison baseline.

---

## Decision 4: Where the new grouping logic lives

**Finding**: Constitution Principle IV requires new shared helpers in `helper.R`. The current aggregate code spans `0_index.R` (detection + routing) and `helper.R` (`detect_series()`).

**Decision**: 
- New function `group_aggregate_folder(rel_paths_in_folder)` goes in `helper.R`. Returns a list of extension groups: each group has `ext`, `members` (all paths), `sample_paths` (up to 5), and a flag `is_singleton_routed` (FALSE = group produces a sentinel, TRUE = group routes individually).
- Detection logic (flat + participant patterns) stays in `0_index.R` — it operates on the full file tree, not a single folder.
- `detect_series()` is removed from `helper.R`.

---

## Decision 5: Singleton routing threshold

**Finding**: An extension group with fewer than `AGGREGATE_THRESHOLD` files within an aggregate folder should route individually (not produce a sentinel). Need a consistent rule for what "fewer than" means here.

**Decision**: Use `AGGREGATE_THRESHOLD` as the gate. Extension groups with ≥ `AGGREGATE_THRESHOLD` members → sentinel (represented by sample paths). Groups with < `AGGREGATE_THRESHOLD` members → individual paths routed to LLM directly. This is the same threshold used to detect the folder as aggregate, keeping one consistent concept.

---

## Decision 6: `is_sentinel` column in `structure.csv`

**Finding**: Current `structure.csv` has `is_sentinel` column used by psychDS and quality reports to detect collapsed rows. Under the new design, no sentinel rows appear in the final written CSV — expansion happens before write.

**Decision**: Remove `is_sentinel` column from `structure.csv` entirely. Update `docs/output-schemas.md` accordingly. Downstream consumers (`3_psychds_convert.R`, quality report) no longer need to check for or handle this column.

---

## Decision 7: `expand_sentinel_rows()` in `3_psychds_convert.R`

**Finding**: This function (line 887, marked TODO) is the main downstream consumer of sentinel rows. It needs to be reconciled with the new approach.

**Decision**: Delete `expand_sentinel_rows()` entirely. Since `structure.csv` is written with file-level rows, psychDS conversion reads it directly with no expansion step needed.

---

## Summary table

| Question | Decision |
|---|---|
| `AGGREGATE_THRESHOLD` discrepancy | Code value (20) is authoritative; amend constitution |
| LLM call budget | Sample paths join normal Phase 1 batch; no separate counter |
| `type_source` for inherited rows | `aggregate_llm` for all rows in an extension group |
| Grouping logic location | `group_aggregate_folder()` in `helper.R`; detection stays in `0_index.R` |
| Singleton threshold | Same `AGGREGATE_THRESHOLD` gate (< threshold → individual) |
| `is_sentinel` column | Removed from `structure.csv` and output schema |
| `expand_sentinel_rows()` | Deleted; no longer needed |
