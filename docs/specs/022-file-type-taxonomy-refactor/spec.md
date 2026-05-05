# Feature Specification: File Type & Group Taxonomy Refactor

**Feature Branch**: `022-file-type-taxonomy-refactor`
**Created**: 2026-03-26
**Status**: Draft
**Input**: User description: "Refine file type/group taxonomy and classification prompt"

## Clarifications

### Session 2026-03-26

- Q: Should `doc` and `supplemental` be kept separate, merged, or split further? → A: Keep separate with sharper definitions; `doc` definition must explicitly exclude `codebook` and `readme` to prevent confusion.
- Q: Is backward compatibility for existing CSVs required? → A: No — all papers will be re-run; FR-011 removed.
- Q: Which batch strategy should be used for cross-batch group label consistency? → A: A+C — moderate batch size increase (20 → 30–40 files) combined with an incremental structure summary header passed to each subsequent batch call.
- Q: Does the 50-file reference annotation set for SC-001 pre-exist or must it be created? → A: Skip the manual set — existing validation GUI and ground truth CSVs are used instead; ground truth labels must be updated to reflect the new taxonomy definitions before validation runs count as acceptance evidence.
- Q: Should `pilot<N>` group values allow alphanumeric suffixes (e.g., `pilot1a`)? → A: Yes — suffixes must be preserved exactly; `pilot1a` and `pilot1b` are distinct valid group values.
- Q: Should extension-based override rules be audited and updated as part of this feature? → A: Yes — audit all overrides for conflicts with new definitions, update them, and add a `type_source` column (`rule`/`llm`) to `structure.csv` for transparency.
- Q: How should `asset` distinguish participant-facing stimuli from result figures? → A: `asset` = participant-facing sensory material only (images/audio/video shown to participants during the study). Result figures, output plots, and saved graphs → `supplemental`.
- Q: How should `.Rmd`/`.qmd` files be classified? → A: Always `code` — they are executable source files regardless of narrative content; the knitted output (if present) is the document.
- Q: Is the `readme` type name-based or content-based? → A: Name-based only — `readme` = files named `README.*`, `LICENSE.*`, or `CONTRIBUTING.*`. Classify by filename alone; if the filename is not one of these, it is not `readme`. Note: a file like `study_overview.pdf` that primarily describes variables should be considered for `codebook` classification.
- Q: What decision rule should the LLM use to classify `codebook` for ambiguous filenames? → A: Primary-purpose inference — classify as `codebook` when the filename/path most plausibly indicates the file's main purpose is describing variables or coding; ambiguous files default to `doc` or `supplemental`. Future note: if no `codebook`-type file is detected for a paper, consider a fallback pass that re-examines `supplemental` and `doc` files for embedded variable descriptions (deferred to a future feature).
- Q: Should non-tabular research measurement files (e.g., `.edf`, `.acq`, `.mat`, physiological recordings) be classified as `data`? → A: Yes — `data` = any file containing research measurements intended for analysis, including non-tabular formats. Column extraction simply skips what it cannot parse. These files will need `is_raw = TRUE` labelling downstream.
- Q: Should image/audio/video entries in `AGGREGATE_EXT_OVERRIDE` be fixed (they currently force all such files to `"asset"` even when they are result figures)? → A: Deferred — a proper fix requires a sentinel system rewrite, not a band-aid on the override table. `AGGREGATE_EXT_OVERRIDE` entries remain as-is for this feature.
- Q: Should `STRUCTURE_PROMPT` be restructured to separate type/group definitions from disambiguation rules? → A: Yes — clean type definitions first, clean group definitions second, then a dedicated disambiguation/tiebreaker section after all definitions. Tiebreakers must not reference types before those types are defined.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Unambiguous file type assignment (Priority: P1)

A researcher running the pipeline on a psychology OSF repo should see every file classified into exactly one type with no ambiguity between `doc` and `supplemental`, and no file landing in `other` because the definitions are unclear.

**Why this priority**: The overlap between `doc`/`supplemental` and between `other` (type) and `na` (group) is the root cause of misclassifications. Fixing the taxonomy is foundational — everything downstream (quality reports, validation, ground truth labelling) depends on correct type assignments.

**Independent Test**: Run the pipeline on 5 known repos and manually verify that every file has a type that matches the new definitions with no "which bucket?" ambiguity.

**Acceptance Scenarios**:

1. **Given** a preregistration PDF, **When** the pipeline classifies it, **Then** it is assigned `supplemental`, never `doc`.
2. **Given** a manuscript or results report PDF, **When** the pipeline classifies it, **Then** it is assigned `doc`, never `supplemental`.
3. **Given** a `.DS_Store` or `Thumbs.db` file, **When** the pipeline classifies it, **Then** it is assigned `other`, not `supplemental` or `doc`.
4. **Given** a SPSS `.sps` syntax file (showing analysis results), **When** the pipeline classifies it, **Then** it is assigned `supplemental`, not `code`.
5. **Given** an `.R` or `.py` analysis script, **When** the pipeline classifies it, **Then** it is assigned `code`, not `supplemental`.

---

### User Story 2 — Unambiguous group assignment (Priority: P1)

Every file with a meaningful research role receives either an experiment-specific group (`ex<N>`, `pilot<N>`) or the group `shared` (spans experiments or belongs to the project as a whole). Files for which experiment grouping is irrelevant receive `na`. The groups `shared` and `na` are never interchangeable.

**Why this priority**: The current group `other` (not tied to a specific experiment) and group `na` (group not applicable) overlap in practice — both get used for files that don't belong to a specific experiment. This ambiguity causes inconsistent outputs that break downstream aggregation and quality reporting.

**Independent Test**: Pick a repo with a mix of experiment-specific files, shared project files, and readmes. Verify that `na` appears only on `readme`, `asset`, and `other` type files; `shared` appears on cross-experiment research files; and `ex<N>` / `pilot<N>` appear on experiment-specific files.

**Acceptance Scenarios**:

1. **Given** a `README.md`, **When** classified, **Then** group is `na`.
2. **Given** an image stimulus file (`asset` type), **When** classified, **Then** group is `na`.
3. **Given** a combined dataset covering all experiments, **When** classified, **Then** group is `shared`, not `na`.
4. **Given** a project proposal document, **When** classified, **Then** group is `shared`, not `na`.
5. **Given** a data file named `Study_2_data.csv`, **When** classified, **Then** group is `ex2`.
6. **Given** a file of type `other` (e.g., `.DS_Store`), **When** classified, **Then** group is `na`.

---

### User Story 3 — Consistent experiment numbering across large repos (Priority: P2)

When a repo contains more than 20 files, all files from the same experiment receive the same group label (e.g., all `ex1` files are `ex1`, never a mix of `ex1` and `shared`) regardless of which LLM batch they appear in.

**Why this priority**: The current 20-file batch limit means the LLM may not see enough context to consistently assign group labels. A file named `Study_1_data.csv` in batch 1 and a file in an `Experiment_1/` folder in batch 2 should both yield `ex1`.

**Independent Test**: Run the pipeline on a repo with 60+ files spanning 3 experiments. Verify group labels are consistent — no experiment's files are split between `ex2` and `shared`.

**Acceptance Scenarios**:

1. **Given** a repo with 60 files across 3 experiments, **When** classified in batches, **Then** all files from Experiment 2 get `ex2` regardless of which batch they appeared in.
2. **Given** a repo where experiment folders appear only in early batches, **When** later batches are classified, **Then** their group labels are consistent with the experiment structure from earlier batches.

---

### Edge Cases

- A file inside a `Supplemental Experiment 1` folder — should be `shared`, not `ex1` (existing rule, must be preserved).
- A file that genuinely cannot be classified into any research category — should be `other` / `na`, never silently receive a wrong type.
- A repo with no numbered experiments (single-study, no experiment numbering) — all research files get `shared`.
- Files with ambiguous names (e.g., `analysis.csv` — data or codebook?) — extension-based heuristics apply before LLM.
- Pilot files with letter suffixes (e.g., `Pilot_1a`) — must produce `pilot1a`, not `pilot1`.
- The old group value `other` in existing output CSVs — must be handled without breaking reads.
- An image file in a `Figures/` folder (result graph, bar chart) — must be `supplemental`, not `asset`.
- An audio file of interview recordings — `data` if used for analysis, `asset` if used as a stimulus in the study.
- A `study_overview.pdf` that describes repo navigation AND lists variable meanings — `codebook` takes priority if variable descriptions are the primary content; `doc` if the variable content is incidental.
- An `.edf` or `.acq` physiological recording file — `data` (non-tabular measurement data); column extraction skips it but `is_raw = TRUE` applies downstream.
- A `.mat` file — `data` if the filename/folder context suggests research measurements; `code` if the filename suggests a script or stimulus matrix.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The `type` taxonomy MUST define values with mutually exclusive, exhaustive definitions such that any given file fits into exactly one type with no overlap between categories.
- **FR-002**: The `doc` type MUST be restricted to narrative documents written *for human readers* about research outcomes or project context: manuscripts, journal articles, papers, reports of findings, project proposals, lab notebook entries, research decision logs, and general prose notes. The litmus test: "Is this a document a journal reviewer or committee member would read to understand the research findings?"
- **FR-003**: The `supplemental` type MUST cover all research-process support materials that are not data for analysis: survey instruments, questionnaires, consent forms, preregistrations, SPSS/STATA syntax files, HTML result output files, saved plot objects, result figures and output graphs saved as image files, and supporting appendices. The key distinguishing question is "does this support or document the research process?" (supplemental) vs. "does this report the conclusions?" (doc).
- **FR-003b**: The `asset` type MUST be restricted to participant-facing sensory material — images, audio, and video files that were presented to participants during the study (e.g., stimulus pictures, rating-scale images, video clips shown in trials). Result figures, output plots, and graphs documenting research outcomes MUST be classified as `supplemental`, not `asset`. The litmus test: "Would a participant see or hear this file during the study?" — if yes, `asset`; if it documents a result or supports the research process, it is not `asset`.
- **FR-004**: The `other` type MUST be reserved for files with no research content: OS metadata files (`.DS_Store`, `Thumbs.db`), package lock files, environment configuration files, binary executables, and installer files. It MUST NOT be used as a catch-all for ambiguous research files.
- **FR-005**: The group value `other` MUST be renamed to `shared` to eliminate the naming collision with the `other` type value.
- **FR-006**: The group value `na` MUST be restricted to exactly three file types: `readme`, `asset`, and `other`. All other types (`data`, `codebook`, `code`, `supplemental`, `doc`) MUST receive `ex<N>`, `pilot<N>`, or `shared` — never `na`.
- **FR-007**: The group value `shared` MUST be used for meaningful research files not tied to a specific numbered experiment or pilot — including combined datasets, project-wide scripts, meta-analyses, and project proposals.
- **FR-008**: The LLM batch strategy MUST be updated to improve cross-batch group label consistency for large repos using two complementary mechanisms: (a) **moderate batch size increase** — raise from 20 to 30–40 files per call to reduce the total number of batches and improve within-batch context; and (b) **incremental structure summary header** — each batch call after the first MUST include a compact, running summary of experiment/folder structure inferred from prior batch responses, so later batches have the context needed to assign consistent group labels. Batch size MUST NOT be pushed so high that attention degradation for tail items outweighs the consistency benefit; the final value should be empirically validated during implementation.
- **FR-008b**: The `pilot<N>` group value MUST support alphanumeric suffixes (e.g., `pilot1a`, `pilot1b`). The suffix MUST be preserved exactly as it appears in the filename or folder — letter suffixes MUST NOT be stripped or collapsed to the numeric part.
- **FR-009**: The updated taxonomy definitions MUST be reflected in the `STRUCTURE_PROMPT` in `pipeline/0_index.R`. All 8 types MUST have thorough definitions with litmus-test language comparable to FR-002/FR-003/FR-004. Specifically:
  - `data`: "any file containing research measurements intended for analysis — tabular (csv, sav, xlsx, etc.) OR non-tabular (`.edf`, `.acq`, `.bdf` physiological recordings, `.mat` matrices, nested `.json` survey exports). Column extraction skips formats it cannot parse; the file remains classified as `data` and should be flagged `is_raw = TRUE`. Litmus test: 'Does this file contain measurements collected from participants or instruments for the purpose of analysis?'"
  - `codebook`: "variable dictionary, data dictionary, or coding guide whose *primary purpose* is describing what variables mean — NOT the data itself." LLM uses primary-purpose inference from the filename/path. Explicitly excludes: (a) README files that describe the repo, (b) results documents or methods documents that mention variables incidentally. When in doubt, default to `doc` or `supplemental` rather than `codebook`.
  - `code`: "executable source file — R, Python, MATLAB, Julia, SQL, shell scripts, `.Rmd`/`.qmd` notebooks. Litmus test: 'Can this file be run or sourced?' — if yes, `code`. `.Rmd`/`.qmd` files are always `code` regardless of narrative content; the knitted output (HTML/PDF) is `doc` or `supplemental`."
  - `readme`: files named `README.*`, `LICENSE.*`, or `CONTRIBUTING.*` only. Classify by filename — if the filename is not one of these, it is not `readme`.
  - `asset`: participant-facing sensory material only (see FR-003b). Litmus test: "Would a participant see or hear this during the study?"
- **FR-009c**: All extension-based override rules MUST be audited against the new type definitions and updated where they conflict (e.g., `.sps` must map to `supplemental`, not `code`). Every file whose type was determined by an override rule MUST have this recorded — the `structure.csv` output MUST include a `type_source` column with value `rule` (override applied) or `llm` (LLM assignment accepted), so downstream consumers can distinguish the two.
- **FR-009b**: All existing `ground_truth/<paper_id>.csv` files MUST be reviewed and re-labelled where the new type/group definitions change the correct answer. The validation GUI MUST reflect the updated allowed values for `type` and `group`.
- **FR-010**: The updated taxonomy MUST be documented in `docs/output-schemas.md` with: (a) the new `shared` group replacing `other`, (b) the new `type_source` column added to the `structure.csv` schema, and (c) the updated `pilot<N>` format noting alphanumeric suffixes are permitted.
- ~~**FR-011**: Existing pipeline output CSVs that contain the old group value `other` MUST remain readable.~~ **Removed** — no backward compatibility required; all papers will be re-run after the refactor.

### Key Entities

- **File type**: The classification of a repository file's content role (`data`, `codebook`, `code`, `supplemental`, `doc`, `readme`, `asset`, `other`). Exactly one per file, mutually exclusive.
- **File group**: The experiment/study scope a file belongs to (`ex<N>`, `pilot<N>`, `shared`, `na`). Exactly one per file, mutually exclusive. Determined primarily by folder structure and filename, not file content.
- **STRUCTURE_PROMPT**: The LLM system prompt that defines all classification rules. Single source of truth for type and group definitions.
- **Batch strategy**: The decision of how many file paths to send per LLM call and how cross-batch context is preserved.
- **type_source**: New column in `structure.csv`. Value is `rule` when an extension-based override determined the final `type`, or `llm` when the LLM assignment was accepted unchanged.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The existing validation tooling (validation GUI + ground truth CSVs) is used to verify taxonomy correctness. Because type and group definitions are changing, the ground truth labels in existing `ground_truth/<paper_id>.csv` files MUST be reviewed and updated to reflect the new taxonomy before validation runs are used as acceptance evidence.
- **SC-002**: Zero files in any new pipeline output use the group value `other` — all are classified as `shared` or `na` under the new taxonomy.
- **SC-003**: For repos with 20+ files, experiment group labels are internally consistent — files that clearly belong to the same experiment never receive different group labels.
- **SC-004**: In a reference annotation exercise, `doc` and `supplemental` have zero disputed cases — every test file is assignable to one or the other without disagreement.
- **SC-005**: The proportion of files classified as `other` type across the corpus falls below 5% (targeting meaningful reduction from current baseline where `other` is used as a catch-all).

## Assumptions

- The 8 current type values (`data`, `codebook`, `code`, `supplemental`, `doc`, `readme`, `asset`, `other`) are all preserved — only their boundary definitions are sharpened (types are not fixed and may be adjusted, but no new types are required at this time).
- Renaming the group `other` → `shared` is a breaking change to existing CSVs; **no backward compatibility is required** — all papers will be re-processed after the refactor.
- The LLM batch size (currently 20 files per call) is an empirical question: the spec requires evaluation and adjustment if inconsistencies are found, but does not mandate a specific batch size.
- Extension-based override rules (applied after LLM classification) remain in place and are the authoritative tie-breaker for unambiguous extensions.
- Column-level classification (`col_type`) is out of scope for this feature.
- The `COLUMN_TYPE_PROMPT` and column classification pipeline are unaffected.
- A fallback mechanism to re-examine `supplemental` and `doc` files for embedded variable descriptions (when no `codebook` is detected for a paper) is **out of scope** for this feature and deferred to a future feature.
