# Spec 030 — PsychDS Dataset Viewer

**Goal:** A self-contained, Dockerized web application that lets researchers browse
psychology datasets at the paper level, search across all variables by column name or
codebook description, and download data — either as whole paper-level PsychDS
repositories or as cross-paper variable collections. The application reads the PsychDS
output directory directly and has zero dependency on the upstream pipeline code.

**Transparency first:** every piece of data shown or downloaded is traceable to its
source JSON field, with pipeline provenance visible on demand and embedded in every
download package.

---

## 1. Scope and Non-Goals

### In scope
- Read-only viewer of PsychDS output files (`psychds/` directory tree)
- Paper-level browse: metadata, study groups, file manifest, pipeline status
- Variable-level cross-paper search by column name, codebook label, and sample values
- Per-variable detail panel: statistics, provenance, pipeline classification decisions
- Provenance panel: per-file original path, type, group, ground truth validation status
- Transparency panel: full pipeline stage descriptions that produced each data point
- **Paper-level download:** ZIP of a full paper's PsychDS directory (all study groups), or a single study group
- **Variable-level download:** ZIP of all normalized data files across the corpus that contain a matching variable, plus a manifest CSV

### Out of scope
- Running, re-running, or triggering the data_check pipeline
- Authentication or user accounts
- Editing or annotating data

---

## 2. Input Data Format

The application mounts one directory: the `psychds/` output folder. Everything the
viewer needs is derived from this tree alone.

### 2.1 Directory Tree Layout

```
psychds/
  conversion_summary.csv              ← one row per (paper_id × study_group) run
  <paper_id>/                         ← e.g. "0956797614557867"
    <study_dir>/                      ← e.g. "study-ex1", "study-shared"
      dataset_description.json        ← paper + variable metadata
      provenance.json                 ← file provenance manifest
      data/
        raw/
          <original_filename>         ← verbatim copy of source file
        source-<slug>_data.csv        ← UTF-8 normalized tabular CSV
        source-<slug>_data.json       ← per-variable statistics sidecar
      analysis/                       ← code files (R, Python, SQL, etc.)
      documentation/
        txt/                          ← extracted plain-text versions of PDFs/DOCX
        <supplemental files>
      materials/                      ← stimuli / assets
    shared/                           ← cross-study shared files (may exist without dataset_description.json)
```

**`paper_id` is always a character string.** Leading zeros are significant.
`paper_id` values like `"0956797614557867"` must never be parsed as numbers.

**`study_dir` naming convention:**
- `study-ex<N>` — main numbered experiment (e.g. `study-ex1`, `study-ex4a`)
- `study-pilot<N>` — pilot study (e.g. `study-pilot1`)
- `study-shared` — cross-experiment shared files
- A paper with only one logical study may have a single `study-ex1` or `study-shared`

A study directory qualifies for display only if it contains `dataset_description.json`.
The `shared/` directory (without the `study-` prefix) holds files referenced by studies
via `metacheck:shared_resources`; it does not have its own `dataset_description.json`
and is shown only as a file list within the papers that reference it.

### 2.2 `dataset_description.json` — Field Reference

JSON-LD document at `<paper_id>/<study_dir>/dataset_description.json`.

#### Top-level fields

| JSON path | Type | Description |
|---|---|---|
| `schema:name` | string | Paper / study title |
| `schema:description` | string | Abstract or study description |
| `schema:author` | array of `{schema:name: string}` | Author list |
| `schema:identifier` | string | DOI URL (e.g. `"https://doi.org/10.1177/…"`) |
| `schema:keywords` | array of string | Topic keywords |
| `schema:schemaVersion` | string | PsychDS version used (e.g. `"Psych-DS 0.1.0"`) |
| `metacheck:paper_id` | string | Paper identifier — always treat as string |
| `metacheck:study_group` | string | Study/experiment group label: `ex1`, `ex2`, `shared`, etc. |
| `metacheck:pipeline_version` | string | Pipeline version that produced this file (e.g. `"021"`) |
| `metacheck:conversion_date` | string (YYYY-MM-DD) | Date of PsychDS conversion |
| `metacheck:source_repository.platform` | string | Source platform — always `"osf"` currently |
| `metacheck:source_repository.download_path` | string | Relative path of source download |
| `metacheck:shared_resources` | string (optional) | Relative path to shared directory for this study group, if files are borrowed from a sibling `shared/` directory |
| `metacheck:shared_files` | array of string (optional) | Relative paths (from the shared dir) of files that are visible to this study group |

#### `metacheck:pipeline_status` object

Summarises the pipeline outcome for this study group.

| Field | Type | Description |
|---|---|---|
| `index_success` | boolean | True if the indexing stage (structure + columns) completed without error |
| `codebook_success` | boolean | True if the codebook-labelling stage completed without error |
| `n_files_total` | integer or null | Total files indexed in the study group |
| `n_data_files` | integer or null | Files classified as `type = "data"` |
| `n_columns` | integer or null | Total columns extracted |
| `n_labelled_columns` | integer | Columns matched to a codebook label |
| `label_status` | string | Overall labelling outcome: `"ok"`, `"no_match"`, or `"no_codebook"` |

#### `schema:variableMeasured` array

Each element is a `PropertyValue` describing one column across one or more data files.

| JSON path | Type | Present when | Description |
|---|---|---|---|
| `@type` | `"PropertyValue"` | always | Schema.org type |
| `name` | string | always | Column name as it appears in the source data file |
| `description` | string | codebook match exists | Human-readable label from matched codebook |
| `minValue` | number | numeric col types | Minimum observed value |
| `maxValue` | number | numeric col types | Maximum observed value |
| `valuePattern` | string | binary col type | Pipe-separated unique values (e.g. `"1|0"`) |
| `metacheck:col_type` | string | always | Column type classification — see §2.4 |
| `metacheck:source_file` | string | always | Original relative path of the source data file |
| `metacheck:sample_values` | string | always | First up to 5 non-NA values, pipe-separated |
| `metacheck:statistics` | object | numeric col types | Descriptive statistics — see §2.3 |

#### `metacheck:statistics` object (numeric columns only)

| Field | Type | Description |
|---|---|---|
| `n` | integer | Count of non-missing values |
| `n_missing` | integer | Count of missing (NA) values |
| `mean` | number | Arithmetic mean |
| `sd` | number | Standard deviation |
| `se` | number | Standard error of the mean |
| `median` | number | Median |
| `p25` | number | 25th percentile |
| `p75` | number | 75th percentile |
| `iqr` | number | Interquartile range |
| `skewness` | number | Pearson moment skewness |
| `kurtosis` | number | Excess kurtosis (normal = 0) |

### 2.3 `source-<slug>_data.json` — Variable Sidecar

JSON file at `<paper_id>/<study_dir>/data/source-<slug>_data.json`. Contains a
superset of the variable information from `dataset_description.json`, scoped to one
specific CSV file. The format is identical to `schema:variableMeasured` plus two
additional top-level fields:

| Field | Type | Description |
|---|---|---|
| `schema:variableMeasured` | array | Per-variable entries (same format as in `dataset_description.json`) |
| `metacheck:original_file.rel_path` | string | Original relative path of the source file |
| `metacheck:original_file.format` | string | Original file extension |
| `metacheck:original_file.size_bytes` | integer | File size in bytes |
| `metacheck:original_file.data_granularity` | string or null | `"individual"` / `"combined"` / null |
| `metacheck:conversion.method` | string | R read function used: `read.csv`, `read.delim`, `read_sav`, etc. |
| `metacheck:conversion.encoding_normalized` | boolean | True if latin1 re-read was triggered |
| `metacheck:conversion.haven_labels_extracted` | boolean | True if SPSS/Stata value labels were extracted |
| `metacheck:conversion.rows_written` | integer | Rows in the normalized CSV |
| `metacheck:conversion.columns_written` | integer | Columns in the normalized CSV |

The viewer uses this file to show per-dataset file context when a user drills into a
specific variable from a specific source file.

### 2.4 `provenance.json` — File Provenance Manifest

JSON at `<paper_id>/<study_dir>/provenance.json`. Contains one array `file_provenance`
with one entry per file in the study group.

| Field | Type | Description |
|---|---|---|
| `psychds_path` | string | Relative path of the file within this study group directory |
| `original_rel_path` | string | Relative path in the original OSF download tree |
| `original_format` | string | File extension of the original file |
| `pipeline_type` | string | Pipeline classification — see §2.5 (File Types) |
| `pipeline_group` | string | Experiment group assigned by the pipeline: `ex1`, `shared`, etc. |
| `pipeline_data_granularity` | string or null | `"individual"` / `"combined"` / null (non-data) |
| `ground_truth_validated` | boolean | True if this file was manually reviewed in the validation GUI |
| `txt_extraction_attempted` | boolean (optional) | True when plain-text extraction was attempted |
| `txt_extraction_skipped` | boolean (optional) | True if no `.txt` output was written |
| `txt_skip_reason` | string (optional) | `"no_extractable_text"` or `"extraction_error"` |
| `txt_psychds_path` | string (optional) | Relative path of the written `.txt` file |

### 2.5 File Type Vocabulary

The `pipeline_type` field in `provenance.json` uses this controlled vocabulary:

| Value | Meaning |
|---|---|
| `data` | Research measurements — tabular (CSV, XLSX, SAV, DTA, etc.) or non-tabular (EEG `.edf`, MATLAB `.mat`, media). Column extraction was attempted only for tabular data files. |
| `codebook` | Variable dictionary / data dictionary whose primary purpose is describing what variables mean |
| `code` | Executable source file: R, Python, MATLAB, SQL, shell scripts, `.Rmd`, `.qmd`, `.ipynb` |
| `software` | Experiment software: stimulus delivery tools, compiled binaries, installers, configuration files |
| `output` | File produced by executing a script: rendered notebooks, script-generated figures, log files |
| `supplemental` | Human-authored research material not covered above: manuscripts, preregistrations, survey instruments, consent forms |
| `readme` | Files named `README.*`, `LICENSE.*`, or `CONTRIBUTING.*` only |
| `asset` | Participant-facing stimuli: images, audio clips, video shown to participants |
| `other` | No research content: OS metadata (`.DS_Store`), environment config |
| `llm_error` | LLM classification failed on all retries — type could not be determined |

### 2.6 Column Type Vocabulary

The `metacheck:col_type` field uses this controlled vocabulary:

| Value | Assigned by | Meaning |
|---|---|---|
| `continuous` | Rule or LLM | Numeric measurement (float or integer with >20 unique values) |
| `ordinal` | LLM | Ordered integer scale (Likert, rating) with few levels |
| `binary` | Rule | Exactly two unique non-NA values |
| `constant` | Rule | Exactly one unique non-NA value |
| `categorical` | LLM | Unordered group label (condition names, gender codes) |
| `date` | Rule | Date-parseable values |
| `id` | Rule | Participant or row identifier (matched by column name pattern) |
| `text` | Rule or LLM | Free-text or long string values |
| `continuous_comma_decimal` | Rule | Numeric with comma as decimal separator (≥95% convertible) |
| `continuous_outliers_excluded` | Rule | Numeric with comma separator but 80–95% convertible |
| `empty` | Rule | All values are NA |
| `unknown` | LLM | Genuinely uninformative — cannot be classified |
| `llm_error` | Pipeline | LLM batch failed on all retries |

### 2.7 `conversion_summary.csv` — Corpus Index

Located at `psychds/conversion_summary.csv`. One row per (paper_id × study_group).

| Column | Type | Description |
|---|---|---|
| `paper_id` | character | Paper identifier — treat as string |
| `study_group` | character | e.g. `ex1`, `shared`; `"single"` for single-study papers |
| `success` | logical | True if the study group converted without error |
| `error` | character | Error code or message; NA if success |
| `n_data_files` | integer | Data files converted to PsychDS CSV |
| `n_raw_files` | integer | Files copied to `data/raw/` only |
| `n_variables` | integer | Variables written to `variableMeasured` |
| `n_labelled` | integer | Variables with a matched codebook label |
| `has_paper_metadata` | logical | True if GROBID TEI XML was found |
| `has_ground_truth` | logical | True if a ground truth file was applied |
| `output_path` | character | Absolute path to the output directory |

---

## 3. Docker Deployment

### 3.1 Image Layout

```
viewer/
  Dockerfile
  docker-compose.yml
  backend/
    ...
  frontend/
    ...
  README.md
```

### 3.2 `docker-compose.yml`

```yaml
version: "3.9"
services:
  backend:
    build: ./backend
    volumes:
      - "${PSYCHDS_DIR}:/data/psychds:ro"
    environment:
      - PSYCHDS_DIR=/data/psychds
      - INDEX_ON_START=true
    ports:
      - "8000:8000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 5

  frontend:
    build: ./frontend
    ports:
      - "3000:3000"
    depends_on:
      backend:
        condition: service_healthy
    environment:
      - VITE_API_BASE=http://localhost:8000
```

**Environment variables:**

| Variable | Required | Default | Description |
|---|---|---|---|
| `PSYCHDS_DIR` | yes | — | Host path to the `psychds/` output directory; mounted read-only |
| `INDEX_ON_START` | no | `true` | Build the search index on container start |
| `INDEX_MAX_WORKERS` | no | `4` | Parallel workers for initial index build |
| `LOG_LEVEL` | no | `info` | Backend log level: `debug`, `info`, `warning`, `error` |

### 3.3 Volume Mount

The `psychds/` directory is mounted **read-only** at `/data/psychds` inside the
backend container. The backend must never write to the mounted volume.

### 3.4 Startup Sequence

1. Backend starts, mounts `/data/psychds`
2. If `INDEX_ON_START=true`, runs the indexer (see §4.1)
3. Healthcheck endpoint (`GET /health`) returns 200 only when indexing is complete
4. Frontend container starts (depends_on with condition: service_healthy)
5. Frontend fetches `/api/corpus/stats` on load to display index summary

---

## 4. Backend

### 4.1 Indexer

The indexer runs once at startup (or on demand via `POST /api/admin/reindex`). It
walks the mounted `psychds/` directory tree and builds an in-memory search index plus
a SQLite database for persistence across restarts.

**SQLite database path:** `/tmp/viewer_index.db` (ephemeral, rebuilt on reindex)

#### 4.1.1 Paper Discovery

1. Read `conversion_summary.csv`
2. For each row where `success = TRUE`, note `paper_id` and `study_group`
3. Walk `<paper_id>/<study_dir>/` where `study_dir = "study-" + study_group` (special
   case: `study_group = "single"` → `study_dir = "study-ex1"` or the only study dir
   present — walk the paper dir to find it)
4. Skip directories that lack `dataset_description.json`
5. For each valid study dir, parse `dataset_description.json` and `provenance.json`

Fallback: if `conversion_summary.csv` is absent, the indexer falls back to walking the
directory tree directly, discovering `dataset_description.json` files by glob.

#### 4.1.2 Index Schema (SQLite)

**`papers` table**

| Column | Type | Source |
|---|---|---|
| `paper_id` | TEXT PRIMARY KEY | `metacheck:paper_id` |
| `title` | TEXT | `schema:name` |
| `description` | TEXT | `schema:description` |
| `authors` | TEXT | JSON array from `schema:author[*].schema:name` |
| `doi` | TEXT | `schema:identifier` |
| `keywords` | TEXT | JSON array from `schema:keywords` |
| `n_study_groups` | INTEGER | count of study dirs with `dataset_description.json` |
| `has_ground_truth` | INTEGER | 1 if any study group has `has_ground_truth = TRUE` |
| `conversion_date` | TEXT | `metacheck:conversion_date` (from any study group) |
| `pipeline_version` | TEXT | `metacheck:pipeline_version` |

**`study_groups` table**

| Column | Type | Source |
|---|---|---|
| `id` | INTEGER PRIMARY KEY |  |
| `paper_id` | TEXT | FK → papers |
| `study_group` | TEXT | `metacheck:study_group` |
| `study_dir` | TEXT | Directory name (e.g. `study-ex1`) |
| `title` | TEXT | `schema:name` |
| `description` | TEXT | `schema:description` |
| `index_success` | INTEGER | `metacheck:pipeline_status.index_success` |
| `codebook_success` | INTEGER | `metacheck:pipeline_status.codebook_success` |
| `n_files_total` | INTEGER | `metacheck:pipeline_status.n_files_total` |
| `n_data_files` | INTEGER | `metacheck:pipeline_status.n_data_files` |
| `n_columns` | INTEGER | `metacheck:pipeline_status.n_columns` |
| `n_labelled_columns` | INTEGER | `metacheck:pipeline_status.n_labelled_columns` |
| `label_status` | TEXT | `metacheck:pipeline_status.label_status` |
| `has_ground_truth` | INTEGER | from `conversion_summary.csv` |
| `n_variables` | INTEGER | from `conversion_summary.csv` |
| `n_labelled_csv` | INTEGER | from `conversion_summary.csv` |

**`variables` table** — one row per variable per study group

| Column | Type | Source |
|---|---|---|
| `id` | INTEGER PRIMARY KEY |  |
| `paper_id` | TEXT | FK → papers |
| `study_group_id` | INTEGER | FK → study_groups |
| `name` | TEXT | `schema:variableMeasured[i].name` |
| `description` | TEXT or NULL | `schema:variableMeasured[i].description` (codebook label) |
| `col_type` | TEXT | `metacheck:col_type` |
| `source_file` | TEXT | `metacheck:source_file` |
| `sample_values` | TEXT | `metacheck:sample_values` |
| `value_pattern` | TEXT or NULL | `valuePattern` (binary only) |
| `min_value` | REAL or NULL | `minValue` |
| `max_value` | REAL or NULL | `maxValue` |
| `stat_n` | INTEGER or NULL | `metacheck:statistics.n` |
| `stat_n_missing` | INTEGER or NULL | `metacheck:statistics.n_missing` |
| `stat_mean` | REAL or NULL | `metacheck:statistics.mean` |
| `stat_sd` | REAL or NULL | `metacheck:statistics.sd` |
| `stat_se` | REAL or NULL | `metacheck:statistics.se` |
| `stat_median` | REAL or NULL | `metacheck:statistics.median` |
| `stat_p25` | REAL or NULL | `metacheck:statistics.p25` |
| `stat_p75` | REAL or NULL | `metacheck:statistics.p75` |
| `stat_iqr` | REAL or NULL | `metacheck:statistics.iqr` |
| `stat_skewness` | REAL or NULL | `metacheck:statistics.skewness` |
| `stat_kurtosis` | REAL or NULL | `metacheck:statistics.kurtosis` |

**FTS5 virtual table** (full-text search)

```sql
CREATE VIRTUAL TABLE variables_fts USING fts5(
  variable_id UNINDEXED,
  name,
  description,
  sample_values,
  content='variables',
  content_rowid='id'
);
```

Populated by inserting `(id, name, description, sample_values)` for every row in
`variables`. The FTS table enables substring + prefix matching across name AND
description in a single query.

**`provenance` table** — one row per file per study group

| Column | Type | Source |
|---|---|---|
| `id` | INTEGER PRIMARY KEY |  |
| `study_group_id` | INTEGER | FK → study_groups |
| `psychds_path` | TEXT | `file_provenance[i].psychds_path` |
| `original_rel_path` | TEXT | `file_provenance[i].original_rel_path` |
| `original_format` | TEXT | `file_provenance[i].original_format` |
| `pipeline_type` | TEXT | `file_provenance[i].pipeline_type` |
| `pipeline_group` | TEXT | `file_provenance[i].pipeline_group` |
| `pipeline_data_granularity` | TEXT or NULL | `file_provenance[i].pipeline_data_granularity` |
| `ground_truth_validated` | INTEGER | `file_provenance[i].ground_truth_validated` |
| `txt_extraction_attempted` | INTEGER or NULL | `file_provenance[i].txt_extraction_attempted` |
| `txt_extraction_skipped` | INTEGER or NULL | `file_provenance[i].txt_extraction_skipped` |
| `txt_skip_reason` | TEXT or NULL | `file_provenance[i].txt_skip_reason` |
| `txt_psychds_path` | TEXT or NULL | `file_provenance[i].txt_psychds_path` |

### 4.2 REST API

Base path: `/api`

All responses are JSON. Errors return `{"error": "<message>"}` with an appropriate
HTTP status code. Pagination uses `limit` (default 50, max 500) and `offset` (default 0).

#### 4.2.1 Health and Corpus

**`GET /health`**
Returns `{"status": "ok", "indexed": true}` when ready. Returns 503 with
`{"status": "indexing"}` while the initial index build is running.

**`GET /api/corpus/stats`**

Returns high-level corpus summary:

```json
{
  "n_papers": 312,
  "n_study_groups": 487,
  "n_variables": 94821,
  "n_labelled_variables": 12034,
  "n_ground_truth_validated_files": 1240,
  "pipeline_version": "021",
  "last_indexed": "2026-04-07T14:23:00Z"
}
```

#### 4.2.2 Paper List

**`GET /api/papers`**

Query parameters:

| Param | Type | Default | Description |
|---|---|---|---|
| `q` | string | — | Free-text search across title, description, keywords, author names |
| `has_labels` | boolean | — | Filter to papers where at least one variable is labelled |
| `has_ground_truth` | boolean | — | Filter to papers with validated ground truth |
| `limit` | integer | 50 | Max results |
| `offset` | integer | 0 | Pagination offset |

Response:

```json
{
  "total": 312,
  "papers": [
    {
      "paper_id": "0956797614557867",
      "title": "Psychological Language on Twitter…",
      "doi": "https://doi.org/10.1177/…",
      "authors": ["Eichstaedt J", "…"],
      "keywords": ["Twitter", "heart disease", "…"],
      "n_study_groups": 1,
      "n_variables": 29,
      "n_labelled_variables": 0,
      "has_ground_truth": false,
      "conversion_date": "2026-03-30"
    }
  ]
}
```

#### 4.2.3 Paper Detail

**`GET /api/papers/:paper_id`**

Returns full paper metadata plus list of study groups. The `study_groups` array is
ordered by study_group label (shared last within a paper).

Response:

```json
{
  "paper_id": "0956797614557867",
  "title": "…",
  "description": "…",
  "authors": ["…"],
  "doi": "…",
  "keywords": ["…"],
  "pipeline_version": "021",
  "conversion_date": "2026-03-30",
  "study_groups": [
    {
      "study_group": "shared",
      "study_dir": "study-shared",
      "title": "… — Study SHARED",
      "pipeline_status": {
        "index_success": true,
        "codebook_success": false,
        "n_files_total": 24,
        "n_data_files": 5,
        "n_columns": 29,
        "n_labelled_columns": 0,
        "label_status": "no_codebook"
      },
      "n_variables": 29,
      "n_labelled": 0,
      "has_ground_truth": false
    }
  ]
}
```

#### 4.2.4 Study Group Detail

**`GET /api/papers/:paper_id/groups/:study_group`**

Returns full dataset_description.json content plus provenance manifest and file tree.

Response:

```json
{
  "paper_id": "…",
  "study_group": "shared",
  "title": "…",
  "description": "…",
  "authors": ["…"],
  "doi": "…",
  "keywords": ["…"],
  "schema_version": "Psych-DS 0.1.0",
  "pipeline_status": { … },
  "source_repository": {
    "platform": "osf",
    "download_path": "data/0956797614557867/"
  },
  "shared_resources": "../shared/",
  "shared_files": ["…"],
  "variables": [
    {
      "name": "county",
      "description": null,
      "col_type": "text",
      "source_file": "Twitter_Predicts_Heart_Disease/countyoutcomes/countyoutcomes.csv",
      "sample_values": "Autauga | Baldwin | Blount | Butler | Calhoun",
      "statistics": null
    },
    {
      "name": "fips",
      "description": null,
      "col_type": "continuous",
      "source_file": "…",
      "sample_values": "1001 | 1003 | 1009 | 1013 | 1015",
      "min_value": 1001,
      "max_value": 56029,
      "statistics": {
        "n": 1347, "n_missing": 0, "mean": 30467.21,
        "sd": 15265.62, "se": 415.94, "median": 31019,
        "p25": 18101, "p75": 42099, "iqr": 23998,
        "skewness": -0.155, "kurtosis": -1.079
      }
    }
  ],
  "provenance": [
    {
      "psychds_path": "data/raw/countyoutcomes.csv",
      "original_rel_path": "Twitter_Predicts_Heart_Disease/countyoutcomes/countyoutcomes.csv",
      "original_format": "csv",
      "pipeline_type": "data",
      "pipeline_group": "shared",
      "pipeline_data_granularity": "combined",
      "ground_truth_validated": false
    }
  ]
}
```

#### 4.2.5 Variable Search

**`GET /api/variables/search`**

Full-text search across all variables in the corpus. Searches both `name` and
`description` fields.

Query parameters:

| Param | Type | Default | Description |
|---|---|---|---|
| `q` | string | required | Search query — matched against column name and codebook description |
| `col_type` | string | — | Filter to one or more col_type values, comma-separated |
| `has_description` | boolean | — | Filter to variables that have a codebook label |
| `paper_id` | string | — | Scope search to one paper |
| `limit` | integer | 50 | Max results |
| `offset` | integer | 0 | Offset |

Response:

```json
{
  "total": 34,
  "query": "age",
  "results": [
    {
      "variable_id": 18421,
      "paper_id": "0956797614524581",
      "paper_title": "The Pen Is Mightier…",
      "doi": "https://doi.org/10.1177/…",
      "study_group": "ex1",
      "name": "age",
      "description": "Participant age in years",
      "col_type": "continuous",
      "source_file": "…/study1_data.csv",
      "sample_values": "19 | 22 | 21 | 20 | 23",
      "min_value": 18,
      "max_value": 35,
      "statistics": { "n": 67, "mean": 21.4, … }
    }
  ]
}
```

Search implementation note: run an FTS5 query matching `name` OR `description` using
`MATCH` with `*` prefix/suffix for partial matching. Fall back to `LIKE '%q%'` for
queries that the FTS parser rejects (e.g. queries with special characters).

#### 4.2.6 Variable Detail

**`GET /api/variables/:variable_id`**

Returns all information for one variable, including the full source file context from
the matching `source-<slug>_data.json` sidecar.

Response augments the variable record with a `source_file_context` block:

```json
{
  "variable_id": 18421,
  "paper_id": "…",
  "study_group": "ex1",
  "name": "age",
  "description": "Participant age in years",
  "col_type": "continuous",
  "source_file": "…",
  "sample_values": "19 | 22 | 21 | 20 | 23",
  "min_value": 18,
  "max_value": 35,
  "statistics": { … },
  "source_file_context": {
    "original_file": {
      "rel_path": "Study_1/data.csv",
      "format": "csv",
      "size_bytes": 14290,
      "data_granularity": "combined"
    },
    "conversion": {
      "method": "read.csv",
      "encoding_normalized": false,
      "haven_labels_extracted": false,
      "rows_written": 67,
      "columns_written": 22
    },
    "sibling_variables": [
      { "name": "condition", "col_type": "categorical", "description": null },
      { "name": "score_factual", "col_type": "continuous", "description": "…" }
    ]
  }
}
```

`source_file_context` is populated by reading the matching `source-*_data.json` file.
If no matching sidecar exists, `source_file_context` is `null`.

`sibling_variables` lists all other variables in the same source file (names, types,
descriptions only — no statistics).

#### 4.2.7 Pipeline Transparency

**`GET /api/pipeline/stages`**

Returns static documentation of every pipeline stage that could have affected the
data. This endpoint returns a hardcoded document embedded in the backend at build time
(not read from disk at runtime). It is used by the frontend to render the "How was this
produced?" panel.

Response:

```json
{
  "stages": [
    {
      "id": "osf_download",
      "name": "OSF Download",
      "description": "Files are downloaded from the Open Science Framework (OSF) repository associated with the paper's DOI. The download is limited to 10 GB. All file types are downloaded regardless of content.",
      "outputs": ["data/<paper_id>/"]
    },
    {
      "id": "archive_unpack",
      "name": "Archive Unpacking",
      "description": "ZIP, TAR, TGZ, GZ, BZ2, and XZ archives are unpacked recursively. Standalone compressed files (.gz, .bz2, .xz) are treated as single compressed files, not tar archives.",
      "outputs": ["data/<paper_id>/"]
    },
    {
      "id": "file_classification",
      "name": "LLM File Classification",
      "description": "Each file path is classified into a type (data/codebook/code/software/output/supplemental/readme/asset/other) and assigned to an experiment group (ex1, ex2, shared, etc.) by a local LLM (batches of 20 paths). Folders with more than 50 files are treated as aggregate folders and classified via a second-pass sentinel prompt.",
      "outputs": ["outputs/<paper_id>/structure.csv"]
    },
    {
      "id": "ground_truth_override",
      "name": "Manual Ground Truth Override",
      "description": "After LLM classification, a human annotator may review file types and groups using the validation GUI. Ground truth entries override LLM classifications. The 'ground_truth_validated' flag in provenance.json indicates which files received manual review.",
      "outputs": ["ground_truth/<paper_id>.csv"]
    },
    {
      "id": "column_extraction",
      "name": "Column Extraction and Statistics",
      "description": "Files classified as type=data with data_format=tabular are read (up to 500 MB). Each column is extracted and classified by type using a rule-based system first, then an LLM for ambiguous cases. Descriptive statistics (mean, SD, median, IQR, skewness, kurtosis) are computed for numeric columns.",
      "outputs": ["outputs/<paper_id>/columns.csv"]
    },
    {
      "id": "codebook_labelling",
      "name": "Codebook Labelling",
      "description": "Codebook and README files are parsed to extract variable descriptions. These descriptions are matched to data columns using rule-based string normalization, with an LLM fallback for fuzzy matches. The 'description' field on each variable (when present) came from this stage.",
      "outputs": ["outputs/<paper_id>/labels.csv", "outputs/<paper_id>/codebook_coverage.csv"]
    },
    {
      "id": "psychds_conversion",
      "name": "PsychDS Conversion",
      "description": "The pipeline outputs are reorganized into the Psych-DS 0.1.0 directory structure. Files are assigned to subdirectories (data/, analysis/, documentation/, materials/) by their pipeline type. Tabular data files are normalized to UTF-8 CSV. Variable statistics are written to JSON sidecars. The provenance.json records the original path of every file.",
      "outputs": ["psychds/<paper_id>/"]
    }
  ]
}
```

**`GET /api/pipeline/col_types`**

Returns static documentation of all column type values (from §2.6 of this spec).

**`GET /api/pipeline/file_types`**

Returns static documentation of all file type values (from §2.5 of this spec).

#### 4.2.8 Paper Downloads

**`GET /api/papers/:paper_id/download`**

Streams a ZIP archive of the entire `psychds/<paper_id>/` directory tree (all study
groups). The response is `Content-Type: application/zip` with header
`Content-Disposition: attachment; filename="psychds-<paper_id>.zip"`.

The ZIP preserves the relative directory structure exactly as it exists in the
mounted `psychds/` directory:

```
psychds-0956797614557867.zip
  study-shared/
    dataset_description.json
    provenance.json
    data/
      raw/
        countyoutcomes.csv
        ...
      source-countyoutcomes_data.csv
      source-countyoutcomes_data.json
    analysis/
    documentation/
```

No files are modified or filtered — the ZIP is a verbatim copy of the directory.

A `DOWNLOAD_MANIFEST.csv` is injected at the ZIP root (not from disk — generated at
request time) containing one row per file:

| Column | Description |
|---|---|
| `psychds_path` | Path of the file within the ZIP (relative to ZIP root) |
| `original_rel_path` | Original path in the OSF download tree (from provenance.json) |
| `original_format` | Original file extension |
| `pipeline_type` | Pipeline file classification (data/codebook/code/etc.) |
| `pipeline_group` | Experiment group assignment |
| `ground_truth_validated` | Whether this file was manually reviewed |
| `study_group` | Study group this file belongs to |

**`GET /api/papers/:paper_id/groups/:study_group/download`**

Streams a ZIP of a single study group directory only:
`psychds/<paper_id>/<study_dir>/`. Same manifest injection logic.
Filename: `psychds-<paper_id>-<study_group>.zip`.

**`GET /api/papers/:paper_id/download/size`**

Returns estimated ZIP size before initiating the download (used by the frontend to
show a size warning for large papers):

```json
{
  "paper_id": "0956797614557867",
  "n_files": 24,
  "total_bytes_uncompressed": 14920381,
  "study_groups": [
    { "study_group": "shared", "n_files": 24, "total_bytes_uncompressed": 14920381 }
  ]
}
```

Size is computed by summing file sizes on disk — no compression is applied at this
stage. Actual ZIP size will be smaller for compressible files.

#### 4.2.9 Variable Downloads

Variable downloads bundle all normalized data files across the corpus that contain a
variable matching a search query (or a specific variable by ID). The download target
is the `source-*_data.csv` file for each matching source file — the UTF-8 normalized,
pipeline-standardized version, not the original raw file.

**`GET /api/variables/search/download`**

Query parameters — identical to `GET /api/variables/search` plus:

| Param | Type | Default | Description |
|---|---|---|---|
| `q` | string | required | Same search query used in the search UI |
| `col_type` | string | — | Same filter |
| `has_description` | boolean | — | Same filter |
| `deduplicate_files` | boolean | `true` | When multiple variables from the same source file match, include that CSV only once |

Returns a ZIP archive. Filename: `variable-search-<q_slugified>.zip`.

**ZIP contents:**

```
variable-search-age.zip
  MANIFEST.csv                          ← generated at request time
  0956797614524581/
    study-ex1/
      source-graphsforcorrigendumstudyonedata_data.csv
  0956797614557867/
    study-shared/
      source-countyoutcomes_data.csv
      source-countyfreqstopics_data.csv
```

**`MANIFEST.csv` — one row per included CSV file:**

| Column | Description |
|---|---|
| `paper_id` | Paper identifier |
| `study_group` | Study group label (ex1, shared, etc.) |
| `paper_title` | Full paper title from dataset_description.json |
| `doi` | Paper DOI |
| `zip_path` | Path of this CSV within the ZIP |
| `original_rel_path` | Original path in the OSF download tree |
| `original_format` | Original file format (csv, sav, xlsx, etc.) |
| `pipeline_data_granularity` | `individual` or `combined` |
| `n_rows` | Rows in this CSV (from `metacheck:conversion.rows_written` in the sidecar) |
| `n_columns` | Columns in this CSV |
| `matching_variables` | Pipe-separated list of variable names in this file that matched the search query |
| `matching_variable_descriptions` | Pipe-separated codebook descriptions for those variables (empty string if unlabelled) |
| `ground_truth_validated` | Whether this file was manually reviewed in the validation GUI |
| `conversion_method` | R read function used (from sidecar `metacheck:conversion.method`) |
| `encoding_normalized` | Whether latin1 re-encoding was applied |

**`GET /api/variables/:variable_id/download`**

Downloads all CSV files containing the specific variable identified by `variable_id`.
Equivalent to `GET /api/variables/search/download` scoped to the single source file
for that variable. Filename: `variable-<variable_name_slugified>.zip`.

This is used from the Variable Detail Modal — a single "Download all files with this
variable" button.

**`GET /api/variables/search/download/size`**

Returns a size estimate for the variable download before streaming:

```json
{
  "query": "age",
  "n_matching_variables": 34,
  "n_source_files": 18,
  "n_papers": 12,
  "total_bytes_uncompressed": 8340291
}
```

#### 4.2.10 Download Implementation Notes

**Streaming ZIP generation:** All download endpoints must stream the ZIP response
incrementally — do not buffer the entire archive in memory before responding. Use a
streaming ZIP library appropriate to the backend language:
- Python: `zipstream-ng` or `zipfly`
- Node.js: `archiver` with pipe to response
- Go: `archive/zip` writer piped to `http.ResponseWriter`

**Concurrency:** ZIP generation for large papers or wide variable searches may be
slow. The backend should set a generous response timeout (120s) and use chunked
transfer encoding. The frontend shows a progress indicator while awaiting the first
byte.

**No ZIP-within-ZIP:** Study group directories inside a paper download are placed as
subdirectories, not nested ZIPs.

**`data/raw/` inclusion in paper downloads:** Raw files are included in paper
downloads. They are verbatim copies of the original OSF files — some may be large
(EEG recordings, video). The `/download/size` endpoint helps the UI warn the user
before they initiate.

**Variable downloads include only normalized CSVs**, not raw files. The raw files
may be un-parseable (EEG, MATLAB matrices) and are not the target of variable-level
analysis. The MANIFEST.csv makes the provenance chain explicit so the researcher
can trace back to the original if needed.

---

## 5. Frontend

### 5.1 Technology

- Framework: React 18+
- Build tool: Vite
- HTTP client: native `fetch` (no external HTTP libraries)
- Styling: CSS Modules or Tailwind CSS — no UI component framework required, but one
  may be used (e.g. shadcn/ui, Radix UI)
- No client-side routing library is required; the app is two pages

### 5.2 Page Structure

The application has two top-level views accessible via tabs or navigation links:

1. **Papers** — browse and search at the paper level
2. **Variables** — search across all variables in the corpus

A persistent header shows:
- Application name: "PsychDS Viewer"
- Corpus stats from `/api/corpus/stats`: N papers, N variables, N labelled
- Tab navigation: Papers | Variables

### 5.3 Papers View

#### 5.3.1 Paper List Panel (left ~35%)

- Search box: filters the paper list by title, author, keyword (calls `GET /api/papers?q=…`)
- Checkboxes: "Has codebook labels" / "Has ground truth validation"
- Scrollable list of paper cards, each showing:
  - Paper title (truncated to 2 lines)
  - Authors (first 3, then "et al.")
  - N study groups | N variables | N labelled
  - Small badge: ground truth validated (if applicable)
  - Download icon button (⬇) — clicking without selecting the paper triggers the
    full-paper download size-check and confirm flow inline in the card
- Selected paper card is highlighted
- Clicking the card body (not the download icon) loads the paper detail panel

#### 5.3.2 Paper Detail Panel (right ~65%)

Tabs within this panel:

**Tab 1: Overview**
- Full title, description (abstract)
- DOI as clickable link
- Authors list
- Keywords as chips
- Pipeline metadata: pipeline version, conversion date, source platform
- **"Download full paper" button**: fetches `/api/papers/:paper_id/download/size`,
  shows a confirmation panel with total file count and uncompressed size
  (e.g. "24 files, ~14.2 MB"), then on confirm streams the full paper ZIP from
  `GET /api/papers/:paper_id/download`

**Tab 2: Studies**

List of study groups for this paper. Each study group row shows:
- Study group label (e.g. "Study 1 (ex1)")
- Pipeline status icons: ✓/✗ for index_success and codebook_success
- N variables | N labelled | label_status badge
- **Download button** (per study group): triggers `GET /api/papers/:paper_id/groups/:study_group/download`; first fetches size from `/download/size`, shows size + file count in a confirmation tooltip, then initiates the download
- Clicking a study group row expands an inline detail section showing:
  - Study title and description
  - Variable table (see §5.3.3)
  - Provenance table (see §5.3.4)
  - "Shared files" section if `metacheck:shared_resources` is set

**Tab 3: All Variables**

Shows a merged variable table across all study groups for this paper.
Includes a study group column for disambiguation.

#### 5.3.3 Variable Table

Columns: Name | Description | Type | Source File | N | Mean | SD | Sample Values

- Type column shows a colored badge for each col_type value
- "Name" and "Description" columns are sortable
- Row click opens the Variable Detail Modal (§5.5)
- Rows where `description` is null have a dimmed appearance
- Rows where `col_type = "llm_error"` are flagged in red

#### 5.3.4 Provenance Table

Columns: PsychDS Path | Original Path | Format | Type | Group | Granularity | GT Validated

- "GT Validated" column shows ✓ or — (not a boolean toggle — read only)
- "Type" column shows a colored badge for each pipeline_type value
- "Original Path" is the full path in the original OSF repository — this is what
  the researcher would see when browsing the OSF page
- Rows where `pipeline_type = "llm_error"` are highlighted

### 5.4 Variables View

#### 5.4.1 Search Bar

- Prominent search input at top of page
- Searches both column names and codebook descriptions simultaneously
- Calls `GET /api/variables/search?q=…` on each keystroke (debounced 300ms)
- Filters: col_type (multi-select dropdown), has_description (checkbox)

#### 5.4.2 Results Table

Columns: Variable Name | Description | Type | Paper | Study | Source File | N | Mean | Min | Max

- Sorted by relevance (FTS5 rank)
- Shows match context: the matched term is highlighted in the Name and Description cells
- "Paper" column links to the paper detail panel
- Row click opens the Variable Detail Modal (§5.5)
- Empty state: "Search for a variable name or codebook description above"

#### 5.4.3 Variable Search Download

When the results table is non-empty, a **"Download all matching data files"** button
appears above the table. Workflow:

1. User clicks the button
2. Frontend fetches `GET /api/variables/search/download/size` with the current query
   and filter params
3. A confirmation panel appears showing:
   - "N matching variables across M source files from K papers"
   - "Estimated size: ~X MB (uncompressed)"
   - Checkbox: "Deduplicate files" (pre-checked; maps to `deduplicate_files=true`)
   - A note: "Download includes normalized CSV files only, plus a MANIFEST.csv
     describing provenance for every file"
4. User confirms → browser initiates download from
   `GET /api/variables/search/download` with the same params
5. A spinner or progress bar is shown while the browser receives the ZIP
   (large downloads may take several seconds to begin streaming)

The "Download all matching data files" button is disabled when no query is entered.

### 5.5 Variable Detail Modal

Opens when clicking any variable row. Shows a two-tab modal:

**Tab 1: Variable**
- Name, description (if any)
- col_type badge with explanation from the type vocabulary
- Source file (original path)
- Sample values (pipe-split into chips)
- Statistics table (if numeric):

  | Stat | Value |
  |---|---|
  | N (valid) | 1347 |
  | N (missing) | 0 |
  | Mean | 30,467.21 |
  | SD | 15,265.62 |
  | SE | 415.94 |
  | Median | 31,019 |
  | IQR | 23,998 |
  | Min | 1,001 |
  | Max | 56,029 |
  | Skewness | −0.155 |
  | Kurtosis | −1.079 |

- For binary columns: shows valuePattern (the two values)
- For categorical/text columns: shows sample_values

**Tab 2: Provenance**
- Section "Source File Context" (from `source_file_context` in the API response):
  - Original file path in the OSF repository
  - Original format (file extension)
  - File size
  - Conversion method (which R function read this file)
  - Encoding normalized? (did the pipeline re-read in latin1?)
  - Haven labels extracted? (SPSS/Stata label extraction)
  - Rows written | Columns written in the normalized CSV
- Section "Sibling Variables": list of other columns in the same source file, as chips
  colored by col_type
- Section "How was this produced?": collapsible cards for each pipeline stage that
  contributed to this variable's data (fetched from `GET /api/pipeline/stages`)

**Download actions** (footer of the modal, always visible regardless of active tab):

- **"Download this data file"** button: downloads the single `source-*_data.csv` for
  this variable's source file — calls `GET /api/variables/:variable_id/download` and
  streams a ZIP containing that one CSV plus a MANIFEST.csv
- **"Download all files with this variable"** button: same endpoint but conceptually
  framed as a corpus-wide action. Because a variable name like `age` may appear in
  many papers, this is equivalent to doing a search download for the exact variable
  name scoped to no filters. Shows a size-confirmation step using
  `GET /api/variables/search/download/size?q=<exact_name>` before streaming.

### 5.7 Visual Design

#### 5.7.1 Design Philosophy

The viewer is a **research tool, not a marketing page.** The aesthetic should be clean,
high-information-density, and neutral — similar in spirit to a well-designed academic
database browser (e.g. PsycNET, PubMed, OSF.io) rather than a consumer product.

Key principles:
- **Information density over whitespace:** researchers need to scan many papers and
  variables quickly; compact rows with clear typographic hierarchy beat generous padding
- **Trust through transparency:** every classification is labelled with its source
  (LLM vs. rule vs. ground truth); data quality signals are always visible, never
  hidden behind a click
- **Color communicates status, not decoration:** the badge color system is systematic
  and consistent; any implementation that adds color for aesthetic reasons risks
  confusion with the status color system

#### 5.7.2 Color Palette

Two modes are required: **light** (default) and **dark** (toggled via a button in the
header; preference persisted to `localStorage`).

**Base palette (CSS custom properties):**

```css
:root {
  --color-bg:           #f8f9fb;   /* page background */
  --color-surface:      #ffffff;   /* cards, panels, modals */
  --color-surface-2:    #f1f3f6;   /* table striping, nested sections */
  --color-border:       #dde1e7;   /* dividers, table borders */
  --color-border-focus: #3b82f6;   /* focus rings */
  --color-text-primary: #111827;   /* headings, primary labels */
  --color-text-secondary: #6b7280; /* metadata, captions */
  --color-text-muted:   #9ca3af;   /* placeholder, disabled */
  --color-accent:       #2563eb;   /* links, active tab indicator, primary buttons */
  --color-accent-hover: #1d4ed8;

  --color-success:      #16a34a;   /* ground truth validated badge */
  --color-warning:      #d97706;   /* LLM-classified (less certain) items */
  --color-error:        #dc2626;   /* llm_error rows and badges */
  --color-info:         #0891b2;   /* informational highlights */
}

[data-theme="dark"] {
  --color-bg:           #0f1117;
  --color-surface:      #1a1d27;
  --color-surface-2:    #222535;
  --color-border:       #2e3347;
  --color-border-focus: #60a5fa;
  --color-text-primary: #f1f5f9;
  --color-text-secondary: #94a3b8;
  --color-text-muted:   #475569;
  --color-accent:       #3b82f6;
  --color-accent-hover: #60a5fa;

  --color-success:      #22c55e;
  --color-warning:      #f59e0b;
  --color-error:        #ef4444;
  --color-info:         #22d3ee;
}
```

#### 5.7.3 Typography

- **Font family:** System font stack — `"Inter", ui-sans-serif, system-ui, -apple-system, sans-serif`
- **Monospace (paths, variable names, sample values):** `"JetBrains Mono", "Fira Code", ui-monospace, monospace`
- **Font sizes:**

| Role | Size | Weight | Line height |
|---|---|---|---|
| Page title / modal heading | 18px | 600 | 1.3 |
| Section heading | 14px | 600 | 1.4 |
| Body / table cells | 13px | 400 | 1.5 |
| Monospace (paths, names) | 12px | 400 | 1.4 |
| Caption / metadata | 12px | 400 | 1.4 |
| Badge text | 11px | 500 | 1 |

Numbers in statistics tables use **tabular numerals** (`font-variant-numeric: tabular-nums`)
so columns align when scanning vertically.

#### 5.7.4 Layout Wireframes

**Overall shell:**

```
┌──────────────────────────────────────────────────────────────────┐
│  PsychDS Viewer          312 papers · 94,821 variables  [☀/🌙]  │
│  ─────────────────────────────────────────────────────────────── │
│  [ Papers ]  [ Variables ]                                        │
└──────────────────────────────────────────────────────────────────┘
```

Header height: 56px. Full-width, `position: sticky; top: 0; z-index: 100`.
Right side of header shows corpus stats in muted text and a light/dark toggle button.

---

**Papers view (two-panel split):**

```
┌────────────────────┬─────────────────────────────────────────────┐
│ 🔍 Search papers…  │  The Pen Is Mightier Than the Keyboard       │
│ ☐ Labels  ☐ GT    │  Mueller P, Oppenheimer D, et al.            │
│ ─────────────────  │  ─────────────────────────────────────────── │
│ ┌────────────────┐ │  [ Overview ]  [ Studies ]  [ All Variables ]│
│ │ The Pen Is…    │ │                                              │
│ │ Mueller et al. │ │  Abstract text here, truncated to 4 lines   │
│ │ 3 studies · 84 │ │  with a "Show more" expand control.         │
│ │ variables  ⬇  │ │                                              │
│ └────────────────┘ │  DOI: https://doi.org/10.1177/…  ↗          │
│ ┌────────────────┐ │  Keywords: [memory] [laptops] [education]   │
│ │ Twitter and…   │ │                                              │
│ │ Eichstaedt J…  │ │  Pipeline v021 · Converted 2026-03-30       │
│ │ 1 study · 29   │ │  Source: OSF                                │
│ │ variables  ⬇  │ │                                              │
│ └────────────────┘ │  [ ⬇ Download full paper (24 files, ~14 MB)]│
│  ...               │                                              │
└────────────────────┴─────────────────────────────────────────────┘
```

Left panel: `min-width: 280px; max-width: 360px; width: 30%`. Resizable via a
draggable divider. Right panel fills remaining width.

---

**Variables view:**

```
┌──────────────────────────────────────────────────────────────────┐
│  🔍  Search variable names and descriptions…                      │
│      Filters: [ col_type ▾ ]  [ ☐ Has description ]             │
│                                                                    │
│  34 results for "age"                    [ ⬇ Download all (18 files) ] │
│  ──────────────────────────────────────────────────────────────── │
│  Name       Description         Type        Paper       N   Mean  │
│  ──────────────────────────────────────────────────────────────── │
│  age        Participant age in  [continuous] The Pen Is… 67  21.4 │
│  **age**    —                   [continuous] Twitter…    843  —   │
│  age_group  Age group (18–25…   [categorical] Study of… —    —   │
│  ...                                                              │
└──────────────────────────────────────────────────────────────────┘
```

Search input: full-width, prominent (height 44px, 16px font). Results toolbar appears
below once a query is entered.

---

**Variable Detail Modal:**

```
┌─────────────────────────────────────────────────────────┐
│  age                                      [continuous]  ✕│
│  "Participant age in years"                              │
│  ─────────────────────────────────────────────────────  │
│  [ Variable ]  [ Provenance ]                           │
│  ─────────────────────────────────────────────────────  │
│  Source file   Study_1/participants.csv                 │
│  Sample values [19] [22] [21] [20] [23]                 │
│                                                         │
│  ┌───────────────────────────────────┐                  │
│  │ N (valid)   67   │  Mean  21.4    │                  │
│  │ N (missing)  0   │  SD     2.1    │                  │
│  │ Min         18   │  Median 21     │                  │
│  │ Max         35   │  IQR    3      │                  │
│  │ Skewness  +0.4   │  Kurtosis -0.2 │                  │
│  └───────────────────────────────────┘                  │
│  ─────────────────────────────────────────────────────  │
│  [ ⬇ Download this file ]  [ ⬇ Download all "age" files]│
└─────────────────────────────────────────────────────────┘
```

Modal width: `min(720px, 95vw)`. Max height: `85vh`, scrollable body. The footer with
download buttons is `position: sticky; bottom: 0` within the modal.

#### 5.7.5 Type Badge System

Badges appear on every variable row and every provenance row. They are small colored
pills with a text label inside.

**Column type badge colors:**

| `col_type` | Light bg | Light text | Dark bg | Dark text | Rationale |
|---|---|---|---|---|---|
| `continuous` | `#dbeafe` | `#1e40af` | `#1e3a5f` | `#93c5fd` | Blue — standard numeric |
| `continuous_comma_decimal` | `#dbeafe` | `#1e40af` | `#1e3a5f` | `#93c5fd` | Same as continuous |
| `continuous_outliers_excluded` | `#fef3c7` | `#92400e` | `#3d2800` | `#fcd34d` | Amber — data quality note |
| `ordinal` | `#e0e7ff` | `#3730a3` | `#1e1b4b` | `#a5b4fc` | Indigo — ordered scale |
| `categorical` | `#d1fae5` | `#065f46` | `#052e1c` | `#6ee7b7` | Green — discrete groups |
| `binary` | `#fce7f3` | `#9d174d` | `#3d0726` | `#f9a8d4` | Pink — two-value |
| `date` | `#cffafe` | `#155e75` | `#082832` | `#67e8f9` | Cyan — temporal |
| `id` | `#f3f4f6` | `#374151` | `#1f2937` | `#d1d5db` | Gray — identifier, not a measure |
| `text` | `#f3f4f6` | `#374151` | `#1f2937` | `#d1d5db` | Gray — string, not a measure |
| `constant` | `#f3f4f6` | `#6b7280` | `#1f2937` | `#6b7280` | Muted gray — degenerate |
| `empty` | `#f3f4f6` | `#9ca3af` | `#1f2937` | `#4b5563` | Very muted — no data |
| `unknown` | `#fef3c7` | `#92400e` | `#3d2800` | `#fcd34d` | Amber — uncertain |
| `llm_error` | `#fee2e2` | `#991b1b` | `#3b0000` | `#fca5a5` | Red — pipeline failure |

**File (pipeline) type badge colors:**

| `pipeline_type` | Light bg | Light text | Rationale |
|---|---|---|---|
| `data` | `#dbeafe` | `#1e40af` | Blue — primary research artifact |
| `codebook` | `#d1fae5` | `#065f46` | Green — describes data |
| `code` | `#e0e7ff` | `#3730a3` | Indigo — executable |
| `software` | `#ede9fe` | `#4c1d95` | Purple — experiment program |
| `output` | `#fce7f3` | `#9d174d` | Pink — script product |
| `supplemental` | `#f3f4f6` | `#374151` | Gray — documentation |
| `readme` | `#f3f4f6` | `#6b7280` | Muted gray |
| `asset` | `#cffafe` | `#155e75` | Cyan — stimuli |
| `other` | `#f3f4f6` | `#9ca3af` | Very muted |
| `llm_error` | `#fee2e2` | `#991b1b` | Red — failure |

Badge anatomy: `border-radius: 4px; padding: 2px 7px; font-size: 11px; font-weight: 500;
white-space: nowrap; display: inline-block`. Dark-mode variants use the same hue at
lower lightness with higher-contrast text.

#### 5.7.6 Paper Card Design

```
┌────────────────────────────────────────────┐
│ The Pen Is Mightier Than the Keyboard      │  ← 14px, 600, 2-line clamp
│ Mueller P, Oppenheimer D + 3 more          │  ← 12px, secondary, 1 line
│ ─────────────────────────────────────────  │
│ 3 studies  ·  84 vars  ·  12 labelled  ⬇  │  ← 12px, muted; ⬇ is a button
│                         [✓ GT]             │  ← success badge, only if validated
└────────────────────────────────────────────┘
```

- Card height: `auto`, min ~72px
- `padding: 12px 14px`
- `border-left: 3px solid transparent` — becomes `var(--color-accent)` when selected
- `background: var(--color-surface)` normally; `var(--color-surface-2)` on hover;
  `var(--color-surface)` with the left border when selected
- Download icon (⬇) is a 24×24 clickable icon button in the bottom-right of the card.
  It has its own hover state (`background: var(--color-surface-2)`) and does not
  trigger paper selection when clicked
- The "GT" (ground truth) badge uses `--color-success` background and is only shown
  when `has_ground_truth = true`

#### 5.7.7 Statistics Display

For numeric variables, stats are shown in a **2-column grid** (not a vertical list).
Left column: counts and central tendency. Right column: spread and shape.

```
┌──────────────────┬──────────────────────┐
│ N (valid)   1347 │ Mean       30,467.2  │
│ N (missing)    0 │ SD         15,265.6  │
│ Min         1001 │ SE            415.9  │
│ Max        56029 │ Median     31,019    │
│                  │ IQR        23,998    │
│                  │ P25        18,101    │
│                  │ P75        42,099    │
│                  │ Skewness      −0.155 │
│                  │ Kurtosis      −1.079 │
└──────────────────┴──────────────────────┘
```

- Font: monospace, 12px, tabular-nums
- Background: `var(--color-surface-2)`, `border-radius: 6px`, `padding: 10px 14px`
- Stat labels: `var(--color-text-secondary)`; values: `var(--color-text-primary)`
- Negative skewness and kurtosis always show the minus sign; positive always shows no sign
  (not "+") to match statistical convention

#### 5.7.8 Sample Value Chips

Sample values (from `metacheck:sample_values`, pipe-separated) are displayed as
individual chips rather than raw text:

```
[Autauga]  [Baldwin]  [Blount]  [Butler]  [Calhoun]
```

Each chip: `background: var(--color-surface-2); border: 1px solid var(--color-border);
border-radius: 4px; padding: 2px 8px; font-family: monospace; font-size: 12px`.

Long values are truncated at 24 characters with a `title` attribute showing the full
value on hover.

#### 5.7.9 Download Confirmation UI

When a download is triggered (paper or variable), show an **inline confirmation
popover** anchored to the button that triggered it — not a full modal dialog.

Popover contents:

```
┌─────────────────────────────────────────┐
│ Download: psychds-0956797614557867.zip  │
│ 24 files  ·  ~14.2 MB (uncompressed)   │
│                                         │
│ Includes: data files, documentation,    │
│ analysis code, and MANIFEST.csv         │
│                                         │
│ [Cancel]              [⬇ Download]      │
└─────────────────────────────────────────┘
```

For variable downloads, the popover shows additional context:

```
┌─────────────────────────────────────────┐
│ Download: variable-search-age.zip       │
│ 34 variables · 18 files · 12 papers    │
│ ~8.3 MB (uncompressed)                  │
│                                         │
│ Includes normalized CSVs + MANIFEST.csv │
│ ☑ Deduplicate files                     │
│                                         │
│ [Cancel]              [⬇ Download]      │
└─────────────────────────────────────────┘
```

- Popover width: `min(340px, 90vw)`
- Show a loading spinner while the size API call is in flight; replace with content
  once resolved
- After "Download" is clicked: disable the button, replace its label with a spinner,
  re-enable when the browser has accepted the file (i.e., after the first byte of the
  response is received)

#### 5.7.10 Loading and Empty States

**Index not ready (startup):**
Full-page centered message: "Building search index…" with an animated progress ring.
Poll `GET /health` every 2 seconds; transition to the main UI when `indexed: true`.

**Search — no query entered (Variables view):**
Centered illustration area (placeholder graphic or simple icon) with text:
"Search for a variable name or codebook description to explore the corpus."

**Search — zero results:**
"No variables found for '*query*'. Try a shorter term or remove filters."

**Paper not found:**
If a paper_id in the URL no longer exists: "This paper is not in the index.
It may have been removed from the corpus, or the index may need rebuilding."

**Download in progress:**
The download button shows a spinner and disabled state. A dismissible toast appears
at the bottom-right: "Preparing download… this may take a moment for large packages."
Toast auto-dismisses after 8s or when the file transfer begins.

**Error state (API failure):**
Red inline error banner below the triggering control:
"Something went wrong: *error message*. Try again or check the server logs."

#### 5.7.11 Provenance Indicators

Three visual indicators appear throughout the UI to communicate data quality at a
glance. They are consistent across every context where they appear.

**Ground Truth Validated badge:**
`[✓ Reviewed]` — small pill, `--color-success` background. Appears on:
- Paper cards (if any file in the paper was reviewed)
- Individual provenance table rows (`ground_truth_validated = true`)
- The source file context section in the Variable Detail Modal

**LLM Error badge:**
`[⚠ LLM Error]` — `--color-error` background. Appears on:
- Variable table rows where `col_type = "llm_error"`
- Provenance table rows where `pipeline_type = "llm_error"`
A tooltip on hover explains: "The LLM classifier failed on all retry attempts for this
item. Classification could not be determined."

**Label status badges** (shown in the Studies tab per study group):

| `label_status` | Badge | Color |
|---|---|---|
| `ok` | `[✓ Labelled]` | `--color-success` |
| `no_match` | `[No matches]` | `--color-warning` |
| `no_codebook` | `[No codebook]` | gray / `--color-text-muted` |

#### 5.7.12 Responsive Behavior

The app is primarily designed for desktop (≥1024px wide). Two breakpoints are defined:

**≥1024px (desktop):** Full two-panel Papers view. Variables view shows all table columns.

**768px–1023px (tablet):** Papers view collapses to single-panel: paper list is shown
first, clicking a card navigates to a full-width detail view (back button appears in
the header). Variables view hides the "Source File" and "Paper" columns; tap a row to
open the modal.

**<768px (mobile):** Same single-panel navigation as tablet. Statistics grid becomes
single-column. Modal fills the full screen with a close button in the top-right.

### 5.6 Pipeline Transparency Panel

Accessible as a persistent "?" or "About the Pipeline" link in the footer.
Opens a full-page overlay or sidebar showing:

1. **Data flow diagram** (static SVG or ASCII art embedded in the frontend):
   ```
   OSF Repository
        ↓ download
   Raw Files
        ↓ unpack archives
        ↓ LLM file classification
        ↓ [optional: manual ground truth override]
        ↓ column extraction + statistics
        ↓ codebook labelling
        ↓ PsychDS conversion
   PsychDS Output (what this viewer reads)
   ```

2. **Stage detail cards** — one per stage from `GET /api/pipeline/stages`:
   - Stage name
   - Description
   - What outputs it produced (files/fields)

3. **Type vocabularies** — two expandable tables:
   - File types from `GET /api/pipeline/file_types`
   - Column types from `GET /api/pipeline/col_types`

4. **Data quality indicators** used throughout the UI:
   - Ground truth validated badge meaning
   - `llm_error` badge meaning
   - `label_status` values meaning

---

## 6. Data Integrity and Edge Cases

### 6.1 paper_id as string

`paper_id` values must be stored and compared as strings at every layer (SQLite TEXT,
JSON strings, URL path params). Never parse as integer. Example paper IDs start with
`09567976…` — if cast to float, leading structure is lost.

### 6.2 Missing or incomplete study groups

Some papers have a `study-shared` directory containing shared files but no
`dataset_description.json`. The indexer skips these directories silently. The frontend
shows them only if referenced via `metacheck:shared_files` in another study group's
description.

### 6.3 Variables without statistics

`metacheck:statistics` is absent for non-numeric column types (text, categorical,
binary, ordinal, id, date, constant, empty, unknown, llm_error). The UI must treat
null statistics gracefully — show "—" in numeric cells, not an error.

### 6.4 Variables without codebook labels

`description` is absent from the JSON entry when no codebook match was found. The
variable is still shown in the UI — the description cell shows "—" or is left blank.
These are the majority of variables in the corpus.

### 6.5 Sidecar JSON file resolution

To find the sidecar for a variable with `metacheck:source_file = "Some_Study/data.csv"`:
1. Strip all non-alphanumeric characters from the filename (excluding the extension)
2. The sidecar is named `source-<slug>_data.json` where slug is the normalized
   lowercase filename without extension
3. Look in `<paper_id>/<study_dir>/data/` for files matching `source-*_data.json`
4. If multiple sidecar files exist, match by the `metacheck:original_file.rel_path`
   field inside each sidecar

### 6.6 LLM error rows

Variables and files with `col_type = "llm_error"` or `pipeline_type = "llm_error"`
indicate that the LLM classification pipeline failed after all retries. These are
shown in the UI with a red error badge. They are included in counts and search results.

### 6.7 Ground truth override

When `ground_truth_validated = true` in provenance.json, the `pipeline_type` and
`pipeline_group` fields already reflect the validated (corrected) values — the
override has been applied. The flag indicates only that human review occurred, not
that the pipeline's initial classification was wrong.

### 6.8 Shared files deduplication

A file listed in `metacheck:shared_files` in a study group's `dataset_description.json`
is stored physically in the sibling `shared/` directory. When showing the file manifest
for a study group, these files are shown with a "shared" indicator. They are NOT
duplicated in the variables index — only the study group that "owns" the
`dataset_description.json` for the shared directory indexes its variables.

---

## 7. Non-Functional Requirements

### 7.1 Performance

- Initial index build for 300 papers (~90,000 variables) must complete within 60
  seconds on a 4-core machine
- Paper list endpoint must respond within 100ms for paginated queries
- Variable search must respond within 200ms for FTS5 queries
- The SQLite database must be persisted to `/tmp/viewer_index.db` to survive container
  restarts without re-indexing
- ZIP download endpoints must begin streaming within 2s of the request. Do not buffer
  the full archive in memory. Use streaming ZIP generation (see §4.2.10)
- `/download/size` endpoints must respond within 300ms — they only sum file sizes from
  disk metadata, no file contents are read

### 7.2 Correctness

- All numeric values in the UI must be formatted with locale-appropriate thousands
  separators and 4 significant figures maximum
- Skewness and kurtosis must show their sign (±)
- Statistics that are `null` in the JSON must show "—" not "null" or "0"

### 7.3 Accessibility

- All color-coded type badges must have a text label (not color alone)
- The variable table must be keyboard-navigable
- Modal dialogs must trap focus and support Escape to close

### 7.4 No authentication

The application serves read-only public research data. No login or session management
is implemented. If deployment behind authentication is needed, use a reverse proxy.

---

## 8. Implementation Technology Recommendations

This spec is technology-agnostic for the backend, but the following are well-suited:

**Backend options:**
- Python + FastAPI (recommended): lightweight, async, SQLite via `aiosqlite`, FTS5
  via `sqlite3` stdlib
- Node.js + Fastify: native JSON handling, `better-sqlite3` for synchronous SQLite
- Go + `net/http`: single binary, `modernc.org/sqlite` for cgo-free SQLite

**Frontend:** React + Vite. No SSR required — this is a pure SPA.

**SQLite FTS5** is the only indexing dependency. No Elasticsearch, no Typesense, no
external search service.

---

## 9. File Summary

Files the viewer reads and/or serves:

| File | Where | Used for |
|---|---|---|
| `conversion_summary.csv` | `psychds/` root | Paper/study group discovery |
| `dataset_description.json` | `psychds/<paper_id>/<study_dir>/` | Paper metadata, variables, pipeline status |
| `provenance.json` | `psychds/<paper_id>/<study_dir>/` | File manifest, original paths, provenance |
| `source-*_data.json` | `psychds/<paper_id>/<study_dir>/data/` | Per-file variable context (on-demand) |
| `source-*_data.csv` | `psychds/<paper_id>/<study_dir>/data/` | **Variable downloads only** — streamed into ZIP |
| `data/raw/*` | `psychds/<paper_id>/<study_dir>/data/raw/` | **Paper downloads only** — streamed into ZIP verbatim |
| `analysis/`, `documentation/`, `materials/` | `psychds/<paper_id>/<study_dir>/` | **Paper downloads only** — included in paper ZIP |

**Read for indexing/display** (always parsed): `conversion_summary.csv`,
`dataset_description.json`, `provenance.json`, `source-*_data.json`

**Read for download only** (streamed, never parsed): `source-*_data.csv`, `data/raw/*`,
`analysis/`, `documentation/`, `materials/`

The viewer does NOT read any pipeline intermediate files outside `psychds/`.
No `outputs/`, `data/`, or `ground_truth/` directories from the pipeline are accessed.
