# Feature Specification: Add Output File Type

**Feature Branch**: `026-add-output-file-type`
**Created**: 2026-03-30
**Status**: Draft
**Input**: User description: "Add a new file type; output. This includes the output of any scripts/intermediate results such as graphs and script outputs"

## Clarifications

### Session 2026-03-30

- Q: When the LLM cannot determine whether an image was script-generated or human-created/stimulus, which type wins? → A: `supplemental` (conservative fallback; avoids misclassifying stimulus or manuscript images as script output)
- Q: Should CSV result tables (model outputs, summary stats) be classified as `output` (skip column extraction) or `data` (column-extracted)? → A: `data`; empirical validation will determine whether result CSVs need separate handling post-implementation
- Q: Should image extensions be added to `AGGREGATE_EXT_OVERRIDE` as `output`, or always resolved by LLM? → A: Always LLM — images can be `output`, `asset`, or `supplemental`; extension alone is insufficient to distinguish between the three
- Q: Should `.rds`/`.rda` files be LLM-classified as `output` when context indicates script-saved objects, or stay `data`? → A: Stay `data`; existing NULL-return from column extraction handles non-data content; classification will be validated empirically
- Q: Should the `supplemental` definition be narrowed to exclude script-generated artefacts, or remain broad with `output` as the preferred type? → A: Narrow — `supplemental` = human-authored non-data documents only; script-generated files explicitly excluded

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Distinguish script outputs from supplemental research documents (Priority: P1)

A researcher auditing a paper's OSF repository wants to understand what types of files are present. Currently, generated graphs, script output files (e.g. `.html` knit outputs, result tables saved as CSVs), and other computational byproducts are lumped into `supplemental` alongside manuscripts, consent forms, and preregistrations — which are fundamentally different artefacts created by researchers, not by scripts. Having a separate `output` type lets the researcher quickly filter to only machine-generated results without sorting through human-authored documents.

**Why this priority**: The `supplemental` type is overloaded. Conflating human-authored documents with script-generated outputs makes downstream filtering and quality checks imprecise. Separating them is the highest-impact change for data quality.

**Independent Test**: Run the pipeline on a paper whose OSF repo contains a mix of a manuscript PDF and a rendered HTML report; confirm the manuscript is `supplemental` and the HTML report is `output`.

**Acceptance Scenarios**:

1. **Given** an OSF repo containing a rendered `.html` file produced by an R Markdown or Quarto script, **When** the pipeline classifies files, **Then** that file receives `type = "output"`.
2. **Given** an OSF repo containing a `.png` or `.pdf` graph/figure saved by a script, **When** the pipeline classifies files, **Then** that file receives `type = "output"`.
3. **Given** an OSF repo containing a `.csv` file that is a results table produced by a script (not raw data), **When** the pipeline classifies files, **Then** that file receives `type = "data"` and undergoes column extraction (classification of result CSVs vs data CSVs will be validated empirically post-implementation).
4. **Given** an OSF repo containing a manuscript or preregistration PDF, **When** the pipeline classifies files, **Then** that file retains `type = "supplemental"` (not reclassified to `output`).
5. **Given** an OSF repo containing a stimulus image used in the experiment, **When** the pipeline classifies files, **Then** that file retains `type = "asset"` (not reclassified to `output`).

---

### User Story 2 — Filter output files out of data-quality analysis (Priority: P2)

A researcher running summary statistics on `structure.csv` wants to exclude computationally generated files from counts of human-created research materials. With a distinct `output` type, filtering is a single equality check rather than a heuristic on filenames or extensions.

**Why this priority**: Downstream uses of `structure.csv` (e.g. `bulk_summary.csv` counts, quality reports) will be more precise once outputs are separated, but this value is realised automatically once P1 is complete.

**Independent Test**: After running the pipeline on a paper with known script outputs, verify that `structure.csv` rows with `type = "output"` are absent from counts of `supplemental` rows.

**Acceptance Scenarios**:

1. **Given** a paper where 3 files are script outputs, **When** `structure.csv` is produced, **Then** those 3 rows have `type = "output"` and are not counted in any `supplemental` summary.

---

### Edge Cases

- CSV files that are results tables (model outputs, summary statistics): classified as `data` and column-extracted; distinction from raw data CSVs will be validated empirically.
- Rendered notebooks (`.html`, `.pdf`) produced from `.Rmd`/`.qmd` scripts: these are `output`, not `supplemental`.
- Image files: figures provably produced by a script are `output`; stimulus images shown to participants remain `asset`; when provenance is ambiguous (cannot determine if script-generated or human-created/embedded), the image falls back to `supplemental`.
- Log files saved by scripts: these are `output`. Intermediate `.RData`/`.rds` files remain `data`; the existing NULL-return from column extraction handles non-data content — classification will be validated empirically.
- Files with ambiguous names where it is unclear whether they were human-authored or script-generated: the LLM should classify based on semantic context; `supplemental` remains the fallback for genuinely ambiguous cases.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The pipeline MUST recognise a new file type `"output"` in `structure.csv`'s `type` column.
- **FR-002**: Files classified as `output` MUST include: rendered notebook outputs (`.html`, `.pdf`, `.docx` produced from code), script-generated figures and graphs (`.png`, `.jpg`, `.svg`, `.eps`, `.pdf` plots), and log files. CSV/Excel and `.rds`/`.rda` files remain `data` regardless of content; empirical validation will determine whether finer-grained reclassification is needed.
- **FR-003**: The LLM classification prompt MUST be updated to include `output` as a valid type with a clear definition and examples, so the LLM can distinguish it from `supplemental`, `data`, and `code`.
- **FR-004**: The `AGGREGATE_EXT_OVERRIDE` extension lookup MUST NOT assign image extensions (`.png`, `.jpg`, `.svg`, `.eps`, etc.) to `output` via extension rules — image files have three possible types (`output`, `asset`, `supplemental`) and MUST always be resolved by the LLM using semantic context.
- **FR-005**: Files that are currently `supplemental` due to being script outputs (e.g. result figures, HTML knit outputs) MUST be reclassified to `output`; human-authored documents (manuscripts, preregistrations, consent forms) MUST remain `supplemental`.
- **FR-006**: `output` files MUST NOT be passed to column extraction (they are not data files).
- **FR-007**: The `output-schemas.md` documentation MUST be updated: add `output` to the File Types table with a precise definition; narrow the `supplemental` definition to explicitly exclude script-generated artefacts (remove "result figures and output graphs" from its examples; add an explicit note that script-generated files belong to `output`).
- **FR-008**: The pipeline documentation (`docs/pipeline.md`) MUST be updated to reflect the new type.

### Key Entities

- **File row** (`structure.csv`): One row per discovered file; the `type` field gains a new valid value `"output"`.
- **LLM classification prompt**: The prompt used to assign file types must include the `output` category.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After running the pipeline on a paper with known script outputs, all script-generated figures and rendered notebooks receive `type = "output"` in `structure.csv`.
- **SC-002**: No human-authored document (manuscript, preregistration, consent form) is reclassified from `supplemental` to `output`.
- **SC-003**: No file with `type = "output"` appears in `columns.csv` (output files are not treated as data sources).
- **SC-004**: The `output-schemas.md` File Types table includes `output` with an accurate, unambiguous definition.
- **SC-005**: The LLM classification prompt includes `output` as a type, with at least 3 example file patterns to guide classification.

## Assumptions

- The primary mechanism for `output` classification is the LLM prompt (same as `supplemental`, `code`, etc.); extension-level rules may supplement but are not the primary classifier.
- The `output` type does not affect column extraction — only `data` files are column-extracted.
- Stimulus images (`asset`) are not affected by this change.
- `readme` and `other` types are not affected by this change.
- Where the LLM cannot determine whether a file is `output` or `supplemental`, `supplemental` remains the fallback to avoid mislabelling human-authored documents.
