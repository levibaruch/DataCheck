# Feature Specification: Harvard Dataverse Source Support

**Feature Branch**: `031-dataverse-source-support`  
**Created**: 2026-04-08  
**Status**: Draft  
**Input**: User description: "the process can only handle OSF structure. I want to also do this for Harvard Dataverse. Pre-downloaded files are at /Users/levibaruch/dev/dataverse_scrape/downloads. Propose a way that we can let this additional structure work."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run the full pipeline against a single Dataverse repository (Priority: P1)

A researcher wants to run the pipeline on a single Harvard Dataverse deposit already downloaded to disk. They invoke the pipeline with a Dataverse paper identifier and receive the same structured output (structure.csv, columns.csv) as they would for an OSF paper.

**Why this priority**: Without this, Dataverse papers produce zero output. It is the minimal viable path — everything else builds on it.

**Independent Test**: Call the pipeline with one Dataverse ID (e.g. `doi_10.7910_DVN_0QEUU5`), verify that `outputs/doi_10.7910_DVN_0QEUU5/structure.csv` and `columns.csv` are produced with correct content.

**Acceptance Scenarios**:

1. **Given** a valid Dataverse DOI slug exists in the pre-downloaded directory, **When** the pipeline is run for that ID, **Then** structure.csv and columns.csv are written to `outputs/<doi_slug>/` with the same schema as OSF output.
2. **Given** the pre-downloaded folder contains nested sub-directories (e.g. `dta/`, `do/`), **When** the pipeline runs, **Then** all files at any depth are indexed and classified correctly.
3. **Given** the pipeline encounters a Dataverse DOI slug, **When** it resolves the source directory, **Then** it reads from the pre-downloaded Dataverse directory rather than attempting an OSF download.

---

### User Story 2 - Bulk-process all downloaded Dataverse repositories (Priority: P2)

A researcher wants to run the pipeline across all 457 downloaded Dataverse deposits in one operation, with incremental progress saved so the run can be resumed after interruption.

**Why this priority**: The primary value of the pipeline is scale; a single-paper path without bulk support delivers limited research value.

**Independent Test**: Run the bulk Dataverse runner on a small subset (e.g. 5 IDs); verify `results/bulk_summary.csv` contains one row per ID and the run can be interrupted and resumed without re-processing completed IDs.

**Acceptance Scenarios**:

1. **Given** the Dataverse downloads directory contains multiple deposits, **When** the bulk runner is started, **Then** each deposit is processed in sequence and results are appended to `bulk_summary.csv` after each paper completes.
2. **Given** the bulk runner is interrupted partway through, **When** it is restarted, **Then** already-processed IDs are skipped and processing resumes from the next unprocessed ID.
3. **Given** a deposit fails with a classifiable error (e.g. empty directory, unreadable files), **When** the runner processes it, **Then** the failure is recorded in `bulk_summary.csv` with an appropriate error code and the runner continues to the next deposit.

---

### User Story 3 - Source identity is recorded and queryable in output (Priority: P3)

Downstream analysis needs to distinguish which rows in `bulk_summary.csv` and `structure.csv` came from OSF versus Harvard Dataverse, so results from the two corpora can be analysed separately.

**Why this priority**: Required for any comparative analysis; can be added after P1/P2 deliver functional output but before the data is used for research.

**Independent Test**: After running the pipeline on one Dataverse ID and one OSF ID, inspect `bulk_summary.csv` and `structure.csv`; verify a `source` column (or equivalent) correctly labels each row.

**Acceptance Scenarios**:

1. **Given** a paper processed from Dataverse, **When** its row appears in `bulk_summary.csv`, **Then** the `source` column reads `"dataverse"`.
2. **Given** a paper processed from OSF, **When** its row appears in `bulk_summary.csv`, **Then** the `source` column reads `"osf"` (or the field is absent/blank for backward compatibility).
3. **Given** downstream analysis reads `bulk_summary.csv`, **When** it filters on `source`, **Then** it can unambiguously separate the two corpora.

---

### Edge Cases

- What happens when a Dataverse directory exists but is completely empty?
- What happens when a DOI slug contains characters that are problematic as directory or file names?
- How does the pipeline handle Dataverse deposits where all files are in deeply nested sub-directories (3+ levels)?
- How does the pipeline behave if the same DOI slug appears in both the Dataverse downloads directory and the existing OSF data directory?
- The Validation GUI scans the `outputs/` directory to build its paper list — how does it distinguish OSF papers from Dataverse deposits to exclude the latter?
- What happens when the Dataverse downloads root directory is missing or inaccessible?
- How does the system handle `.DS_Store` and other OS-generated metadata files present in Dataverse downloads?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The pipeline MUST accept a Dataverse DOI slug (e.g. `doi_10.7910_DVN_0QEUU5`) as the `paper_id` for a Dataverse deposit. The slug is used verbatim — no transformation — as the key in all output CSVs, the output directory name (`outputs/<doi_slug>/`), and resume detection.
- **FR-002**: Dataverse deposits MUST be stored under `data_check/data/dataverse/<doi_slug>/` (a `dataverse/` subfolder within the existing `data/` cache). The pipeline reads files from this location — no live network download occurs.
- **FR-003**: The pipeline MUST index files at all directory depths within a Dataverse deposit, matching the recursive behaviour already applied to OSF repositories.
- **FR-004**: The pipeline MUST apply the same LLM-based file classification, column extraction, and output-writing logic to Dataverse files as it does to OSF files.
- **FR-005**: A bulk runner MUST be provided that iterates over all subdirectories in the Dataverse downloads root, running the pipeline for each, and writes results incrementally to `bulk_summary.csv`.
- **FR-006**: The bulk runner MUST auto-resume: deposits already present in `bulk_summary.csv` are skipped on restart.
- **FR-007**: The bulk runner MUST record failures with an appropriate error code in `bulk_summary.csv` and continue processing remaining deposits.
- **FR-008**: A `source` column MUST be added to `bulk_summary.csv` identifying whether a row originates from `"osf"` or `"dataverse"`.
- **FR-009**: OS-generated metadata files (e.g. `.DS_Store`) MUST be excluded from indexing and classification.
- **FR-011**: The Validation GUI MUST NOT display Dataverse deposits in its paper selector. It must remain OSF-only. Dataverse outputs written to `outputs/<doi_slug>/` are excluded from the GUI's paper list.
- **FR-012**: Dataverse deposits that are successfully indexed MUST flow through the existing psychDS bulk conversion pipeline and produce valid `psychds/<doi_slug>/` output.
- **FR-013**: The `metacheck:source_repository` provenance block in psychDS output MUST correctly set `platform` to `"dataverse"` (not `"osf"`) and `download_path` to `data/dataverse/<doi_slug>/` for Dataverse-sourced deposits.
- **FR-010**: The pipeline MUST treat the Dataverse downloads root directory path as a configurable constant, not a hard-coded path.

### Key Entities

- **Dataverse Deposit**: A single pre-downloaded Harvard Dataverse repository, stored as a directory named by DOI slug. Contains research files at one or more directory depths. Analogous to an OSF repository in the existing pipeline.
- **DOI Slug**: The identifier for a Dataverse deposit (e.g. `doi_10.7910_DVN_0QEUU5`). Used verbatim as `paper_id` throughout the pipeline — in output directory names, all CSV columns, and resume detection. Must be treated as an opaque character string (no parsing or transformation).
- **Source**: A categorical label (`"osf"` or `"dataverse"`) recorded on each processed deposit to enable corpus-level filtering.
- **Dataverse Data Root**: `data_check/data/dataverse/` — the top-level directory containing all Dataverse deposits, structured as `dataverse/<doi_slug>/`. Mirrors the OSF `data/<paper_id>/` convention. Configured as a pipeline constant.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of Dataverse deposits that produce valid output for OSF papers (non-empty, readable files present) also produce valid `structure.csv` and `columns.csv` output when run through the Dataverse path.
- **SC-002**: The bulk Dataverse runner processes all 457 downloaded deposits in a single unattended run, with failures recorded but not causing the run to abort.
- **SC-003**: Restarting the bulk runner after interruption skips all already-processed deposits — zero duplicate rows in `bulk_summary.csv`.
- **SC-004**: Every row in `bulk_summary.csv` produced after this feature is implemented carries a non-null `source` value (`"osf"` or `"dataverse"`).
- **SC-005**: OS metadata files (`.DS_Store`, `Thumbs.db`) appear in zero rows of any output CSV.
- **SC-006**: Every successfully indexed Dataverse deposit produces a valid `psychds/<doi_slug>/` directory, and no `metacheck:source_repository` block in any generated psychDS file reads `platform = "osf"` for a Dataverse deposit.

## Assumptions

- Dataverse deposits will be moved from the external scrape location into `data_check/data/dataverse/<doi_slug>/` before pipeline processing — the pipeline expects them at this path.
- The directory naming convention `doi_10.7910_DVN_XXXXX` is stable and consistent across all deposits.
- Existing OSF output (existing rows in `bulk_summary.csv`, existing `outputs/` directories) must remain unchanged by this feature — backward compatibility is required.
- The existing `outputs/<paper_id>/` directory structure is reused for Dataverse, with the DOI slug as the directory name.
- No new external packages are needed; the same file-reading, classification, and column-extraction helpers that work for OSF will work for Dataverse files.
- The Dataverse data root (`data_check/data/dataverse/`) will be defined as a pipeline constant, analogous to `DATA_DIR`.

## Clarifications

### Session 2026-04-08

- Q: What string should identify a Dataverse deposit in all output files and directory names? → A: DOI slug as-is (e.g. `doi_10.7910_DVN_0QEUU5`) — matches the download directory name exactly, no transformation applied.
- Q: Should Dataverse output files go into the same `outputs/` directory tree as OSF papers? → A: Yes — same `outputs/<doi_slug>/` tree. Dataverse deposits MUST be excluded from the Validation GUI for now (GUI remains OSF-only).
- Q: Does the Dataverse pipeline need to capture paper-level metadata (title, journal, DOI) per deposit? → A: No — file-level output only for now, matching existing OSF behavior. Metadata extraction deferred to a future feature (see Deferred Work below).
- Q: Should psychDS conversion be in scope — i.e., should Dataverse deposits produce valid `psychds/<doi_slug>/` output? → A: Yes, in scope. Dataverse deposits flow through the existing psychDS bulk conversion pipeline automatically once indexed; the `metacheck:source_repository` provenance block must be updated to correctly reflect `"dataverse"` rather than the hardcoded `"osf"`.
- Q: What should `download_path` contain in the psychDS `metacheck:source_repository` block for Dataverse deposits? → A: Dataverse data will be stored under `data_check/data/dataverse/<doi_slug>/` (a subfolder of the existing `data/` cache named `dataverse`). The `download_path` value will be `data/dataverse/<doi_slug>/`, mirroring the OSF convention of `data/<paper_id>/`.
- Q: Should the psychDS `MAX_DATA_MB` size-check work correctly for Dataverse deposits? → A: No — deferred. The size check remains OSF-only for now; Dataverse deposits are always processed regardless of size. See Deferred Work.

## Deferred Work

- **TODO — Dataverse paper metadata**: Each Dataverse deposit may contain a `README.txt` or similar file with bibliographic metadata (title, published DOI, journal). Future work should parse this and record at least `title` and `doi` in `bulk_summary.csv`, mirroring how the OSF pipeline could surface paper-level metadata from its XML. This was explicitly deferred from this feature to keep scope bounded.
- **TODO — PsychDS size-check for Dataverse**: `run_psychds_bulk.R` constructs the data path as `data_check/data/<pid>/`, which misses the `dataverse/` prefix for Dataverse deposits. As a result, `MAX_DATA_MB` is silently ineffective for Dataverse (always reads 0 MB). Fix by passing the resolved data path rather than constructing it from `pid` alone.

## Dependencies

- Existing `run_index()` pipeline (pipeline/0_index.R) — this feature extends or wraps it.
- Existing bulk OSF runner — the Dataverse bulk runner should follow the same incremental-write, auto-resume pattern.
- `bulk_summary.csv` schema — a `source` column will be added; downstream consumers (including `run_psychds_bulk.R`) need to be aware.
- `pipeline/3_psychds_convert.R` — the `metacheck:source_repository` provenance block must be made source-aware; currently hardcodes `platform = "osf"`.
