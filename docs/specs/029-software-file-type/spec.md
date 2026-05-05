# Feature Specification: Software File Type Clarification

**Feature Branch**: `029-software-file-type`  
**Created**: 2026-04-02  
**Status**: Draft  
**Input**: User description: "within the 0_index file types, there is overlap in the code, other and supplemental; software that was written/used for the experiment. Add this to the prompts, workflow and the GUI/coding of the validation GUI."

## Background

The current file-type taxonomy (`code`, `other`, `supplemental`) leaves experimental software ambiguous. The canonical distinction between `code` and `software` is **purpose-based**:

- `code`: files whose purpose is to generate research outputs or run analyses — analysis scripts, data cleaning scripts, statistical modelling files, rendering notebooks.
- `software`: files that run code for any purpose *other than* producing analyses — experiment presentation programs, stimulus delivery tools, task runners, data collection applications, and the compiled/packaged artefacts of those programs.

Under this definition, a PsychoPy `.py` file that presents stimuli to participants is `software`, while an analysis `.py` script that processes the resulting data is `code`. The current taxonomy has no `software` type, so these files fall into `other` (OS junk) or `supplemental` (research documents) — neither of which is correct.

Annotators in the validation GUI currently encounter this ambiguity and have no consistent answer. This feature introduces explicit handling for experimental software across the full pipeline: classification rules, LLM prompts, and the validation GUI.

## Clarifications

### Session 2026-04-02

- Q: What is the defining distinction between `code` and `software`? → A: `code` is used to generate outputs/analyses; `software` is anything else that runs code (e.g., experiment presentation, data collection, task delivery tools).
- Q: How does the classifier determine purpose for source-language files with ambiguous names? → A: The LLM already receives the full relative file path (not just filename), so folder context is always available. For non-aggregate files, the LLM is the only classifier — there is no rule-based pre-classification. For aggregate files, `AGGREGATE_EXT_OVERRIDE` applies post-LLM; compiled-binary extensions must be added to that map.
- Q: How should notebooks (`.ipynb`, `.Rmd`, `.qmd`) that contain a mix of analysis and experiment-delivery code be classified? → A: Always `code` — notebooks are always analysis artefacts regardless of content.
- Q: Should existing source-language entries (`.py`, `.r`, `.m`, etc.) in `AGGREGATE_EXT_OVERRIDE` be changed? → A: Leave as `"code"` for now — accept rare mis-labelling of experiment source files inside aggregates; annotators can correct via GUI. Revisit later.
- Q: Should `software` appear in the validation GUI's file-list filter panel as well as the labelling buttons? → A: Yes — add to both labelling buttons and the filter panel.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Automatic Classification of Experimental Software (Priority: P1)

A researcher deposits experiment task files alongside their data — whether compiled binaries or source-language scripts that run the experiment rather than analyse data. The pipeline should classify these files as `software` without requiring human review.

**Why this priority**: This is the root cause of the ambiguity. Fixing automatic classification prevents systematic mis-labelling before any human validation step is needed.

**Independent Test**: Run the pipeline on a paper that includes experiment task programs (compiled or source-language); verify that `structure.csv` contains `type = "software"` for those files and `type = "code"` for analysis scripts.

**Acceptance Scenarios**:

1. **Given** a paper repo containing a compiled `.exe`, `.app`, or `.jar` experiment program, **When** the pipeline classifies files, **Then** those files receive `type = "software"` in `structure.csv`.
2. **Given** a paper repo containing a source-language file (e.g., `run_task.py`, `experiment.m`) whose purpose is to deliver the experiment to participants, **When** the pipeline classifies files, **Then** that file receives `type = "software"`.
3. **Given** an analysis script (e.g., `analysis.R`, `clean_data.py`) whose purpose is to process or model research data, **When** the pipeline classifies files, **Then** that file retains `type = "code"`.

---

### User Story 2 — LLM Prompt Correctly Distinguishes Software from Code and Other (Priority: P2)

When rule-based classification cannot resolve a file's type, the LLM prompt must describe `software` clearly enough that the model chooses it over `code`, `supplemental`, or `other` for experimental software.

**Why this priority**: Most ambiguous cases reach the LLM. Without updated prompt definitions, the new type will never be selected by the model even if it exists in the enum.

**Independent Test**: Submit test filenames that represent experimental software to the LLM using the updated prompt; verify the model returns `"software"` consistently and does not confuse it with `code`.

**Acceptance Scenarios**:

1. **Given** a filename like `run_task.py`, `ExperimentTask.exe`, `StimulusApp.app`, or `paradigm.m`, **When** the LLM classifies it, **Then** the returned type is `"software"`.
2. **Given** a filename like `analysis.R`, `clean_data.py`, or `model_fit.m`, **When** the LLM classifies it, **Then** the returned type is `"code"`, not `"software"`.
3. **Given** a filename like `.DS_Store` or `Thumbs.db`, **When** the LLM classifies it, **Then** the returned type remains `"other"`, not `"software"`.

---

### User Story 3 — Validation GUI Exposes Software Type for Manual Correction (Priority: P3)

When a human annotator reviews a file in the validation GUI and believes the automatic classification is wrong (e.g., an experiment task script was labelled `code`), they can reassign it to `software` using a labelled button and keyboard shortcut.

**Why this priority**: The GUI is the human quality-control layer. Without a `software` button, annotators are forced to pick the least-wrong existing type.

**Independent Test**: Open the validation GUI with a paper containing mis-labelled experimental software; verify a `software` button is present, clickable, keyboard-accessible, and that the correction persists in the ground truth CSV.

**Acceptance Scenarios**:

1. **Given** the validation GUI is open, **When** the annotator views any file, **Then** a `software` type button is visible alongside existing type buttons.
2. **Given** the annotator clicks the `software` button or presses its assigned keyboard shortcut, **When** the action completes, **Then** the file's type in the ground truth CSV updates to `"software"`.
3. **Given** the `software` button is active for a selected file, **When** rendered in both light and dark mode, **Then** the button displays consistent, visually distinct styling matching the badge design pattern used for other types.

---

### Edge Cases

- What happens when a source-language file (e.g., `.py`, `.R`, `.m`) could plausibly be either an experiment task or an analysis script? The LLM receives the full relative path (e.g., `experiment/run_task.py` vs `analysis/clean_data.py`) and infers purpose from folder + filename context. No separate rule-based folder heuristic is needed for source files.
- How does the pipeline handle experiment-related `.jar`, `.exe`, or `.app` files in stimuli or asset folders? File type takes precedence over folder location for these formats — they are always `software`.
- What if a dependency file (e.g., `requirements.txt`, `environment.yml`) could plausibly support either an experiment tool or an analysis environment? If the containing folder is named `software`, `experiment`, `task`, or `paradigm`, classify as `software`; otherwise fall back to `other`.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The classification system MUST recognise a `software` file type, distinct from `code`, `other`, and `supplemental`.
- **FR-002**: The classification system MUST distinguish `code` from `software` by **purpose**: files whose purpose is to generate research outputs or run analyses are `code`; files whose purpose is to run the experiment itself (stimulus delivery, data collection, task presentation) are `software`. Notebooks (`.ipynb`, `.Rmd`, `.qmd`) are always `code` regardless of content.
- **FR-003**: The `AGGREGATE_EXT_OVERRIDE` map MUST be extended to map compiled-binary and installer extensions (`.exe`, `.app`, `.jar`, `.msi`, `.dmg`) to `"software"`, so that aggregate-folder files of these types are correctly typed after sentinel expansion.
- **FR-004**: For non-aggregate files, the LLM is the sole classifier. The updated LLM prompt (FR-005) is the only mechanism for classifying source-language experiment files as `software` in the non-aggregate path.
- **FR-005**: The LLM classification prompt MUST include a definition for `software` in its TYPE block, with the purpose-based distinction from `code` made explicit, and hard-case disambiguation examples.
- **FR-006**: The sentinel classification prompt MUST also include the `software` type definition to maintain consistency with the main prompt.
- **FR-007**: `structure.csv` MUST be able to contain `type = "software"` rows; the schema documentation MUST be updated accordingly.
- **FR-008**: Files classified as `type = "software"` MUST be excluded from column extraction (treated identically to `code`, `output`, and `other` in this regard).
- **FR-009**: The validation GUI MUST display a `software` type button that allows annotators to assign or correct the type for any file.
- **FR-010**: The validation GUI `software` button MUST have an assigned keyboard shortcut consistent with the existing shortcut scheme.
- **FR-013**: The `software` type MUST appear in the validation GUI's file-list filter panel alongside existing type filters, allowing annotators to isolate software files for review.
- **FR-011**: The validation GUI MUST render `software` type badges with a visually distinct colour in both light and dark modes, matching the visual design pattern of existing type badges.
- **FR-012**: The `output-schemas.md` documentation MUST be updated to include `software` in the File Types table with the purpose-based definition.

### Key Entities

- **File Type (`software`)**: A new enumeration value in `structure.csv`'s `type` column. Represents programs and files whose purpose is to run the experiment — stimulus delivery tools, task runners, data collection applications, compiled binaries, and installers — as distinct from analysis scripts (`code`) and OS/config detritus (`other`).
- **Classification Rule**: An extension to the rule-based classifier that maps compiled-binary extensions and purpose-indicating filename/folder patterns to `type = "software"` before the LLM is consulted.
- **LLM Prompt Definition**: The text block within `STRUCTURE_PROMPT` and `SENTINEL_PROMPT` that describes valid `type` values; must be updated to add `software` with a purpose-based definition.
- **Validation GUI Type Button**: A UI control in the validation app that allows human annotators to assign `type = "software"` to a file row.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of compiled experiment-program extensions (`.exe`, `.app`, `.jar`, `.msi`, `.dmg`) in the test paper set receive `type = "software"` after the update.
- **SC-002**: The LLM correctly returns `"software"` for at least 90% of unambiguous software filenames and `"code"` for at least 90% of unambiguous analysis filenames in a representative prompt test.
- **SC-003**: No existing `type = "code"` analysis scripts in the current test paper set change type after the update (regression rate = 0% for pure analysis files).
- **SC-004**: The validation GUI `software` button is reachable by keyboard in ≤ 1 keystroke, consistent with all other type buttons.
- **SC-005**: All three updated consumers (rule-based classifier, LLM prompt, validation GUI) accept `"software"` as a valid type — verified by the full test suite passing with no new failures.

## Assumptions

- Purpose is the primary classification signal for source-language files; form (source vs. compiled) is secondary.
- The new type does not require a `data_format` sub-classification (only `data` rows carry `data_format`).
- The keyboard shortcut for the new GUI button will be assigned to the next available slot; the exact key is an implementation detail.
- `ground_truth/<paper_id>.csv` files already accept free-form strings in `type_gt`, so no schema migration is needed for existing ground truth files.
- Files previously mis-labelled as `other`, `code`, or `supplemental` in existing ground truth CSVs are not automatically corrected; human annotators correct them using the updated GUI.
