# Feature Specification: Pipeline Output Transparency

**Feature Branch**: `041-pipeline-output-transparency`  
**Created**: 2026-04-23  
**Status**: Draft  
**Input**: User description: "an expert has analysed the output of our main workflow for transparency. They have written a report based on it data_check/docs/terminal_output_analysis.md. Write a spec for this report to improve transparency and trustworthyness"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Dataset-Level Verdict (Priority: P1)

A researcher running the pipeline on a dataset needs to know immediately whether the dataset processed successfully, partially succeeded, or failed — and why. Currently the terminal output logs many events but never delivers a final verdict, leaving the researcher unable to judge whether results are usable without manually reading all prior output.

**Why this priority**: Without a clear outcome signal, the researcher cannot trust or act on pipeline results. This is the most fundamental gap identified by the expert review.

**Independent Test**: Run the pipeline on one dataset and verify a single final status line (e.g. `[SUCCESS]`, `[PARTIAL]`, `[FAILED]`) appears at the end with a brief explanation. Delivers standalone value — the researcher knows whether to use the output.

**Acceptance Scenarios**:

1. **Given** a dataset that completes all stages without errors, **When** the pipeline finishes, **Then** a `[SUCCESS]` verdict is printed with a one-line summary of key counts (files classified, columns extracted).
2. **Given** a dataset where some stages fail (e.g. psychDS conversion errors), **When** the pipeline finishes, **Then** a `[PARTIAL]` verdict is printed listing which stages succeeded and which failed.
3. **Given** a dataset where a critical early stage fails (e.g. download failure, no data files found), **When** the pipeline finishes, **Then** a `[FAILED]` verdict is printed with the root cause in plain language.
4. **Given** a `skipped — no columns.csv` event, **When** it occurs, **Then** the output clarifies whether this is expected behavior or a problem.

---

### User Story 2 - Explainable LLM Decisions (Priority: P2)

A researcher sees that a file was classified as `data / ex2 combined` by the LLM. They need to understand what drove that decision — what inputs the LLM used and what the key reasoning was — so they can assess whether to trust it or flag it for review.

**Why this priority**: LLM decisions affect the entire downstream pipeline (column extraction, codebook matching, PsychDS conversion). Opacity here undermines trust in all subsequent results.

**Independent Test**: Run the pipeline on a dataset and verify that each classification line indicates whether the decision was made by the rule engine or the LLM, with no additional LLM calls added for explanation purposes.

**Acceptance Scenarios**:

1. **Given** a file classified by the rule engine, **When** the classification is printed, **Then** the output indicates the method used (e.g. `[rules]`).
2. **Given** a granularity decision (individual vs combined), **When** it is printed, **Then** the basis for the decision is shown (e.g. `[rules]` for a regex match, `[LLM]` for an LLM-inferred result).

---

### User Story 3 - Silent Failures Become Explicit Warnings (Priority: P2)

A researcher sees `Extracting columns + statistics from 0 data file(s)` and `No columns extracted` — despite `data=154` files being classified earlier. Currently there is no explanation of why extraction was skipped. The researcher cannot distinguish between expected behavior (unsupported format) and a bug.

**Why this priority**: Silent failures are the most common source of mistrust. Researchers need to know when something went wrong, what went wrong, and whether it matters.

**Independent Test**: Run the pipeline on a dataset with files in unsupported formats and verify that a warning message is printed for each skipped file, explaining the skip reason.

**Acceptance Scenarios**:

1. **Given** data files exist but zero columns are extracted, **When** extraction finishes, **Then** a `[WARNING]` message lists why each file was skipped (unsupported format, parsing error, file empty, size limit exceeded).
2. **Given** a structured extraction fails and fallback to LLM is triggered, **When** the fallback occurs, **Then** a message explains what failed and what the fallback will attempt differently.
3. **Given** a retry occurs (e.g. `retry 1/4`), **When** it is logged, **Then** the reason for the retry is included (e.g. "LLM returned malformed JSON", "timeout on attempt 1").
4. **Given** psychDS conversion fails with an internal error, **When** it is logged, **Then** the message is translated into plain language explaining what was attempted and why it failed.

---

### User Story 4 - Interpretable Metrics and Cross-Stage Context (Priority: P3)

A researcher sees `labelled=1 unlabelled=78 status=ok` and `coverage: {"unmatched_in_data":10,"matched":1}`. The raw numbers and `ok` status give no actionable context. The researcher needs metrics displayed in a way that lets them draw their own conclusions, and needs the pipeline to explain cross-stage situations that are confusing but expected.

**Why this priority**: Raw numbers without framing (percentages, context for known-expected situations) reduce trust and force researchers to do mental arithmetic. Lower priority than verdicts and failure messages, but important for overall result quality assessment.

**Independent Test**: Run the pipeline on a dataset and verify that codebook coverage is shown as a percentage, and that if zero columns are extracted despite data files existing, the output explains the expected reason.

**Acceptance Scenarios**:

1. **Given** codebook coverage is computed, **When** it is printed, **Then** match rate is shown as a human-readable fraction and percentage (e.g. `coverage: matched=1/11 (9%)`) rather than raw JSON — no warning threshold applied; the researcher interprets the number.
2. **Given** data files are detected in indexing but zero columns are extracted in the column stage, **When** extraction finishes, **Then** the output explains that the pipeline currently indexes only combined-granularity files, so individual-granularity datasets will produce zero extracted columns by design.

---

### User Story 5 - Defined Terminology (Priority: P3)

A researcher encounters terms like `granularity: individual`, file types `suppl`/`softw`/`output`, and group names `ex6b`/`sharedex4b`. These are exposed without definition, requiring the researcher to consult source code or documentation to understand what they mean.

**Why this priority**: Undefined terminology reduces trust and forces researchers outside the terminal to find meaning. Lower priority than actionable signals, but important for overall researcher experience.

**Independent Test**: Run the pipeline and verify that at least one definition or legend is printed when a domain-specific term first appears.

**Acceptance Scenarios**:

1. **Given** `granularity` is printed for the first time in a run, **When** the value is shown, **Then** the meaning of `individual` vs `combined` is explained in one line (e.g. "individual = one file per participant; combined = multiple participants in one file").
2. **Given** file type categories are assigned, **When** types appear in output, **Then** a legend line explains the categories used (data, asset, suppl, code, softw, output, other) at the start of the classification stage.
3. **Given** group inference runs (ex1, ex2, pilot1, sharedex4b, etc.), **When** groups are reported, **Then** the basis for grouping is stated (e.g. "groups inferred from folder names").

*(Note: Progress bar accuracy is deferred — fixing `1/1` display requires resolving retry and batch-count dependencies first.)*

---

### Edge Cases

- What verdict is shown when the pipeline is interrupted mid-run vs. completes with errors?
- What if codebook coverage is 0/0 (no codebook present at all) — should coverage line be omitted entirely or shown as `matched=0/0`?
- What happens when a dataset has only unsupported file formats — `[FAILED]` or `[PARTIAL]`?
- What if a dataset is entirely individual-granularity — should the "only combined files indexed" explanation appear, or is this only shown when data files were detected but zero columns extracted?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Pipeline MUST print a final per-dataset verdict (`[SUCCESS]`, `[PARTIAL]`, or `[FAILED]`) at the end of each paper's run, with a one-line plain-language summary.
- **FR-002**: Pipeline MUST indicate the classification method (rule-based or LLM) for each file type and granularity decision in the terminal output, with no additional LLM calls introduced.
- **FR-003**: Pipeline MUST print a message whenever a data file is skipped during column extraction, stating the skip reason (unsupported format, parsing error, size limit, empty file).
- **FR-004**: Pipeline MUST translate known internal stage errors (e.g. row-count mismatch in psychDS) into plain-language messages before printing.
- **FR-005**: Pipeline MUST display codebook coverage as a human-readable fraction and percentage (e.g. `matched=1/11 (9%)`), replacing the raw JSON format.
- **FR-006**: Pipeline MUST explain when zero columns are extracted despite data files existing, noting that the pipeline currently indexes only combined-granularity files.
- **FR-007**: Pipeline MUST print a one-line definition or legend for domain-specific terms (`granularity`, file type categories, group inference basis) when they first appear in a run.
- **FR-008**: Pipeline MUST explain retry and fallback events with a reason at the time they occur.

### Key Entities

- **Dataset Run**: One execution of the pipeline for a single paper ID — has a final verdict, a list of stage outcomes, and summary statistics.
- **Stage Outcome**: The result of one pipeline stage (index, classify, extract columns, label, psychDS) — can be success, partial, failed, or skipped, with a reason.
- **Transparency Event**: Any classification decision, warning, error, or metric surfaced to the researcher — must carry enough context to be interpreted without reading source code.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After each pipeline run, a researcher can determine whether a dataset's output is usable within 5 seconds of the run completing, without scrolling back through prior output.
- **SC-002**: Every file classification in the terminal output indicates whether the decision was made by rules or LLM, with no increase in LLM call count.
- **SC-003**: Zero silent failures — every skipped file, fallback trigger, and retry produces an explanatory message in the terminal output.
- **SC-004**: Codebook coverage is always shown as a readable fraction and percentage; researchers can assess match quality without manual calculation.
- **SC-005**: When zero columns are extracted despite data files being present, the output explains the expected cause (combined-only indexing), eliminating researcher confusion about this known pipeline behaviour.
- **SC-006**: A researcher encountering the output for the first time can correctly define `granularity`, the file type categories, and the grouping logic based solely on the terminal output, without consulting external documentation.

## Assumptions

- Improvements are to terminal/console output only — no changes to CSV output schemas, file structure, or LLM prompts.
- No new LLM calls are introduced for transparency purposes; classification method labelling (FR-002) uses metadata already available at decision time.
- Plain-language translation of internal errors (FR-004) covers the recurring patterns identified in the expert report; exhaustive coverage of all possible R errors is out of scope.
- The pipeline currently indexes only combined-granularity files for column extraction; individual-granularity datasets producing zero extracted columns is expected behaviour (FR-006).
- Progress bar accuracy (always shows `1/1`) is deferred to a future feature due to dependencies on retry and batch-count tracking logic.
- The `[SUCCESS]` / `[PARTIAL]` / `[FAILED]` verdict taxonomy (FR-001) assumes that stage-level success/failure state is already tracked internally and can be summarised at run end.
- `status=ok` in codebook labelling reflects that the labelling stage ran without errors, not that coverage was high; this is correct and should be preserved — coverage quality is surfaced separately via the percentage display (FR-005).
