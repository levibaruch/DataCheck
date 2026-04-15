# Feature Specification: LLM Prompt Refinements

**Feature Branch**: `033-llm-prompt-refinements`
**Created**: 2026-04-09
**Status**: Draft

## Overview

During ground-truth annotation of psychology research repositories, seven recurring misclassification patterns were identified in the file classification prompt. Each causes the pipeline to assign an incorrect `type` or `group` label — corrupting downstream outputs (structure.csv, psychDS conversion, codebook matching). This feature corrects all seven patterns through targeted additions and clarifications to the classification prompt. No pipeline logic changes are required.

---

## User Scenarios & Testing

### User Story 1 — Log files from experiment software classified as data (Priority: P1)

A researcher runs the pipeline on a paper that used PsychoPy or E-Prime to collect data. The software writes one `.log` file per participant containing trial-by-trial responses. These files are the primary raw data for the study.

**Why this priority**: Log files are one of the most common raw data formats for behavioural experiments. Currently they are classified as `output` (system log) — making them invisible to column extraction and psychDS conversion.

**Independent Test**: Run pipeline on a paper whose data folder contains `.log` files from an experiment (e.g., `session1.log`, `trial_data.log`). Verify structure.csv assigns `type = "data"` and `data_granularity = "individual"`.

**Acceptance Scenarios**:

1. **Given** a `.log` file in a folder clearly associated with experiment data (e.g., `data/`, `raw/`, folder named after the task), **When** the pipeline classifies it, **Then** it is labelled `type = "data"`.
2. **Given** a `.log` file whose filename contains a participant identifier (e.g., `sub01.log`, `p12_session2.log`), **When** classified, **Then** `type = "data"`, `data_granularity = "individual"`.
3. **Given** a `.log` file that is clearly a script execution log (e.g., `run_analysis.log`, `error.log` in a `logs/` folder), **When** classified, **Then** `type = "output"`.

---

### User Story 2 — Intermediate result files classified as data, not output (Priority: P1)

A researcher processes raw data through multiple cleaning and scoring steps. Each step writes an intermediate CSV (e.g., `scores_cleaned.csv`, `results_step1.csv`) that feeds into the next step. These are inputs to subsequent analyses, not final outputs.

**Why this priority**: Mislabelling intermediate files as `output` excludes them from column extraction. Researchers browsing the pipeline output cannot find variables from these files.

**Independent Test**: Run pipeline on a paper containing intermediate CSV files with "scores" or "results" in their name. Verify they are assigned `type = "data"` not `type = "output"`.

**Acceptance Scenarios**:

1. **Given** a tabular file (`.csv`, `.sav`, `.dta`, `.xlsx`) whose name contains "scores", "results", "processed", or "cleaned", **When** classified, **Then** `type = "data"` — not `type = "output"`.
2. **Given** a non-tabular file (`.html`, `.pdf`) whose name contains "results", **When** classified, **Then** `type = "output"` or `type = "supplemental"` as appropriate (the tabular-format correction does not apply).
3. **Given** a tabular file whose name contains "figure" or "plot", **When** classified, **Then** `type = "output"` (existing rule preserved).

---

### User Story 3 — Pretest data classified as experiment, not pilot (Priority: P2)

A researcher ran a pretest to norm stimuli or validate materials before the main study. The folder is named `pretest/` or files are named `pretest_data.csv`. Currently these are classified as `pilot` — implying the data was not used in the analysis — which is incorrect.

**Why this priority**: Affects `group` assignment in structure.csv. Incorrect `pilot` labels break psychDS study grouping and misrepresent the research design.

**Independent Test**: Run pipeline on a paper with a `pretest/` folder or files named `pretest_*.csv`. Verify structure.csv assigns `group = "ex<N>"` (or `group = "shared"` if no study number is present), not `group = "pilot1"`.

**Acceptance Scenarios**:

1. **Given** a folder named `pretest/` or a file named `pretest_data.csv`, **When** classified, **Then** `group` is not `"pilot1"` — it is either `"ex<N>"` (if a study number is present) or `"shared"`.
2. **Given** a folder named `pilot/` or a file named `pilot_run.csv`, **When** classified, **Then** `group = "pilot1"` (existing pilot rule preserved).
3. **Given** a folder named `pretest_study2/`, **When** classified, **Then** `group = "ex2"` (the study number takes precedence).

---

### User Story 4 — External / borrowed study data classified as data, not supplemental (Priority: P2)

A researcher reuses data from a previously published study as a comparison group or baseline. Files are named after the original study or year (e.g., `prior_study_data.csv`, `Smith2019_data.sav`). Currently these are labelled `supplemental`.

**Why this priority**: Misclassification hides valid data columns from extraction and inflates supplemental file counts.

**Independent Test**: Run pipeline on a paper containing files named with a prior-study pattern (year + data extension, or "prior_study" in name). Verify `type = "data"`.

**Acceptance Scenarios**:

1. **Given** a tabular file whose name contains a year and a data-format extension (e.g., `Smith2019_data.csv`, `study2_2018.sav`), **When** classified, **Then** `type = "data"`.
2. **Given** a tabular file described in context as replication or comparison data, **When** classified, **Then** `type = "data"`, not `type = "supplemental"`.
3. **Given** a PDF or Word document from a prior study, **When** classified, **Then** `type = "supplemental"` (the correction applies to tabular data files only).

---

### User Story 5 — Dummy and placeholder files classified as other (Priority: P2)

Some repositories contain clearly synthetic or example files included for documentation purposes (e.g., `example_data.csv`, `dummy.sav`, `test_output.csv`). These should not be indexed as research data.

**Why this priority**: Placeholder files pollute column extraction with meaningless variables and inflate file counts.

**Independent Test**: Run pipeline on a paper containing files named `example_data.csv` and `dummy.sav`. Verify `type = "other"` for both.

**Acceptance Scenarios**:

1. **Given** a file whose name starts with or contains "example", "dummy", or "placeholder", **When** classified, **Then** `type = "other"`.
2. **Given** a real data file whose name contains "test" as part of a meaningful compound (e.g., `implicit_association_test_data.csv`, `pretest_results.csv`), **When** classified, **Then** `type = "data"` (the rule does not fire when "test" is part of a research construct name).

---

### User Story 6 — Configuration files classified as software or other (Priority: P3)

Repositories contain configuration files for the experiment software (`.yaml`, `.cfg`, `.ini`, `.toml`) or for project tooling (`package.json`, `.eslintrc`). Experiment config should be `software`; tooling config should be `other`.

**Why this priority**: Experiment configuration files define task parameters and are part of the research materials. Misclassifying them inflates `other` or `code` counts.

**Independent Test**: Run pipeline on a paper containing `config.yaml` (experiment settings) and `package.json` (project tooling). Verify `config.yaml` → `software`, `package.json` → `other`.

**Acceptance Scenarios**:

1. **Given** a `.yaml`, `.cfg`, `.ini`, or `.toml` file inside a folder associated with the experiment (e.g., `task/`, `paradigm/`, `experiment/`), **When** classified, **Then** `type = "software"`.
2. **Given** `package.json`, `.eslintrc`, or similar tooling config at the root level, **When** classified, **Then** `type = "other"`.
3. **Given** a `.yaml` file whose name contains "analysis" or "model" (e.g., `model_params.yaml`), **When** classified, **Then** `type = "code"` — not `type = "other"`.

---

### User Story 7 — SQL files classified as data, not code (Priority: P3)

SQL files in psychology research repositories are almost exclusively data exports or database dumps, not query scripts. Currently they are classified as `code`.

**Why this priority**: Correct classification matters for reporting and psychDS conversion accuracy.

**Independent Test**: Run pipeline on a paper containing a `.sql` file. Verify `type = "data"` in structure.csv.

**Acceptance Scenarios**:

1. **Given** a `.sql` file in a research repository, **When** classified, **Then** `type = "data"`.
2. **Given** a `.sql` file whose name contains "query", "script", or "procedure", **When** classified, **Then** `type = "code"` (genuine analysis scripts are still code).

---

### Edge Cases

- A `.log` file inside a `logs/` folder at repo root should stay `output`, not become `data`.
- "pretest" in a filename where it means a statistical pre-test (e.g., `pretest_for_normality.R`) — the file is `code`; the `group` rule does not override type.
- A YAML file that is both analysis config and experiment config — classify as `software` if in an experiment folder, `code` if in a scripts/analysis folder.
- "test" in `implicit_association_test_data.csv` is a research construct, not a placeholder signal — must remain `data`.

---

## Requirements

### Functional Requirements

- **FR-001**: The classification prompt MUST classify `.log` files as `data` when folder context indicates experiment software output (folder named `data/`, `raw/`, or after a task name), regardless of whether a participant ID appears in the filename.
- **FR-002**: The classification prompt MUST classify tabular files (`.csv`, `.sav`, `.dta`, `.xlsx`, `.tsv`, `.dat`) with names containing "scores", "processed", or "cleaned" as `data` — not `output`.
- **FR-003**: The classification prompt MUST NOT assign `group = "pilot<N>"` to files whose name or folder contains "pretest". Pretest → experiment group or shared.
- **FR-004**: The classification prompt MUST classify tabular data files borrowed from prior studies (identified by "prior", "replication", or year-in-filename patterns alongside a tabular extension) as `data`, not `supplemental`.
- **FR-005**: The classification prompt MUST classify files with "example", "dummy", or "placeholder" in their name as `other`, with an explicit carve-out for compound names where these words are part of a research construct.
- **FR-006**: The classification prompt MUST classify `.yaml`, `.cfg`, `.ini`, and `.toml` files in experiment-associated folders as `software`, and project tooling configs as `other`.
- **FR-007**: The classification prompt MUST classify `.sql` files as `data` by default, with a carve-out for files explicitly named as query or procedure scripts.
- **FR-008**: All seven corrections MUST be expressed as hard-case disambiguation rules in the existing "Hard cases" section of `STRUCTURE_PROMPT` — not as changes to the type definitions.
- **FR-009**: Existing correct behaviours MUST be preserved: `.log` with participant ID → `data`; tabular files with "figure"/"plot" → `output`; `pilot` folders → `pilot<N>`; `package.json` → `other`.

### Key Entities

- **Classification prompt** (`STRUCTURE_PROMPT` in `prompts.R`): The text sent to the LLM for Phase 1 individual file classification. Only this artefact is modified by this feature.
- **Hard case rule**: A single disambiguation entry in the "Hard cases" section, expressing a filename/folder pattern → type/group assignment.

---

## Success Criteria

### Measurable Outcomes

- **SC-001**: On the existing GT paper set, the number of misclassified `.log` files assigned `type = "output"` or `type = "other"` drops to zero for files in data-associated folders.
- **SC-002**: Tabular files with "scores", "processed", or "cleaned" in their names are assigned `type = "data"` in 100% of GT papers where they appear.
- **SC-003**: No file with "pretest" in its name or folder path is assigned `group = "pilot<N>"` across the GT paper set.
- **SC-004**: Overall GT accuracy on `type` classification (measured by `report_normal.R`) does not decrease after this change — any regression is a failing criterion.
- **SC-005**: The seven new rules produce no contradictions on any GT paper.

---

## Assumptions

- All seven corrections are prompt text additions only — no changes to `0_index.R`, `helper.R`, or any other pipeline file.
- `AGGREGATE_EXT_OVERRIDE` (which overrides LLM results during sentinel expansion) is **not** modified here — that is addressed in feature 034.
- The "Hard cases" section of `STRUCTURE_PROMPT` is the correct location for all new rules; type definition blocks are not changed.
- SQL column extraction is out of scope — `.sql` files classified as `data` will receive `data_format = "raw"` from `classify_data_format()`, so no column extraction will occur.
- `SENTINEL_PROMPT` (used for aggregate folder classification) may need parallel updates for some rules; this is a stretch goal within this feature.
