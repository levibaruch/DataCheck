# Feature Specification: Software Folder Bulk Detection

**Feature Branch**: `040-software-folder-detection`  
**Created**: 2026-04-21  
**Status**: Draft  
**Input**: User description: "currently, software packages that were included in the repository are a big issue. They bloat the system and cause thousands of calls. I propose a rule-based fallback in the indexation that, if a certain folder is found + a threshold is reached (Maybe /src/ , /lib/, stuff like that?, then determine at N files), the folder is labelled as software with a clear source"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Bloated Repo Completes Instead of Failing (Priority: P1)

A researcher's OSF repository contains a bundled software library (e.g. an R package, Python package, or JavaScript module) alongside actual study data. Currently the file count explodes past the LLM call cap, the paper is marked `too_large`, and no data is extracted. With this feature, the software folder is detected by name and file count before LLM classification runs, all files within it are bulk-labeled as `software`, and the remaining data files are classified normally — so the paper succeeds.

**Why this priority**: Directly converts `too_large` failures into successful extractions. Core pipeline reliability issue.

**Independent Test**: Run a paper known to fail with `too_large` due to a bundled software folder. Verify it now completes with `software` labels on the folder contents and correct labels on remaining files.

**Acceptance Scenarios**:

1. **Given** a repo where a folder named `node_modules` or `vendor` contains 300 files, **When** indexation runs, **Then** all files in that folder are labeled `software` without any LLM calls, and the paper does not hit `too_large`.
2. **Given** a repo where a software-named folder contains only 5 files (below threshold), **When** indexation runs, **Then** those files are sent through normal LLM classification rather than bulk-labeled.
3. **Given** a repo where the entire directory is a software package structure, **When** indexation runs, **Then** all files are bulk-labeled `software` and the paper completes with a `software_folder` source annotation.

---

### User Story 2 - Legitimate Data Files Are Not Caught by the Rule (Priority: P2)

A researcher names a data folder `src` or `lib` but it contains fewer than N files. The rule-based detection should not bulk-label these as software, allowing normal LLM classification to correctly identify them as data.

**Why this priority**: Precision matters as much as recall — false positives would silently hide study data.

**Independent Test**: Run a paper with a small folder named `src` containing 3 CSV files. Verify those CSVs are classified as `data` via LLM, not bulk-labeled as `software`.

**Acceptance Scenarios**:

1. **Given** a folder named `lib` containing 4 files, **When** indexation runs, **Then** the file count threshold is not met and the files are sent through normal classification.
2. **Given** a folder named `src` containing 500+ files where the majority have recognizable data extensions (CSV, SAV, DTA, XLSX, XLS, RDS), **When** indexation runs, **Then** the extension-majority check overrides the folder-name rule and the files are sent through normal LLM classification rather than bulk-labeled as `software`.

---

### User Story 3 - Bulk-Labeled Files Are Auditable (Priority: P3)

After a pipeline run, an analyst reviewing the output can distinguish files that were bulk-labeled by the folder rule from files that went through LLM classification. This prevents confusion when investigating misclassifications.

**Why this priority**: Transparency and debuggability; does not affect pipeline correctness.

**Independent Test**: After running a paper with a detected software folder, inspect `structure.csv`. Verify bulk-labeled files have a distinct source field indicating rule-based origin.

**Acceptance Scenarios**:

1. **Given** files bulk-labeled via the folder rule, **When** `structure.csv` is read, **Then** those rows have a source field value of `rule_folder` (or similar) distinguishing them from LLM-classified rows.
2. **Given** a mix of bulk-labeled and LLM-labeled files in the same paper, **When** the output is reviewed, **Then** the two groups are unambiguously distinguishable by the source field.

---

### Edge Cases

- What happens when a software-named folder is nested inside another software-named folder (e.g. `vendor/lib/`)?
- How does the system handle a repo where 90%+ of all files are in a detected software folder — does the remaining 10% still classify normally?
- What if the same folder name appears at multiple directory depths (e.g. both `./src/` and `./analysis/src/`)?
- What if a detected folder contains zero files (empty)?
- Does the file count threshold apply per-folder instance or as a cumulative total across all matching folders?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST maintain a configurable list of folder name patterns that indicate bundled software (minimum set: `node_modules`, `vendor`, `lib`, `renv`, `dist`, `build`, `__pycache__`, `site-packages`).
- **FR-002**: System MUST apply a file count threshold — a folder triggers bulk labeling only if it contains at least N files (default: 500), where N is a named constant adjustable without code changes. The threshold is intentionally high: the rule targets genuine software package directories (typically 500–5,000+ files), not merely large data folders.
- **FR-003**: System MUST evaluate the folder rule BEFORE any LLM classification calls are made for a paper.
- **FR-004**: System MUST label all files within a triggered folder as type `software` without sending them to LLM classification.
- **FR-005**: System MUST record the classification source for bulk-labeled files, distinguishing them from LLM-classified entries in the output.
- **FR-006**: System MUST continue classifying all files outside detected software folders through normal LLM classification, unaffected by the rule.
- **FR-007**: System MUST handle repos where multiple folders trigger the rule simultaneously, detecting each independently.
- **FR-008**: System MUST apply the folder rule recursively — if a top-level folder triggers the rule, all files in its subdirectories are also bulk-labeled without traversal into them for individual LLM classification.
- **FR-009**: Folder name matching MUST be case-insensitive and match on the folder name segment only (not a substring of a longer name), to minimize false positives.
- **FR-010**: Before bulk-labeling a triggered folder, system MUST inspect file extensions within it. If a majority of files carry recognizable data extensions (CSV, TSV, SAV, DTA, XLSX, XLS, RDS, RDA, RDATA, SAS7BDAT), the folder MUST be excluded from bulk labeling and sent through normal LLM classification instead.

### Key Entities

- **Software Folder Pattern List**: Named set of folder names (not full paths) that indicate bundled software. Stored as a named constant alongside existing pipeline constants.
- **File Count Threshold (N)**: Minimum file count within a matching folder to trigger bulk labeling. Named constant, default 20.
- **Classification Source**: A per-file field in structure output indicating whether a file was classified by LLM or by the folder detection rule.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Papers that previously failed with `too_large` solely due to bundled software folders now complete successfully without manual intervention.
- **SC-002**: LLM call count per paper is reduced by at least 80% for papers containing a triggered software folder, compared to pre-feature baseline for the same papers.
- **SC-003**: Zero legitimate data files (CSV, SAV, DTA, XLSX, etc.) in folders below the count threshold are incorrectly bulk-labeled as `software`.
- **SC-004**: All files bulk-labeled by the folder rule are identifiable in output without ambiguity — no log inspection required.
- **SC-005**: Papers with no software-named folders produce classification results identical to pre-feature behavior.

## Assumptions

- The existing `software` file type (from feature 029) is the correct target label for bulk-detected files — no new type is introduced.
- `src` is excluded from the default pattern list due to high false-positive risk (many researchers use `src/` for data scripts or source data); it may be added later with a higher threshold.
- Threshold N = 500 is the starting default. Rationale: genuine software package directories (node_modules, renv/library, vendor) routinely contain 500–5,000+ files. Folders below 500 are manageable and should go through normal classification. The constant will be validated against known test papers before final merge.
- Folder detection applies at all directory depths, not only top-level folders.
- `renv/` is included in the default pattern list because R environment caches commonly contain hundreds of package files in OSF repos.
