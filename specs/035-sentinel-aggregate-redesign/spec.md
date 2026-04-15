# Feature Specification: Sentinel / Aggregate System Redesign

**Feature Branch**: `035-sentinel-aggregate-redesign`  
**Created**: 2026-04-14  
**Status**: Draft  
**Input**: Replace the current sentinel/aggregate system with a simpler, more reliable design that correctly identifies large aggregate folders containing assets or per-participant datasets.

---

## Background

The current system collapses large folders into synthetic "sentinel" rows before LLM classification. It uses a fragile regex-based series-detection algorithm (`detect_series`), a two-phase LLM pipeline where phase 2 receives artificial descriptor strings (not real paths), and a post-hoc extension override table that bypasses LLM reasoning. The result is a patchwork of interdependent heuristics that is hard to maintain and produces inconsistent output (see: `expand_sentinel_rows` TODO, `sentinel_llm` accuracy 50–63%, image bug in `AGGREGATE_EXT_OVERRIDE`).

The core goal has always been simpler: when a folder is too large to send to the LLM path-by-path, classify it as a unit and propagate that classification to all its members.

---

## User Scenarios & Testing

### User Story 1 — Stimulus folder classified as asset (Priority: P1)

A repository has a `stimuli/` folder containing 300 `.jpg` images. The pipeline must classify all files as `asset` without sending 300 individual paths to the LLM.

**Why this priority**: Most common aggregate pattern. Currently broken when `AGGREGATE_EXT_OVERRIDE` is bypassed by the image bug.

**Independent Test**: Run `run_index()` on any paper with a large image/audio stimuli folder. Verify all files in the aggregate folder receive `type = asset` as individual rows in `structure.csv`.

**Acceptance Scenarios**:

1. **Given** a folder with >20 files of the same extension (e.g., 300 `.jpg`), **When** `run_index()` processes the paper, **Then** the LLM receives up to 5 real sample paths from that extension group, classifies the group, and `structure.csv` contains one file-level row per member — all with the LLM's classification.

2. **Given** a large folder containing a dominant extension group (>20 files) plus a smaller outlier group (<20 files of a different extension), **When** `run_index()` processes the paper, **Then** the dominant group is classified as above, and the outlier files are routed as individual paths to the LLM — each classified on its own merits.

---

### User Story 2 — Per-participant folder classified as data (Priority: P1)

A repository has a folder `FCTM_Data/FCTM_Exp1/` with 142 numeric subdirectories (participant IDs), each containing `.dat` files. The pipeline must classify all files as `data` with the correct group label.

**Why this priority**: Second most common aggregate pattern. Current series detection frequently creates wrong sub-sentinels or misses participant directories nested >1 level deep.

**Independent Test**: Run `run_index()` on paper `0956797614547916`. Verify all per-participant files receive `type = data` and `group = ex1`.

**Acceptance Scenarios**:

1. **Given** a folder whose immediate subdirectories are mostly numeric names and there are >20 such subdirectories, **When** `run_index()` processes the paper, **Then** the folder is treated as one aggregate unit and all files inherit a single type/group classification.

2. **Given** a participant aggregate folder where `.dat` is the dominant extension, **When** `run_index()` processes the paper, **Then** the LLM receives up to 5 real `.dat` sample paths, classifies the group, and all member files in `structure.csv` receive file-level rows with that classification.

---

### User Story 3 — Heterogeneous aggregate folder handled gracefully (Priority: P2)

A folder has >20 files with mixed extensions. The dominant extension does not reach the homogeneity threshold but still accounts for the majority (e.g., 75 images + 25 `.txt` files).

**Why this priority**: Current failure mode — all members inherit one type, so the minority gets silently misclassified.

**Independent Test**: Identify a test paper with a large folder containing a clear dominant extension group plus a smaller outlier group. Verify that the dominant group is classified correctly and the outlier files are classified individually — not forced to inherit the dominant type.

**Acceptance Scenarios**:

1. **Given** an aggregate folder with a dominant extension group (>20 files) and an outlier group (<20 files of a different extension), **When** the pipeline processes it, **Then** the dominant group is classified by LLM using sample paths, and the outlier files are routed individually to LLM — no file inherits a type from a different extension group.

2. **Given** an aggregate folder split roughly evenly between two extension groups (e.g., 50% images, 50% `.dat`), **When** the pipeline processes it, **Then** each group produces its own sentinel row classified independently — they do not share a single type.

3. **Given** any aggregate folder split into groups, **When** classification is complete, **Then** no file inherits a type determined by files of a different extension.

---

### User Story 4 — Aggregate files appear correctly in all downstream outputs (Priority: P2)

Any consumer of `structure.csv` — quality reports, psychDS conversion, column extraction — must see one row per file. Sentinel grouping is an internal classification detail; it must not surface in outputs.

**Why this priority**: Currently `is_sentinel` rows leak into downstream consumers, causing missing files in psychDS and skipped columns in quality reports.

**Independent Test**: Run the full pipeline on any paper with an aggregate folder. Verify that `structure.csv` on disk contains one row per file (no `is_sentinel = TRUE` rows), and that psychDS output includes all aggregate files at the correct paths.

**Acceptance Scenarios**:

1. **Given** a paper with an aggregate folder of N files, **When** `run_index()` completes and writes `structure.csv`, **Then** the file contains exactly N individual file rows for that folder — no collapsed sentinel rows.

2. **Given** `structure.csv` written by the new pipeline, **When** `psychds_convert()` runs, **Then** all files from aggregate folders are copied to the correct psychDS subdirectory without any special sentinel-expansion step required.

---

### Edge Cases

- What happens at exactly `AGGREGATE_THRESHOLD` files — is the folder treated as aggregate?
- What if a large folder has a clear dominant extension but also a few files of a completely different type (e.g., 95 images + 5 CSV codebooks)?
- What if the dominant extension is inherently ambiguous (`.txt`, `.dat`, `.log`) with no naming context to disambiguate?
- What if an aggregate folder is nested inside another aggregate folder?
- What if a participant aggregate contains both data files and per-participant scripts?

---

## Requirements

### Functional Requirements

- **FR-001**: The pipeline MUST detect aggregate folders using two patterns: (A) flat — more than `AGGREGATE_THRESHOLD` direct file children in one directory; (B) participant — more than `AGGREGATE_THRESHOLD` numeric-named immediate subdirectories.

- **FR-002**: Every extension group within an aggregate folder MUST be classified by the LLM. The extension rule map MAY be used as a validation signal but MUST NOT replace LLM classification.

- **FR-003**: The extension-to-type rule map MUST cover at minimum: common image formats → `asset`; common audio/video formats → `asset`; tabular data formats → `data`; code formats → `code`; compiled binary formats → `software`.

- **FR-004**: An aggregate folder MUST be split into extension groups before classification. Each distinct extension present in the folder forms its own group. Groups with a count above `AGGREGATE_THRESHOLD` produce a sentinel row; groups below that threshold are routed as individual files to LLM classification.

- **FR-005**: Files MUST inherit only the classification of their own extension group's sentinel — never the classification of a different extension group within the same folder. Sub-sentinel splitting by filename prefix series is removed; extension-based grouping replaces it.

- **FR-005a**: For each extension group, the pipeline MUST send up to 5 real representative paths from that group to the LLM for classification. No synthetic descriptor strings.

- **FR-006**: Aggregate classification MUST occur in a single LLM phase alongside non-aggregate files. There is no separate phase 2.

- **FR-007**: Each extension group within an aggregate folder MUST produce one sentinel row in `structure.csv` at classification time. Before any downstream consumer reads `structure.csv`, sentinel rows MUST be expanded to one row per member file, each carrying the sentinel's type and group. The final `structure.csv` contains only file-level rows — no sentinel rows persist past the expansion step.

- **FR-008**: The pipeline MUST provide an expansion function: given a sentinel row, produce one row per member file with the sentinel's type/group values propagated.

- **FR-009**: `psychds_convert.R` MUST call the expansion function before processing `structure.csv`, so all individual member files are available for the file-copy step.

- **FR-010**: The redesigned system MUST produce classification accuracy on test papers at least equal to the current system on all `sentinel_llm` source rows across the 20-paper test suite.

- **FR-011**: Files within an aggregate folder whose extension clearly differs from the dominant extension MAY be routed individually (singletons) to LLM classification rather than inheriting the folder's type. This is an optional refinement.

### Key Entities

- **Aggregate folder**: directory meeting the flat or participant threshold; treated as a classification unit rather than a collection of individual paths.
- **Sentinel row**: single row in `structure.csv` representing one extension group within an aggregate folder; carries `is_sentinel = TRUE`, `file_count`, `dominant_ext`, and `member_paths`. A folder may produce more than one sentinel row if it contains multiple extension groups that each exceed `AGGREGATE_THRESHOLD`.
- **Representative sample**: up to 5 real file paths drawn from an aggregate folder, used as LLM input when extension-rule classification does not apply.
- **Extension rule map**: lookup from lowercase extension to unambiguous type; covers only extensions where the correct type is certain regardless of filename or folder context.
- **Extension group**: the subset of files within an aggregate folder that share one extension. Groups ≥ `AGGREGATE_THRESHOLD` → sentinel; groups below → routed individually.

---

## Success Criteria

### Measurable Outcomes

- **SC-001**: `detect_series()` is removed entirely — zero occurrences in the codebase after implementation.

- **SC-002**: No synthetic descriptor strings of the form `folder/[prefix: "...", N files, .ext, samples: ...]` appear in LLM input during any test run.

- **SC-003**: Sentinel/aggregate logic in `0_index.R` and `helper.R` combined is reduced by ≥40% in lines compared to the current implementation.

- **SC-004**: `sentinel_llm` accuracy on the 20-paper test suite meets or exceeds the current benchmark (62.8% for `STRUCTURE_PROMPT_NEW`).

- **SC-005**: All 20 test papers pass `run_tests.R` without regression on type accuracy or group accuracy versus the current baseline.

- **SC-006**: PsychDS conversion for all test papers that have sentinel rows completes without missing files in the output directory.

- **SC-007**: LLM call count per paper for aggregate-heavy papers does not increase versus the current system.

---

## Assumptions

- `AGGREGATE_THRESHOLD` (currently 20) is retained unchanged; adjusting the threshold is out of scope.
- The two detection patterns (flat and participant) are correct — only the post-detection classification and storage steps change.
- The extension-to-type rule map replaces `AGGREGATE_EXT_OVERRIDE`. Its role is reduced to optional validation (e.g., flagging obvious LLM errors) — it no longer drives classification.
- Splitting by extension uses `AGGREGATE_THRESHOLD` as the group-size gate: groups of files ≥ threshold → sentinel; groups below → individual paths.
- `expand_sentinel_rows` in `3_psychds_convert.R` is the only downstream consumer that needs updating in this feature.
- The singleton refinement (FR-011) is optional for MVP; all members may initially inherit the folder type uniformly.
