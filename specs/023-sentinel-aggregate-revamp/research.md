# Research: Sentinel/Aggregate System Revamp

**Feature**: 023-sentinel-aggregate-revamp
**Phase**: 0 — Research

---

## Decision 1: Series detection algorithm

**Decision**: Longest-common-prefix (LCP) after stripping the trailing numeric/ID/date suffix.

**Rationale**: The spec mandates LCP (FR-002). The naming patterns in practice are:
- Participant ID suffix: `NNN_data_PICCBI_<ID>_<SESSION>_<date>.csv` → prefix `NNN_data_PICCBI_`
- IAT task prefix: `FlowerInsectCong-RA####-date.txt` → prefix `FlowerInsectCong-`

R implementation approach:
1. Strip trailing numeric/date suffix with `sub("[-_]?[0-9A-Za-z]{3,}[-_]?[0-9]{4,}.*$", "", basename, perl = TRUE)` — removes anything ending in a long alphanumeric run followed by digits (ID or date).
2. Simpler/more robust: strip everything after the last non-alphanumeric separator that precedes a purely-numeric segment, using `sub("[-_][0-9]+.*$", "", basename)`.
3. Files sharing a resulting prefix of ≥ 2 characters form one series → one sub-sentinel.
4. Files whose prefix after stripping is unique (length-1 prefix groups) → these are singletons and go directly to Phase 1 as individual non-aggregate paths.

**Alternatives considered**:
- Clustering by edit distance — too slow for 500+ file folders, harder to reason about.
- Extension-only grouping — already done by the dominant_ext logic; series detection adds the prefix dimension.
- Regex suffix pattern matching — fragile across the diversity of lab naming conventions; LCP is data-driven.

---

## Decision 2: Sub-sentinel format for Phase 2 LLM

**Decision**: Each sub-sentinel is a structured descriptor string rather than a synthetic `[N_files.ext]` path:

```
folder/[prefix: "FlowerInsectCong-", 47 files, .txt, samples: FlowerInsectCong-RA0001-20190401.txt, ...]
```

**Rationale**: The LLM needs the series prefix (the meaningful signal), the file count, dominant extension, and real sample filenames (FR-003). The current `[N_files.ext]` format gives only count and extension, losing the prefix that distinguishes IAT conditions. Structured brackets keep the format recognisable as a sentinel while embedding richer context.

**SENTINEL_PROMPT** (to be added to `prompts.R`): Distinct from `STRUCTURE_PROMPT`. It receives:
- A summary of Phase 1 results (experiment map: which paths went to ex1, ex2, etc.)
- A list of sub-sentinel descriptors

It returns the same JSON schema as `STRUCTURE_PROMPT` but the `path` field is the sub-sentinel descriptor string. The prompt must instruct the LLM:
- To use Phase 1 context to assign consistent group labels
- That type may already be resolved (extension_rule) — if so, only assign group
- To output ONLY the JSON array

**Alternatives considered**:
- Re-using `STRUCTURE_PROMPT` — violates Principle IV (prompts have different contracts) and loses Phase 1 context injection point.
- One LLM call per sub-sentinel — violates FR-004 and inflates call count.

---

## Decision 3: Phase 1 / Phase 2 split mechanics

**Decision**: Non-aggregate files → Phase 1 (existing `llm_batch()` loop). Sub-sentinels → Phase 2 (new `llm_batch()` call with `SENTINEL_PROMPT` and Phase 1 summary prefix). Both phases count toward `MAX_LLM_CALLS = 10`.

**Rationale**: The spec requires sequential phases (FR-001). Phase 2 call count = `ceiling(n_sub_sentinels / LLM_BATCH_SIZE)`. Since sub-sentinels replace individual sentinel paths that previously consumed Phase 1 calls, total call count is unchanged (SC-005).

**Edge case — no non-aggregate files**: If `length(non_agg_relpaths) == 0`, the existing cancel-sentinel fallback activates: all files are processed as individual paths in a single unified LLM pass. The two-phase split is skipped (FR-012).

**Edge case — Phase 2 exceeds MAX_LLM_CALLS**: The `too_large` guard is applied to the combined Phase 1 + Phase 2 call count before any LLM work begins. Both phases share the same counter.

---

## Decision 4: `type_source` enum values

**Decision**: Three values — `"llm"` (Phase 1 direct), `"extension_rule"` (override table), `"sentinel_llm"` (Phase 2 sentinel result). Retire `"rule"` (old name for extension_rule).

**Rationale**: FR-007 specifies this exact enum. Renaming `"rule"` → `"extension_rule"` is more descriptive and aligned with the spec. `docs/output-schemas.md` must be updated.

---

## Decision 5: `data_granularity` derivation logic

**Decision**: Derived from series membership at expansion time, not from folder location.

- File expanded from a sub-sentinel AND the sub-sentinel belongs to a detected series (not a single-sentinel fallback for a folder with no series) → `"individual"`
- File classified in Phase 1 (non-aggregate path, including singletons inside aggregate folders that were routed to Phase 1) → `"combined"`
- File of type ≠ `"data"` → `NA`
- Sub-sentinel fallback (no series found, folder → single sentinel) files expanded from it → these are part of a single-sentinel, not a series; they could be either individual or combined. Per the spec: `"individual"` only for series members. A single-sentinel folder with no series found should be `NA` for type=data files, or we default to `"combined"` since we have no series evidence. **Decision**: single-sentinel expanded files get `data_granularity = "combined"` since we cannot distinguish individual vs combined without series information. Only confirmed series-member files get `"individual"`.

**Implementation**: Add `is_series_member` flag to `agg_expanded_df` during expansion; set `data_granularity = ifelse(type == "data" & is_series_member, "individual", ifelse(type == "data", "combined", NA))`.

---

## Decision 6: Ambiguous extensions to remove from `AGGREGATE_EXT_OVERRIDE`

**Decision**: Remove `.txt` and `.dat` from the override table (FR-010). These extensions are genuinely ambiguous (participant data files often use `.txt`; `.dat` files vary widely). Leave them for `sentinel_llm` inheritance.

**Keep in override**: `.csv`, `.sav`, `.dta`, `.sas7bdat`, `.xlsx`, `.xls`, `.rds` (unambiguous data); all code and asset extensions.

---

## Decision 7: Validation GUI migration

**Decision**: Replace binary `is_raw` (checkbox) with tri-state `data_granularity` (select input: `"individual"`, `"combined"`, unset/NA). The select input is disabled for non-data types (same rule as the old `is_raw` checkbox). Ground truth column renamed `is_raw_gt` → `data_granularity_gt`.

**Rationale**: `is_raw` is being retired. The GUI must reflect the new schema. The disable-for-non-data logic transfers directly. The non-data correction guard in `gt_store.R` changes from `is_raw_gt = FALSE` → `data_granularity_gt = NA`.

**`3_psychds_convert.R`**: Any reads of `is_raw` from `ground_truth/<paper_id>.csv` switch to `data_granularity`. The override logic maps `data_granularity == "individual"` → raw participant data (the closest semantic equivalent to the old `is_raw = TRUE`).

---

## Decision 8: `aggregate_folder` column

**Decision**: New column in `structure.csv`. For files expanded from aggregate sentinels: set to the aggregate folder's relative path (e.g. `"ASD_CTL/RA_IATData"`). For non-aggregate files: `NA`.

**Rationale**: FR-008 is explicit. This enables full audit trail (US-5).

---

## Resolved unknowns

All NEEDS CLARIFICATION items from the spec are resolved above. No external research required — decisions derive from spec requirements, existing code patterns, and R base capabilities.
