# Feature Specification: Source-Aware Storage Paths

**Feature Branch**: `032-source-aware-storage`  
**Created**: 2026-04-08  
**Status**: Draft  
**Input**: User description: "With this new dataverse implementation, it is time to futureproof the data in-output. Currently the OSF files just live in data, with dataverse as a subplace. This needs to change Everywhere, from the download to psychDS output to validation GUI to testing suite. The OSF and dataverse outputs should be separately stored (so data/osf/(ID) or data/dataverse/DOI). This needs to be done in a way that is futureproof and takes into account all later steps. From this, it is also important to make it futureproof when other sources may be added (researchbox!)"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run pipeline for an OSF paper (Priority: P1)

A researcher runs the pipeline against an OSF paper ID. Downloaded raw data, pipeline outputs (columns/structure CSVs), and psychDS artifacts all land under paths prefixed with `osf/` rather than at the root of their respective directories.

**Why this priority**: This is the most common workflow and the regression baseline — if OSF papers still work correctly after the refactor, the foundation is sound.

**Independent Test**: Can be tested by running `run_single.R` for a known OSF paper ID and verifying the resulting directory tree.

**Acceptance Scenarios**:

1. **Given** an OSF paper ID, **When** `run_index()` completes, **Then** raw downloaded files exist under `data/osf/<paper_id>/` and pipeline output CSVs exist under `outputs/osf/<paper_id>/`
2. **Given** an OSF paper that was previously processed, **When** the pipeline is re-run, **Then** it correctly detects the existing data under `data/osf/<paper_id>/` and skips re-download
3. **Given** an OSF paper, **When** psychDS conversion runs, **Then** artifacts appear under `psychds/osf/<paper_id>/`

---

### User Story 2 - Run pipeline for a Dataverse paper (Priority: P1)

A researcher runs the pipeline against a Dataverse DOI. All storage paths follow `data/dataverse/<doi>/`, `outputs/dataverse/<doi>/`, and `psychds/dataverse/<doi>/` — consistent with the OSF pattern.

**Why this priority**: The direct motivation for this feature; Dataverse currently uses an inconsistent subpath (`data/dataverse/`) but outputs and psychDS still use flat paths.

**Independent Test**: Can be tested by running the Dataverse bulk runner against a known Dataverse paper and verifying paths in all three storage layers.

**Acceptance Scenarios**:

1. **Given** a Dataverse paper DOI, **When** the pipeline runs, **Then** raw data, outputs, and psychDS artifacts each live under their respective `dataverse/<doi>/` subdirectories
2. **Given** a Dataverse DOI containing slashes or special characters, **When** a path is constructed, **Then** the ID is sanitized consistently so the path is valid on all platforms

---

### User Story 3 - Validation GUI continues to work for OSF papers (Priority: P2)

A researcher using the validation GUI can browse and annotate OSF papers as before. Ground-truth annotation is OSF-only; Dataverse papers are not surfaced in the GUI.

**Why this priority**: The GUI must not regress for OSF papers as a result of the storage refactor. Dataverse is explicitly out of scope for GT annotation.

**Independent Test**: Can be tested by launching the validation GUI after the refactor and confirming OSF paper loading and annotation saving work correctly with the new `outputs/osf/<id>/` paths.

**Acceptance Scenarios**:

1. **Given** a bulk summary containing both OSF and Dataverse papers, **When** the GUI loads, **Then** only OSF papers appear in the paper selector
2. **Given** an OSF paper selected in the GUI, **When** data is loaded, **Then** the correct outputs CSVs from `outputs/osf/<paper_id>/` are shown
3. **Given** a researcher saves a ground-truth annotation for an OSF paper, **Then** it is written to `ground_truth/osf/<paper_id>.csv`

---

### User Story 4 - Test suite runs against source-aware paths (Priority: P2)

The automated test suite (`run_tests.R`) resolves test paper paths using the new source-aware structure, covering at least one Dataverse test paper in addition to the existing OSF papers.

**Why this priority**: Without updated tests, regressions in path resolution will go undetected.

**Independent Test**: Running `run_tests.R` completes without path-not-found errors; test report shows pass/fail per paper with source label.

**Acceptance Scenarios**:

1. **Given** the existing OSF test papers in `test_papers.csv`, **When** tests run, **Then** all existing tests pass with zero path errors
2. **Given** a Dataverse paper added to `test_papers.csv`, **When** tests run, **Then** the paper is processed and its result is reported

---

### User Story 5 - Future source (e.g. ResearchBox) can be added with minimal changes (Priority: P3)

A developer adding a new data source (ResearchBox) only needs to register the source name and its download logic — all path construction, output routing, and psychDS conversion automatically resolve to `data/researchbox/<id>/`, `outputs/researchbox/<id>/`, etc.

**Why this priority**: Futureproofing; ResearchBox does not need to be production-ready yet, but the abstraction must not require touch-points beyond the source registration site.

**Independent Test**: Can be tested by adding a stub "mock" source type and confirming that paths are generated correctly without editing path-construction code elsewhere.

**Acceptance Scenarios**:

1. **Given** a new source name registered in the source registry, **When** a paper from that source is processed, **Then** all storage paths automatically use `<layer>/<source>/<id>/` without additional path-logic changes
2. **Given** an unknown/unregistered source identifier, **When** the pipeline encounters it, **Then** it raises an informative error rather than silently using a wrong path

---

### Edge Cases

- What happens when a paper ID contains characters that are invalid in directory names (e.g., DOIs with `/`, `:`)? The system must sanitize or encode IDs consistently across all path layers.
- What happens when old-format data already exists at the flat path (`data/<paper_id>/`) after migration? The pipeline should detect and report stale legacy paths rather than silently creating duplicates.
- What happens when `outputs/` or `psychds/` subdirectories for a source do not yet exist? They must be created automatically on first use.
- How does the bulk summary CSV record source and ID so that downstream consumers can reconstruct the path? The `source` column already exists and must remain populated.
- What happens if a bulk run mixes OSF and Dataverse papers in a single pass? Paths must be resolved independently per paper with no cross-contamination.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST store downloaded raw data under `data/<source>/<id>/` where `<source>` is a registered source identifier (e.g., `osf`, `dataverse`) and `<id>` is the paper's identifier within that source.
- **FR-002**: The system MUST store pipeline output CSVs (structure, columns, codebook coverage, labels) under `outputs/<source>/<id>/` using the same source/id scheme.
- **FR-003**: The system MUST store psychDS conversion artifacts under `psychds/<source>/<id>/` using the same source/id scheme. The shared rollup file `psychds/conversion_summary.csv` MUST remain a single unified file spanning all sources (not split per-source).
- **FR-004**: Ground-truth annotation is OSF-only. The system MUST store OSF ground-truth files under `ground_truth/osf/<id>.csv`. No ground-truth paths are defined for Dataverse or other sources.
- **FR-005**: All path construction MUST go through a single centralized path-resolution function so that adding a new source requires changes in one place only.
- **FR-006**: The system MUST expose a `source` field in all per-paper outputs (structure CSV, bulk summary) so downstream tools can reconstruct paths without hardcoded logic.
- **FR-007**: The validation GUI MUST filter its paper selector to OSF papers only. It MUST load output CSVs from `outputs/osf/<id>/` and save annotations to `ground_truth/osf/<id>.csv`. Dataverse papers MUST NOT appear in the GUI.
- **FR-008**: The test suite MUST be updated so all existing test papers resolve to `data/osf/<id>/`. `tests/test_papers.csv` MUST gain an explicit `source` column (schema: `id, source, label`) so source is never inferred from ID format. Existing OSF rows default to `source = "osf"`.
- **FR-009**: All existing bulk runners MUST pass the source identifier through to path construction rather than hardcoding it.
- **FR-010**: The system MUST sanitize paper IDs that contain characters invalid in filesystem paths using a consistent rule applied at the path-construction layer.
- **FR-011**: When a paper is processed, any missing parent directories in the `data/`, `outputs/`, or `psychds/` trees MUST be created automatically.
- **FR-012**: The system MUST log a warning (not a fatal error) when it detects data at a legacy flat path (`data/<id>/`) but the expected source-aware path does not exist, to aid migration.

### Key Entities

- **Source**: A registered identifier for a data repository type (`osf`, `dataverse`, `researchbox`, …). Acts as the top-level namespace in all storage hierarchies.
- **Paper**: A unit of work identified by a Source + ID pair. The Source determines which download logic and path prefix to use; the ID is the repository-specific identifier.
- **Storage Layer**: One of three artifact hierarchies — raw data (`data/`), pipeline outputs (`outputs/`), or psychDS artifacts (`psychds/`). All three are namespaced identically by Source.
- **Ground Truth**: Human-supplied annotations for OSF papers only, stored at `ground_truth/osf/<id>.csv`. Dataverse and other sources have no ground-truth layer.
- **Path Resolver**: The centralized function that maps (source, id, layer) → filesystem path. All file I/O in the pipeline routes through this resolver.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All existing OSF test papers in `tests/test_papers.csv` pass with zero path-related errors after the refactor.
- **SC-002**: At least one Dataverse paper can be processed end-to-end (download → index → psychDS → GUI annotation) with all artifacts found at `data/dataverse/`, `outputs/dataverse/`, and `psychds/dataverse/` paths.
- **SC-003**: Adding a new stub source type requires changes to at most one registration site; zero changes are needed in path-construction call sites outside that registration.
- **SC-004**: The validation GUI successfully loads and saves annotations for OSF papers using the new `outputs/osf/<id>/` paths; Dataverse papers do not appear in the selector.
- **SC-005**: The bulk summary CSV produced by any bulk runner contains a populated `source` column for 100% of processed papers.
- **SC-006**: No paper's artifacts appear at the old flat path (`data/<id>/` or `outputs/<id>/`) after a fresh run — all new runs produce source-namespaced paths.

## Assumptions

- The existing `source` column in `structure.csv` and `bulk_summary.csv` already carries `"osf"` or `"dataverse"` values; this feature will rely on that field being correct and will not re-derive source from directory layout.
- DOI sanitization (replacing `/` and `:` with safe characters) will use a simple, consistent rule; reversibility is desirable but not strictly required since the original DOI is stored in the output CSV.
- Migration of existing data from flat paths to source-aware paths is out of scope. The feature targets new runs only; a separate migration step can handle existing data.
- The `ground_truth/` directory currently stores files as `ground_truth/<paper_id>.csv`. Existing OSF ground-truth files will need to be moved to `ground_truth/osf/<paper_id>.csv` as part of the implementation.
- ResearchBox support is not implemented in this feature — only the path-resolution abstraction needs to support it as a future drop-in.

## Clarifications

### Session 2026-04-08

- Q: Should `psychds/conversion_summary.csv` remain a single unified file or split per-source? → A: Keep unified at `psychds/conversion_summary.csv` — one rollup across all sources.
- Q: Should `test_papers.csv` gain an explicit `source` column or infer source from ID format? → A: Add explicit `source` column — schema becomes `id, source, label`.
- Q: How should the GUI paper selector label mixed-source papers? → A: The validation GUI covers OSF papers only; Dataverse papers are excluded from ground-truth annotation entirely.

## Dependencies

- Feature 031 (Dataverse source support) must be complete before this feature, as it establishes the `source` field in outputs and the Dataverse download path.
- The `source` column must be reliably populated in `bulk_summary.csv` before the GUI can use source-aware paths.
