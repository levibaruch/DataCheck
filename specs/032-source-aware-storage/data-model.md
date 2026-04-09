# Data Model: Source-Aware Storage Paths (032)

**Date**: 2026-04-08

## Path Model

The central abstraction of this feature. All per-paper filesystem paths follow the pattern:

```
<layer_root>/<source>/<sanitized_id>/[optional subpath]
```

| Layer | Root Constant | Example path |
|-------|--------------|--------------|
| `data` | `DATA_DIR` (`./data_check/data`) | `data/osf/0956797614523297/` |
| `outputs` | `OUTPUT_DIR` (`./data_check/outputs`) | `outputs/dataverse/doi-10.7910_DVN_ABC123/` |
| `psychds` | `PSYCHDS_OUT_DIR` (`./data_check/psychds`) | `psychds/osf/0956797614523297/` |
| `ground_truth` | `GROUND_TRUTH_DIR` (`./data_check/ground_truth`) | `ground_truth/osf/0956797614523297.csv` |

**Exception**: `psychds/conversion_summary.csv` lives at the `PSYCHDS_OUT_DIR` root — not namespaced by source.

## Entity: Source

A registered identifier for a data repository type.

| Field | Type | Constraints |
|-------|------|-------------|
| `name` | character | One of `"osf"`, `"dataverse"` (registry in `paper_path()`) |

**Validation**: `paper_path()` stops with an informative error if `source` is not in the known-sources list. New sources added by registering them in `KNOWN_SOURCES` inside `paper_path()` — no other code changes needed.

## Entity: Paper

A unit of work, identified by Source + ID.

| Field | Type | Constraints |
|-------|------|-------------|
| `source` | character | Must be a registered Source name |
| `paper_id` | character | Source-specific identifier; must be stored/read as character (Principle II) |
| `sanitized_id` | character (derived) | `sanitize_id(paper_id)` — safe for filesystem; never persisted to CSV |

**ID sanitization rule** (`sanitize_id()`):

| Character | Replacement | Example |
|-----------|-------------|---------|
| `:` | `-` | `doi:10.7910` → `doi-10.7910` |
| `/` | `_` | `DVN/ABC123` → `DVN_ABC123` |

Full example: `doi:10.7910/DVN/ABC123` → `doi-10.7910_DVN_ABC123`

## Entity: test_papers.csv

Updated schema (adds `source` column):

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | character | Paper ID; read with `colClasses = c(id = "character")` (Principle II) |
| `source` | character | Registered source name; all existing rows = `"osf"` |
| `label` | character | Human-readable test description |

## New Helper Functions (in `helper.R`)

### `paper_path(layer, source, paper_id, ...)`

**Inputs**:
- `layer`: character — one of `"data"`, `"outputs"`, `"psychds"`, `"ground_truth"`
- `source`: character — registered source identifier
- `paper_id`: character — paper-specific ID (unsanitized)
- `...`: additional path components forwarded to `file.path()`

**Output**: character — absolute-style path string

**Errors**: stops if `source` not in `KNOWN_SOURCES`; stops if `layer` not recognized

**Side effects**: none (pure path construction)

---

### `sanitize_id(id)`

**Input**: character (single value)  
**Output**: character — filesystem-safe ID  
**Side effects**: none

---

### `list_downloaded_papers()`

**Inputs**: none (uses `DATA_DIR` and `KNOWN_SOURCES` globals)  
**Output**: `data.frame(source = character, paper_id = character)` or `NULL` if no papers found  
**Side effects**: none (read-only filesystem scan)

---

### `apply_ground_truth(structure_df, source, paper_id)` (updated signature)

**Change from prior**: adds `source` parameter as second argument.  
**GT path constructed via**: `paste0(paper_path("ground_truth", source, paper_id), ".csv")`

## Invariants

1. `paper_id` is NEVER sanitized in CSV outputs — only at path-construction time.
2. `paper_path()` MUST be the only site where `<layer>/<source>/<id>` paths are assembled.
3. `psychds/conversion_summary.csv` is the one exception to the source-namespacing rule — it remains at the `PSYCHDS_OUT_DIR` root.
4. Ground-truth is OSF-only — `paper_path("ground_truth", "dataverse", ...)` is technically callable but no code in the pipeline invokes it.
