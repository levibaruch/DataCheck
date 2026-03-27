# Feature Specification: Sentinel/Aggregate System Revamp

**Feature Branch**: `023-sentinel-aggregate-revamp`
**Created**: 2026-03-27
**Status**: Draft
**Input**: User description: "the current sentinel system in 0_index is brutish and bad; while the intention is good; limiting llm calls over huge amount of files, the current implementation makes no sense and takes too much liberties. I feel this may be due to some confusion upstream about raw vs actionable datafiles; these are different of course. We need to fully revamp the sentinel/aggregate system to be more accurate and transparent"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Sub-group series detection within aggregates (Priority: P1)

A researcher runs the pipeline on a paper whose OSF repository contains 563 participant CSV files in a `data/` folder, all named `NNN_data_PICCBI_PARTICIPANT_SESSION_date.csv`. Rather than collapsing all 563 to a single opaque sentinel (`data/[563_files.csv]`), the pipeline detects the common naming pattern, identifies a single series, and creates one sub-sentinel that carries meaningful sample filenames into the LLM. In the IAT paper, a `RA_IATData/` folder with 329 files spanning 20 distinct task conditions (e.g. `FlowerInsectCong-RA####-date.txt`, `RaceEvalCong-RA####-date.txt`) is sub-grouped into ~20 series, each carrying its task-name prefix — which the LLM uses to assign correct experiment group labels. When no numeric series is detected (e.g. a jsPsych `examples/` folder with 55 uniquely-named HTML files), the system degrades gracefully to a single sentinel for the whole folder.

**Why this priority**: Sub-grouping is what makes the sentinel meaningful. A single sentinel for 329 mixed-condition files produces one group label. Twenty sub-sentinels — one per IAT task prefix — allow correct per-condition group assignment. The graceful degradation ensures the behaviour is never worse than today.

**Independent Test**: Run `run_index()` on a paper with a large folder containing multiple distinguishable filename series. Confirm `structure.csv` contains distinct `aggregate_folder` sub-paths and that files from different series carry different group labels where appropriate. Run on a paper with a non-series aggregate (e.g. library examples folder) and confirm it still produces a single sentinel result.

**Acceptance Scenarios**:

1. **Given** a folder of 329 files with 20 distinct task-name prefixes, **When** sub-grouping runs, **Then** ~20 sub-sentinels are produced, one per prefix, each with its own sample filenames.
2. **Given** a folder of 55 uniquely-named HTML files with no numeric ID pattern, **When** sub-grouping runs, **Then** no series is found and the folder is treated as a single sentinel (current behaviour preserved).
3. **Given** two sub-sentinels in the same folder, **When** Phase 2 classifies them, **Then** they can receive different `group` values if their task-name prefixes correspond to different experiments.

---

### User Story 2 - Context-aware Phase 2 sentinel classification (Priority: P2)

After all non-aggregate files are classified in Phase 1, aggregate sentinels are sent to the LLM in a dedicated Phase 2 call that receives the full Phase 1 classification summary as context. The LLM can now reason from what it already knows about the paper: "this repo has `Eval_IAT_MTurk_AllParticipants_Anon.csv (data/ex1)` and `Stereo_IAT_MTurk_AllParticipants_Anon.csv (data/ex2)` — the `FlowerInsectCong-MT_*` sub-sentinel clearly belongs to ex1." When the sub-sentinel's type is already resolved by the extension override table (e.g. 61 `.jpg` stimuli), Phase 2 is skipped for that sub-sentinel and only needed for group assignment for ambiguous-extension sub-sentinels.

**Why this priority**: Group consistency — the hardest current failure — is solved by ensuring Phase 2 has a fully-populated experiment map when it runs. Type accuracy for unambiguous extensions is solved without any LLM call at all.

**Independent Test**: Run on a paper with a participant folder alongside a named merged data file. Confirm the participant folder's `group` in `structure.csv` matches the group assigned to the merged file in Phase 1.

**Acceptance Scenarios**:

1. **Given** Phase 1 classifies `Eval_IAT_MTurk_AllParticipants_Anon.csv` as `data/ex1`, **When** Phase 2 classifies the `FlowerInsectCong-MT_*` sub-sentinel, **Then** it is assigned `group = "ex1"`.
2. **Given** a sub-sentinel whose extension is in the override table (e.g. `.jpg`), **When** Phase 2 runs, **Then** type is already resolved and only group is requested from the LLM.
3. **Given** multiple sub-sentinels from different folders, **When** Phase 2 runs, **Then** all are batched into a single LLM call.

---

### User Story 3 - Individual vs combined data granularity flag (Priority: P3)

Every data file in `structure.csv` carries a `data_granularity` field distinguishing whether it is an individual-level file (one record per participant, part of a detected series) or a combined file (classified individually, not part of any series). The key signal is **series membership**, not folder location. A single `merged_results.csv` sitting alongside 200 participant files in the same aggregate folder is a singleton — it goes to Phase 1 for individual LLM classification and is `"combined"`. The 200 participant files that form a detected series are expanded from a sub-sentinel and are `"individual"`. Non-data files (code, assets, docs) carry `NA`.

**Why this priority**: Individual files are structurally redundant for column extraction purposes; combined files are what analysis scripts actually use. Surfacing the distinction allows downstream stages to skip or deprioritise individual files and focus extraction on combined files.

**Independent Test**: Run on a paper whose aggregate folder contains 200 numbered participant files AND one singleton merged summary file. Confirm sub-sentinel-expanded rows show `data_granularity = "individual"`, the singleton merged file (Phase 1) shows `data_granularity = "combined"`, and a standalone merged file outside the folder also shows `data_granularity = "combined"`.

**Acceptance Scenarios**:

1. **Given** a data file expanded from a sub-sentinel (member of a detected series), **When** `structure.csv` is written, **Then** `data_granularity = "individual"`.
2. **Given** a data file classified individually by Phase 1 — whether a singleton inside an aggregate folder or a standalone file outside one — **When** `structure.csv` is written, **Then** `data_granularity = "combined"`.
3. **Given** any non-data file (type = `"code"`, `"asset"`, `"supplemental"`, etc.), **When** `structure.csv` is written, **Then** `data_granularity = NA`.

---

### User Story 4 - Per-file accurate type after expansion (Priority: P4)

After the sub-sentinel is classified, each file expanded from the aggregate is typed individually: unambiguous extensions are resolved by the extension override table first; only files with ambiguous extensions inherit the sub-sentinel's LLM-assigned type. This prevents `.R` scripts inside a data folder being typed as `data`.

**Why this priority**: Even a well-classified sub-sentinel can contain files of mixed types. Per-file resolution is the last-mile fix that makes expansion correct regardless of folder heterogeneity.

**Independent Test**: Run on a paper whose aggregate folder contains `.csv` participant files and stray `.R` scripts. Confirm `.R` files show `type = "code"` and `.csv` files show `type = "data"`.

**Acceptance Scenarios**:

1. **Given** a sub-sentinel classified as `type = "data"`, **When** a `.R` file is expanded from it, **Then** `type = "code"`, `type_source = "extension_rule"`.
2. **Given** a sub-sentinel classified as `type = "data"`, **When** a `.txt` file is expanded (ambiguous, removed from override table), **Then** it inherits `type = "data"`, `type_source = "sentinel_llm"`.
3. **Given** any aggregate-expanded file, **When** `structure.csv` is written, **Then** `aggregate_folder` is populated and `type_source` is non-null.

---

### User Story 5 - Transparent audit trail in structure.csv (Priority: P5)

A user examining `structure.csv` can tell exactly why each file received its type and group — direct LLM (Phase 1), extension override table, or Phase 2 sentinel LLM — and which aggregate folder it came from. The IAT paper produces rows where `FlowerInsectCong-RA####.txt` files show `type_source = "sentinel_llm"`, `aggregate_folder = "ASD_CTL/RA_IATData/"`, and `data_granularity = "individual"`, making the full classification chain auditable without re-running the pipeline.

**Why this priority**: Observability is necessary to trust outputs and diagnose errors across papers at scale.

**Acceptance Scenarios**:

1. **Given** a file classified in Phase 1, **Then** `type_source = "llm"`, `aggregate_folder = NA`.
2. **Given** a file expanded from an aggregate with an extension in the override table, **Then** `type_source = "extension_rule"`, `aggregate_folder` set.
3. **Given** a file expanded from an aggregate with type from the Phase 2 sentinel call, **Then** `type_source = "sentinel_llm"`, `aggregate_folder` set.

---

### Edge Cases

- **No non-aggregate files**: If all files fall into aggregate folders, Phase 1 produces no results. The two-phase split collapses: all sub-sentinels are classified in a single combined call without prior context. Cancel-sentinel-and-process-all fallback is preserved as before.
- **No series found in aggregate**: If sub-grouping finds no numeric pattern (e.g. 55 uniquely-named HTML files), the folder is treated as a single sentinel — identical to current behaviour. No regression.
- **Deduplication shrinks a folder below threshold**: The PICCBI paper shows that deduplication (step 3c, which runs before aggregate detection) can reduce a folder below 50, removing it from aggregate detection entirely. Its files then enter Phase 1 as individual non-aggregate paths. This is correct behaviour and should be noted in documentation.
- **Sub-sentinel type already resolved by extension rule**: When all files in a sub-group share an unambiguous extension (`.csv`, `.jpg`, `.R`), type is assigned by the override table without any LLM call. Phase 2 is still called for group assignment unless the group can also be inferred from the folder name.
- **Combined file placed inside an aggregate folder**: A single `merged_results.csv` sitting alongside 200 participant files is a singleton — it is not part of any series, goes to Phase 1 directly, and receives `data_granularity = "combined"`. Series membership, not folder location, determines the field.
- **Phase 2 exceeds `MAX_LLM_CALLS`**: Sub-sentinel batches count toward the same call limit as Phase 1. The existing `too_large` guard applies to the total across both phases.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The pipeline MUST run LLM classification in two sequential phases: Phase 1 classifies all non-aggregate files using the existing batching loop; Phase 2 classifies aggregate sub-sentinels using Phase 1 results as context.
- **FR-002**: Within each detected aggregate folder, the pipeline MUST attempt series detection by finding the longest common filename prefix across all members (stripping the variable numeric/ID/date suffix). Files sharing a common prefix of ≥2 characters form a series and are collapsed to one sub-sentinel. Folders where no series is found are treated as a single sentinel (current behaviour).
- **FR-003**: Each sub-sentinel sent to Phase 2 MUST include: the folder path, the series prefix (or `"mixed"` for single-sentinel fallback), the file count, the dominant extension, and a sample of 5 real filenames from the series.
- **FR-004**: All sub-sentinels from all aggregate folders MUST be batched together in Phase 2 (not one call per sentinel), consuming at most `ceil(n_sub_sentinels / LLM_BATCH_SIZE)` additional LLM calls.
- **FR-005**: When a sub-sentinel's type is fully resolved by the extension override table before Phase 2, Phase 2 MUST still be called for that sub-sentinel but only to assign group — not to re-classify type.
- **FR-006**: The pipeline MUST classify every file expanded from an aggregate using its own file extension first (extension override table), falling back to the sub-sentinel's LLM-assigned type only when the extension is absent from the table.
- **FR-007**: The pipeline MUST record the source of every type assignment in a `type_source` column using a defined enum: `"llm"` (Phase 1), `"extension_rule"` (override table), `"sentinel_llm"` (Phase 2 sentinel result).
- **FR-008**: The pipeline MUST record which aggregate folder a file was expanded from in an `aggregate_folder` column (`NA` for non-aggregate files).
- **FR-009**: The pipeline MUST populate a `data_granularity` column for every row: `"individual"` for any data file expanded from a sub-sentinel (part of a detected series), `"combined"` for any data file classified individually by Phase 1 (whether a singleton inside an aggregate folder or a standalone file outside one), `NA` for non-data files.
- **FR-010**: Extension entries in `AGGREGATE_EXT_OVERRIDE` that are genuinely ambiguous between data and non-data roles (e.g. `.txt`, `.dat`) MUST be removed and left for `sentinel_llm` inheritance.
- **FR-011**: The pipeline MUST emit a diagnostic message per aggregate folder listing: folder path, number of sub-sentinels produced, member counts per sub-sentinel, and Phase 2 assigned type and group.
- **FR-012**: If all files fall into aggregate folders (no Phase 1 paths), the two-phase split MUST be skipped and all sub-sentinels processed in a single combined pass.

### Key Entities

- **Aggregate Folder**: A directory exceeding `AGGREGATE_THRESHOLD` in direct file children (flat aggregate) or numeric-named subdirectories (participant aggregate).
- **Series**: A group of files within an aggregate folder sharing a common filename prefix, detected by longest-common-prefix after stripping numeric/ID/date suffixes. Collapses to one sub-sentinel.
- **Sub-Sentinel**: A compact descriptor for one series (or the whole folder if no series found) — prefix, file count, dominant extension, 5 sample filenames — sent to Phase 2 LLM in place of individual paths.
- **Phase 1 Classification**: LLM classification of all non-aggregate files using the existing batching loop and incremental experiment-map context building.
- **Phase 2 Sentinel Classification**: A dedicated LLM batch for all sub-sentinels, receiving the full Phase 1 classification summary as context.
- **Expanded File Row**: A row in `structure.csv` for a real file originally collapsed under a sub-sentinel. Carries `aggregate_folder`, `type_source`, and individually-resolved `type`.
- **`data_granularity`**: A tri-state field (`"individual"` / `"combined"` / `NA`). Derived from series membership, not folder location. `"individual"` = expanded from a sub-sentinel (part of a detected series); `"combined"` = classified individually by Phase 1, regardless of whether the file sits inside or outside an aggregate folder; `NA` = non-data file.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On papers with multiple IAT task conditions in a single aggregate folder (e.g. the IAT paper), each task-condition series receives a distinct sub-sentinel and the LLM assigns group labels consistent with Phase 1 merged data file classifications.
- **SC-002**: No file in `structure.csv` receives a type purely because of the dominant extension of its aggregate folder — `.R` files inside data folders show `type = "code"`.
- **SC-003**: Every row in `structure.csv` has a non-null `type_source` value from the defined enum.
- **SC-004**: All sub-sentinel-expanded data files show `data_granularity = "individual"`; all Phase-1-classified data files (including singletons inside aggregate folders) show `data_granularity = "combined"`; all non-data files show `data_granularity = NA`.
- **SC-005**: Total LLM call count per paper does not increase relative to the current approach — Phase 2 sub-sentinel calls replace the sentinel placeholder paths that previously occupied Phase 1 batches.
- **SC-006**: Folders with no detectable numeric series (e.g. jsPsych `examples/`) produce a single sentinel result identical in quality to the current system — no regression.

## Assumptions

- `AGGREGATE_THRESHOLD = 50` remains the correct cut-off; adjusting it is out of scope.
- Longest-common-prefix series detection is sufficient for the naming patterns observed in practice (participant IDs, IAT task conditions, stimulus numbering). More sophisticated clustering is not needed.
- `data_granularity` is derived from series membership (was this file expanded from a sub-sentinel?) not from folder location or path naming. A singleton data file inside an aggregate folder is `"combined"`, not `"individual"`.
- Deduplication (step 3c) runs before aggregate detection. A folder reduced below the threshold by deduplication is correctly handled as non-aggregate; this interaction is expected and correct.
- The Phase 2 batch counts toward the same `MAX_LLM_CALLS` limit as Phase 1.
- When a sub-sentinel's type is unambiguous from the extension override table, the Phase 2 call still provides group assignment — the call is not skipped entirely.

## Dependencies

- `pipeline/0_index.R` — primary change surface: sub-grouping logic, two-phase LLM loop, expansion, `structure.csv` write.
- `pipeline/prompts.R` — a new `SENTINEL_PROMPT` must be added for Phase 2, distinct from `STRUCTURE_PROMPT`.
- `docs/output-schemas.md` — update `type_source` enum (add `"sentinel_llm"`, retire `"rule"`), add `aggregate_folder` and `data_granularity` column definitions.
- `tools/validation_gui/app.R` and `tools/validation_gui/gt_store.R` — hardcode `is_raw` / `is_raw_gt` / `is_raw_val` throughout; must be updated to `data_granularity` with a tri-state selector.
- `docs/pipeline.md` — flow diagram step 4 description needs updating to describe two-phase classification and sub-grouping.

## TODOs

- [ ] Update `tools/validation_gui/app.R`: replace the `is_raw_val` checkbox with a `data_granularity` selector (`"individual"`, `"combined"`, unset/NA); update the disable-for-non-data logic accordingly.
- [ ] Update `tools/validation_gui/gt_store.R`: rename `is_raw_gt` column to `data_granularity_gt`; update the non-data correction guard (currently forces `is_raw_gt = FALSE` → should set `data_granularity_gt = NA`).
- [ ] Update `pipeline/3_psychds_convert.R`: wherever `ground_truth/<paper_id>.csv` is read and `is_raw` is applied as an override, switch to `data_granularity`.
